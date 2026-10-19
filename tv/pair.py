#!/usr/bin/env python3
"""Pair this Mac with your Android TV or Mi TV (once).

  pair.py <tv-ip>

The TV shows a 6-character code; type it here. This saves cert.pem, key.pem and tv_ip.txt next to this script.
"""
import asyncio
import sys
from pathlib import Path

from androidtvremote2 import AndroidTVRemote, CannotConnect, InvalidAuth

DIR = Path(__file__).resolve().parent


async def pair(ip):
    remote = AndroidTVRemote("tv-remote", str(DIR / "cert.pem"), str(DIR / "key.pem"), ip)
    await remote.async_generate_cert_if_missing()
    try:
        await remote.async_start_pairing()
    except CannotConnect:
        sys.exit(f"Can't reach the TV at {ip}. Is it on, and on the same network?")
    code = input("Enter the code shown on the TV: ").strip()
    try:
        await remote.async_finish_pairing(code)
    except InvalidAuth:
        sys.exit("That code didn't work. Run this again.")
    (DIR / "tv_ip.txt").write_text(ip)
    print("Paired. Restart the app if it is open.")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: pair.py <tv-ip>")
    asyncio.run(pair(sys.argv[1]))
