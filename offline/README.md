# Offline Resources

`offline/` contains the native installers intentionally shipped as Flutter
assets. It is a small, versioned target matrix, not a universal package mirror.

Linux distributions do not share one safe binary package format. A Debian
`.deb` cannot replace an RPM, APK, or Arch package, and USB/IP kernel modules
must match the running kernel. The application therefore enables offline
installation only for a concrete operating system and architecture combination.

## Resource matrix

| Target | Directory | Included resources | Roles |
| --- | --- | --- | --- |
| Windows x64 | `windows/x64/` | `usbipd-win_5.3.0_x64.msi`, `VC_redist.x64.exe`, official `USBip-0.9.8.0-x64.exe` client installer | Server + client |
| Windows ARM64 | `windows/arm64/` | `usbipd-win_5.3.0_arm64.msi`, `USBip-0.9.7.5-arm64-release.exe` | Server + client |
| Kali amd64 | `linux/kali-amd64/` | `usbip`, `libudev1`, `libwrap0`, `usb.ids` `.deb` | Server + client |
| Kali i386 | `linux/kali-i386/` | `usbip`, `libudev1`, `libwrap0`, `usb.ids` `.deb` | Server + client |
| Kali ARM64 | `linux/kali-arm64/` | `usbip`, `libudev1`, `libwrap0`, `usb.ids` `.deb` | Server + client |
| Kali ARMHF | `linux/kali-armhf/` | `usbip`, `libudev1`, `libwrap0`, `usb.ids` `.deb` | Server + client |
| Debian 12 amd64 | `linux/debian-bookworm-amd64/` | Debian 12 native dependency set and `usbip` `.deb` | Server + client |

Windows x86/32-bit is intentionally absent. Current `usbipd-win` and
`usbip-win2` resources used by this project do not provide a complete supported
32-bit Windows driver combination.

The Windows x64 client resource is the official `USBip-0.9.8.0-x64.exe`
installer. The offline script first installs the bundled Microsoft Visual C++
x64 runtime, then executes the official installer. The official installer owns
the user-space files, DLLs, signed `usbip2_ude` and `usbip2_filter` driver
packages, driver services, and virtual USB device node. This project does not
manually copy a fixed `client/` directory and does not call `pnputil` directly.
The runtime is required by `usbipw.exe`; without it Windows may report that the
executable cannot be found even when the file exists. The `-Server` switch
installs only `usbipd-win`; `-Client` installs the runtime and official client;
using both switches installs both roles.

Do not reintroduce the legacy `USBip-0.9.7.7-x64.exe` resource, a manually
assembled `client/` directory, or legacy `usbip_vhci` files into the x64 bundle.
Mixing the old device model with the official usbip-win2 installer can leave a
successful-looking file copy without a usable virtual USB device. The ARM64
target still uses its architecture-specific installer. If the official
installer registers the driver service but Windows has not created the virtual
USB device node yet, restart Windows and run the environment check again.

The bundled VC++ runtime is downloaded from Microsoft's official endpoint:

```text
https://aka.ms/vs/17/release/vc_redist.x64.exe
SHA256: cc0ff0eb1dc3f5188ae6300faef32bf5beeba4bdd6e8e445a9184072096b713b
```

Redistributing this file must comply with the Microsoft Visual C++ Redistributable
license. See `licenses/` and review the current Microsoft license terms before
publishing a release.

## What is not included

Linux resources do not include:

- `libc6` or other core system libraries that could make a system unbootable;
- `usbip-core`, `usbip-host` or `vhci-hcd` kernel modules;
- a generic package that is safe for Ubuntu, Fedora, Arch, Alpine and Kali at once.

The offline Linux installer loads modules from `/lib/modules/$(uname -r)` on the
target machine. If the target kernel does not provide the modules, installing
the user-space `.deb` does not create them. Obtain a matching kernel package or
use the target distribution's own package source.

Windows installers register services and kernel drivers. They require matching
architecture and administrator/UAC approval. The portable Flutter executable
does not remove that requirement.

## How the application uses these files

1. The Flutter asset bundle contains the selected files under
   `data/flutter_assets/offline/`.
2. The app detects operating system, distribution and CPU architecture.
3. It extracts only the selected resource set to a temporary directory such as
   `/tmp/usbip-unified-offline-XXXXXX/` on Linux or `%TEMP%\\usbip-unified-offline-*`
   on Windows.
4. It invokes the platform installer with elevated privileges.
5. It removes the temporary directory after the installer exits.

The temporary directory is expected. It is not the installation destination and
does not need to be copied by the user. If an install is interrupted, stale
temporary directories can be removed after confirming no installer is running.

The Linux script refuses unsupported distributions and never deletes dpkg lock
files. If apt/dpkg is already running, wait for it to finish and retry.

## Direct installer commands

Linux, from this directory on a matching Kali/Debian host:

```bash
sudo ./install-linux-offline.sh --architecture amd64
```

The script auto-detects `kali` or Debian 12. To inspect options:

```bash
./install-linux-offline.sh --help
```

Windows, from PowerShell on a matching host:

```powershell
.\install-windows-offline.ps1 -Server -Client -Architecture auto
```

Use `-Server` or `-Client` alone when only one role is required. The script
relaunches itself with UAC when necessary. On x64, `-Client` installs the
Microsoft VC++ runtime and runs the official `USBip-0.9.8.0-x64.exe` installer,
which registers the client and its drivers. The project does not invoke
`pnputil` directly. Windows x86 is rejected explicitly.

## Integrity and licenses

Verify every resource before redistribution or installation:

```bash
sha256sum -c SHA256SUMS
```

`SHA256SUMS` covers all files in this directory except the manifest itself.
After adding or replacing a file, regenerate it from `offline/` with a stable
sorted file list and review the diff:

```bash
find . -type f ! -name SHA256SUMS -printf '%P\0' \
  | sort -z \
  | xargs -0 sha256sum > SHA256SUMS
```

The license texts under `licenses/` must remain with redistributable binaries.
The x64 client payload is from `usbip-win2`; the x64 VC++ runtime is a
Microsoft redistributable and must be distributed according to Microsoft's
license terms. Do not replace it with a locally compiled or unverified DLL.
Also review the upstream release license and notices before publishing a new
version. Resource versions and their known limitations are documented in the
root `README.md` and `CHANGELOG.md`.

## Adding a new target

For a new distribution or architecture, add all of the following together:

1. Packages or installers from a trusted, matching release source.
2. A directory with a stable target name under `linux/` or `windows/`.
3. Asset entries in `pubspec.yaml`.
4. Bundle selection and target detection in
   `lib/services/offline_installer.dart`.
5. Installer selection logic and validation in the platform script.
6. Checksums, license notices, tests, and this matrix.
7. A real target-machine verification note; a successful download is not a
   compatibility test.

Do not add a package merely because its CPU architecture matches. Distribution,
ABI, dependency versions, kernel modules and driver signing all matter.
