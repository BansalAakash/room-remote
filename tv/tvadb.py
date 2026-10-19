#!/usr/bin/env python3
"""ADB over Wi-Fi helpers for the Mi TV (screenshots, force-stop).

  tvadb.py wait            wait for the TV to come back, connect, authorise
  tvadb.py shot [out.png]  screenshot of the TV screen
  tvadb.py stop <package>  force-stop an app (e.g. com.netflix.ninja)

The TV's MAC is used to find it again if DHCP gives it a new address.
"""
import re
import subprocess
import socket
import sys
import time
from pathlib import Path

from adb_shell.adb_device import AdbDeviceTcp
from adb_shell.auth.keygen import keygen
from adb_shell.auth.sign_pythonrsa import PythonRSASigner

DIR = Path(__file__).parent
KEY = DIR / "adbkey"
MAC = "a6:bb:d1:d9:6f:3d"
PORT = 5555


def find_tv():
    base = subprocess.run(["ipconfig", "getifaddr", "en0"], capture_output=True, text=True).stdout.strip().rsplit(".", 1)[0]
    procs = [subprocess.Popen(["ping", "-c1", "-t1", f"{base}.{i}"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) for i in range(2, 254)]
    for p in procs:
        p.wait()
    arp = subprocess.run(["arp", "-an"], capture_output=True, text=True).stdout
    m = re.search(r"\(([\d.]+)\) at " + MAC, arp, re.I)
    return m.group(1) if m else None


def port_open(ip):
    s = socket.socket()
    s.settimeout(1.5)
    try:
        s.connect((ip, PORT))
        return True
    except OSError:
        return False
    finally:
        s.close()


def connect(ip):
    if not KEY.exists():
        keygen(str(KEY))
    priv = open(KEY).read()
    pub = open(str(KEY) + ".pub").read()
    signer = PythonRSASigner(pub, priv)
    dev = AdbDeviceTcp(ip, PORT, default_transport_timeout_s=15)
    dev.connect(rsa_keys=[signer], auth_timeout_s=60)
    return dev


def current_ip(deadline_s=0):
    end = time.time() + deadline_s
    while True:
        ip = find_tv()
        if ip and port_open(ip):
            return ip
        if time.time() >= end:
            return ip
        time.sleep(5)


def main():
    cmd = sys.argv[1]
    if cmd == "wait":
        ip = current_ip(540)
        print("TV at", ip, "| adb port open:", bool(ip and port_open(ip)), flush=True)
        if ip and port_open(ip):
            dev = connect(ip)
            print("connected:", dev.shell("getprop ro.product.model").strip(), flush=True)
    else:
        ip = current_ip(30)
        dev = connect(ip)
        if cmd == "shot":
            out = sys.argv[2] if len(sys.argv) > 2 else str(DIR / "screen.png")
            dev.shell("screencap -p /sdcard/s.png")
            dev.pull("/sdcard/s.png", out)
            print(out)
        elif cmd == "stop":
            dev.shell(f"am force-stop {sys.argv[2]}")
            print("stopped", sys.argv[2])


if __name__ == "__main__":
    main()
