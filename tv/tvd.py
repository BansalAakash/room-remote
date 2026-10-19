#!/usr/bin/env python3
"""tvd: local helper behind the menu-bar remote. Keeps one live connection to the Mi TV.

  tvd.py            serve on 127.0.0.1:8787  (loopback only)
GET  /status                         {state: on|standby|offline, app, volume, muted, ip, job, since, ...}
POST /key      {keys:[..], gap}      press remote keys
POST /vol      {level}               set exact volume (closed loop on the TV's own reading)
POST /text     {text}                type on the TV
POST /app      {name}                launch an app (netflix|youtube|prime|hotstar|sonyliv|zee5|home)
POST /youtube  {q}                   open YouTube search results
POST /wake, /sleep
POST /netflix  {title, season, episode, at}   closed-loop Netflix play (camera) as a background job
POST /seek     {to}                  seek the Netflix player to mm:ss (camera) as a background job
GET  /screen                         PNG of the TV (ADB screenshot, camera fallback for protected apps)

Every failure answers with JSON {"error": "..."}: 400 bad input, 409 job busy, 503 TV asleep or
connection lost, 504 TV did not respond in time, 403 for a foreign Host or Origin header.
/status also carries "since" (epoch seconds: when the current state began), "connected",
"volume_max" and "error" (last connect failure, if any).
"""
import asyncio
import json
import logging
import os
import re
import shlex
import socket
import subprocess
import time
from pathlib import Path
from urllib.parse import quote_plus

from aiohttp import web
from androidtvremote2 import AndroidTVRemote, ConnectionClosed
from androidtvremote2.remotemessage_pb2 import RemoteKeyCode
from PIL import Image, ImageStat

DIR = Path(__file__).resolve().parent
PY = str(DIR / ".venv" / "bin" / "python")
IPFILE = DIR / "tv_ip.txt"
PEEK = DIR / "cam" / "peek.png"
PORT = 8787
REMOTE_PORT = 6466          # Android TV remote protocol (closed in standby)
CAST_PORT = 8009            # Chromecast service (stays up in standby)
CONNECT_TIMEOUT = 10.0
OFFLINE_AFTER = 30.0        # a handshake that keeps failing while the TV's ports are open only counts as offline after this long
_fail = {"since": None}
WAKE_TIMEOUT = 120.0
VOL_DOWN_GAP = 0.6          # this TV mutes if VOLUME_DOWN is pressed twice too quickly: space the presses
_last_vol_down = [0.0]
VOL_SETTLE = 0.5            # seconds to wait after a volume press before re-reading the TV
APPS = {"youtube": "com.google.android.youtube.tv", "prime": "com.amazon.amazonvideo.livingroom",
        "hotstar": "in.startv.hotstar", "sonyliv": "com.sonyliv", "zee5": "com.graymatrix.did"}
HOSTS = {f"127.0.0.1:{PORT}", f"localhost:{PORT}", f"[::1]:{PORT}"}
ORIGINS = {f"http://{h}" for h in HOSTS}
VALID_KEYS = set(RemoteKeyCode.keys())
TIME_RE = re.compile(r"\d{1,2}(:\d{1,2}){1,2}")
log = logging.getLogger("tvd")

S = {"state": "offline", "since": time.time(), "app": "", "volume": None, "volume_max": None,
     "muted": None, "connected": False, "error": None,
     "ip": (IPFILE.read_text().strip() if IPFILE.exists() else "") }
remote = None                       # live AndroidTVRemote, or None
job_proc = None                     # most recent subprocess started by start_job
job_tasks = set()
tv_lock = asyncio.Lock()            # one key/volume/text sequence at a time
wake_lock = asyncio.Lock()
screen_lock = asyncio.Lock()


class ApiError(Exception):
    def __init__(self, status, msg, **extra):
        super().__init__(msg)
        self.status, self.msg, self.extra = status, msg, extra


def err(status, msg, **extra):
    return web.json_response({"error": msg, **extra}, status=status)


def set_state(new):
    if S["state"] != new:
        S["state"] = new
        S["since"] = time.time()


