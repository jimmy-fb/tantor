import io
from contextlib import contextmanager

import paramiko

from app.services.crypto import decrypt


class SSHManager:
    @staticmethod
    @contextmanager
    def connect(ip_address: str, port: int, username: str, auth_type: str, encrypted_credential: str):
        """Context manager that yields a connected Paramiko SSHClient."""
        client = paramiko.SSHClient()
        client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        credential = decrypt(encrypted_credential)

        try:
            if auth_type == "password":
                client.connect(
                    hostname=ip_address,
                    port=port,
                    username=username,
                    password=credential,
                    timeout=15,
                    look_for_keys=False,
                    allow_agent=False,
                )
            else:
                pkey = paramiko.RSAKey.from_private_key(io.StringIO(credential))
                client.connect(
                    hostname=ip_address,
                    port=port,
                    username=username,
                    pkey=pkey,
                    timeout=15,
                    look_for_keys=False,
                    allow_agent=False,
                )
            yield client
        finally:
            client.close()

    @staticmethod
    def exec_command(client: paramiko.SSHClient, command: str, timeout: int = 30) -> tuple[int, str, str]:
        """Execute a command and return (exit_code, stdout, stderr)."""
        stdin, stdout, stderr = client.exec_command(command, timeout=timeout)
        exit_code = stdout.channel.recv_exit_status()
        return exit_code, stdout.read().decode().strip(), stderr.read().decode().strip()

    @staticmethod
    def upload_content(client: paramiko.SSHClient, content: str, remote_path: str):
        """Upload string content to a remote file via SFTP."""
        sftp = client.open_sftp()
        try:
            with sftp.file(remote_path, "w") as f:
                f.write(content)
        finally:
            sftp.close()

    @staticmethod
    def test_connection(ip_address: str, port: int, username: str, auth_type: str, encrypted_credential: str) -> tuple[bool, str, str | None]:
        """Test SSH connectivity. Returns (success, message, os_info)."""
        try:
            with SSHManager.connect(ip_address, port, username, auth_type, encrypted_credential) as client:
                _, os_info, _ = SSHManager.exec_command(client, "cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2 | tr -d '\"'")
                return True, "Connection successful", os_info or None
        except paramiko.AuthenticationException:
            return False, "Authentication failed. Check credentials.", None
        except paramiko.SSHException as e:
            return False, f"SSH error: {e}", None
        except TimeoutError:
            return False, "Connection timed out", None
        except Exception as e:
            return False, f"Connection failed: {e}", None


ssh_manager = SSHManager()
