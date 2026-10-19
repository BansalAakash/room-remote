# Room Remote

A macOS menu bar app that controls the devices in your room: your Android TV / Mi TV and your Tuya smart plugs (Smart Life, Zebronics, Wipro and others).

- **TV tab:** remote keys, volume, app launcher, power, and a text box for typing and searching on the TV.
- **Plugs tab:** one picker for all your plugs. Each plug has a 24-hour dial that lights up when it is on. Tap the dial to add, edit or delete schedules, hold a plug on or off for a while (30 min to 4 h), see its switching history, and choose what it does after a power cut.
- **Your schedules stay in sync with the Smart Life app.** They are read from and written to the same place the app uses.
- Plug switching is local and fast. If a plug's Wi-Fi drops local connections, the app falls back to the Tuya cloud automatically.

Requires macOS 14 or later.

## Install

1. Download `RoomRemote-<version>.zip` from the [Releases](../../releases) page (or from the [`releases/`](releases) folder) and unzip it.
2. In Terminal, from the unzipped folder:

   ```bash
   ./install.sh
   ```

   This installs the app into `~/Applications` and sets up the helpers (needs `python3`; macOS offers to install it the first time).
3. Open it: `open ~/Applications/RoomRemote.app`. It lives in the menu bar (a house icon). The app is not notarized, so if macOS blocks it, right-click the app, choose **Open**, then **Open** again.

Right-click the menu bar icon for **Open at Login**, **Keep Open** (stops the panel closing when you click elsewhere) and the keyboard shortcut.

## Set up your TV

Turn the TV on, find its IP address (Settings, Network), then run:

```bash
~/Library/Application\ Support/RoomRemote/tv/.venv/bin/python ~/Library/Application\ Support/RoomRemote/tv/pair.py <tv-ip>
```

Type the code the TV shows. You only do this once. Optional: enable ADB debugging on the TV (Developer options) for faster app launching and screenshots.

## Set up your plugs

Plugs must first be added in the **Smart Life** (or Tuya Smart) phone app. Then:

1. Create a free account at [iot.tuya.com](https://iot.tuya.com) and a **Cloud** project (pick the data center for your region). In the project, open **Devices, Link App Account** and scan the QR code with the Smart Life app, so your plugs appear under the project. Note the project's **Access ID** and **Access Secret**.
2. Run Tuya's setup wizard in a scratch folder. It asks for the Access ID, Access Secret, one device ID (from the project's device list) and your region, and it saves your plugs' local keys:

   ```bash
   cd ~/Library/Application\ Support/RoomRemote/room
   mkdir -p wizard && cd wizard
   ../.venv/bin/python -m tinytuya wizard
   ```

   Answer **Y** when it offers to scan the network.
3. Import the result:

   ```bash
   cd ~/Library/Application\ Support/RoomRemote/room
   .venv/bin/python room.py import
   ```

   This writes `devices.json`. Edit it to give a plug a nicer `"title"` or a `"symbol"` (an SF Symbol name). A plug whose name contains "fridge" or "freezer" asks for confirmation before it is switched off and uses "pause, then back on" for timed holds.
4. Restart the app. Your plugs appear in the Plugs tab.

Give the plugs fixed IP addresses in your router if you can; the local connection needs the address in `devices.json` to stay the same. Your Mac and the plugs need to be on the same network (and, on some routers, the same Wi-Fi band).

The free Tuya IoT Core trial has to be extended every so often (Cloud, My Services, extend). Local on/off keeps working without it; schedules, history and the cloud fallback need it.

## Command line

```bash
cd ~/Library/Application\ Support/RoomRemote/room
.venv/bin/python room.py status <plug>
.venv/bin/python room.py on|off <plug>
.venv/bin/python room.py for <plug> on|off <seconds>     # switch now, flip back later
.venv/bin/python room.py cancel <plug>                    # cancel that countdown
.venv/bin/python room.py relay <plug> memory|on|off       # state after a power cut
.venv/bin/python room.py timers <plug>                    # list schedules (JSON)
.venv/bin/python room.py timer-add <plug> HH:MM on|off [1111111]
.venv/bin/python room.py log <plug> [hours] [--all]       # switching history
```

The optional seven digits are the days, Sunday first.

## What is not included

- The TV tab's "Ask" mode (an AI assistant) and the Netflix camera helpers are not part of this build. The Ask box reports that it is unavailable.

## Build from source

```bash
xcode-select --install     # once
./scripts/build.sh         # builds build/RoomRemote.app
./scripts/install.sh       # installs it and the helpers
./scripts/make-release.sh 1.0.0   # packs releases/RoomRemote-1.0.0.zip
```

Everything the app uses at run time is in `~/Library/Application Support/RoomRemote` (set `ROOM_REMOTE_HOME` to change it). `./scripts/uninstall.sh` removes it all.

## Privacy

Everything runs on your Mac. TV and plug control stay on your local network. Schedules, history and the cloud fallback talk to Tuya's cloud with your own project keys, which are stored only in `~/Library/Application Support/RoomRemote/room/`. Nothing is sent anywhere else.

## Licence

MIT
