# Upstream Reference Sources

This directory contains vendored source snapshots of the three upstream
projects used for protocol, driver, command-line, and platform-behavior
research. Their local Git metadata is intentionally not part of this
repository. They are reference material, not runtime dependencies of this
application. The Flutter application does not load, launch, or embed their
Python, WPF, or Tkinter UI; the product UI and domain model are new code under
`lib/`.

| Directory | Upstream | Role in this project | License |
| --- | --- | --- | --- |
| `k-francis-usbip-gui` | [K-Francis-H/usbip-gui](https://github.com/K-Francis-H/usbip-gui) | Linux USB/IP command and module workflow reference | GPL-3.0 |
| `snakeusbip` | [Snakefoxu/SnakeUSBIP](https://github.com/Snakefoxu/SnakeUSBIP) | Windows client workflow, driver and connection behavior reference | GPL-3.0 |
| `snakeusbip-server` | [Snakefoxu/SnakeUSBIP-Server](https://github.com/Snakefoxu/SnakeUSBIP-Server) | Windows server workflow, `usbipd-win` and firewall behavior reference | GPL-3.0 |

The repository uses the vendored-snapshot layout: source files and upstream
license files are committed as ordinary files, while nested `.git` directories
are removed. This makes a fresh GitHub clone self-contained and avoids
accidental gitlinks. `SOURCES.lock` records the exact revisions independently
of local checkout metadata. The application does not import code from these
directories.

The exact shallow-clone revisions used during this development pass are listed
in `SOURCES.lock`. All three upstream projects are GPL-3.0. The main Flutter
application is MIT-licensed, but that does not relicense the reference sources:
their source snapshots, notices, and any derivative code remain subject to the
applicable upstream license. Do not copy GPL implementation code into `lib/`
without completing a license review and updating the distribution notices.

The Flutter project currently uses the native platform tools rather than
linking against the upstream desktop applications:

```text
Linux       -> usbip / usbipd / kernel modules
Windows     -> usbipd-win or usbip-win2
Flutter UI  -> lib/main.dart and lib/services/usbip_service.dart
```

## Updating the references

Use the helper from the repository root to refresh the snapshots:

```bash
./tool/update-upstream.sh
```

The helper clones each upstream repository with depth one, replaces the
corresponding snapshot directory, and prints the new commit ID. It intentionally
removes files that no longer exist upstream. After an update, verify the license
files, inspect the diff, and update `SOURCES.lock` with the resulting commit IDs.
A source refresh is not a product feature by itself and must not change the
runtime command adapter without tests.

## Publishing checklist

Before pushing this directory to GitHub:

1. Ensure each included project has its original license and notices.
2. Confirm no nested `.git` metadata exists under `third_party/`.
3. Confirm `SOURCES.lock` matches the included source revisions.
4. Run `./tool/check-repository.sh` from the project root.
