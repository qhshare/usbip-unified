# USBIP Unified Manager

English | [中文](README.md)

A Flutter desktop application for managing USB/IP on Linux and Windows. It
provides one interface for sharing local USB devices, connecting remote USB
devices, binding, unbinding, attaching, detaching, configuring ports, and
installing the native USB/IP components required by the host platform.

> Project status: early release (`0.1.0`). End-to-end USB/IP validation has
> been completed between Windows x64 and Linux amd64 using a loopback CH340
> serial device in both directions. Other USB device classes, concurrent
> devices, hot-plug/reconnect, high-bandwidth workloads, and long-duration
> stability still require testing.

## Contents

- [Features](#features)
- [How It Works](#how-it-works)
- [Support Matrix](#support-matrix)
- [Hardware Validation](#hardware-validation)
- [Run in 30 Seconds](#run-in-30-seconds)
- [Build from Source](#build-from-source)
- [Linux](#linux)
- [Windows](#windows)
- [Usage](#usage)
- [Offline Installation](#offline-installation)
- [Portable Releases](#portable-releases)
- [Development and Testing](#development-and-testing)
- [Release Process](#release-process)
- [Repository Layout](#repository-layout)
- [Building Guide](BUILDING.en.md)
- [Third-Party Sources and Licenses](#third-party-sources-and-licenses)
- [Third-Party Notices](#third-party-notices)
- [Security](#security)
- [Known Limitations](#known-limitations)

## Features

- Material 3 Flutter desktop interface shared by Linux and Windows.
- Explicitly separated server and client roles. A server lists local USB
  devices and provides bind/unbind actions; a client lists remote exports and
  provides attach/detach actions.
- Linux integration with the distribution's `usbip`, `usbipd`, and kernel
  modules.
- Windows server integration with `usbipd-win` and Windows client integration
  with `usbip-win2`.
- Displays local network addresses, the server listening port, the remote
  server address, and the remote server port.
- Custom TCP listening ports for the Linux server. Windows `usbipd-win` uses
  the fixed USB/IP port `3240`.
- Detailed operation logs containing the executed command, exit code, native
  output, and important workflow steps. This helps diagnose permissions,
  drivers, ports, and device state.
- Environment checks, online installation, bundled offline installation, and
  manual installation guidance in the settings page.
- Offline resources bundled as Flutter assets and selected according to the
  detected distribution and CPU architecture.

## How It Works

This is a new Flutter application developed from scratch. It does not combine
the user interfaces of the three reference projects and does not embed their
Tkinter or WPF interfaces:

```text
Flutter UI
    |
UsbIpService
    |
Native process boundary
    |-- Linux:   usbip / usbipd / usbip-host / vhci-hcd
    |-- Windows: usbipd-win / usbipd.exe
    `-- Windows: usbip-win2 / usbipw.exe / virtual USB driver
```

Flutter owns the interface, role state, input validation, native command
invocation, output parsing, and logs. The USB/IP protocol, Linux kernel
modules, Windows virtual USB driver, and Windows service registration remain
responsibilities of the operating system and native components. Copying a
Flutter directory cannot replace those components.

The source of the reference projects is stored under `third_party/` for
research into commands, drivers, and platform behavior. The application does
not run their old UIs. See [ARCHITECTURE.md](ARCHITECTURE.md) for the component
boundary and extension model.

## Support Matrix

| Platform / architecture | Server | Client | Bundled offline resources | Current status |
| --- | ---: | ---: | --- | --- |
| Linux Kali amd64 | Yes | Yes | `.deb` | Kali amd64 resources included |
| Linux Kali i386 | Yes | Yes | `.deb` | Requires 32-bit Kali userland and compatible kernel |
| Linux Kali arm64 | Yes | Yes | `.deb` | Requires a matching ARM64 kernel |
| Linux Kali armhf | Yes | Yes | `.deb` | Requires a matching ARM hard-float kernel |
| Debian 12 amd64 | Yes | Yes | `.deb` | Uses a separate Debian 12 resource set |
| Ubuntu / Fedora / Arch / Alpine | Depends on system tools | Depends on system tools | None | Use online installation or distribution-specific manual installation |
| Windows x64 | Yes | Yes | MSI + VC++ runtime + client files + drivers | `usbipd-win`, `usbipw.exe`, and virtual USB drivers included |
| Windows ARM64 | Yes | Yes | MSI + EXE | Uses matching ARM64 tools and drivers |
| Windows x86 (32-bit) | No | No | None | No complete supported 32-bit driver combination from the current upstreams |
| macOS | No | No | None | No maintained macOS USB/IP backend in this project |

“Supported” means that the code and command mapping exist. It does not mean
that every hardware device, kernel version, driver version, or network topology
has been tested on real hardware. Linux `.deb` files are not generic Linux
packages, and Windows offline resources must match the system architecture.

## Hardware Validation

On 2026-10-10, end-to-end USB/IP validation was completed between Windows x64
and Linux amd64 with a CH340 USB-to-serial adapter (`1a86:7523`). Its TX/RX
pins were shorted to form a loopback for bidirectional data testing.

| Direction | Server | Client | Result |
| --- | --- | --- | --- |
| Windows -> Linux | Windows 10 x64, `usbipd-win 5.3.0` | Kali amd64, `usbip` + `vhci_hcd` | Linux created `/dev/ttyUSB0` and loaded `ch341-uart`; at `9600 8N1` in raw mode, `55 AA 01 02 03 0D 0A` was sent and the identical bytes were received |
| Linux -> Windows | Kali amd64, `usbip` server | Windows 10 x64, `USBip-win2 0.9.8.0` | Windows attached the device as a COM serial port, and bidirectional send/receive testing passed |

These results validate the basic Windows server, Linux client, Linux server,
and Windows client workflows in the current release, as well as the
bidirectional CH340 serial data path. They do not establish compatibility for
all USB device classes, concurrent devices, hot-plug/reconnect, sleep/resume,
high-bandwidth workloads, or long-duration operation.

## Run in 30 Seconds

### Linux development run

Install Flutter stable and the Linux desktop build dependencies, then run:

```bash
git clone https://github.com/qhshare/usbip-unified.git
cd usbip-unified
flutter pub get
./run.sh
```

`run.sh` changes to the project directory, checks for Flutter, generates the
Flutter Linux runner through `tool/bootstrap.sh` if `linux/` is missing, and
then runs `flutter run -d linux`.

See [BUILDING.en.md](BUILDING.en.md) for build-host dependencies, source
initialization, tests, release builds, portable packaging, and GitHub Release
publishing.

### Windows development run

On Windows, install Flutter stable and Visual Studio with the **Desktop
development with C++** workload. From the project directory, run:

```bat
flutter pub get
run-windows.bat
```

If the `windows/` directory does not exist, the script invokes
`tool\bootstrap.bat`. A Linux build cannot replace real Windows testing for
drivers and USB/IP behavior.

## Build from Source

Build on a matching desktop host with Flutter stable and the platform toolchain.
The minimal Linux flow is:

```bash
flutter pub get
dart analyze lib test
flutter test
flutter build linux --release
```

Windows builds must run on Windows:

```bat
flutter pub get
dart analyze lib test
flutter test
flutter build windows --release
```

Create portable release archives with:

```bash
./tool/package-portable.sh linux
```

```bat
tool\package-portable.bat x64
tool\package-portable.bat arm64
```

Read [BUILDING.en.md](BUILDING.en.md) for prerequisites, `flutter doctor`
checks, ARM64 builds, checksums, troubleshooting, and GitHub Release steps.

## Linux

### Online installation

The settings page's online installer uses the package manager detected on the
host. The equivalent manual commands are:

```bash
# Debian / Ubuntu / Kali
sudo apt update
sudo apt install usbip

# Fedora
sudo dnf install usbip

# Arch Linux
sudo pacman -S usbip
```

Check the native command and kernel modules:

```bash
command -v usbip
modinfo usbip-core
modinfo usbip-host
modinfo vhci-hcd
```

A server commonly needs:

```bash
sudo modprobe usbip-core
sudo modprobe usbip-host
```

A client commonly needs:

```bash
sudo modprobe usbip-core
sudo modprobe vhci-hcd
```

The application may use `pkexec` or `sudo` when an operation needs elevated
privileges. Linux installation, binding, unbinding, attaching, and detaching
can all require root privileges.

### Linux offline resources

The repository includes multi-architecture Kali resources and a separate Debian
12 amd64 resource set. The settings page shows the detected operating system,
distribution, and architecture. The offline installation button is enabled
only when an exact bundled target matches the host.

The installer extracts assets into a temporary directory such as
`/tmp/usbip-unified-offline-XXXXXX/`, invokes `dpkg` with an explicit package
list, and removes the temporary directory when installation finishes. This is
necessary because Flutter assets are read-only at runtime. The packages are
not permanently installed into `/tmp`.

If `apt` or `dpkg` is already running, the installer stops and asks the user to
wait. It never deletes package-manager lock files.

The offline `.deb` files provide user-space tools and dependencies. They do not
include `libc6`, the kernel-specific `.ko` modules, or a universal Linux
kernel. `usbip-host` and `vhci-hcd` must come from the kernel running on the
target system. Do not force Kali packages onto Ubuntu, Fedora, or Arch Linux.

## Windows

### Server

The Windows server uses
[usbipd-win](https://github.com/dorssel/usbipd-win):

```powershell
winget install --id dorssel.usbipd-win --exact
usbipd list
Get-Service usbipd
```

The server workflow uses `usbipd bind --busid <BUSID>` and
`usbipd unbind --busid <BUSID>`. `usbipd-win` listens on the fixed USB/IP TCP
port `3240`. The application does not pretend that this Windows service port
is configurable. For an external port, use FRP, a VPN, or router port mapping.

### Client

The Windows client uses
[usbip-win2](https://github.com/vadimgrn/usbip-win2), including its virtual USB
driver:

```powershell
usbipw.exe list -r <server-address>
```

Client installation involves a kernel driver and UAC elevation. Use a package
matching the Windows architecture, read the corresponding release notes, and
create a system restore point before installing a driver. The bundled client
versions are x64 `0.9.8.0` and ARM64 `0.9.7.5`. The x64 release executes the
official USBip-win2 installer as a versioned unit. That installer owns the
client files, DLLs, signed driver packages, driver services, and virtual USB
device registration. The application does not copy a fixed `client/`
directory and does not call `pnputil` directly. The x64 package also includes
the Microsoft Visual C++ runtime required by `usbipw.exe`. These are the
resource choices in this repository, not a claim that every release is
suitable for production.

The Windows client remote port must match the actual server port or the FRP
mapping port. The application accepts Windows client ports from `1024` through
`65535`; Linux clients accept `1` through `65535`.

## Usage

### As a server

1. Select **Linux Server** or **Windows Server** at the top of the application
   or in settings.
2. Select **Refresh devices** and confirm that local USB devices and BUSIDs are
   listed.
3. Check the local IP addresses and TCP port displayed on the overview page.
   A server may have multiple network interfaces; use an address reachable by
   the client.
4. Select a device and click **Bind / Share**. Linux checks or starts
   `usbipd`; Windows uses the `usbipd-win` service.
5. Give the trusted client the displayed `IP:port`. Do not unplug or unbind the
   device while a client is using it.
6. After the client detaches, click **Unbind**. Devices that are already shared
   or connected are protected against repeated binding and unsafe unbinding.

### As a client

1. Select **Linux Client** or **Windows Client**.
2. Enter the remote server address and port in settings.
3. Click **Apply and refresh** or **Refresh devices** to list remote exports.
4. Select a device and click **Attach**. The application obtains connection
   state from the local `usbip port` output. If this query fails, attach and
   detach actions are disabled rather than treating an unknown state as
   disconnected.
5. Use **Detach** to release the local virtual USB port. Detach uses the local
   port number, not the remote BUSID.

### Command-line equivalents

Linux server:

```bash
usbip list -l
sudo usbip bind -b 1-2
sudo usbip unbind -b 1-2
```

Linux client:

```bash
usbip --tcp-port 3240 list -r 192.168.1.20
sudo usbip --tcp-port 3240 attach -r 192.168.1.20 -b 1-2
usbip port
sudo usbip detach -p 00
```

Windows server:

```powershell
usbipd list
usbipd bind --busid 4-3
usbipd unbind --busid 4-3
```

Windows client:

```powershell
usbipw.exe list -r 192.168.1.20
usbipw.exe attach -r 192.168.1.20 -b 1-2
usbipw.exe port
usbipw.exe detach -p 00
```

## Offline Installation

Offline installation resources are stored in `offline/` and included as
Flutter assets in the desktop release bundle. The current resource set
contains:

- Windows x64: the `usbipd-win_5.3.0_x64.msi` server installer, the official
  `VC_redist.x64.exe`, and the official `USBip-0.9.8.0-x64.exe` USBip-win2
  client installer. The USBip-win2 installer deploys the client files, DLLs,
  signed driver packages, driver services, and virtual USB device node as one
  versioned installation. The Flutter application does not copy a fixed
  `client/` payload and does not call `pnputil` directly.
- Windows ARM64: the `usbipd-win` MSI and an ARM64 installer containing the
  matching client and driver set.
- Kali amd64/i386/arm64/armhf: matching `.deb` packages.
- Debian 12 amd64: a separate Debian 12 `.deb` package set.
- `offline/licenses/`: license texts shipped with the redistributable binaries.
- `offline/SHA256SUMS`: resource integrity manifest.

Verify the resources:

```bash
cd offline
sha256sum -c SHA256SUMS
```

The Windows offline installer supports separate roles: `-Server` installs only
the sharing side, `-Client` installs the client and virtual USB drivers, and
`-Server -Client` installs both. On Windows x64, `-Client` first installs the
official Microsoft Visual C++ x64 runtime and then executes the bundled
`USBip-0.9.8.0-x64.exe` installer. The official installer owns the client
files, DLLs, driver services, and virtual USB device registration; the project
script does not manually copy client files or call `pnputil`. ARM64 uses its
architecture-specific installer. The script verifies `usbipd.exe`, the
`usbipd` service, `usbipd list`, the client executable, the client driver
services, and the virtual USB device node after installation. If the driver
service exists but Windows has not created the virtual device node yet, the
result is marked as requiring a restart rather than being reported as fully
ready.

The bundled VC++ runtime is downloaded from Microsoft's official endpoint:

```text
https://aka.ms/vs/17/release/vc_redist.x64.exe
SHA256: cc0ff0eb1dc3f5188ae6300faef32bf5beeba4bdd6e8e445a9184072096b713b
```

Redistribution must comply with the Microsoft Visual C++ Redistributable
license. Keep the applicable notices in `offline/licenses/` and review the
current Microsoft terms before publishing a release.

When the target system has no matching resource, the application disables
offline installation and provides online installation and manual guidance.
Adding a distribution requires matching packages, dependency versions, an
installer path, asset declarations, checksums, tests, and documentation. Do
not copy a `.deb` from another distribution just because the CPU architecture
matches.

See [offline/README.md](offline/README.md) for the resource matrix, direct
installer commands, checksum procedure, and instructions for adding a new
target.

## Portable Releases

The Flutter desktop application is distributed as an extract-and-run directory.
It does not require an MSI, `.deb`, registry entries, or the Flutter SDK on the
target machine. The **Check environment** action is read-only and the portable
EXE does not install system components just by starting. Native USB/IP tools and
drivers still need to be supplied by the target system or by the application's
installer. On Windows, the server requires the registered `usbipd` service and
the client requires the `usbip2_ude`/`usbip2_filter` kernel drivers and virtual
USB device node, so the full Windows backend cannot be completely portable. If
those components are already installed and pass the environment check, the GUI
can be used without installing them again.

Build Linux on a Linux host:

```bash
./tool/package-portable.sh linux
```

If the build host cannot reach `pub.dev` but has already run `flutter pub get`
successfully, reuse the existing `.dart_tool/package_config.json`:

```bash
./tool/package-portable.sh linux --no-pub
```

`--no-pub` skips dependency resolution and the `flutter clean` command, but
still removes `build/` and `.dart_tool/flutter_build`, which is useful for
repeating a build offline. If `.dart_tool/package_config.json` is missing, run
`flutter pub get` once on a network-enabled host. After changing dependencies or
`pubspec.yaml`, run the normal dependency-resolution flow instead of reusing the
old package configuration.

Output:

```text
dist/usbip-unified-linux-x64-portable-20261010.17.tar.gz
```

Build Windows on a Windows build host:

```bat
tool\package-portable.bat x64
tool\package-portable.bat arm64
```

If the Windows build host already has a usable
`.dart_tool\package_config.json` but cannot reach `pub.dev`, skip dependency
resolution with:

```bat
tool\package-portable.bat x64 --no-pub
tool\package-portable.bat arm64 --no-pub
```

The default packaging flow runs `flutter clean` and `flutter pub get`, rebuilds
the Windows release, and verifies that
`data\flutter_assets\offline\install-windows-offline.ps1` matches the source
file. `--no-pub` reuses the existing dependency configuration, skips those two
commands, and still removes `build/` and `.dart_tool/flutter_build`. Both modes
perform the bundle checks. After changing the source or offline installer, do
not reuse an old `build/windows` directory or
ZIP; run the packaging command again. Windows PowerShell 5.1 can misread UTF-8
scripts without a BOM, so the offline installer is intentionally ASCII-only to
prevent encoding-related parse errors.
The build number is shown in the native window title, the page subtitle, and
the startup log, for example `0.1.0+20261010.17`. If that build number is not
visible, the running `usbip_unified.exe` is an older release. Replacing only a
PowerShell script in a temporary directory does not update the GUI's
executable discovery code; rebuild and extract the complete portable ZIP.

After launching the new package, confirm the build number first, then run the
environment check and refresh devices. Do not mix files from an old extracted
directory with a new package; extract the complete
`dist\usbip-unified-windows-x64-portable-20261010.17.zip` (or the matching
ARM64 archive).

Output:

```text
dist/usbip-unified-windows-x64-portable-20261010.17.zip
dist/usbip-unified-windows-arm64-portable-20261010.17.zip
```

Extract the archive and run `usbip_unified` on Linux or
`usbip_unified.exe` on Windows. Keep the adjacent `data/` directory. The
`offline/` resources are inside the Flutter asset bundle. `dist/`, `build/`,
and local development environments are ignored by Git; upload release
archives to GitHub Releases rather than committing them to the source tree.

## Development and Testing

Install dependencies:

```bash
flutter pub get
```

Only run `./tool/bootstrap.sh` or `tool\bootstrap.bat` when the `linux/` or
`windows/` runner directory is missing. Bootstrap may overwrite local runner
changes, so commit or back up those changes first.

Recommended checks before committing:

```bash
dart format --output=none --set-exit-if-changed lib test
dart analyze lib test
flutter test
./tool/check-repository.sh
```

Linux release build:

```bash
flutter build linux --release
```

Windows release builds must run on Windows:

```bat
flutter build windows --release
```

Update the vendored reference sources:

```bash
./tool/update-upstream.sh
```

After an update, record the new commit IDs in
`third_party/SOURCES.lock`. When reference sources are committed as ordinary
files, do not include their internal `.git/` directories. Keep the source,
license, and source lock information. Run `./tool/check-repository.sh` before
publishing to detect accidental nested repositories or local credentials.

## Release Process

The project repository is `https://github.com/qhshare/usbip-unified`, and the
default branch is `main`. For a new release:

1. Update the version in `pubspec.yaml` and `CHANGELOG.md`, then confirm the
   source, offline resources, and documentation all belong to that version.
2. Run `dart format --output=none --set-exit-if-changed lib test`,
   `dart analyze`, `flutter test`,
   `./tool/check-repository.sh`, and the offline checksum verification. Complete
   platform validation on Linux and Windows build hosts as applicable.
3. On the Linux build host, run `./tool/package-portable.sh linux`. On the
   Windows build host, run `tool\package-portable.bat x64` and, when needed,
   `arm64`. Archive names include the build number after `+` in
   `pubspec.yaml`; for the current version they are
   `usbip-unified-linux-x64-portable-20261010.17.tar.gz` and
   `usbip-unified-windows-x64-portable-20261010.17.zip`.
4. Generate checksums only for archives from the current build:

```bash
build="$(sed -n 's/^version: //p' pubspec.yaml)"
build="${build#*+}"
(
  cd dist
  find . -maxdepth 1 -type f \
    \( -name "usbip-unified-*-portable-${build}.tar.gz" \
       -o -name "usbip-unified-*-portable-${build}.zip" \) \
    -printf '%f\0' | sort -z | xargs -0 -r sha256sum > "SHA256SUMS-${build}.txt"
  test -s "SHA256SUMS-${build}.txt" || {
    rm -f "SHA256SUMS-${build}.txt"
    echo "No portable archives found for build ${build}." >&2
    exit 1
  }
)
```

For the current version this writes `dist/SHA256SUMS-20261010.17.txt`.

5. Commit source, tests, scripts, documentation, and required `offline/`
   resources. Confirm that `dist/`, `build/`, `.dart_tool/`, `.tmp/`, Wine
   environments, and nested third-party `.git/` directories are not staged.
   Offline resources are committed with the source; current files are below
   GitHub's 100 MB per-file limit. Use Git LFS or GitHub Release assets for
   future large installers.
6. Push `main`, create the version tag and GitHub Release. The current version
   uses tag `v0.1.0-20261010.17`; upload the Linux/Windows archives and
   `SHA256SUMS-<build>.txt` as Release assets. Keep third-party notices,
   offline licenses, and Release notes traceable in the source repository. If
   they are not included in the portable archives, upload or link them from the
   Release page.

Do not commit `dist/` or Release assets to source history. The GitHub Actions
workflow at `.github/workflows/ci.yml` runs formatting, static analysis, tests,
repository checks, offline checksum verification, and the Linux release build.
It does not build Windows packages, upload artifacts, or create a GitHub
Release.

## Repository Layout

```text
.github/workflows/ci.yml     GitHub Actions checks and Linux release build
lib/                         Flutter UI and Dart service layer
test/                        Unit tests and widget tests
linux/                       Flutter Linux runner
windows/                     Flutter Windows runner
offline/                     Deliberately shipped installers and checksums
third_party/                 Upstream reference sources and source lock
tool/                        Bootstrap, packaging, update, and check scripts
run.sh                       Linux development run script
run-windows.bat              Windows development run script
tool/package-portable.sh     Linux portable packaging script
tool/package-portable.bat    Windows portable packaging script
BUILDING.en.md               Source build, test, packaging, and release guide
ARCHITECTURE.md              Module boundaries and data flow
CONTRIBUTING.md              Development and pull request guidance
SECURITY.md                  Security boundaries and vulnerability reporting
CHANGELOG.md                 Version history
THIRD_PARTY_NOTICES.md       Third-party source and binary notices
```

The following should not be committed: `.dart_tool/`, `build/`, `dist/`,
`.tmp/`, `.wine*/`, IDE-private configuration, logs, and local credentials.
`pubspec.lock` should be committed.

## Third-Party Sources and Licenses

The main application is distributed under the MIT License in [LICENSE](LICENSE).
The reference projects and native tools remain subject to their own licenses:

- [K-Francis-H/usbip-gui](https://github.com/K-Francis-H/usbip-gui)
- [Snakefoxu/SnakeUSBIP](https://github.com/Snakefoxu/SnakeUSBIP)
- [Snakefoxu/SnakeUSBIP-Server](https://github.com/Snakefoxu/SnakeUSBIP-Server)

The three reference snapshots are GPL-3.0 according to the source lock. Their
source, license files, and exact revisions are stored under `third_party/`.
Do not copy GPL-3.0 implementation code into the MIT-licensed application
without completing a license review and updating the distribution notices.

Windows `usbipd-win`, Windows `usbip-win2`, and Linux `usbip` are also governed
by their respective upstream licenses. Before redistributing binary resources,
retain the applicable license files and review the upstream release terms.

See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for the component list,
license locations, source revisions, and binary redistribution reminders.

## Third-Party Notices

The reference projects are not runtime dependencies of the Flutter application.
Their source is not imported into `lib/`, and their original desktop UIs are
not launched by the product. They are kept for protocol, command, driver, and
platform compatibility research.

The exact revisions of the source snapshots are recorded in
`third_party/SOURCES.lock`. Offline binary resources are covered by
`offline/SHA256SUMS`. Keep all required notices when updating or publishing
these resources.

## Security

USB/IP commonly uses TCP `3240` and does not provide end-to-end encryption or
authentication by itself. Do not expose the port directly to an untrusted
public network. For cross-network use, prefer WireGuard, Tailscale, ZeroTier,
or another controlled VPN, and restrict the firewall to trusted networks. If
using FRP, configure authentication and access controls.

Binding, sharing, and attaching give a remote host access to the USB device.
A device is normally exclusive to one client. Driver installation, UAC, root,
`pkexec`, `sudo`, and package-manager operations can change system state.
Review the command, package source, target device, and network exposure before
confirming an operation.

## Known Limitations

- There is currently no account system, multi-node discovery, device scheduler,
  or access-control service.
- USB/IP does not encrypt device data at the application layer.
- Windows x86 (32-bit) has no bundled complete toolchain and is unsupported.
- Linux offline packages cover only the distributions and architectures listed
  in the support matrix. Other distributions must use their own online or
  manual packages.
- Linux kernel modules and Windows virtual USB drivers cannot be made universal
  by copying them into a Flutter runtime bundle.
- Current hardware validation only covers a CH340 serial device between Windows
  x64 and Linux amd64. Other USB device classes, concurrent devices,
  hot-plug/reconnect, sleep/resume, high-bandwidth workloads, and long-duration
  stability still require separate testing.

## Related Documentation

- [ARCHITECTURE.md](ARCHITECTURE.md)
- [offline/README.md](offline/README.md)
- [third_party/README.md](third_party/README.md)
- [CONTRIBUTING.md](CONTRIBUTING.md)
- [SECURITY.md](SECURITY.md)
- [CHANGELOG.md](CHANGELOG.md)
- [BUILDING.en.md](BUILDING.en.md)
- [第三方声明 / Third-Party Notices](THIRD_PARTY_NOTICES.md)
