import os
import sys

import paramiko

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

TARGETS = [
    ("router-2", "10.84.118.167", "192.168.48.5", 36, 80),
    ("router-3", "10.84.121.7", "192.168.48.1", 36, 80),
]

password = os.environ["WIRES_PI_PASSWORD"]

for label, pi_host, router_host, channel, bandwidth in TARGETS:
    print(f"=== {label}: {router_host} through {pi_host} ===")
    pi = paramiko.SSHClient()
    pi.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    router = paramiko.SSHClient()
    router.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    try:
        pi.connect(pi_host, username="wiloc", password=password, timeout=10)
        tunnel = pi.get_transport().open_channel(
            "direct-tcpip", (router_host, 22), ("127.0.0.1", 0)
        )
        router.connect(
            router_host,
            username="wiloc",
            password=password,
            sock=tunnel,
            timeout=10,
        )
        command = f"/jffs/csi/setup.sh {channel} {bandwidth} 4 2>&1"
        _, stdout, stderr = router.exec_command(command, timeout=60)
        print(stdout.read().decode(errors="replace"))
        error = stderr.read().decode(errors="replace")
        if error:
            print(error)
    except Exception as exc:
        print(f"{type(exc).__name__}: {exc}")
    finally:
        router.close()
        pi.close()
