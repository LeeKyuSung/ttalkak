# ttalkak (딸깍)

English · [한국어](README.ko.md)

Four tiny macOS menu bar apps that each do exactly one thing. **Left-click acts immediately** — no menu
drops down, no confirmation.

*ttalkak* (딸깍) is the Korean onomatopoeia for a click.

![Menu bar icons](screenshots/menubar-icons.png)

| App | Left-click | Permissions |
| --- | --- | --- |
| **AudioFix** — speaker with a warning badge | Restarts `coreaudiod` — fixes crackling audio and output devices that won't connect | Admin password (can be waived, opt-in) |
| **ThemeToggle** — half-filled circle | Switches between Dark and Light appearance | Automation (System Events) |
| **MicRecorder** — filled microphone | Starts / stops recording | Microphone, Downloads folder |
| **ResourceBar** — SSD bar, GPU / CPU / memory graphs, network speed | Opens the detail panel of the widget you clicked | None |

**Right-click** (or control-click) opens a small settings menu.

![Right-click menu](screenshots/audiofix-menu.png)

The icon *is* the state. ThemeToggle fills the half of the circle that matches the current appearance;
AudioFix spins a refresh arrow while it restarts; MicRecorder is a microphone when idle and a solid red
dot while recording. Elapsed time and status messages live in the tooltip and the right-click menu
only — putting text in the menu bar widens the item, and a widened item gets pushed off the menu bar
entirely. ([why](docs/macos-notes.md))

The icons are drawn in an explicit black or white rather than as template images. A template image in the
menu bar is drawn at roughly 40 % of the strength macOS gives its own items, which makes a third-party
icon look washed out next to Wi-Fi and Control Center. ([why](docs/macos-notes.md))

Every app's right-click menu has a **Pin to the right end of the menu bar** toggle. When items overflow,
macOS drops the leftmost ones, so the right end — next to Control Center — is the only spot that survives
on a notched MacBook with no external display attached. Turning it on moves the icon there and keeps it
there on every launch; turning it off puts the icon back where it was before you pinned it.

MicRecorder and ResourceBar ship with it on: a recording indicator you cannot see is useless, and
ResourceBar is 228 pt wide, so on a notched screen the right end is the only place it fits. The other two
default to off. ⌘-drag still works as usual while the toggle is off.

---

## Requirements

- macOS 14.0+ (Apple Silicon)
- Xcode command line tools (`xcode-select --install`)

## Build and install

```bash
git clone https://github.com/LeeKyuSung/ttalkak.git
cd ttalkak
bash build.sh                    # all four
bash build.sh MicRecorder        # just one

for a in AudioFix ThemeToggle MicRecorder ResourceBar; do
  ditto "build/$a.app" "/Applications/$a.app" && open "/Applications/$a.app"
done
```

Installing into `/Applications` matters. macOS will not remember privacy permissions for bundles that live
in places like `/private/tmp`.

Each app's right-click menu has a **Launch at login** toggle.

### Signing

The build script picks up an `Apple Development` certificate automatically if you have one. Without it, it
falls back to ad-hoc signing — in which case **every source edit resets the app's privacy permissions**,
because an ad-hoc signature's identity is just the code hash. You will re-approve the microphone prompt a
lot while hacking on it.

Use your own bundle identifier with:

```bash
BUNDLE_PREFIX=com.example bash build.sh
```

### Uninstall

Quit the apps and delete them from `/Applications`. If you enabled AudioFix's passwordless option, also
revert that — see [docs/sudoers.md](docs/sudoers.md) (Korean). ResourceBar's spike log stays in
`Library/Logs/ResourceBar` in your home folder; delete that folder too if you like.

---

## Why `killall` and not `launchctl`

The obvious way to restart CoreAudio does not work when System Integrity Protection is enabled, which is
the default:

```text
sudo launchctl kickstart -kp system/com.apple.audio.coreaudiod
→ Could not kickstart service: 150: Operation not permitted while
  System Integrity Protection is engaged (150)
```

SIP blocks `launchctl` operations on `system/` domain daemons entirely, even for root. Sending a signal as
root is still allowed, and launchd brings `coreaudiod` straight back. So `sudo killall coreaudiod` is the
path that actually works.

Because `killall` only sends a signal, exit code 0 does not mean the daemon restarted. AudioFix confirms it
by checking that **the PID actually changed**, and says so honestly when it cannot confirm.

### Passwordless restart (opt-in)

By default every click asks for an admin password. The right-click menu offers to install a sudoers rule so
it does not — it is **never installed automatically**, since it waives sudo authentication.

The rule permits exactly one command, arguments included, so it cannot be used to kill anything else:

```text
Cmnd_Alias AUDIOFIX_KILL = /usr/bin/killall coreaudiod
<your-username> ALL=(root) NOPASSWD: AUDIOFIX_KILL, AUDIOFIX_PROBE
```

You can read the exact script before running it:

```bash
/Applications/AudioFix.app/Contents/MacOS/AudioFix --print-installer
```

Editing sudoers badly can lock you out of `sudo`, so the installer backs up `/etc/sudoers`, validates the
**assembled** configuration with `visudo -cf` (not just the fragment), and rolls back on any failure. It
also records whether it was the one that added the `@includedir` line, so uninstalling never removes a line
that was already there. Details in [docs/sudoers.md](docs/sudoers.md) (Korean).

---

## Recordings