def link_alive(r):
    """True while the TCP/TLS link behind r is up. The library only clears its protocol object on
    disconnect(), so a connection the TV dropped still looks connected: check the transport too.
    (Uses the library's private _remote_message_protocol; pinned to androidtvremote2 0.3.x.)"""
    proto = getattr(r, "_remote_message_protocol", None)
    if proto is None or proto.on_con_lost.done():
        return False
    return proto.transport is not None and not proto.transport.is_closing()


def live_remote():
    """The connected remote, or 503 when the TV is asleep or the link is gone."""
    r = remote
    if r is None or not link_alive(r):
        raise ApiError(503, "Reconnecting to Mi TV. Try again in a moment.")
    if not r.is_on:
        raise ApiError(503, "TV is not awake - use Wake")
    return r


def read_level(r):
    vi = r.volume_info
    return vi.get("level") if vi else None


def _on_volume(v):
    S.update(volume=v.get("level"), volume_max=v.get("max"), muted=v.get("muted"))


def drop_remote():
    global remote
    r, remote = remote, None
    S.update(connected=False, app="", volume=None, volume_max=None, muted=None)
    if r is not None:
        try:
            r.disconnect()
        except Exception:
            log.exception("disconnect failed")


def port_open(ip, p, t=1.0):
    s = socket.socket()
    s.settimeout(t)
    try:
        s.connect((ip, p))
        return True
    except OSError:
        return False
    finally:
        s.close()


async def connect_remote(ip):
    """Connect a fresh AndroidTVRemote and make it the live one. Returns True on success."""
    global remote
    r = AndroidTVRemote("tv-remote", str(DIR / "cert.pem"), str(DIR / "key.pem"), ip)

    def guarded(fn):
        def cb(value):
            if remote is r:                 # ignore late callbacks from a connection already dropped
                fn(value)
        return cb

    r.add_is_on_updated_callback(guarded(lambda on: set_state("on" if on else "standby")))
    r.add_current_app_updated_callback(guarded(lambda a: S.update(app=a or "")))
    r.add_volume_info_updated_callback(guarded(_on_volume))
    try:
        await asyncio.wait_for(r.async_connect(), CONNECT_TIMEOUT)
    except asyncio.CancelledError:
        r.disconnect()
        raise
    except Exception as exc:
        r.disconnect()
        err_text = f"{type(exc).__name__}: {exc}"
        if err_text != S["error"]:                 # log each new failure once, not every 2 s retry
            log.info("connect to %s failed: %s", ip, err_text)
        S["error"] = err_text
        now = time.monotonic()
        _fail["since"] = _fail["since"] or now
        if now - _fail["since"] >= OFFLINE_AFTER:  # the ports answer but the handshake keeps failing: a real problem
            set_state("offline")                   # (one timeout is a hiccup: keep the last known state and retry in 2 s)
        return False
    remote = r
    _fail["since"] = None
    S.update(connected=True, error=None, app=r.current_app or "")
    set_state("on" if r.is_on else "standby")
    if r.volume_info:
        _on_volume(r.volume_info)
    log.info("connected to %s (%s)", ip, "on" if r.is_on else "standby")
    return True


async def rediscover():
    """The TV's address may have changed (DHCP): look it up by MAC and remember it."""
    import tvadb                                   # lazy: adb_shell is only needed here, /app, /screen
    new = await asyncio.to_thread(tvadb.find_tv)
    if new and new != S["ip"]:
        log.info("TV moved %s -> %s", S["ip"], new)
        S["ip"] = new
        IPFILE.write_text(new)


_check_lock = asyncio.Lock()
_gone = {"since": None, "misses": 0}
STANDBY_AFTER = 6.0            # a failed background probe only means "asleep" after this long (the TV's Wi-Fi is flaky)


async def probe(ip, port, tries, timeout):
    for _ in range(tries):
        if await asyncio.to_thread(port_open, ip, port, timeout):
            return True
    return False


