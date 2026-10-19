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
    devices = load() if argv and argv[0] != "import" else {}
    if argv and argv[0] == "import":
        return import_main(argv[1:])
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
        print(json.dumps({"name": name, "on": on, "countdown": dps.get("9", 0), "relay": dps.get("38"), "inching": inching_seconds(dps.get("44"))}))
    else:
        print(f"{name}: {'on' if on else 'off'}")


if __name__ == "__main__":
    main(sys.argv[1:])
