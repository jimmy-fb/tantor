import base64
import json
import logging
import uuid
from pathlib import Path

from sqlalchemy.orm import Session

from app.config import settings
from app.models.cluster import Cluster
from app.models.host import Host
from app.models.service import Service
from app.services.ansible_runner import ansible_runner
from app.services.config_generator import config_generator
from app.services.crypto import decrypt

logger = logging.getLogger("tantor.deployer")


def _sync_local_kafka_ui(db: Session):
    """Sync all running clusters to the local kafka-ui config."""
    try:
        import subprocess
        import yaml
        from pathlib import Path

        config_path = Path("/opt/tantor/kafka-ui/config.yml")
        if not config_path.parent.exists():
            return  # kafka-ui not installed locally

        running_clusters = db.query(Cluster).filter(Cluster.state == "running").all()
        hosts_map = {h.id: h for h in db.query(Host).all()}

        kafka_clusters = []
        for c in running_clusters:
            c_cfg = json.loads(c.config_json) if c.config_json else {}
            port = c_cfg.get("listener_port", 9092)
            broker_svcs = db.query(Service).filter(
                Service.cluster_id == c.id,
                Service.role.in_(["broker", "broker_controller"]),
            ).all()
            bootstrap = []
            for s in broker_svcs:
                h = hosts_map.get(s.host_id)
                if h:
                    bootstrap.append(f"{h.ip_address}:{port}")
            if bootstrap:
                kafka_clusters.append({
                    "name": c.name,
                    "bootstrapServers": ",".join(bootstrap),
                })

        config = {
            "kafka": {"clusters": kafka_clusters},
            "dynamic": {"config": {"enabled": True}},
            "server": {"port": 8989, "servlet": {"context-path": "/kafka-ui"}},
            "auth": {"type": "DISABLED"},
            "logging": {"level": {"root": "WARN", "io.kafbat.ui": "INFO"}},
        }
        config_path.write_text(yaml.dump(config, default_flow_style=False))
        subprocess.run(["systemctl", "restart", "tantor-kafka-ui"], capture_output=True, timeout=10)
    except Exception as e:
        logger.warning("Failed to sync local kafka-ui: %s", e)

# In-memory task tracking
_deployment_tasks: dict[str, dict] = {}


def get_task(task_id: str) -> dict | None:
    return _deployment_tasks.get(task_id)


def init_task(task_id: str, cluster_id: str):
    _deployment_tasks[task_id] = {
        "task_id": task_id,
        "cluster_id": cluster_id,
        "status": "running",
        "logs": [],
    }


def _log(task_id: str, message: str):
    task = _deployment_tasks.get(task_id)
    if task:
        task["logs"].append(message)
    if message.strip():
        logger.info("[%s] %s", task_id[:8], message)


def _build_service_info(svc: Service, host: Host, cluster_config: dict) -> dict:
    return {
        "id": svc.id,
        "host_id": svc.host_id,
        "ip_address": host.ip_address,
        "port": host.ssh_port,
        "username": host.username,
        "auth_type": host.auth_type,
        "encrypted_credential": host.encrypted_credential,
        "role": svc.role,
        "node_id": svc.node_id,
        "controller_port": cluster_config.get("controller_port", 9093),
    }