async def check_tv(deliberate=False):
    """Bring S and the connection up to date.
    Background (deliberate=False): a connected, healthy link is trusted, with no probing at all (the TV pushes its own
    updates), and a failed probe only changes the state after it has kept failing for a while.
    Deliberate (the app asked, e.g. the popover just opened): patient probes with long timeouts, and the verdict is final at once."""
    async with _check_lock:
        ip = S["ip"]
        connected = remote is not None and link_alive(remote)
        if connected and not deliberate:
            _gone["since"] = None
            return
        timeout = 3.0 if deliberate else 2.0
        if await probe(ip, REMOTE_PORT, 2, timeout):
            _gone.update(since=None, misses=0)
            if connected:
                return                                   # alive and answering
            if remote is not None:
                log.info("TV link dropped; reconnecting")
                drop_remote()
            await connect_remote(ip)
            return
        if remote is not None:
            drop_remote()
        now = time.monotonic()
        _gone["since"] = _gone["since"] or now
        quiet = now - _gone["since"]
        if await probe(ip, CAST_PORT, 2, timeout):
            if deliberate or quiet >= STANDBY_AFTER:
                S["error"] = None
                set_state("standby")
        elif deliberate or quiet >= OFFLINE_AFTER:
            set_state("offline")
            _gone["misses"] += 1
            if _gone["misses"] >= 3:
                _gone["misses"] = 0
                await rediscover()


async def tv_loop():
    """Quiet background upkeep: reconnect when the link is gone; otherwise leave the TV alone."""
    while True:
        try:
            await check_tv(False)
        except asyncio.CancelledError:
            raise
        except Exception:
            log.exception("tv loop")
        await asyncio.sleep(5 if remote is not None else 10)


# ---- request helpers -------------------------------------------------------------------------

async def body(request):
    try:
        d = await request.json()
    except Exception:
        raise ApiError(400, "body must be a JSON object")
    if not isinstance(d, dict):
        raise ApiError(400, "body must be a JSON object")
    return d


def key_name(k):
    if not isinstance(k, str) or not k.strip():
        raise ApiError(400, "keys must be a list of key names")
    n = k.strip().upper()
    if n.startswith("TEXT:"):
        raise ApiError(400, "use /text to type")
    if not n.startswith("KEYCODE_"):
        n = "KEYCODE_" + n
    if n not in VALID_KEYS:
        raise ApiError(400, f"unknown key {k}")
    return n


def _time(v, name):
    if v is None:
        return None
    if not isinstance(v, str) or not TIME_RE.fullmatch(v):
        raise ApiError(400, f"{name} must be mm:ss or h:mm:ss")
    return v


def _int(v, lo, hi, name):
    try:
        n = int(v)
    except (TypeError, ValueError):
        raise ApiError(400, f"{name} must be an integer")
    if not lo <= n <= hi:
        raise ApiError(400, f"{name} must be {lo}..{hi}")
    return n


def _shell(argv):
    return " ".join(shlex.quote(str(a)) for a in argv)


# ---- handlers --------------------------------------------------------------------------------

async def status(request):
    if request.query.get("fresh"):                 # the app opened: read the TV now instead of trusting the background loop
        try:
            await asyncio.wait_for(check_tv(True), 18)
        except asyncio.TimeoutError:
            pass
    p = job_proc
    job = None
    if p is not None:
        job = {"running": p.poll() is None, "label": p.label, "tail": p.tail, "exit": p.returncode}
    return web.json_response({**S, "job": job})


async def press(r, name):
    """send_key_command with the volume-down spacing rule applied for every caller."""
    if "VOLUME_DOWN" in str(name):
        wait = VOL_DOWN_GAP - (time.monotonic() - _last_vol_down[0])
        if wait > 0:
            await asyncio.sleep(wait)
        _last_vol_down[0] = time.monotonic()
    r.send_key_command(name)


async def key(request):
    d = await body(request)
    keys = d.get("keys")
    if not isinstance(keys, list) or not 1 <= len(keys) <= 20:
        raise ApiError(400, "keys must be a list of 1-20 key names")
    names = [key_name(k) for k in keys]
    gap = d.get("gap", 0.25)
    if isinstance(gap, bool) or not isinstance(gap, (int, float)):
        raise ApiError(400, "gap must be a number of seconds")
    gap = min(max(float(gap), 0.05), 3.0)
    async with tv_lock:
        for i, name in enumerate(names):
            await press(live_remote(), name)
            if i < len(names) - 1:
                await asyncio.sleep(gap)
    return web.json_response({"ok": True})


