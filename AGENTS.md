# Room Remote

macOS menu bar app (SwiftUI, one file: `app/TVRemote.swift`) with two Python helpers.

- `tv/` is the TV helper (`tvd.py`, a local HTTP server on 127.0.0.1:8787) that talks to an Android TV / Mi TV.
- `room/room.py` controls Tuya smart plugs locally, and reads and edits their schedules through the Tuya cloud API.
- At run time everything lives in `~/Library/Application Support/RoomRemote/{tv,room}`. Set `ROOM_REMOTE_HOME` to move it.
- Build: `scripts/build.sh`. Release zip: `scripts/make-release.sh <version>`. Install: `scripts/install.sh`.
- Keys, certificates, device lists and logs are git-ignored. Never commit them.

## Setting this up for a user (for AI assistants)

Do the technical steps yourself; tell the user plainly when a step needs their hands. Run each verification before moving on.

1. **Prerequisites.** macOS 14 or later. Check `python3 --version` (macOS offers to install it; let it). For building from source also `xcode-select --install`.
2. **Get the app.** Either download `RoomRemote-<version>.zip` from the Releases page, unzip it and run `./install.sh` inside, or build from source: `./scripts/build.sh && ./scripts/install.sh`. Verify: `ls ~/Applications/RoomRemote.app`.
3. **Open it.** `open ~/Applications/RoomRemote.app` (a house icon appears in the menu bar). The app is not notarized: if macOS blocks it, the user must right-click the app, choose **Open**, then **Open** again.
4. **Pair the TV (only needed once).** **ASK** the user for the TV's IP address (TV: Settings > Network) and have the TV on. Run `~/Library/Application\ Support/RoomRemote/tv/.venv/bin/python ~/Library/Application\ Support/RoomRemote/tv/pair.py <tv-ip>`. The TV shows a code; the **user** must type it into the prompt. Optional: ask the user to turn on ADB debugging in the TV's Developer options (Settings > Device Preferences > About, tap Build 7 times) for faster app launching and screenshots.
5. **Add plugs (optional).** Plugs must already be set up in the Smart Life (or Tuya Smart) phone app. In the app: Plugs tab > **Add a plug**; the **user** types the code from Smart Life (Me > gear > Account and Security > User Code) and scans the QR code with Smart Life. You cannot do this part for them. Their Mac and the plugs must be on the same Wi-Fi.
6. **Schedules and history (optional).** Needs the user's own free Tuya developer project (iot.tuya.com): follow "Optional: schedules and history" in `README.md`. **ASK** for the Access ID, Access Secret, one device ID and the region; never write them anywhere except the local `room` folder, and never commit them.
7. **Verify.** TV: press a key in the app's TV tab and check the TV reacts. Plugs: `~/Library/Application\ Support/RoomRemote/room/.venv/bin/python ~/Library/Application\ Support/RoomRemote/room/room.py status <plug>`.

Uninstall: `./scripts/uninstall.sh` (removes the app and everything under `~/Library/Application Support/RoomRemote`).

### Common problems

| Symptom | Fix |
|---|---|
| macOS says the app cannot be opened | Right-click the app, **Open**, then **Open** again (it is not notarized). |
| TV does not react | Pair again with `pair.py`; check the TV and Mac are on the same network and the IP has not changed. |
| A plug does not respond locally | Give it a fixed IP in the router and keep the Mac on the same Wi-Fi band; the app falls back to the Tuya cloud on its own. |
| Schedules or history are missing | They need the optional Tuya developer key (step 6). The free IoT Core trial must be extended every so often. |

## Conventions

- When you change what the app looks like, update the images in the README.
- Never commit keys, certificates, device lists or logs.
