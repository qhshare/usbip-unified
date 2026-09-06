# Building Guide

This document is for developers and maintainers who want to build USBIP
Unified Manager from source. It is a Flutter desktop application, so Linux and
Windows artifacts should be built on the corresponding platform build host.
The target user does not need the Flutter SDK, but the build host does.

## 1. Prepare the build environment

### Linux

Install Git, Flutter stable, Clang, CMake, Ninja, `pkg-config`, and GTK 3
development files:

```bash
sudo apt update
sudo apt install -y git clang cmake ninja-build pkg-config libgtk-3-dev
flutter config --enable-linux-desktop
flutter doctor -v
```

The Linux desktop toolchain should pass `flutter doctor -v`. The `usbip`,
`usbipd`, and kernel modules required to run USB/IP are not Flutter build
dependencies. Install them separately as described in [README.en.md](README.en.md).

### Windows

Install Git for Windows, Flutter stable, Visual Studio 2022 or a compatible
version, the **Desktop development with C++** workload, a Windows 10/11 SDK,
and PowerShell:

```powershell
flutter config --enable-windows-desktop
flutter doctor -v
```

MSVC, the Windows SDK, CMake tools, and the C++ workload must pass the check.
Linux cross-build environments and Wine are not substitutes for real Windows
validation of UAC, services, driver signing, firewall behavior, and USB/IP.

## 2. Get the source and verify resources

```bash
git clone https://github.com/<user>/<repository>.git
cd <repository>
flutter pub get
```

The versioned installers under `offline/` are intentionally part of this
repository, so a normal clone does not need to download them again. Verify them
before building:

```bash
cd offline
sha256sum -c SHA256SUMS
cd ..
```

If GNU `sha256sum` is unavailable on Windows, check individual files with:

```powershell
Get-ChildItem -Recurse offline -File |
  Where-Object { $_.Name -ne 'SHA256SUMS' } |
  ForEach-Object { Get-FileHash $_.FullName -Algorithm SHA256 }
```

If `linux/` or `windows/` is missing, generate the Flutter runners:

```bash
./tool/bootstrap.sh
```

```bat
tool\bootstrap.bat
```

The bootstrap scripts run `flutter create --platforms=linux,windows` and
`flutter pub get`, and may regenerate platform templates. A normal clone
already contains both platform directories and only needs `flutter pub get`.
Commit or back up local runner changes before running bootstrap.

## 3. Run in development

Linux:

```bash
./run.sh
```

This is equivalent to `flutter run -d linux`. Arguments are forwarded to
Flutter, for example:

```bash
./run.sh --verbose
```

Windows:

```bat
run-windows.bat
```

This is equivalent to `flutter run -d windows`. Flutter hot reload is suitable
for Dart/UI changes. Stop and restart after changing `pubspec.yaml`, asset
declarations, the C++ runner, installers, or platform build files.

## 4. Tests and static checks

Run these commands from the repository root before committing:

```bash
dart format --output=none --set-exit-if-changed lib test
dart analyze lib test
flutter test
./tool/check-repository.sh
```

For local formatting, run `dart format lib test`. The repository check validates
the offline checksum manifest, nested Git metadata, and common private-key
files. It does not replace real Linux/Windows USB/IP integration testing and
does not install kernel modules or Windows drivers.

## 5. Build release artifacts

### Linux

```bash
flutter build linux --release
```

The output is `build/linux/x64/release/bundle/`. The `usbip_unified` executable
must be used with the adjacent `data/` and `lib/` directories; do not copy only
the executable.

### Windows

Run on a Windows build host:

```bat
flutter build windows --release
```

The x64 output is `build/windows/x64/runner/Release/`. To build ARM64:

```bat
flutter build windows --release --target-platform windows-arm64
```

The Windows executable must be distributed with the adjacent `data/` directory.
ARM64 requires a matching Flutter/Visual Studio toolchain and ARM64 offline
resources; x64 drivers must not be substituted.

## 6. Create portable packages

The packaging scripts run a release build and compress the complete Flutter
bundle into `dist/`.

Linux:

```bash
./tool/package-portable.sh linux
```

Output: `dist/usbip-unified-linux-x64-portable.tar.gz`.

Windows:

```bat
tool\package-portable.bat x64
tool\package-portable.bat arm64
```

Outputs:

```text
dist/usbip-unified-windows-x64-portable.zip
dist/usbip-unified-windows-arm64-portable.zip
```

The Windows batch script uses PowerShell `Compress-Archive`; no separate zip
utility is required. Keep the complete extracted directory and its `data/`
directory. The Linux bundle also requires `lib/`. Portable only describes the
Flutter GUI distribution: USB/IP tools, services, kernel modules, and Windows
virtual USB drivers must already exist or be installed by the app.

## 7. Publish a GitHub Release

`build/`, `dist/`, `.dart_tool/`, `.tmp/`, and Wine environments are ignored by
`.gitignore`. Keep source and build artifacts separate:

1. Commit source, tests, scripts, documentation, and the intentional `offline/`
   resources.
2. Build the `dist/` archives on the corresponding platform hosts.
3. Generate checksums for the Release files:

```bash
find dist -maxdepth 1 -type f ! -name SHA256SUMS -printf '%f\0' \
  | sort -z \
  | xargs -0 -r -I{} sha256sum "dist/{}" > dist/SHA256SUMS
```

On Windows:

```powershell
Get-ChildItem dist -File |
  Where-Object { $_.Name -ne 'SHA256SUMS' } |
  ForEach-Object { Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256 }
```

4. Create a version tag and GitHub Release.
5. Upload the Linux and Windows archives, checksums,
   `THIRD_PARTY_NOTICES.md`, and architecture notes.

Do not copy `dist/` into Git staging. If a future offline installer exceeds
GitHub's single-file limit, move it to Git LFS or Release assets and update
`offline/README.md` and the checksum manifest.

## 8. Troubleshooting

### Flutter is not found

Run `flutter doctor -v`. Add the Flutter SDK's `bin/` directory to `PATH` and
open a new terminal.

### Linux is missing GTK, CMake, or Ninja

On Debian, Ubuntu, or Kali:

```bash
sudo apt install -y clang cmake ninja-build pkg-config libgtk-3-dev
```

On other distributions, install the equivalent development packages.

### The build succeeds but the app does not start

Run the complete bundle rather than copying only the executable. On Linux check
`data/` and `lib/`; on Windows check `data/`. A usable desktop session is also
required.

### The app starts but no USB devices are listed

Check that the target has `usbip`/`usbipd` or `usbipd-win`, that the user has
root/administrator rights, and that the Linux kernel modules or Windows virtual
USB driver are working. Review the application log and native command output;
this is not necessarily a Flutter build failure.

### Why does offline installation use `/tmp`?

This is expected. Flutter assets are read-only, so the installer extracts the
selected resources to a temporary directory, invokes `dpkg`, MSI, or the
Windows installer, and then removes the temporary files. The actual install
location is selected by the system installer, not `/tmp`.

### Why is there no Windows 32-bit version?

The current Windows USB/IP server and virtual USB client resources do not form a
complete supported x86 driver combination. A normal Flutter x86 desktop binary
would not make the USB/IP driver chain usable, so Windows x86 is not released.

## 9. Related documentation

- [README.en.md](README.en.md): features, installation, and usage
- [README.md](README.md): Chinese user guide
- [ARCHITECTURE.md](ARCHITECTURE.md): module boundaries and data flow
- [CONTRIBUTING.md](CONTRIBUTING.md): contribution and pre-commit checks
- [offline/README.md](offline/README.md): offline resources and installers
- [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md): licenses and binary notices
