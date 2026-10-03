import os
from datetime import datetime, timezone
from pathlib import Path

import paramiko


ROOT = Path(__file__).resolve().parents[1]
LOCAL_CONFIG = ROOT / "nexmon_firmware" / "csi" / "configcsi.sh"
PASSWORD = os.environ["WIRES_PI_PASSWORD"]
TARGETS = (
    ("router-2", "10.84.118.167", "192.168.48.5", 36, 80),
    ("router-3", "10.84.121.7", "192.168.48.1", 36, 80),
)


for name, pi_host, router_host, channel, bandwidth in TARGETS:
    print(f"=== {name} ===")
    pi = paramiko.SSHClient()
    pi.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    router = paramiko.SSHClient()
    router.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    try:
        pi.connect(pi_host, username="wiloc", password=PASSWORD, timeout=10)
        tunnel = pi.get_transport().open_channel(
            "direct-tcpip", (router_host, 22), ("127.0.0.1", 0)
        )
        router.connect(
            router_host,
            username="wiloc",
            password=PASSWORD,
            sock=tunnel,
            timeout=10,
        )
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        temporary = f"/jffs/csi/configcsi.sh.new-{stamp}"
        backup = f"/jffs/csi/configcsi.sh.bak-{stamp}"
        stdin, stdout, stderr = router.exec_command(
            f"cat > {temporary}", timeout=30
        )
        stdin.write(LOCAL_CONFIG.read_text(encoding="utf-8"))
        stdin.channel.shutdown_write()
        upload_output = stdout.read().decode(errors="replace")
        upload_error = stderr.read().decode(errors="replace")
        upload_status = stdout.channel.recv_exit_status()
        if upload_status:
            raise RuntimeError(
                f"router upload failed ({upload_status})\n"
                f"{upload_output}{upload_error}"
            )
        command = (
            f"cp /jffs/csi/configcsi.sh {backup} && "
            f"mv {temporary} /jffs/csi/configcsi.sh && "
            "chmod 755 /jffs/csi/configcsi.sh && "
            f"/jffs/csi/setup.sh {channel} {bandwidth} 4 2>&1"
        )
        _, stdout, stderr = router.exec_command(command, timeout=90)
        output = stdout.read().decode(errors="replace")
        error = stderr.read().decode(errors="replace")
        status = stdout.channel.recv_exit_status()
        if status:
            raise RuntimeError(f"router setup failed ({status})\n{output}{error}")
        print(output)
        print(f"backup={backup}")
    finally:
        router.close()
        pi.close()
