#!/usr/bin/env python3
"""Wake the Mi TV and land on the Home screen.

  wake.py [ip]

Fast path (about 3 s): in the usual 'standby' the screen is off but the TV's remote port stays open; the power key
turns the screen on, exactly like the physical remote. Slow path (about 40 s): if the TV is fully asleep (remote port
closed) only its Chromecast service (8009) answers; launching a Cast app wakes it. Either way we finish on Home.
"""
import asyncio
import socket
import sys
import time

from androidtvremote2 import AndroidTVRemote

IP = sys.argv[1]


def port_open(p, t=1.5):
    s = socket.socket(); s.settimeout(t)
    try:
        s.connect((IP, p)); return True
    except OSError:
        return False
    finally:
        s.close()


def cast_wake():
    import pychromecast
    cc = pychromecast.get_chromecast_from_host((IP, 8009, None, "MiTV", "MiTV"))
    try:
        cc.wait(timeout=15)
        cc.start_app("233637DE")            # YouTube receiver: any Cast app launch wakes the TV
    except Exception as e:                  # the call can time out while the TV is still waking: keep waiting for the port
        print("cast launch:", e)
    return cc


async def run():
    cc = None
    if not port_open(6466):                 # slow path: fully asleep
        if not port_open(8009):
            sys.exit("TV not reachable (fully powered off or off the network)")
        cc = await asyncio.to_thread(cast_wake)
        for _ in range(60):
            if port_open(6466):
                break
            await asyncio.sleep(1)
        else:
            sys.exit("TV did not come up")

    r = AndroidTVRemote("tv-remote", "cert.pem", "key.pem", IP)
    await r.async_connect()
    await asyncio.sleep(1)
    woke = False
    if not r.is_on:                         # fast path: screen off, system awake -> power key
        r.send_key_command("POWER")
        for _ in range(40):
            await asyncio.sleep(0.5)
            if r.is_on:
                woke = True
                break
        if not woke:
            r.disconnect()
            sys.exit("screen did not turn on")
    elif cc is None:
        r.disconnect()
        print("already on")                 # awake and showing something: leave it alone
        return

    for _ in range(4):                      # land on Home, never on the Cast screen
        if cc is not None:
            try:
                cc.quit_app()
            except Exception:
                pass
        r.send_key_command("HOME")
        await asyncio.sleep(2.5)
        app = (r.current_app or "").lower()
        if "launcher" in app:
            break
    print("woke; foreground app:", r.current_app)
    r.disconnect()
    if cc is not None:
        try:
            cc.disconnect()
        except Exception:
            pass


asyncio.run(run())