async def settle_volume(r, cur, goal):
    """Step the TV volume toward the CURRENT goal, one press at a time; goal() is read before every press, so a newer
    request redirects the run mid-way (latest wins). The TV's reported level lags the press: wait VOL_SETTLE seconds,
    re-read, and if it has not moved yet wait up to 1 s more before pressing again. Bounded per goal: |delta| + 4
    presses, one reversal to undo an overshoot, and 504 after 3 presses with no change."""
    target = goal()
    step = 1 if target > cur else -1
    budget = abs(target - cur) + 4
    stalls, reversed_once = 0, False
    while True:
        if goal() != target:                              # redirected: start a fresh budget for the new goal
            target = goal()
            step = 1 if target > cur else -1
            budget = abs(target - cur) + 4
            stalls, reversed_once = 0, False
        if cur == target:
            return cur
        if budget <= 0:
            raise ApiError(504, f"volume did not reach {target}", volume=cur)
        budget -= 1
        live_remote()
        before = cur
        await press(r, "KEYCODE_VOLUME_UP" if step > 0 else "KEYCODE_VOLUME_DOWN")
        await asyncio.sleep(VOL_SETTLE)
        new = read_level(r)
        for _ in range(10):                  # reading still old: give the TV up to 1 s more before pressing again
            if new != before or not link_alive(r):
                break
            await asyncio.sleep(0.1)
            new = read_level(r)
        if new is None or not link_alive(r):
            raise ApiError(503, "TV connection lost while setting volume")
        if target > 0 and (r.volume_info or {}).get("muted"):     # a rare double-press mute: undo it and carry on
            log.warning("volume run: TV muted itself; unmuting")
            r.send_key_command("MUTE")
            await asyncio.sleep(0.8)
            new = read_level(r)
            if new is None or (r.volume_info or {}).get("muted"):
                raise ApiError(504, "TV stayed muted", volume=new)
        stalls = stalls + 1 if new == cur else 0
        if stalls >= 3:
            raise ApiError(504, "TV volume is not changing", volume=new)
        cur = new
        if goal() != target:
            continue                                         # redirected while pressing: re-plan from the new level
        if cur == target:
            return cur
        passed = cur > target if step > 0 else cur < target
        if passed:
            if reversed_once:
                raise ApiError(504, f"could not land on volume {target}", volume=cur)
            reversed_once, step = True, -step


_vol = {"goal": None, "task": None}


async def _vol_worker():
    async with tv_lock:
        r = live_remote()
        cur = read_level(r)
        if cur is None:
            raise ApiError(503, "TV volume is not known yet")
        return await settle_volume(r, cur, lambda: _vol["goal"])


async def vol(request):
    d = await body(request)
    try:
        target = int(d["level"])
    except (KeyError, TypeError, ValueError):
        raise ApiError(400, "level must be an integer")
    if target < 0:
        raise ApiError(400, "level must be >= 0")
    vmax = (live_remote().volume_info or {}).get("max")
    if vmax is not None and target > vmax:
        raise ApiError(400, f"level must be 0..{vmax}")
    _vol["goal"] = target                     # latest request wins: a run in flight is redirected, not queued behind
    cur = None
    for _ in range(3):
        task = _vol["task"]
        if task is None or task.done():
            _vol["task"] = task = asyncio.get_running_loop().create_task(_vol_worker())
        cur = await asyncio.shield(task)
        if cur == _vol["goal"]:
            break
    return web.json_response({"volume": cur, "goal": _vol["goal"]})


async def text(request):
    d = await body(request)
    t = d.get("text")
    if not isinstance(t, str) or not 1 <= len(t) <= 200:
        raise ApiError(400, "text must be 1-200 characters")
    async with tv_lock:
        for i, ch in enumerate(t):
            live_remote().send_text(ch)
            if i < len(t) - 1:
                await asyncio.sleep(0.35)
    return web.json_response({"ok": True})


def adb_launch(ip, package):
    import tvadb
    try:
        dev = tvadb.connect(ip)
    except Exception as exc:
        raise ApiError(503, f"ADB unavailable: {exc}")
    try:
        # TV apps register under LEANBACK_LAUNCHER (Prime Video has no phone LAUNCHER entry, so that command silently
        # does nothing); try it first, then the phone category. Check the app really came to the front.
        for category in ("LEANBACK_LAUNCHER", "LAUNCHER"):
            dev.shell(f"monkey -p {package} -c android.intent.category.{category} 1")
            for _ in range(10):
                time.sleep(0.5)
                if package in dev.shell("dumpsys window | grep mCurrentFocus | head -1"):
                    return
        raise ApiError(504, "The app did not open")
    finally:
        dev.close()