- Saved to **`~/Downloads`**
- Named `녹음_2026-08-14_101530.m4a`, with a numeric suffix if a name collides
- AAC mono 64 kbps `.m4a` — feeds straight into Whisper-style transcription

Pick the input device from the right-click menu; the choice is remembered. The default is the **built-in
microphone** on purpose: selecting a Bluetooth headset as the input forces the HFP profile, which degrades
output audio to phone-call quality for as long as you are recording.

The recorder also:

- finalizes the file when the app quits or you log out, so it is never left unplayable
- keeps whatever was captured when the input device disappears mid-recording, and tells you why it stopped
- ignores a second click while a recording is still starting, so you never get two overlapping recordings
- checks the recording every second and, if something is wrong, beeps, shows an alert, and turns the icon
  into an orange triangle:
  - **stalled**: the length written to the file has not grown for 5 seconds. The alert offers to start a
    fresh recording right away
  - **silent**: the input has been digital silence (at or below -80 dBFS) for 20 seconds — usually a muted
    mic or a device that delivers no sound
  - **after stopping**: warns if the saved file is noticeably shorter than the time spent recording
  - added after a 27-minute recording silently came out as 1.6 seconds, with no error reported (2026-10-27)
- logs start, problems, and stop to the unified log:
  `log show --last 1d --predicate 'subsystem == "kr.leekyusung.MicRecorder"'`

---

## ResourceBar

One 228 pt item that draws, left to right, SSD usage as a bar, GPU, CPU and memory as one-minute line
graphs, and upload / download speed. It updates every second and needs no permissions.

- **SSD** is real usage, `1 - f_bavail / f_blocks` on `/System/Volumes/Data`. Space macOS calls
  purgeable is not counted as free, so the number does not swing the way it does in some monitors. The
  bar is blue below 80%, orange from 80% and red from 90%.
- **Left-click a widget** to open its detail panel: a five-minute graph (SSD shows a usage line instead),
  and for CPU, memory and SSD the eight processes using the most, each with a quit button (SIGTERM after a
  confirmation). The button is off for `loginwindow`, because quitting it logs you out on the spot.
- **Other accounts' processes.** An ordinary app cannot read the CPU and memory usage of processes that
  belong to root or `_windowserver`, so ResourceBar hands just those PIDs to `/bin/ps`: every two seconds
  while a CPU or memory panel is open, and twice for each spike-log line. They are marked *(시스템)* and
  cannot be quit. `ps` reports RSS rather than the
  footprint Activity Monitor shows, so their memory reads low (WindowServer: 107 MB against 549 MB), and
  `kernel_task` is invisible even to `ps`.
- **Spike log.** When CPU or GPU stays above 80 % for 10 seconds, or memory pressure reaches *warning*, one
  JSON line with the top processes is appended to `Library/Logs/ResourceBar/spikes-YYYY-MM-DD.jsonl` in
  your home folder. CPU, GPU and *critical* pressure repeat every 60 seconds while they last; *warning*
  alone repeats every 10 minutes, because on many Macs it is the resting state. Files older than 30 days
  are deleted.
- **Cost.** Measured against [Stats](https://github.com/exelban/stats) on the same Mac in the same
  minutes, with two displays attached, as a percentage of one core: ResourceBar about 1 %, Stats 5.2 to
  6.0 %. Memory footprint 13 MB against 201 MB. An open CPU or memory panel adds 1.4 to 1.9 points while it
  stays open, about 0.5 of that being `ps`.
- Most of the drawing cost is not the drawing itself. With a second display attached, AppKit snapshots a
  status item again for the other screen's menu bar each time it redraws, so one wide item is far cheaper
  than five narrow ones.

`--login-item on|off` registers or removes the login item without going through the menu, which is handy
in an install script. The measurement flags behind the numbers above and the design notes are in
[docs/resourcebar.md](docs/resourcebar.md) (Korean).

---

## Layout

```text
ttalkak/
├── Shared/Shared.swift          process exec, admin exec, alerts, status icon, login item
├── AudioFix/AudioFix.swift
├── ThemeToggle/ThemeToggle.swift
├── MicRecorder/MicRecorder.swift
├── ResourceBar/                 ResourceBar.swift (entry point) plus readers, panels, spike log, drawing
├── build.sh
└── docs/
    ├── macos-notes.md           macOS constraints hit while building this
    ├── resourcebar.md           ResourceBar design notes and measurements
    └── sudoers.md               privilege design and how to undo it
```

No dependencies, no Xcode project, no SwiftPM. Each app is one `swiftc` invocation over `Shared.swift` plus
the files in its own folder (one file each, except ResourceBar).

The click behaviour lives in `StatusIcon`. The trick is keeping `statusItem.menu` **empty at rest** — if a
menu stays attached, a left-click opens it and the action never fires, which defeats the whole point.
(ResourceBar does the same in `AppController`, because its item is a drawn 228 pt view rather than an
icon.)

---

## Notes

[docs/macos-notes.md](docs/macos-notes.md) is written in Korean and covers what actually cost time here: SIP
blocking `launchctl`, status icons silently banished behind the notch, TCC refusing the microphone because
of a missing entitlement rather than user choice, `do shell script` swallowing exit codes, pipe deadlock
when draining stdout and stderr in sequence, and losing an entire recording by not letting the file finalize.

[docs/resourcebar.md](docs/resourcebar.md) (Korean) covers the ResourceBar design, the spike-log rules and
the measurements against Stats.

## License

MIT — see [LICENSE](LICENSE)
