#!/usr/bin/env python3
"""Local control of Tuya plugs.  room.py list | status|on|off <name> | on|off <name> [--wait SECS]

Devices live in devices.json (id, key, ip, optional version, default 3.3)."""
import base64, fcntl, json, os, socket, sys, time
import tinytuya

HERE = os.path.dirname(os.path.abspath(__file__))


def load():
    path = os.path.join(HERE, "devices.json")
    if not os.path.exists(path):
        sys.exit("No plugs set up yet. Run the Tuya wizard, then `room.py import` (see the README).")
    with open(path) as f:
        return json.load(f)


def connect(d):
    dev = tinytuya.OutletDevice(d["id"], d["ip"], d["key"], version=d.get("version", 3.3))
    dev.set_socketTimeout(4)
    dev.set_socketRetryLimit(1)
    return dev


def wake(d):
    """A plug that has sat idle ignores its first handshake; a bare TCP connect first gets it listening again.
    False when nothing answers at all, so the caller can give up on the local route quickly."""
    try:
        socket.create_connection((d["ip"], 6668), timeout=2).close()
    except OSError:
        return False
    time.sleep(0.5)
    return True


def inching_seconds(raw):
    """The plug's "inching" auto-off (dp 44): 3 bytes, a flag then the on-time in seconds. 0 when unset."""
    try:
        data = base64.b64decode(raw or "")
    except Exception:
        return 0
    return int.from_bytes(data[1:3], "big") if len(data) >= 3 and data[0] == 1 else 0


RELAY_TO_CLOUD = {"memory": "last", "on": "power_on", "off": "power_off"}
RELAY_FROM_CLOUD = {v: k for k, v in RELAY_TO_CLOUD.items()}


def local(cmd, argv, d):
    """Run one local command and read the plug back. Returns the plug's dps, or None if it never answered."""
    for _ in range(2):
        if not wake(d):
            continue
        dev = connect(d)
        r = dev.status()  # probe first, so a command is never sent down a dead connection
        if "dps" in r:
            if cmd == "status":
                return r["dps"]
            if cmd == "on":
                dev.turn_on()
            elif cmd == "off":
                dev.turn_off()
            elif cmd == "for":  # switch now, flip back after <seconds> (the plug's own countdown, dp 9)
                dev.set_value(1, argv[2] == "on")
                time.sleep(0.5)
                dev.set_value(9, int(argv[3]))
            elif cmd == "cancel":
                dev.set_value(9, 0)
            elif cmd == "relay":  # what the plug does when power returns (dp 38)
                dev.set_value(38, argv[2])
            time.sleep(1)
            r = dev.status()
            if "dps" in r:
                return r["dps"]
        dev.close()
        time.sleep(1)
    return None


def via_cloud(cmd, argv, d):
    """Fallback when the plug's Wi-Fi drops local connections: the same commands through Tuya's cloud."""
    c = cloud()
    commands = {"on": [("switch_1", True)], "off": [("switch_1", False)], "cancel": [("countdown_1", 0)],
                "for": [("switch_1", argv[2] == "on"), ("countdown_1", int(argv[3]))] if cmd == "for" else [],
                "relay": [("relay_status", RELAY_TO_CLOUD.get(argv[2] if cmd == "relay" else "", "last"))]}.get(cmd, [])
    for code, value in commands:
        r = c.cloudrequest(f"/v1.0/devices/{d['id']}/commands", action="POST", post={"commands": [{"code": code, "value": value}]})
        if not r.get("success"):
            sys.exit(f"error: {r.get('msg', r)}")
        time.sleep(0.5)
    if commands:
        time.sleep(1)
    r = c.cloudrequest(f"/v1.0/devices/{d['id']}/status")
    if not r.get("success"):
        sys.exit(f"error: {r.get('msg', r)}")
    status = {item["code"]: item["value"] for item in r["result"]}
    return {"1": status.get("switch_1"), "9": status.get("countdown_1", 0), "38": RELAY_FROM_CLOUD.get(status.get("relay_status")),
            "44": status.get("switch_inching", "")}


TZ_ID, TZ_OFFSET = "Asia/Kolkata", "+05:30"
TIMER_CATEGORY = "category_power"


def cloud():
    os.chdir(HERE)  # tinytuya.json (cloud keys) lives next to this file
    if not os.path.exists(os.path.join(HERE, "tinytuya.json")):
        sys.exit("error: no cloud keys. Schedules and history need a Tuya developer project (see the README).")
    return tinytuya.Cloud()