async def app_launch(request):
    d = await body(request)
    name = d.get("name")
    if name not in ("netflix", "home") and name not in APPS:
        raise ApiError(400, "unknown app")
    async with tv_lock:
        r = live_remote()
        if name == "netflix":
            r.send_launch_app_command("nflx://www.netflix.com")
        elif name == "home":
            r.send_key_command("HOME")
        else:
            await asyncio.to_thread(adb_launch, S["ip"], APPS[name])
    return web.json_response({"ok": True})


async def youtube(request):
    d = await body(request)
    q = d.get("q")
    if not isinstance(q, str) or not q.strip():
        raise ApiError(400, "q must be a non-empty string")
    async with tv_lock:
        live_remote().send_launch_app_command(
            "https://www.youtube.com/results?search_query=" + quote_plus(q.strip()[:200]))
    return web.json_response({"ok": True})


async def wake(request):
    if S["state"] == "on":
        return web.json_response({"ok": True, "note": "already on"})
    async with wake_lock:
        if S["state"] == "on":
            return web.json_response({"ok": True, "note": "already on"})
        p = await asyncio.create_subprocess_exec(PY, "wake.py", S["ip"], cwd=str(DIR),
                                                 stdout=asyncio.subprocess.PIPE,
                                                 stderr=asyncio.subprocess.STDOUT)
        try:
            out, _ = await asyncio.wait_for(p.communicate(), WAKE_TIMEOUT)
        except asyncio.TimeoutError:
            p.kill()
            await p.wait()
            raise ApiError(504, "wake timed out")
    tail = out.decode(errors="replace")[-200:]
    if p.returncode != 0:
        raise ApiError(503, "wake failed", out=tail)
    return web.json_response({"ok": True, "out": tail})


async def sleep_tv(request):
    # POWER is a toggle: only sent when the TV is confirmed on (live_remote), so it can never wake a standby TV.
    async with tv_lock:
        live_remote().send_key_command("POWER")
    return web.json_response({"ok": True})


def job_running():
    return job_proc is not None and job_proc.poll() is None


async def pump(proc):
    """Drain a job's stdout into proc.tail so /status can show progress."""
    loop = asyncio.get_running_loop()
    while True:
        line = await loop.run_in_executor(None, proc.stdout.readline)
        if not line:
            break
        proc.tail = (proc.tail + line)[-600:]
    rc = await loop.run_in_executor(None, proc.wait)
    proc.tail = (proc.tail + f"\n[exit {rc}]")[-600:]
    proc.stdout.close()


def start_job(label, *argv):
    """Start a background job. One at a time: 409 while another is still running."""
    global job_proc
    if job_running():
        raise ApiError(409, "another job is running", running=job_proc.label)
    env = {**os.environ, "PYTHONUNBUFFERED": "1"}    # child output streams instead of sitting in a buffer
    try:
        proc = subprocess.Popen(list(argv), cwd=str(DIR), stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, text=True, env=env)
    except OSError as exc:
        raise ApiError(500, f"could not start job: {exc}")
    proc.label, proc.tail = label, ""
    job_proc = proc
    task = asyncio.get_running_loop().create_task(pump(proc))
    job_tasks.add(task)                 # keep a reference so the pump is not garbage-collected
    task.add_done_callback(job_tasks.discard)


async def netflix(request):
    d = await body(request)
    title = d.get("title")
    if not isinstance(title, str) or not title.strip() or len(title) > 200:
        raise ApiError(400, "title must be a non-empty string")
    title = title.strip()
    season, episode = d.get("season"), d.get("episode")
    if (season is None) != (episode is None):
        raise ApiError(400, "season and episode go together")
    at = _time(d.get("at"), "at")
    argv = [PY, "netflix.py", S["ip"], title]
    label = f"Netflix: {title}"
    if season is not None:
        season = _int(season, 1, 99, "season")
        episode = _int(episode, 1, 999, "episode")
        argv += [str(season), str(episode)]
        label += f" S{season}E{episode}"
    if at:                                            # play, then seek, as one job
        script = f"{_shell(argv)} && sleep 12 && {_shell([PY, 'seek.py', S['ip'], at])}"
        start_job(label + f" @ {at}", "/bin/sh", "-c", script)
    else:
        start_job(label, *argv)
    return web.json_response({"ok": True})


