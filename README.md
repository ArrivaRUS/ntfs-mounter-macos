# NTFS Mounter for macOS

**English** | [Русский](README.ru.md)

[![CI](https://github.com/ArrivaRUS/ntfs-mounter-macos/actions/workflows/ci.yml/badge.svg)](https://github.com/ArrivaRUS/ntfs-mounter-macos/actions/workflows/ci.yml)

NTFS read/write support for macOS on Apple Silicon — **no kernel extensions, no Reduced Security mode**. Pairs the user-space [FUSE-T](https://github.com/macos-fuse-t/fuse-t) with the [macos-fuse-t/ntfs-3g](https://github.com/macos-fuse-t/ntfs-3g) fork, and wraps them with:

- a CLI (`ntfs-mount list / mount / unmount / eject / auto`),
- a **LaunchDaemon** that automatically mounts every NTFS drive in read/write as soon as it's plugged in,
- a **menu-bar app** with per-drive Eject buttons,
- automatic defence against Apple's built-in FSKit NTFS driver (which silently re-mounts the same disk read-only in parallel on macOS Tahoe).

Tested on **macOS 26 Tahoe / Apple Silicon**.

## Why

macOS reads NTFS but can't write to it. Standard solutions either cost money (Paragon, Tuxera) or require disabling SIP / installing kernel extensions (classic macFUSE). FUSE-T runs entirely in user space (it talks to the kernel through a tiny NFS shim), so:

- no kext to install,
- no need to lower System Integrity Protection,
- no need to reboot into Recovery mode.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│   Menu-bar app (Swift)            macOS GUI                 │
│   - builds menu on open from `ntfs-mount list --porcelain`  │
│   - "● RW" / "○ RO" indicator per drive                     │
│   - Eject per disk / Eject All / Open in Finder             │
│   - privileged ops via sudo -n, fallback to admin prompt    │
└──────────────────────┬──────────────────────────────────────┘
                       │ calls `ntfs-mount eject / mount`
┌──────────────────────┴──────────────────────────────────────┐
│   ntfs-mount (bash CLI)                                     │
│   - parses `diskutil list` + `mount`                        │
│   - hot-replaces zombie mounts from old device IDs          │
│   - kills Apple's parallel FSKit-NTFS mounts                │
│   - label-scoped eject: unmount FUSE-T mount + SIGTERM      │
│     ntfs-3g, then `diskutil eject`                          │
└──────────────────────┬──────────────────────────────────────┘
                       │ uses
┌──────────────────────┴──────────────────────────────────────┐
│   ntfs-3g (binary, built from macos-fuse-t/ntfs-3g)         │
│   ← talks to FUSE-T via libfuse-t                           │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│   automount-daemon (LaunchDaemon, root)                     │
│   - polls every 3s via `ntfs-mount list --porcelain`        │
│   - new NTFS drive → mounts RW                              │
│   - Apple FSKit parasite re-appears → unmounts it           │
│   - resolves owner uid via /dev/console (the GUI user)      │
│   - respects eject markers in /var/run/ntfs-mount           │
└─────────────────────────────────────────────────────────────┘
```

## Install

```bash
git clone https://github.com/ArrivaRUS/ntfs-mounter-macos.git
cd ntfs-mounter-macos

# 1. The driver (FUSE-T + ntfs-3g) + CLI
bash install.sh

# 2. The GUI (menu-bar app) + auto-mount daemon
bash install-gui.sh

# 3. Full-Disk Access for the daemon (required since macOS Sequoia)
bash grant-permissions.sh
```

The third step is the only non-obvious one. Even running as root, a LaunchDaemon cannot open `/dev/diskX` raw devices unless you've explicitly given Full Disk Access to **both**:

- `/usr/local/bin/ntfs-3g` (the binary that does the raw read/write)
- `/bin/bash` (the daemon's interpreter)

`grant-permissions.sh` opens the right System Settings page and walks you through it.

> **Note:** FDA grants are tied to the binary's hash. If you rebuild/reinstall `ntfs-3g`, re-add it in System Settings → Privacy & Security → Full Disk Access.

## Usage

After install, just **plug in an NTFS drive**. Within ~5–10 seconds it appears mounted read/write at `/Volumes/<label>`, and the menu-bar icon shows it with a `● RW` tag.

For manual control:

```bash
ntfs-mount list                 # all NTFS volumes with their RO/RW status
ntfs-mount list --porcelain     # machine-readable: device|label|fs|mountpoint|state
ntfs-mount mount disk4s1        # remount this disk as RW (by id or label)
ntfs-mount mount all
ntfs-mount unmount disk4s1
ntfs-mount eject disk4s1        # unmount + gracefully stop ntfs-3g + diskutil eject
ntfs-mount auto                 # remount all NTFS as RW

NTFS_MOUNT_DEBUG=1 ntfs-mount mount disk4s1   # per-step trace for diagnostics
```

To re-format a drive whose NTFS got corrupted beyond repair (erases everything, asks for confirmation):

```bash
LABEL="MyDrive" bash format-ntfs.sh
```

## Known sharp edges this project solves

These are real problems we hit while building this, and the workarounds are baked into the scripts:

| Problem | What the scripts do |
|---|---|
| Homebrew cask `fuse-t` sometimes registers as installed but never runs the `.pkg` | `install.sh` runs `installer` directly if `/usr/local/lib/libfuse-t.dylib` is missing |
| `autoreconf` on `macos-fuse-t/ntfs-3g` puts `ltmain.sh` in `..` instead of `.` (LT_INIT hidden behind `m4_ifdef`) | `install.sh` copies it back and re-runs `autoreconf` |
| macOS bash is **3.2** — no associative arrays, no `printf '%(...)T'`, UTF-8 ellipsis breaks `$VAR…` parsing | All scripts are bash-3.2-compatible (no `declare -A`, ASCII only near variables) |
| LaunchDaemon gets `Operation not permitted` on `/dev/diskX` even as root | `grant-permissions.sh` opens System Settings → Full Disk Access page |
| macOS Tahoe FSKit silently re-mounts every NTFS read-only in parallel, blocking writes | Daemon detects parasitic `fskit`/`read-only` mounts and unmounts them every cycle |
| Zombie `ntfs-3g` processes survive a USB unplug and keep holding `/Volumes/<label>` with stale data | `mount_one` inspects `ps -o args=` and kills ntfs-3g processes whose `/dev/diskX` no longer matches the current device |
| When daemon runs as root, `$(id -un)` returns `root` and the mount ends up with `uid=0` (nobody but root can write) | `resolve_owner` first reads `NTFS_OWNER_USER` env, then falls back to `stat -f '%Su' /dev/console`, then to first uid≥501 from `dscl` — and refuses to mount if it still gets `0` |
| `diskutil info` doesn't report mount points for FUSE-T NFS-based mounts | Parser falls back to `/sbin/mount` matching by `/dev/diskX`, then by `fuse-t:/<label>`, then by guessing `/Volumes/<label>` |
| `diskutil eject` always fails with "Volume failed to eject" while a FUSE-T mount is alive — DiskArbitration simply doesn't see NFS-style mounts | `eject` explicitly unmounts the FUSE-T mount (scoped to *this* disk's label, so a second NTFS drive is untouched), SIGTERMs ntfs-3g, then runs `diskutil eject` |
| `set -e` + command substitution of tools that return non-zero on success (`ntfsfix` journal replay, `diskutil unmount` of unmounted path) silently killed the script mid-function | Scripts run with `set -uo pipefail` only; critical exit codes are checked explicitly |
| Apple's Spotlight and `fseventsd` hold files open on NTFS volumes, breaking Finder's move-to-Trash with "object is in use" | After every mount the utility runs `mdutil -i off` on the volume and touches `.fseventsd/no_log` |
| NTFS volumes silently accumulate journal/MFT damage on macOS (no native chkdsk) and start refusing `rmdir` | `ntfs-3g` mounts with the `recover` option (journal replay); for real MFT damage use `chkdsk /f` on Windows — or `format-ntfs.sh` if the data is expendable |

## Components

| File | What it is |
|---|---|
| `install.sh` | Installs FUSE-T pkg, builds ntfs-3g from source, installs CLI |
| `install-gui.sh` | Compiles `NTFSMounter.swift` into `~/Applications/NTFSMounter.app`, sets up LaunchDaemon + LaunchAgent |
| `grant-permissions.sh` | Walks user through giving Full Disk Access to `ntfs-3g` and `/bin/bash` |
| `uninstall-gui.sh` | Removes the GUI layer (keeps driver/CLI) |
| `format-ntfs.sh` | Safe re-format of a drive to fresh NTFS (asks for `YES` confirmation) |
| `ntfs-mount` | bash CLI — mount/unmount/eject/list logic, FSKit-killing, zombie cleanup, owner resolution |
| `automount-daemon.sh` | Polling loop (bash 3.2 compatible) — calls `ntfs-mount` on state changes |
| `NTFSMounter.swift` | Menu-bar app using `NSStatusBar` + `externaldrive.fill` SF Symbol |
| `com.user.ntfs-automount.plist` | LaunchDaemon plist (root, KeepAlive) |
| `com.user.ntfsmounter.plist` | LaunchAgent plist (user, KeepAlive, log to `~/Library/Logs/NTFSMounter.log`) |

## Performance

FUSE-T routes I/O through a user-space NFS server, so throughput is noticeably below kernel-mode drivers like macFUSE or Paragon. Expect roughly **20–60 MB/s** for sequential I/O on USB 3 SSDs — fine for browsing, editing documents, copying medium files. For 100GB+ disk-to-disk transfers, commercial drivers will be faster.

## Caveats

- **Don't pull the plug.** Always Eject through the menu-bar (or `ntfs-mount eject`). FUSE-T caches writes; physical disconnect without sync risks NTFS journal damage.
- After the first write to a drive that was last touched by Windows with **Fast Startup** enabled, macOS may pop up "Disk needs to be checked" — this is the NTFS journal flag flipping. Press *Skip* / *Ignore*.
- The Apple FSKit NTFS driver on macOS Tahoe **will** keep trying to mount your drive in parallel. The daemon keeps killing it. If you stop the daemon (`sudo launchctl bootout system/com.user.ntfs-automount`), you'll be back to read-only mode within seconds.
- **macOS has no full NTFS repair tool.** `ntfsfix` shipped with this project only replays the journal — it can't fix MFT-level corruption. If you see phantom directories that refuse to `rmdir` with `Directory not empty`, plug the disk into a **Windows machine** and run `chkdsk D: /f /r` — or, if the data is expendable, re-format with `format-ntfs.sh`.
- **Never `kill -9` ntfs-3g manually.** Hard-killing it tears down the FUSE-T NFS channel mid-flight, and macOS *ejects the entire USB device*. The `eject` command unmounts first and stops ntfs-3g with SIGTERM (graceful) — it only escalates if the process ignores it.

## Uninstall

```bash
bash uninstall-gui.sh                                # GUI + daemon
sudo rm -f /usr/local/bin/ntfs-mount \
           /usr/local/bin/ntfs-3g \
           /usr/local/bin/ntfsfix \
           /usr/local/sbin/mount.ntfs-3g
brew uninstall --cask macos-fuse-t/homebrew-cask/fuse-t
```

## License

MIT. The bundled ntfs-3g build is built from [macos-fuse-t/ntfs-3g](https://github.com/macos-fuse-t/ntfs-3g) (GPL-2.0 + LGPL-2.0). FUSE-T is its own license — see [its repo](https://github.com/macos-fuse-t/fuse-t).