def timer_call(c, dev, method, path="", body=None):
    r = c.cloudrequest(f"/v1.0/devices/{dev['id']}/timers{path}", action=method, post=body)
    if not r.get("success"):
        sys.exit(f"error: {r.get('msg', r)}")
    return r.get("result")


def list_timers(c, dev):
    out = []
    for cat in timer_call(c, dev, "GET") or []:
        for g in cat.get("groups", []):
            for t in g.get("timers", []):
                if t.get("status") == 2:
                    continue
                fn = (t.get("functions") or [{}])[0]
                out.append({"group": g["id"], "category": cat["category"]["category"], "time": t["time"],
                            "loops": t["loops"], "on": bool(fn.get("value")), "code": fn.get("code", "switch_1"),
                            "enabled": t["status"] == 1})
    return sorted(out, key=lambda t: t["time"])


def timer_body(category, loops, time_, code, on):
    return {"category": category, "loops": loops, "time_zone": TZ_OFFSET, "timezone_id": TZ_ID,
            "instruct": [{"time": time_, "functions": [{"code": code, "value": on}]}]}


def timers_main(cmd, name, args, dev):
    """Schedules live in Tuya's cloud, the same ones the Smart Life app shows."""
    c = cloud()
    if cmd == "timers":
        print(json.dumps({"name": name, "timers": list_timers(c, dev)}))
        return
    if cmd == "timer-add":  # name HH:MM on|off [loops]
        time_, on = args[0], args[1] == "on"
        loops = args[2] if len(args) > 2 else "1111111"
        r = timer_call(c, dev, "POST", "", timer_body(TIMER_CATEGORY, loops, time_, "switch_1", on))
    else:
        group = args[0]
        cur = next((t for t in list_timers(c, dev) if t["group"] == group), None)
        if not cur:
            sys.exit("error: no such timer")
        base = f"/categories/{cur['category']}/groups/{group}"
        if cmd == "timer-enable":
            r = timer_call(c, dev, "PUT", base + "/status", {"value": "1" if args[1] == "1" else "0"})
        elif cmd == "timer-del":
            r = timer_call(c, dev, "DELETE", base)
        else:  # timer-set group HH:MM on|off [loops]
            loops = args[3] if len(args) > 3 else cur["loops"]
            body = timer_body(cur["category"], loops, args[1], cur["code"], args[2] == "on")
            r = timer_call(c, dev, "PUT", f"/groups/{group}", body)
            if not cur["enabled"]:
                timer_call(c, dev, "PUT", base + "/status", {"value": "0"})
    print(json.dumps({"name": name, "ok": True, "result": r}))


def log_main(name, args, dev):
    """room.py log <name> [hours] [--all]: the plug's history from Tuya's cloud, oldest first. Switch changes only unless --all."""
    hours = next((float(a) for a in args if a.replace(".", "", 1).isdigit()), 24.0)
    c = cloud()
    end = int(time.time() * 1000)
    query = {"type": "7", "start_time": end - int(hours * 3600 * 1000), "end_time": end, "size": 100}
    events = []
    for _ in range(30):  # page backwards by time: the API's own row-key paging repeats itself
        r = c.cloudrequest(f"/v1.0/devices/{dev['id']}/logs", query=query)
        if not r.get("success"):
            sys.exit(f"error: {r.get('msg', r)}")
        result = r["result"]
        page = result.get("logs", [])
        events += page
        if not result.get("has_next") or not page:
            break
        query["end_time"] = min(e["event_time"] for e in page) - 1
    seen = set()
    events = [e for e in events if (key := (e["event_time"], e["code"], str(e["value"]))) not in seen and not seen.add(key)]
    events.sort(key=lambda e: e["event_time"])
    out, last = [], None
    for e in events:
        if "--all" not in args:
            if e["code"] != "switch_1":
                continue
            if str(e["value"]).lower() == last:  # the plug re-reports its state; show real changes only
                continue
            last = str(e["value"]).lower()
        when = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(e["event_time"] / 1000))
        value = {"true": "ON", "false": "OFF"}.get(str(e["value"]).lower(), e["value"]) if e["code"] == "switch_1" else e["value"]
        out.append({"time": when, "code": e["code"], "value": value})
    if "--json" in args:
        print(json.dumps({"name": name, "events": out}))
    else:
        for e in out:
            print(f"{e['time']}  {e['code']:<14} {e['value']}")