async def seek(request):
    d = await body(request)
    to = _time(d.get("to"), "to")
    if to is None:
        raise ApiError(400, "to (mm:ss) is required")
    start_job(f"Seek to {to}", PY, "seek.py", S["ip"], to)
    return web.json_response({"ok": True})


def blank(path):
    """True for a flat frame (protected apps return an all-black screenshot)."""
    try:
        return ImageStat.Stat(Image.open(path).convert("L")).stddev[0] < 2.0
    except Exception:
        return True


def grab_screen():
    import screen as sc
    PEEK.parent.mkdir(exist_ok=True)
    PEEK.unlink(missing_ok=True)
    try:
        if sc._adb_frame(PEEK) and PEEK.exists() and PEEK.stat().st_size > 0 and not blank(PEEK):
            return "adb"
    except Exception:
        log.exception("ADB screenshot failed")
    PEEK.unlink(missing_ok=True)
    raise ApiError(503, "This app blocks screenshots (Netflix, Hotstar and similar), so the screen cannot be shown")


async def screen_png(request):
    async with screen_lock:
        src = await asyncio.to_thread(grab_screen)
        data = await asyncio.to_thread(PEEK.read_bytes)
    return web.Response(body=data, content_type="image/png",
                        headers={"X-Source": src, "Cache-Control": "no-store"})


# ---- app wiring ------------------------------------------------------------------------------

@web.middleware
async def guard(request, handler):
    """Loopback-only API. Refuse foreign Host (DNS rebinding) and any browser cross-origin request
    (a page on another site cannot drive the TV). Native clients send neither header, so they pass.
    Every failure, including unknown routes and wrong methods, answers with JSON {error}."""
    if request.headers.get("Host") not in HOSTS:
        return err(403, "Host must be 127.0.0.1 or localhost")
    origin = request.headers.get("Origin")
    if origin is not None and origin not in ORIGINS:
        return err(403, "cross-origin requests are refused")
    try:
        return await handler(request)
    except ApiError as e:
        return err(e.status, e.msg, **e.extra)
    except web.HTTPException as e:
        return err(e.status, e.reason or "error")
    except ConnectionClosed:
        return err(503, "TV connection lost - use Wake")
    except Exception as e:
        log.exception("%s %s", request.method, request.path)
        return err(500, f"{type(e).__name__}: {e}")


async def on_startup(app):
    app["tv"] = asyncio.get_running_loop().create_task(tv_loop())


async def on_cleanup(app):
    task = app.get("tv")
    if task is not None:
        task.cancel()
        try:
            await task
        except asyncio.CancelledError:
            pass
    drop_remote()
    p = job_proc
    if p is not None and p.poll() is None:
        p.terminate()
        for _ in range(50):
            if p.poll() is not None:
                break
            await asyncio.sleep(0.1)
        else:
            p.kill()
    for t in list(job_tasks):
        t.cancel()


def make_app(with_tv_loop=True):
    app = web.Application(middlewares=[guard])
    app.add_routes([web.get("/status", status), web.post("/key", key), web.post("/vol", vol),
                    web.post("/text", text), web.post("/app", app_launch), web.post("/youtube", youtube),
                    web.post("/wake", wake), web.post("/sleep", sleep_tv), 
                    web.get("/screen", screen_png),
                    web.post("/assistant", assistant_unavailable), web.get("/assistant", assistant_unavailable),
                    web.post("/assistant/stop", assistant_unavailable), web.post("/assistant/reset", assistant_unavailable)])
    if with_tv_loop:
        app.on_startup.append(on_startup)
    app.on_cleanup.append(on_cleanup)
    return app


# ---- assistant routes: not part of this build, so the app's "Ask" mode reports that politely ----
async def assistant_unavailable(request):
    raise ApiError(501, "The assistant is not included in this build.")


def main():
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    web.run_app(make_app(), host="127.0.0.1", port=PORT, print=None, access_log=None)


if __name__ == "__main__":
    main()