def deploy_cluster(cluster_id: str, task_id: str, db: Session):
    """Deploy a cluster using Ansible. Called as a background task."""
    cluster = db.query(Cluster).filter(Cluster.id == cluster_id).first()
    if not cluster:
        _log(task_id, "ERROR: Cluster not found")
        _deployment_tasks[task_id]["status"] = "error"
        return

    services = db.query(Service).filter(Service.cluster_id == cluster_id).all()
    hosts = {h.id: h for h in db.query(Host).all()}
    cluster_config = json.loads(cluster.config_json) if cluster.config_json else {}

    # ── Pre-flight validation ──────────────────────────────────────
    _log(task_id, "Running pre-flight checks...")

    # Check 1: Node IDs must be unique within the cluster
    node_ids = [svc.node_id for svc in services]
    if len(node_ids) != len(set(node_ids)):
        _log(task_id, f"ERROR: Duplicate node_ids detected: {node_ids}")
        _deployment_tasks[task_id]["status"] = "error"
        cluster.state = "error"
        db.commit()
        return

    # Check 2: All hosts must exist and be reachable
    offline_hosts = []
    for svc in services:
        host = hosts.get(svc.host_id)
        if not host:
            _log(task_id, f"ERROR: Host {svc.host_id} not found for service {svc.role}")
            _deployment_tasks[task_id]["status"] = "error"
            cluster.state = "error"
            db.commit()
            return
        if host.status != "online":
            offline_hosts.append(f"{host.hostname} ({host.ip_address})")
            _log(task_id, f"WARNING: Host {host.hostname} ({host.ip_address}) status is '{host.status}', not 'online'")

    if offline_hosts:
        _log(task_id, f"WARNING: {len(offline_hosts)} host(s) are offline: {', '.join(offline_hosts)}. Deployment may fail.")

    # Check 3: KRaft mode needs at least one controller
    if cluster.mode == "kraft":
        controller_roles = {svc.role for svc in services} & {"controller", "broker_controller"}
        if not controller_roles:
            _log(task_id, "ERROR: KRaft mode requires at least one controller or broker_controller role")
            _deployment_tasks[task_id]["status"] = "error"
            cluster.state = "error"
            db.commit()
            return

    # Check 4: Replication factor can't exceed broker count
    broker_count = sum(1 for svc in services if svc.role in ("broker", "broker_controller"))
    rf = cluster_config.get("replication_factor", 3)
    if rf > broker_count:
        _log(task_id, f"WARNING: replication_factor={rf} exceeds broker count={broker_count}. Adjusting to {broker_count}.")
        cluster_config["replication_factor"] = broker_count

    _log(task_id, f"Pre-flight checks passed: {len(services)} services, {broker_count} brokers, RF={cluster_config.get('replication_factor', 1)}")

    all_service_infos = []
    for svc in services:
        host = hosts.get(svc.host_id)
        if host:
            all_service_infos.append(_build_service_info(svc, host, cluster_config))

    cluster.state = "deploying"
    db.commit()

    try:
        _run_ansible_deployment(task_id, cluster, services, hosts, all_service_infos, cluster_config, db)
    except Exception as e:
        logger.exception("Deployment failed for cluster %s", cluster_id)
        _log(task_id, f"FATAL ERROR: {e}")
        _deployment_tasks[task_id]["status"] = "error"
        cluster.state = "error"
        db.commit()