# --- Adding plugs without a developer account: sign in by scanning a QR code with the Smart Life app (Tuya's device-sharing login).
SHARING_CLIENT_ID, SHARING_SCHEMA = "HA_3y9q4ak7g4ephrvke", "haauthorize"
LOGIN_FILE, SESSION_FILE = os.path.join(HERE, ".login.json"), os.path.join(HERE, "tuya_session.json")


def write_private(path, data):
    with open(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as f:
        json.dump(data, f, indent=2)


def login_start(args):
    """room.py login-start <user-code>: prints the text to show as a QR code. The user code is in Smart Life: Me, Settings, Account and Security."""
    from tuya_sharing import LoginControl
    if not args:
        sys.exit("usage: room.py login-start <user-code>")
    r = LoginControl().qr_code(SHARING_CLIENT_ID, SHARING_SCHEMA, args[0].strip())
    if not r.get("success"):
        sys.exit("error: that user code was not accepted. Check it in Smart Life and try again.")
    token = r["result"]["qrcode"]
    write_private(LOGIN_FILE, {"user_code": args[0].strip(), "token": token})
    print(json.dumps({"qr": f"tuyaSmart--qrLogin?token={token}"}))


def login_poll():
    """room.py login-poll: {"status": "waiting"} until the QR code has been scanned and approved, then {"status": "ok"}."""
    from tuya_sharing import LoginControl
    if not os.path.exists(LOGIN_FILE):
        sys.exit("error: start the sign-in first")
    pending = json.load(open(LOGIN_FILE))
    ok, result = LoginControl().login_result(pending["token"], SHARING_CLIENT_ID, pending["user_code"])
    if not ok:
        print(json.dumps({"status": "waiting"}))
        return
    write_private(SESSION_FILE, {
        "user_code": pending["user_code"], "terminal_id": result["terminal_id"], "endpoint": result["endpoint"],
        "token": {k: result[k] for k in ("t", "uid", "expire_time", "access_token", "refresh_token")}})
    os.remove(LOGIN_FILE)
    print(json.dumps({"status": "ok"}))


def sharing_manager():
    from tuya_sharing import Manager
    if not os.path.exists(SESSION_FILE):
        sys.exit("error: not signed in")
    session = json.load(open(SESSION_FILE))
    manager = Manager(SHARING_CLIENT_ID, session["user_code"], session["terminal_id"], session["endpoint"], session["token"])
    try:
        manager.update_device_cache()
    except Exception:
        sys.exit("error: the sign-in expired. Sign in again.")
    return manager


def slug(text):
    import re
    return re.sub(r"[^a-z0-9]+", "_", text.lower()).strip("_") or "plug"


def discover_main():
    """room.py discover: the devices on the signed-in Smart Life account (never prints keys)."""
    manager = sharing_manager()
    have = {d["id"] for d in (json.load(open(os.path.join(HERE, "devices.json"))) if os.path.exists(os.path.join(HERE, "devices.json")) else {}).values()}
    devices = [{"id": d.id, "name": d.name, "product": d.product_name, "category": d.category, "online": bool(d.online), "added": d.id in have}
               for d in manager.device_map.values() if not d.sub]
    print(json.dumps({"devices": devices}))


def add_device_main(args):
    """room.py add-device <id> [title]: finds the plug on this network and saves it, with its local key, to devices.json."""
    manager = sharing_manager()
    device = manager.device_map.get(args[0]) if args else None
    if not device:
        sys.exit("error: no such device on the account")
    found = {v.get("gwId"): (ip, v.get("version")) for ip, v in tinytuya.deviceScan(False, 20).items()}
    if device.id not in found:
        sys.exit("error: can't see that plug on this network. Is it on, and is this Mac on the same Wi-Fi?")
    ip, version = found[device.id]
    path = os.path.join(HERE, "devices.json")
    devices = json.load(open(path)) if os.path.exists(path) else {}
    title = " ".join(args[1:]) or device.name
    name, n = slug(title), 2
    while name in devices and devices[name]["id"] != device.id:
        name, n = f"{slug(title)}_{n}", n + 1
    entry = {"id": device.id, "key": device.local_key, "ip": ip, "title": title}
    if str(version) != "3.3":
        entry["version"] = float(version)
    devices[name] = entry
    write_private(path, devices)
    print(json.dumps({"ok": True, "name": name, "ip": ip}))


def remove_device_main(args):
    """room.py remove-device <name>: forgets a plug in this app. It stays on the Smart Life account."""
    path = os.path.join(HERE, "devices.json")
    devices = json.load(open(path)) if os.path.exists(path) else {}
    if not args or args[0] not in devices:
        sys.exit("error: no such plug")
    del devices[args[0]]
    write_private(path, devices)
    print(json.dumps({"ok": True, "removed": args[0]}))


def import_main(args):
    """room.py import [wizard-folder]: turn the output of `python -m tinytuya wizard` (run in that folder) into devices.json."""
    import re
    folder = os.path.abspath(args[0]) if args else os.path.join(HERE, "wizard")
    wizard = json.load(open(os.path.join(folder, "devices.json")))
    found = {}
    snapshot = os.path.join(folder, "snapshot.json")
    if os.path.exists(snapshot):
        found = {d["id"]: d for d in json.load(open(snapshot)).get("devices", [])}
    if not found:
        print("Scanning the network for the plugs (about 20 s)...")
        found = {v.get("gwId"): {"ip": ip, "ver": v.get("version")} for ip, v in tinytuya.deviceScan(False, 20).items()}
    devices = {}
    for d in wizard:
        seen = found.get(d["id"])
        if not seen or not seen.get("ip"):
            print(f"skipped {d.get('name')}: not found on the network")
            continue
        name = re.sub(r"[^a-z0-9]+", "_", d.get("name", d["id"]).lower()).strip("_") or d["id"]
        entry = {"id": d["id"], "key": d["key"], "ip": seen["ip"], "title": d.get("name", name)}
        if str(seen.get("ver", "3.3")) != "3.3":
            entry["version"] = float(seen["ver"])
        devices[name] = entry
    if not devices:
        sys.exit("error: no plugs found. Are they on, and is this Mac on the same network?")
    with open(os.path.join(HERE, "devices.json"), "w") as f:
        json.dump(devices, f, indent=2)
    os.chmod(os.path.join(HERE, "devices.json"), 0o600)
    cloud_keys = os.path.join(folder, "tinytuya.json")
    if os.path.exists(cloud_keys):
        import shutil
        shutil.copy(cloud_keys, os.path.join(HERE, "tinytuya.json"))
        os.chmod(os.path.join(HERE, "tinytuya.json"), 0o600)
    print("Saved", ", ".join(devices), "to devices.json")


def main(argv):
    devices = load() if argv and argv[0] not in ("import", "login-start", "login-poll", "discover", "add-device", "remove-device") else {}
    if argv and argv[0] == "import":
        return import_main(argv[1:])
    if argv and argv[0] == "login-start":
        return login_start(argv[1:])
    if argv and argv[0] == "login-poll":
        return login_poll()
    if argv and argv[0] == "discover":
        return discover_main()
    if argv and argv[0] == "add-device":
        return add_device_main(argv[1:])
    if argv and argv[0] == "remove-device":
        return remove_device_main(argv[1:])
    if not argv or argv[0] == "list":
        for n, d in devices.items():
            print(f"{n}\t{d['ip']}\t{d.get('product', '')}")
        return
    cmd, name = argv[0], (argv[1] if len(argv) > 1 else "")
    if cmd == "log" and name in devices:
        log_main(name, argv[2:], devices[name])
        return
    if cmd in ("timers", "timer-add", "timer-set", "timer-enable", "timer-del") and name in devices:
        timers_main(cmd, name, [a for a in argv[2:] if a != "--json"], devices[name])
        return
    if cmd not in ("status", "on", "off", "for", "cancel", "relay") or name not in devices:
        sys.exit(f"usage: room.py status|on|off <{'|'.join(devices)}> [--json]\n"
                 "       room.py for <name> on|off <seconds> | cancel <name> | relay <name> memory|on|off\n"
                 "       room.py log <name> [hours] [--all] | import [wizard-folder]\n"
                 "       room.py timers|timer-add|timer-set|timer-enable|timer-del <name> ...")
    # Plugs take one local connection at a time: serialise callers (menu bar app, CLI) so they queue instead of colliding.
    lock = open(os.path.join(HERE, ".room.lock"), "w")
    fcntl.flock(lock, fcntl.LOCK_EX)
    dps = local(cmd, argv, devices[name]) or via_cloud(cmd, argv, devices[name])
    on = bool(dps.get("1"))
    if "--json" in argv:
        print(json.dumps({"name": name, "on": on, "countdown": dps.get("9", 0), "relay": dps.get("38"), "inching": inching_seconds(dps.get("44")),
                          "cloud": os.path.exists(os.path.join(HERE, "tinytuya.json"))}))
    else:
        print(f"{name}: {'on' if on else 'off'}")


if __name__ == "__main__":
    main(sys.argv[1:])
