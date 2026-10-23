#!/usr/bin/env bash
# Prints the IP address of every Android TV / Mi TV on your Wi-Fi: devices answering on the Android TV remote
# port (6466) or with ADB debugging on (5555). Works on macOS and Linux with python3.
# Usage: scripts/find-tv.sh
set -u
exec python3 - "$@" <<'PY'
import socket, sys
from concurrent.futures import ThreadPoolExecutor

def my_ip():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 80))          # no packet is sent; this just picks the Wi-Fi interface
        return s.getsockname()[0]
    except OSError:
        return None
    finally:
        s.close()

ip = my_ip()
if not ip:
    sys.exit("Could not work out this computer's Wi-Fi address. Are you connected to Wi-Fi?")
base = ip.rsplit(".", 1)[0]

def check(host):
    for port in (6466, 5555):
        try:
            with socket.create_connection((host, port), timeout=1.5):
                return host
        except OSError:
            pass
    return None

found = []
for attempt in range(2):                     # a sleeping device's Wi-Fi can miss the first knock
    with ThreadPoolExecutor(max_workers=128) as ex:
        found = [h for h in ex.map(check, [f"{base}.{i}" for i in range(1, 255)]) if h and h != ip]
    if found:
        break
for h in found:
    print(h)
if not found:
    sys.stderr.write("No TV answered. Make sure the TV is on (not in standby) and on this Wi-Fi.\n")
    sys.exit(1)
PY