def _run_ansible_deployment(
    task_id: str,
    cluster: Cluster,
    services: list[Service],
    hosts: dict[str, Host],
    all_service_infos: list[dict],
    cluster_config: dict,
    db: Session,
):
    kafka_version = cluster.kafka_version
    scala_version = settings.KAFKA_SCALA_VERSION
    kafka_tgz = f"kafka_{scala_version}-{kafka_version}.tgz"
    kafka_tgz_path = Path(settings.KAFKA_REPO_DIR) / kafka_tgz

    # Check binary exists in airgapped repo; auto-download if missing
    if not kafka_tgz_path.exists():
        _log(task_id, f"Kafka binary not found locally. Downloading {kafka_tgz}...")
        kafka_tgz_path.parent.mkdir(parents=True, exist_ok=True)
        download_url = f"https://downloads.apache.org/kafka/{kafka_version}/{kafka_tgz}"
        archive_url = f"https://archive.apache.org/dist/kafka/{kafka_version}/{kafka_tgz}"
        # Try primary, then archive
        import urllib.request
        try:
            urllib.request.urlretrieve(download_url, str(kafka_tgz_path))
        except Exception:
            _log(task_id, f"Primary mirror failed, trying archive...")
            try:
                urllib.request.urlretrieve(archive_url, str(kafka_tgz_path))
            except Exception as dl_err:
                _log(task_id, f"ERROR: Failed to download Kafka binary: {dl_err}")
                _log(task_id, f"Place {kafka_tgz} in {settings.KAFKA_REPO_DIR}/ or upload via the Kafka Versions page")
                _deployment_tasks[task_id]["status"] = "error"
                cluster.state = "error"
                db.commit()
                return
        _log(task_id, f"Downloaded {kafka_tgz} ({kafka_tgz_path.stat().st_size // (1024*1024)} MB)")

    _log(task_id, f"Using local Kafka binary: {kafka_tgz} ({kafka_tgz_path.stat().st_size // (1024*1024)} MB)")

    # Generate or reuse KRaft cluster UUID
    cluster_uuid = ""
    if cluster.mode == "kraft":
        if cluster.cluster_uuid:
            cluster_uuid = cluster.cluster_uuid
            _log(task_id, f"Reusing KRaft cluster ID: {cluster_uuid}")
        else:
            cluster_uuid = base64.urlsafe_b64encode(uuid.uuid4().bytes).decode().rstrip("=")
            cluster.cluster_uuid = cluster_uuid
            db.commit()
            _log(task_id, f"Generated KRaft cluster ID: {cluster_uuid}")

    # Prepare Ansible workspace
    work_dir = ansible_runner.prepare_workspace(task_id)
    _log(task_id, "Prepared Ansible workspace")

    # Build service dicts with decrypted credentials
    svc_dicts = []
    for svc in services:
        host = hosts.get(svc.host_id)
        if not host:
            continue
        svc_dicts.append({
            "ip_address": host.ip_address,
            "port": host.ssh_port,
            "username": host.username,
            "auth_type": host.auth_type,
            "credential": decrypt(host.encrypted_credential),
            "role": svc.role,
            "node_id": svc.node_id,
        })

    # Generate Ansible inventory
    inv_path = ansible_runner.generate_inventory(work_dir, svc_dicts)
    ansible_runner.generate_ansible_cfg(work_dir)
    _log(task_id, "Generated Ansible inventory and config")

    # Pre-render Kafka configs using existing ConfigGenerator
    _log(task_id, "Generating Kafka configurations...")
    configs = {}
    systemd_units = {}

    for svc_info in all_service_infos:
        host = hosts.get(svc_info["host_id"])
        if not host:
            continue

        ip = host.ip_address
        nid = svc_info["node_id"]
        role = svc_info["role"]

        config_content = config_generator.generate_config_for_service(
            svc_info, all_service_infos, cluster_config
        )

        if role in ("broker", "broker_controller", "controller"):
            config_name = f"{ip}_{nid}_server.properties"
            remote_config = f"{settings.KAFKA_INSTALL_DIR}/config/server.properties"
        elif role == "ksqldb":
            config_name = f"{ip}_{nid}_ksql-server.properties"
            remote_config = f"{settings.KSQLDB_INSTALL_DIR}/config/ksql-server.properties"
        elif role == "kafka_connect":
            config_name = f"{ip}_{nid}_connect-distributed.properties"
            remote_config = f"{settings.KAFKA_INSTALL_DIR}/config/connect-distributed.properties"
        elif role == "zookeeper":
            config_name = f"{ip}_{nid}_zookeeper.properties"
            remote_config = f"{settings.KAFKA_INSTALL_DIR}/config/zookeeper.properties"
        else:
            config_name = f"{ip}_{nid}_server.properties"
            remote_config = f"{settings.KAFKA_INSTALL_DIR}/config/server.properties"

        configs[config_name] = config_content

        # Generate systemd unit
        service_type_map = {
            "broker": "kafka", "broker_controller": "kafka",
            "controller": "kafka-kraft-controller",
            "ksqldb": "ksqldb", "kafka_connect": "kafka-connect",
            "zookeeper": "kafka",
        }
        service_type = service_type_map.get(role, "kafka")
        unit_content = config_generator.generate_systemd_unit(
            service_type, remote_config, settings.KAFKA_INSTALL_DIR, settings.KSQLDB_INSTALL_DIR
        )
        unit_name = f"{ip}_{nid}_{service_type}.service"
        systemd_units[unit_name] = unit_content

    configs_dir = ansible_runner.write_config_files(work_dir, configs)
    systemd_dir = ansible_runner.write_systemd_units(work_dir, systemd_units)
    _log(task_id, f"Generated {len(configs)} configs and {len(systemd_units)} systemd units")

    # Determine which role groups exist
    roles_present = {svc.role for svc in services}
    has_brokers = bool(roles_present & {"broker", "broker_controller"})
    has_controllers = "controller" in roles_present
    has_ksqldb = "ksqldb" in roles_present
    has_connect = "kafka_connect" in roles_present

    # Resolve ksqlDB binary if needed
    ksqldb_tgz = ""
    ksqldb_tgz_path = ""
    if has_ksqldb:
        ksqldb_repo = Path(settings.KSQLDB_REPO_DIR)
        ksqldb_files = sorted(ksqldb_repo.glob("ksqldb-*.tgz")) if ksqldb_repo.exists() else []
        if ksqldb_files:
            ksqldb_tgz_path = str(ksqldb_files[-1])  # latest version
            ksqldb_tgz = ksqldb_files[-1].name
            _log(task_id, f"Using ksqlDB binary: {ksqldb_tgz} ({ksqldb_files[-1].stat().st_size // (1024*1024)} MB)")
        else:
            _log(task_id, "WARNING: No ksqlDB binary found in repo. ksqlDB deployment may fail.")

    # Generate playbook
    playbook_path = ansible_runner.generate_playbook(work_dir, "deploy_kafka.yml.j2", {
        "kafka_install_dir": settings.KAFKA_INSTALL_DIR,
        "kafka_binary_filename": kafka_tgz,
        "kafka_binary_local_path": str(kafka_tgz_path),
        "kafka_data_dir": cluster_config.get("log_dirs", settings.KAFKA_DATA_DIR),
        "kafka_log_dir": settings.KAFKA_LOG_DIR,
        "cluster_uuid": cluster_uuid,
        "cluster_mode": cluster.mode,
        "cluster_config": cluster_config,
        "configs_dir": str(configs_dir),
        "systemd_dir": str(systemd_dir),
        "has_brokers": has_brokers,
        "has_controllers": has_controllers,
        "has_ksqldb": has_ksqldb,
        "has_connect": has_connect,
        "ksqldb_install_dir": settings.KSQLDB_INSTALL_DIR,
        "ksqldb_binary_filename": ksqldb_tgz,
        "ksqldb_binary_local_path": ksqldb_tgz_path,
    })
    _log(task_id, "Generated Ansible playbook")

    # Run playbook with real-time streaming
    _log(task_id, "")
    _log(task_id, "=" * 60)
    _log(task_id, "Starting Ansible playbook execution...")
    _log(task_id, "=" * 60)
    _log(task_id, "")

    exit_code = ansible_runner.run_playbook(
        work_dir, playbook_path, inv_path,
        log_callback=lambda line: _log(task_id, line),
    )

    # Update statuses
    if exit_code == 0:
        for svc in services:
            svc.status = "running"
        cluster.state = "running"
        _deployment_tasks[task_id]["status"] = "completed"
        _log(task_id, "")
        _log(task_id, "Deployment completed successfully!")

        # Auto-sync local kafka-ui config with the new cluster
        try:
            _sync_local_kafka_ui(db)
            _log(task_id, "Kafka UI synced with new cluster configuration")
        except Exception as e:
            _log(task_id, f"NOTE: Could not auto-sync Kafka UI: {e}")
    else:
        cluster.state = "error"
        _deployment_tasks[task_id]["status"] = "completed_with_errors"
        _log(task_id, "")
        _log(task_id, f"Deployment failed (ansible exit code: {exit_code})")
    db.commit()

    # Cleanup
    ansible_runner.cleanup_workspace(work_dir)
    _log(task_id, "Workspace cleaned up")
