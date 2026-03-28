import json
import logging
import re
import urllib.request
from pathlib import Path

from fastapi import Depends, APIRouter, BackgroundTasks, HTTPException, UploadFile, File

from app.config import settings
from app.schemas.version import KafkaVersionInfo, KafkaDownloadRequest, ConnectPlugin
from app.api.deps import require_admin, require_monitor_or_above
from app.models.user import User

router = APIRouter(prefix="/api/versions", tags=["versions"])

KAFKA_TGZ_PATTERN = re.compile(r"^kafka_(\d+\.\d+)-(\d+\.\d+\.\d+)\.tgz$")
KAFKA_TGZ_LOOSE = re.compile(r"kafka[_-](\d+\.\d+)[_-](\d+\.\d+\.\d+)\.(tgz|tar\.gz)$")


def _load_catalog() -> dict:
    catalog_path = Path(settings.VERSION_CATALOG_PATH)
    if catalog_path.exists():
        return json.loads(catalog_path.read_text())
    return {"versions": []}


@router.get("/kafka", response_model=list[KafkaVersionInfo])
def list_kafka_versions(_: User = Depends(require_monitor_or_above)):
    """List available Kafka versions from local repo + catalog metadata."""
    repo_dir = Path(settings.KAFKA_REPO_DIR)
    catalog = _load_catalog()
    catalog_map = {v["version"]: v for v in catalog.get("versions", [])}

    # Scan repo directory for .tgz files
    found: dict[str, dict] = {}
    if repo_dir.exists():
        for f in repo_dir.glob("*.tgz"):
            match = KAFKA_TGZ_PATTERN.match(f.name)
            if match:
                scala_ver, kafka_ver = match.group(1), match.group(2)
                found[kafka_ver] = {
                    "scala_version": scala_ver,
                    "filename": f.name,
                    "size_mb": round(f.stat().st_size / (1024 * 1024), 1),
                }

    # Merge: catalog entries first, then any extras from disk
    result = []
    seen = set()
    for cat_entry in catalog.get("versions", []):
        ver = cat_entry["version"]
        seen.add(ver)
        disk = found.get(ver)
        result.append(KafkaVersionInfo(
            version=ver,
            scala_version=disk["scala_version"] if disk else settings.KAFKA_SCALA_VERSION,
            filename=disk["filename"] if disk else f"kafka_{settings.KAFKA_SCALA_VERSION}-{ver}.tgz",
            size_mb=disk["size_mb"] if disk else 0,
            available=disk is not None,
            release_date=cat_entry.get("release_date"),
            features=cat_entry.get("features"),
            security_fixes=cat_entry.get("security_fixes"),
            upgrade_notes=cat_entry.get("upgrade_notes"),
        ))

    # Add versions found on disk but not in catalog
    for ver, disk in found.items():
        if ver not in seen:
            result.append(KafkaVersionInfo(
                version=ver,
                scala_version=disk["scala_version"],
                filename=disk["filename"],
                size_mb=disk["size_mb"],
                available=True,
            ))

    return result


@router.get("/kafka/{version}", response_model=KafkaVersionInfo)
def get_kafka_version_detail(version: str, _: User = Depends(require_monitor_or_above)):
    """Get detailed info for a specific Kafka version."""
    all_versions = list_kafka_versions()
    for v in all_versions:
        if v.version == version:
            return v
    raise HTTPException(status_code=404, detail=f"Version {version} not found")


@router.post("/kafka/upload")
async def upload_kafka_binary(file: UploadFile = File(...), _: User = Depends(require_admin)):
    """Upload a Kafka .tgz binary to the local repo.

    Accepts filenames like:
      kafka_2.13-3.7.0.tgz  (exact)
      kafka-2.13-3.7.0.tar.gz  (loose, auto-renamed)
    """
    if not file.filename:
        raise HTTPException(status_code=400, detail="No filename provided")

    # Try exact pattern first
    exact = KAFKA_TGZ_PATTERN.match(file.filename)
    if exact:
        canonical = file.filename
    else:
        # Try loose pattern and auto-rename
        loose = KAFKA_TGZ_LOOSE.search(file.filename)
        if loose:
            scala_ver, kafka_ver = loose.group(1), loose.group(2)
            canonical = f"kafka_{scala_ver}-{kafka_ver}.tgz"
        else:
            raise HTTPException(
                status_code=400,
                detail=f"Invalid filename '{file.filename}'. Expected pattern: kafka_{{scala}}-{{version}}.tgz (e.g. kafka_2.13-3.7.0.tgz)",
            )

    dest = Path(settings.KAFKA_REPO_DIR) / canonical
    dest.parent.mkdir(parents=True, exist_ok=True)
    content = await file.read()
    if len(content) < 1000:
        raise HTTPException(status_code=400, detail="File appears too small to be a valid Kafka binary")
    dest.write_bytes(content)
    size_mb = round(len(content) / (1024 * 1024), 1)
    logging.getLogger("tantor.versions").info(f"Uploaded Kafka binary: {canonical} ({size_mb} MB)")
    return {"filename": canonical, "size_mb": size_mb, "uploaded": True}


@router.get("/connect-plugins", response_model=list[ConnectPlugin])
def list_connect_plugins(_: User = Depends(require_monitor_or_above)):
    """List available Kafka Connect plugin JARs in the repo."""
    plugins_dir = Path(settings.CONNECT_PLUGINS_DIR)
    result = []
    if plugins_dir.exists():
        for f in plugins_dir.glob("*.jar"):
            result.append(ConnectPlugin(
                name=f.stem,
                filename=f.name,
                size_mb=round(f.stat().st_size / (1024 * 1024), 1),
            ))
    return result
