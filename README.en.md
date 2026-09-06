# USBIP Unified Manager

English | [中文](README.md)

A Flutter desktop application for managing USB/IP on Linux and Windows. It
provides one interface for sharing local USB devices, connecting remote USB
devices, binding, unbinding, attaching, detaching, configuring ports, and
installing the native USB/IP components required by the host platform.

> Project status: early release (`0.1.0`). The Linux workflow has been verified
> in the development environment. Windows drivers, UAC elevation, firewall
> behavior, and real USB/IP connections still require verification on Windows
> x64 and ARM64 hardware.

## Contents

- [Features](#features)
- [How It Works](#how-it-works)
- [Support Matrix](#support-matrix)
- [Run in 30 Seconds](#run-in-30-seconds)
- [Build from Source](#build-from-source)
- [Linux](#linux)
- [Windows](#windows)
- [Usage](#usage)
- [Offline Installation](#offline-installation)
- [Portable Releases](#portable-releases)
- [Development and Testing](#development-and-testing)
- [Publishing to GitHub](#publishing-to-github)
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
| Windows x64 | Yes | Yes | MSI + EXE | `usbipd-win` and `usbip-win2` resources included |
| Windows ARM64 | Yes | Yes | MSI + EXE | Uses matching ARM64 tools and drivers |
| Windows x86 (32-bit) | No | No | None | No complete supported 32-bit driver combination from the current upstreams |
| macOS | No | No | None | No maintained macOS USB/IP backend in this project |

“Supported” means that the code and command mapping exist. It does not mean
that every hardware device, kernel version, driver version, or network topology
has been tested on real hardware. Linux `.deb` files are not generic Linux
packages, and Windows offline resources must match the system architecture.

## Run in 30 Seconds

### Linux development run

Install Flutter stable and the Linux desktop build dependencies, then run:

```bash
cd USBIP-整合
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
versions are x64 `0.9.7.7` and ARM64 `0.9.7.5`. These are the resource choices
in this repository, not a claim that every release is suitable for production.

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

- Windows x64/ARM64: `usbipd-win` MSI and `usbip-win2` client installers.
- Kali amd64/i386/arm64/armhf: matching `.deb` packages.
- Debian 12 amd64: a separate Debian 12 `.deb` package set.
- `offline/licenses/`: license texts shipped with the redistributable binaries.
- `offline/SHA256SUMS`: resource integrity manifest.

Verify the resources:

```bash
cd offline
sha256sum -c SHA256SUMS
```

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
target machine. Native USB/IP tools and drivers still need to be supplied by
the target system or by the application's installer.

Build Linux on a Linux host:

```bash
./tool/bootstrap.sh
./tool/package-portable.sh linux
```

Output:

```text
dist/usbip-unified-linux-x64-portable.tar.gz
```

Build Windows on a Windows build host:

```bat
tool\bootstrap.bat
tool\package-portable.bat x64
tool\package-portable.bat arm64
```

Output:

```text
dist/usbip-unified-windows-x64-portable.zip
dist/usbip-unified-windows-arm64-portable.zip
```

Extract the archive and run `usbip_unified` on Linux or
`usbip_unified.exe` on Windows. Keep the adjacent `data/` directory. The
`offline/` resources are inside the Flutter asset bundle. `dist/`, `build/`,
and local development environments are ignored by Git; upload release
archives to GitHub Releases rather than committing them to the source tree.

## Development and Testing

Initialize or regenerate the desktop runners:

```bash
./tool/bootstrap.sh
flutter pub get
```

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

## Publishing to GitHub

The project has its own local Git repository. After creating an empty GitHub
repository, run from the project root:

```bash
git remote add origin https://github.com/<your-user>/<repository>.git
git add -A
git status --short
git commit -m "Initial USBIP Unified Manager release"
git push -u origin main
```

Before pushing, confirm that the status does not include `.dart_tool/`,
`build/`, `dist/`, `.tmp/`, `.wine*/`, IDE-private configuration, or nested
third-party `.git` metadata. `pubspec.lock` should be committed to keep the
resolved Flutter/Dart dependency versions reproducible.

The current offline resource files are below GitHub's 100 MB single-file
limit. If future installers exceed that limit, use Git LFS or GitHub Releases
instead of adding large binaries to the source history.

After pushing the source, upload the Linux and Windows portable archives from
`dist/` as GitHub Release assets. Include `THIRD_PARTY_NOTICES.md`, checksums,
and the target architecture information with the release. Do not commit the
`dist/` directory to the source repository.

## Repository Layout

```text
lib/                         Flutter UI and Dart service layer
test/                        Unit tests and widget tests
linux/                       Flutter Linux runner
windows/                     Flutter Windows runner
offline/                     Deliberately shipped installers and checksums
third_party/                 Upstream reference sources and source lock
tool/                        Bootstrap, packaging, update, and check scripts
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
- Windows driver signing, UAC, firewall behavior, sleep/resume, and combinations
  of real USB devices still require verification on the corresponding Windows
  versions.

## Related Documentation

- [ARCHITECTURE.md](ARCHITECTURE.md)
- [offline/README.md](offline/README.md)
- [third_party/README.md](third_party/README.md)
- [CONTRIBUTING.md](CONTRIBUTING.md)
- [SECURITY.md](SECURITY.md)
- [CHANGELOG.md](CHANGELOG.md)
- [BUILDING.en.md](BUILDING.en.md)
- [第三方声明 / Third-Party Notices](THIRD_PARTY_NOTICES.md)
