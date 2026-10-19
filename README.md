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

## Add your plugs

Plugs must first be added in the **Smart Life** (or Tuya Smart) phone app. Then, in this app:

1. Open the **Plugs** tab and choose **Add a plug** (or **Add a plug…** in the plug picker).
2. In Smart Life, open **Me, the settings gear, Account and Security, User Code** and type that code into the app.
3. A QR code appears. In Smart Life tap the scan icon (top right of Home), scan it and approve the sign-in.
4. Your Smart Life devices are listed. Tap **Add** on each plug you want. They need to be on, and your Mac on the same Wi-Fi, so the app can find them.

To remove a plug later, open the plug picker and choose **Remove …**. It only disappears from this app; it stays in Smart Life.

That is all. This uses Tuya's device-sharing sign-in (the same one Home Assistant uses), so you don't need a developer account. It gives the app each plug's local key; nothing else about your account is stored. You can revoke access any time in Smart Life.

Plugs added this way support on/off, timed holds ("on for 30 min, then off") and the power-cut setting. **Schedules and switching history** also need a Tuya developer key (below). Without one, the Plugs tab says so and hides them.

### Optional: schedules and history

Create a free account at [iot.tuya.com](https://iot.tuya.com) and a **Cloud** project (pick the data center for your region). In the project, open **Devices, Link App Account** and scan the QR code with Smart Life. Then run the setup wizard in a scratch folder (it asks for the project's **Access ID**, **Access Secret**, one device ID and your region, and you should answer **Y** to scanning the network):

```bash
cd ~/Library/Application\ Support/RoomRemote/room
mkdir -p wizard && cd wizard
../.venv/bin/python -m tinytuya wizard
cd .. && .venv/bin/python room.py import
```

This also writes `devices.json`. You can edit it to give a plug a nicer `"title"` or a `"symbol"` (an SF Symbol name). A plug whose name contains "fridge" or "freezer" asks for confirmation before it is switched off and uses "pause, then back on" for timed holds. Restart the app afterwards.

Give the plugs fixed IP addresses in your router if you can; the local connection needs the address in `devices.json` to stay the same. Your Mac and the plugs need to be on the same network (and, on some routers, the same Wi-Fi band). The free Tuya IoT Core trial has to be extended every so often (Cloud, My Services, extend); local switching keeps working without it.

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
.venv/bin/python room.py discover                         # devices on your signed-in Smart Life account (after the in-app sign-in)
.venv/bin/python room.py add-device <device-id> [title]   # save one to devices.json
.venv/bin/python room.py remove-device <plug>             # forget one (it stays in Smart Life)
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
