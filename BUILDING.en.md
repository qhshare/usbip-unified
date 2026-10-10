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
git clone https://github.com/qhshare/usbip-unified.git
cd usbip-unified
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

Output: `dist/usbip-unified-linux-x64-portable-20261010.17.tar.gz`.

Windows:

```bat
tool\package-portable.bat x64
tool\package-portable.bat arm64
```

Windows portable packages must be built on a native Windows build host. A Linux
or macOS Dart frontend must not be combined with the Windows release Engine;
the packaging script rejects that combination so an EXE cannot report Linux at
runtime.

On a Windows build host with an existing dependency configuration but no
`pub.dev` access, skip dependency resolution while still cleaning generated
build caches with:

```bat
tool\package-portable.bat x64 --no-pub
tool\package-portable.bat arm64 --no-pub
```

`--no-pub` requires `.dart_tool\package_config.json`. It reuses the existing
dependency configuration while deleting `build/` and
`.dart_tool/flutter_build`. After changing `pubspec.yaml` or dependency
versions, run the normal `flutter pub get` flow.

Outputs:

```text
dist/usbip-unified-windows-x64-portable-20261010.17.zip
dist/usbip-unified-windows-arm64-portable-20261010.17.zip
```

The Windows batch script uses PowerShell `Compress-Archive`; no separate zip
utility is required. Keep the complete extracted directory and its `data/`
directory. The Linux bundle also requires `lib/`. Portable only describes the
Flutter GUI distribution: USB/IP tools, services, kernel modules, and Windows
virtual USB drivers must already exist or be installed by the app.

## 7. Publish a GitHub Release

The project repository is `https://github.com/qhshare/usbip-unified`, and the
default branch is `main`. Use this checklist for a new release:

1. Update the version in `pubspec.yaml` and `CHANGELOG.md`, then confirm the
   source, offline resources, and documentation all belong to that version.
2. Run `dart format --output=none --set-exit-if-changed lib test`,
   `dart analyze`, `flutter test`,
   `./tool/check-repository.sh`, and the offline checksum verification. Complete
   platform validation and packaging on the corresponding Linux and Windows
   build hosts.
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

5. Commit source, tests, scripts, documentation, and the intentional `offline/`
   resources. Confirm that `dist/`, `build/`, `.dart_tool/`, `.tmp/`, Wine
   environments, and nested third-party `.git/` directories are not staged.
   `.gitignore` already excludes `build/`, `dist/`, and local development
   environments.
6. Push `main`, then create the version tag and GitHub Release. The current
   version uses tag `v0.1.0-20261010.17`; upload the Linux/Windows archives and
   `SHA256SUMS-<build>.txt`. Keep `THIRD_PARTY_NOTICES.md`, offline licenses,
   and Release notes traceable in the source repository. If they are not
   included in the portable archives, upload or link them from the Release
   page.

Do not commit `dist/` or Release assets to source history. Current offline
resources are below GitHub's 100 MB per-file limit. If a future resource
exceeds that limit, move it to Git LFS or a Release asset and update
`offline/README.md` and the checksum manifest.

`.github/workflows/ci.yml` runs formatting, static analysis, tests, repository
checks, offline checksum verification, and the Linux release build. It does not
build Windows packages, upload build artifacts, or create a GitHub Release.

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
