# Room Remote

macOS menu bar app (SwiftUI, one file: `app/TVRemote.swift`) with two Python helpers.

- `tv/` is the TV helper (`tvd.py`, a local HTTP server on 127.0.0.1:8787) that talks to an Android TV / Mi TV.
- `room/room.py` controls Tuya smart plugs locally, and reads and edits their schedules through the Tuya cloud API.
- At run time everything lives in `~/Library/Application Support/RoomRemote/{tv,room}`. Set `ROOM_REMOTE_HOME` to move it.
- Build: `scripts/build.sh`. Release zip: `scripts/make-release.sh <version>`. Install: `scripts/install.sh`.
- Keys, certificates, device lists and logs are git-ignored. Never commit them.
