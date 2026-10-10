import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart' show rootBundle;
import 'usbip_service.dart';

/// A native resource set for one concrete target architecture.
class OfflineBundle {
  const OfflineBundle({required this.architecture, required this.assets});
  final String architecture;
  final List<String> assets;
}

class OfflineTargetInfo {
  const OfflineTargetInfo({
    required this.platform,
    required this.distribution,
    required this.architecture,
    required this.supported,
    required this.message,
  });

  final String platform;
  final String distribution;
  final String architecture;
  final bool supported;
  final String message;
}

/// Paths reported by the Windows offline installer after it finishes.
///
/// The installer can be asked to install both roles in one invocation, so the
/// result must be parsed as two independent values. Keeping this parser here
/// also prevents the UI from accidentally assigning `usbipd.exe` to the
/// Windows client field.
class InstalledToolPaths {
  const InstalledToolPaths({this.server, this.client});

  final String? server;
  final String? client;

  static InstalledToolPaths parse(String output) {
    return InstalledToolPaths(
      server: _marker(output, 'SERVER_PATH') ??
          _value(output, 'Server executable:'),
      client: _marker(output, 'CLIENT_PATH') ??
          _value(output, 'Client executable:'),
    );
  }

  static String? _marker(String output, String name) {
    final matches = RegExp('^\\s*${RegExp.escape(name)}\\|([^\\r\\n]*)',
            multiLine: true, caseSensitive: false)
        .allMatches(output)
        .map((match) => match.group(1)?.trim())
        .whereType<String>()
        .where((value) => value.isNotEmpty)
        .toList();
    return matches.isEmpty ? null : matches.last;
  }

  static String? _value(String output, String label) {
    final match = RegExp('^\\s*${RegExp.escape(label)}\\s*(.+)',
            multiLine: true, caseSensitive: false)
        .firstMatch(output);
    final value = match?.group(1)?.trim();
    return value == null || value.isEmpty ? null : value;
  }
}

/// Machine-readable result emitted by `install-windows-offline.ps1`.
///
/// The human-readable installer log is intentionally kept alongside these
/// markers. The markers let the UI distinguish a successful server-only
/// installation from a client whose executable exists but whose virtual bus
/// still needs a reboot or PnP enumeration.
class WindowsOfflineInstallStatus {
  const WindowsOfflineInstallStatus({
    this.installStatus = 'unknown',
    this.restartRequired = false,
    this.serverStatus = 'unknown',
    this.clientStatus = 'unknown',
    this.clientDriverStatus = 'unknown',
    this.clientDeviceStatus = 'unknown',
    this.hasStructuredStatus = false,
  });

  final String installStatus;
  final bool restartRequired;
  final String serverStatus;
  final String clientStatus;
  final String clientDriverStatus;
  final String clientDeviceStatus;
  final bool hasStructuredStatus;

  bool get success => installStatus == 'success';
  bool get partial => installStatus == 'partial';
  bool get failed => installStatus == 'failed';

  static WindowsOfflineInstallStatus parse(String output) {
    String? marker(String name) {
      final matches = RegExp('^\\s*${RegExp.escape(name)}\\|([^\\r\\n]*)',
              multiLine: true, caseSensitive: false)
          .allMatches(output)
          .map((match) => match.group(1)?.trim().toLowerCase())
          .whereType<String>()
          .where((value) => value.isNotEmpty)
          .toList();
      return matches.isEmpty ? null : matches.last;
    }

    final installStatus = marker('INSTALL_STATUS');
    final restart = marker('RESTART_REQUIRED');
    return WindowsOfflineInstallStatus(
      installStatus: installStatus ?? 'unknown',
      restartRequired: restart == 'true' || restart == '1' || restart == 'yes',
      serverStatus: marker('SERVER_STATUS') ?? 'unknown',
      clientStatus: marker('CLIENT_STATUS') ?? 'unknown',
      clientDriverStatus: marker('CLIENT_DRIVER_STATUS') ?? 'unknown',
      clientDeviceStatus: marker('CLIENT_DEVICE_STATUS') ?? 'unknown',
      hasStructuredStatus: installStatus != null,
    );
  }

  String summary(
      {required bool serverRequested, required bool clientRequested}) {
    final parts = <String>[];
    if (serverRequested) parts.add('共享端=$serverStatus');
    if (clientRequested) {
      parts.add('客户端=$clientStatus');
      parts.add('驱动=$clientDriverStatus');
      parts.add('虚拟设备=$clientDeviceStatus');
    }
    if (restartRequired) parts.add('需要重启 Windows');
    return parts.isEmpty ? '未返回角色状态' : parts.join('，');
  }
}

/// Extracts the bundled native installers to a temporary directory and runs
/// the platform installer. The assets are shipped inside the Flutter bundle;
/// kernel modules and driver registration still require system privileges.
class OfflineInstaller {
  /// Fingerprint of the Windows installer flow shipped in this source tree.
  ///
  /// A user can easily start an older extracted portable directory after a
  /// newer ZIP was released. Checking this marker prevents the old
  /// `usbip_vhci.inf`/`pnputil` flow from being mistaken for the current
  /// signed usbip-win2 installer flow.
  static const windowsInstallerRevision = 'official-usbip-win2-0.9.8.0-v2';

  static bool hasExpectedWindowsInstallerRevision(String script) => script
      .contains('USBIP_UNIFIED_INSTALLER_REVISION|$windowsInstallerRevision');

  /// Windows resources per architecture. Upstream `usbipd-win` and
  /// `usbip-win2` publish x64 and ARM64 builds only; there is no 32-bit
  /// Windows driver to bundle.
  static const windowsBundles = <String, List<String>>{
    'x64': [
      'offline/windows/x64/usbipd-win_5.3.0_x64.msi',
      'offline/windows/x64/VC_redist.x64.exe',
      'offline/windows/x64/USBip-0.9.8.0-x64.exe',
    ],
    'arm64': [
      'offline/windows/arm64/usbipd-win_5.3.0_arm64.msi',
      'offline/windows/arm64/USBip-0.9.7.5-arm64-release.exe',
    ],
  };

  /// Linux user-space packages per Debian architecture name.
  static const linuxBundles = <String, List<String>>{
    'amd64': [
      'offline/linux/kali-amd64/libudev1_261.2-1_amd64.deb',
      'offline/linux/kali-amd64/libwrap0_7.6.q-37_amd64.deb',
      'offline/linux/kali-amd64/usb.ids_2026.06.26-1_all.deb',
      'offline/linux/kali-amd64/usbip_2.0+7.0.12-2kali1_amd64.deb',
    ],
    'i386': [
      'offline/linux/kali-i386/libudev1_261.2-1_i386.deb',
      'offline/linux/kali-i386/libwrap0_7.6.q-37_i386.deb',
      'offline/linux/kali-i386/usb.ids_2026.06.26-1_all.deb',
      'offline/linux/kali-i386/usbip_2.0+7.0.12-2kali1_i386.deb',
    ],
    'arm64': [
      'offline/linux/kali-arm64/libudev1_261.2-1_arm64.deb',
      'offline/linux/kali-arm64/libwrap0_7.6.q-37_arm64.deb',
      'offline/linux/kali-arm64/usb.ids_2026.06.26-1_all.deb',
      'offline/linux/kali-arm64/usbip_2.0+7.0.12-2kali1_arm64.deb',
    ],
    'armhf': [
      'offline/linux/kali-armhf/libudev1_261.2-1_armhf.deb',
      'offline/linux/kali-armhf/libwrap0_7.6.q-37_armhf.deb',
      'offline/linux/kali-armhf/usb.ids_2026.06.26-1_all.deb',
      'offline/linux/kali-armhf/usbip_2.0+7.0.12-2kali1_armhf.deb',
    ],
  };

  static const debianBookwormAmd64 = <String>[
    'offline/linux/debian-bookworm-amd64/libudev1_252.39-1~deb12u2_amd64.deb',
    'offline/linux/debian-bookworm-amd64/libwrap0_7.6.q-32_amd64.deb',
    'offline/linux/debian-bookworm-amd64/libnsl2_1.3.0-2_amd64.deb',
    'offline/linux/debian-bookworm-amd64/usb.ids_2025.07.26-0+deb12u1_all.deb',
    'offline/linux/debian-bookworm-amd64/usbip_2.0+6.1.176-1_amd64.deb',
  ];

  static const windowsScript = 'offline/install-windows-offline.ps1';
  static const linuxScript = 'offline/install-linux-offline.sh';

  /// Returns bundled Windows client installers that cannot be loaded from the
  /// current Flutter asset bundle. Online installation uses this before it
  /// installs anything so an incomplete or stale portable package fails
  /// clearly instead of leaving a partial role installation behind.
  Future<List<String>> missingWindowsClientAssets(
      {String? overrideArchitecture}) async {
    if (!Platform.isWindows) return const [];
    final architecture = overrideArchitecture ?? detectArchitecture();
    final assets = switch (architecture) {
      'x64' => const [
          'offline/windows/x64/VC_redist.x64.exe',
          'offline/windows/x64/USBip-0.9.8.0-x64.exe',
        ],
      'arm64' => const [
          'offline/windows/arm64/USBip-0.9.7.5-arm64-release.exe',
        ],
      _ => const [],
    };
    final missing = <String>[];
    for (final asset in assets) {
      try {
        await rootBundle.load(asset);
      } catch (_) {
        missing.add(asset);
      }
    }
    try {
      final scriptBytes = await rootBundle.load(windowsScript);
      final script = const Utf8Decoder(allowMalformed: true).convert(scriptBytes
          .buffer
          .asUint8List(scriptBytes.offsetInBytes, scriptBytes.lengthInBytes));
      if (!hasExpectedWindowsInstallerRevision(script)) {
        missing.add('$windowsScript（旧版安装流程，需包含 $windowsInstallerRevision）');
      }
    } catch (_) {
      missing.add('$windowsScript（无法读取）');
    }
    return missing;
  }

  String windowsClientBundlePreflightMessage(List<String> missing) {
    return [
      '当前便携包不完整或仍是旧版 Windows 客户端流程，已停止安装。',
      '缺少或不匹配的客户端资源：',
      ...missing.map((asset) => '  $asset'),
      '请完全退出旧版应用，删除旧解压目录，重新解压包含完整 data/flutter_assets 的最新 Windows Release。',
      '新流程应执行官方 USBip-0.9.8.0-x64.exe，不应出现 pnputil、usbip_vhci.inf 或 Copying client file。',
    ].join('\n');
  }

  /// Detects a Flutter/Dart frontend built for the wrong operating system.
  ///
  /// The Windows runner can still start if a Linux `app.dill` was passed to a
  /// Windows AOT snapshotter. In that case `Platform.isLinux` is true inside
  /// a `.exe`, so the application selects the Linux role and looks for the
  /// Linux installer even though the host is Windows.
  String? runtimePlatformMismatch() {
    final executable = Platform.resolvedExecutable.toLowerCase();
    final operatingSystem = Platform.operatingSystem.toLowerCase();
    final version = Platform.operatingSystemVersion.toLowerCase();
    final environmentOs = Platform.environment['OS']?.toLowerCase();
    final hasWindowsEnvironment = environmentOs == 'windows_nt' ||
        Platform.environment.containsKey('WINDIR') ||
        version.contains('windows');
    final executableLooksWindows = executable.endsWith('.exe');

    if (executableLooksWindows && operatingSystem != 'windows') {
      return '可执行文件是 Windows EXE，但 Dart 运行时报告为 $operatingSystem。'
          '这通常表示 Windows 构建复用了 Linux 的 app.dill/AOT 前端缓存。';
    }
    if (hasWindowsEnvironment && operatingSystem != 'windows') {
      return 'Windows 环境变量/系统版本已检测到 Windows，但 Dart 运行时报告为 '
          '$operatingSystem。请重新执行原生 Windows Release 构建。';
    }
    return null;
  }

  /// Describes the executable and Flutter asset locations used by the current
  /// process. A portable Windows build can otherwise be mistaken for a newly
  /// built one when several extracted releases are on disk.
  Future<List<String>> runtimeDiagnostics() async {
    final lines = <String>[
      '运行平台：${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
      'Dart 可执行文件：${Platform.resolvedExecutable}',
      '当前工作目录：${Directory.current.path}',
    ];
    final platformMismatch = runtimePlatformMismatch();
    lines.add(platformMismatch == null
        ? '平台一致性检查：通过'
        : '平台一致性检查：失败：$platformMismatch');
    if (Platform.isWindows) {
      lines.add(
          'Windows 进程架构：${Platform.environment['PROCESSOR_ARCHITEW6432'] ?? Platform.environment['PROCESSOR_ARCHITECTURE'] ?? '未知'}');
    }

    try {
      final executableDirectory = File(Platform.resolvedExecutable).parent;
      final dataDirectory =
          Directory('${executableDirectory.path}${Platform.pathSeparator}data');
      final assetDirectory = Directory(
          '${dataDirectory.path}${Platform.pathSeparator}flutter_assets');
      final scriptName = Platform.isWindows ? windowsScript : linuxScript;
      final scriptFile = File(
          '${assetDirectory.path}${Platform.pathSeparator}${scriptName.replaceAll('/', Platform.pathSeparator)}');
      lines.add('便携包目录：${executableDirectory.path}');
      lines.add('Flutter data 目录存在：${await dataDirectory.exists()}');
      lines.add('Flutter assets 目录存在：${await assetDirectory.exists()}');
      lines.add('内置安装脚本路径：${scriptFile.path}');
      lines.add('内置安装脚本存在：${await scriptFile.exists()}');
      if (await scriptFile.exists()) {
        final bytes = await scriptFile.readAsBytes();
        final text = const Utf8Decoder(allowMalformed: true).convert(bytes);
        final marker = Platform.isWindows
            ? text.contains(r"$ErrorActionPreference = 'Stop'") &&
                text.contains('Target architecture:')
            : text.contains('set -euo pipefail');
        lines.add('内置安装脚本大小：${bytes.length} 字节');
        lines.add('内置安装脚本格式检查：${marker ? '通过' : '未通过'}');
        if (Platform.isWindows) {
          lines.add(
              'Windows 安装器版本检查：${hasExpectedWindowsInstallerRevision(text) ? '通过（$windowsInstallerRevision）' : '未通过（当前便携包可能是旧版）'}');
        }
      }
    } catch (error) {
      lines.add('便携包路径诊断异常：$error');
    }
    return lines;
  }

  /// Maps the running machine to a bundled architecture directory.
  /// Returns null when no bundled resource set matches the host.
  OfflineBundle? resolveBundle({String? overrideArchitecture}) {
    final table = Platform.isWindows ? windowsBundles : linuxBundles;
    final key = overrideArchitecture ?? detectArchitecture();
    final assets = Platform.isLinux
        ? (_isDebianBookworm()
            ? (key == 'amd64' ? debianBookwormAmd64 : null)
            : (_isKali() ? table[key] : null))
        : table[key];
    if (assets == null) return null;
    final script = Platform.isWindows ? windowsScript : linuxScript;
    return OfflineBundle(architecture: key, assets: [...assets, script]);
  }

  OfflineTargetInfo inspectTarget() {
    final architecture = detectArchitecture();
    if (Platform.isWindows) {
      final supported = windowsBundles.containsKey(architecture);
      return OfflineTargetInfo(
        platform: 'Windows',
        distribution: 'Windows',
        architecture: architecture,
        supported: supported,
        message: supported
            ? 'Windows $architecture 已提供 usbipd-win 服务端和 usbip-win2 客户端离线资源。'
            : unsupportedMessage(architecture),
      );
    }
    if (Platform.isLinux) {
      final distribution = _linuxDistributionLabel();
      final supported = resolveBundle() != null;
      return OfflineTargetInfo(
        platform: 'Linux',
        distribution: distribution,
        architecture: architecture,
        supported: supported,
        message: supported
            ? '$distribution $architecture 已提供匹配的离线资源；请确认当前内核和系统依赖兼容。'
            : unsupportedMessage(architecture),
      );
    }
    return OfflineTargetInfo(
      platform: Platform.operatingSystem,
      distribution: '未知系统',
      architecture: architecture,
      supported: false,
      message: '当前离线安装器仅支持 Windows 和 Linux。',
    );
  }

  String manualInstallGuide() {
    if (Platform.isWindows) {
      return 'Windows 未找到匹配的离线架构资源。请在 64 位 Windows 上使用 x64 或 ARM64 资源，或从项目发布页手动安装对应版本的 usbipd-win 和 usbip-win2。';
    }
    if (Platform.isLinux) {
      return '''当前 Linux 没有匹配的内置离线包。

请先确认系统和架构：
  cat /etc/os-release
  uname -m
  uname -r

Debian / Ubuntu：
  sudo apt update
  sudo apt install usbip

Fedora：
  sudo dnf install usbip

Arch Linux：
  sudo pacman -S usbip

安装后检查当前内核模块：
  modinfo usbip-core
  modinfo usbip-host
  modinfo vhci-hcd

本程序不会把其他发行版的 .deb 强行安装到当前系统。''';
    }
    return '请根据当前操作系统安装匹配的 USB/IP 用户态工具和内核组件。';
  }

  String _linuxDistributionLabel() {
    try {
      final release = _readOsRelease();
      final name = release['ID'] ?? 'Linux';
      final versionId = release['VERSION_ID'];
      return versionId == null || versionId.isEmpty ? name : '$name $versionId';
    } catch (_) {
      return 'Linux';
    }
  }

  bool _isDebianBookworm() {
    if (!Platform.isLinux) return false;
    try {
      final release = _readOsRelease();
      return release['ID']?.toLowerCase() == 'debian' &&
          release['VERSION_ID']?.split('.').first == '12';
    } catch (_) {
      return false;
    }
  }

  bool _isKali() {
    if (!Platform.isLinux) return false;
    try {
      return _readOsRelease()['ID']?.toLowerCase() == 'kali';
    } catch (_) {
      return false;
    }
  }

  Map<String, String> _readOsRelease() {
    final values = <String, String>{};
    final release = File('/etc/os-release').readAsLinesSync();
    for (final source in release) {
      final line = source.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final separator = line.indexOf('=');
      if (separator <= 0) continue;
      final key = line.substring(0, separator).trim();
      var value = line.substring(separator + 1).trim();
      if (value.length >= 2 &&
          ((value.startsWith('"') && value.endsWith('"')) ||
              (value.startsWith("'") && value.endsWith("'")))) {
        value = value.substring(1, value.length - 1);
      }
      values[key] = value;
    }
    return values;
  }

  /// Normalizes the host architecture to the naming used by the bundle.
  String detectArchitecture() {
    final raw = _rawArchitecture().toLowerCase();
    if (Platform.isWindows) {
      if (raw.contains('arm64') || raw.contains('aarch64')) return 'arm64';
      if (raw.contains('amd64') || raw.contains('x86_64')) return 'x64';
      if (raw == 'x86' || raw.contains('i386') || raw.contains('i686')) {
        return 'x86';
      }
      return raw;
    }
    if (raw.contains('x86_64') || raw.contains('amd64')) return 'amd64';
    if (raw.contains('aarch64') || raw.contains('arm64')) return 'arm64';
    if (RegExp(r'^i[3-6]86$').hasMatch(raw)) return 'i386';
    if (raw.startsWith('armv') || raw.contains('armhf')) return 'armhf';
    return raw;
  }

  String _rawArchitecture() {
    final env = Platform.environment;
    if (Platform.isWindows) {
      final wow = env['PROCESSOR_ARCHITEW6432'];
      if (wow != null && wow.isNotEmpty) return wow;
      return env['PROCESSOR_ARCHITECTURE'] ?? 'x64';
    }
    try {
      final result = Process.runSync('uname', ['-m']);
      final value = (result.stdout as String).trim();
      if (value.isNotEmpty) return value;
    } catch (_) {
      // Fall through to the Dart-reported version string.
    }
    return Platform.version.contains('arm64') ? 'aarch64' : 'x86_64';
  }

  Future<Directory> extract(OfflineBundle bundle) async {
    final root =
        await Directory.systemTemp.createTemp('usbip-unified-offline-');
    try {
      for (final asset in bundle.assets) {
        final bytes = await rootBundle.load(asset);
        final relative = asset.substring('offline/'.length);
        final output = File('${root.path}${Platform.pathSeparator}$relative');
        await output.parent.create(recursive: true);
        await output.writeAsBytes(
            bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes));
      }
      if (!Platform.isWindows) {
        final chmod = await Process.run('chmod', [
          '+x',
          '${root.path}${Platform.pathSeparator}install-linux-offline.sh'
        ]);
        if (chmod.exitCode != 0) {
          throw StateError('无法设置离线安装脚本执行权限：${chmod.stderr}');
        }
      }
      return root;
    } catch (_) {
      await _cleanup(root);
      rethrow;
    }
  }

  Future<CommandResult> install(
      {required bool server,
      required bool client,
      String? overrideArchitecture,
      void Function(String line)? onOutput}) async {
    if (!Platform.isWindows && !Platform.isLinux) {
      return const CommandResult(
        command: 'offline installer',
        code: 2,
        output: '当前离线安装包仅支持 Linux 和 Windows。',
      );
    }
    if (Platform.isWindows && !server && !client) {
      return const CommandResult(
        command: 'install-windows-offline.ps1',
        code: 2,
        output: '至少选择服务端或客户端组件。',
      );
    }
    final bundle = resolveBundle(overrideArchitecture: overrideArchitecture);
    if (bundle == null) {
      return CommandResult(
        command: 'offline installer',
        code: 2,
        output:
            unsupportedMessage(overrideArchitecture ?? detectArchitecture()),
      );
    }
    if (Platform.isWindows && client) {
      // Keep the explicit offline action protected by the same bundle check as
      // the online installer. Otherwise an old extracted Flutter release can
      // still invoke the legacy pnputil/client payload directly.
      final missing = await missingWindowsClientAssets(
          overrideArchitecture: bundle.architecture);
      if (missing.isNotEmpty) {
        final output = windowsClientBundlePreflightMessage(missing);
        onOutput?.call(output);
        return CommandResult(
          command: 'Windows client bundle preflight',
          code: 2,
          output: output,
        );
      }
    }
    late final Directory root;
    try {
      root = await extract(bundle);
    } catch (error) {
      return CommandResult(
        command: 'offline resource extraction',
        code: 1,
        output: '离线资源解压失败：$error',
      );
    }
    if (Platform.isWindows) {
      final script =
          '${root.path}${Platform.pathSeparator}install-windows-offline.ps1';
      final resultFile =
          '${root.path}${Platform.pathSeparator}install-result.txt';
      final args = [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        script
      ];
      if (server) args.add('-Server');
      if (client) args.add('-Client');
      args.addAll(['-Architecture', bundle.architecture]);
      args.addAll(['-ResultFile', resultFile]);
      // Keep the exact role flags in the returned output. This is important
      // because the same bundled script supports server-only, client-only,
      // and complete installation, and the elevated child owns the real log.
      final requestedRoles = [
        if (server) 'Server',
        if (client) 'Client',
      ].join(' ');
      final result = await _run('powershell.exe', args, onOutput: onOutput);
      // The elevated child writes this file after the UAC prompt. Check the
      // file separately from its contents: an existing but empty file means
      // the child started and then failed before it could write a message.
      final resultFileExists = await File(resultFile).exists();
      final installerOutput = await _readTextFile(resultFile);
      final output = _mergeInstallerOutput(result.output, installerOutput,
          exitCode: result.code,
          resultFileExists: resultFileExists,
          resultFilePath: resultFile,
          requestedRoles: requestedRoles,
          architecture: bundle.architecture);
      await _cleanup(root);
      return CommandResult(
        command:
            '${result.command} # roles: ${requestedRoles.isEmpty ? 'none' : requestedRoles}',
        code: result.code,
        output: output,
      );
    }
    final script =
        '${root.path}${Platform.pathSeparator}install-linux-offline.sh';
    late final CommandResult result;
    if (await _isRoot()) {
      result = await _run(script, ['--architecture', bundle.architecture]);
    } else if (!await _commandExists('pkexec')) {
      result = CommandResult(
        command: 'pkexec $script',
        code: 127,
        output: '未找到 pkexec。请安装 polkit，或从 root 终端手动执行离线安装脚本。',
      );
    } else {
      result =
          await _run('pkexec', [script, '--architecture', bundle.architecture]);
    }
    await _cleanup(root);
    return result;
  }

  Future<void> _cleanup(Directory root) async {
    try {
      if (await root.exists()) await root.delete(recursive: true);
    } catch (_) {
      // Cleanup failure must not hide the installer result.
    }
  }

  Future<String> _readTextFile(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return '';
      return (await file.readAsString()).trim();
    } catch (_) {
      return '';
    }
  }

  /// UAC relaunches the PowerShell script as a second process. Depending on
  /// the Windows PowerShell version, its console output and the result file
  /// can contain different subsets of the log. Keep both sources so the GUI
  /// can still parse the verified executable paths and show the real failure
  /// when the elevated process exits early.
  String _mergeInstallerOutput(String processOutput, String resultOutput,
      {required int exitCode,
      required bool resultFileExists,
      String? resultFilePath,
      String requestedRoles = '',
      String architecture = ''}) {
    final lines = <String>[];
    final seen = <String>{};
    void add(String value) {
      for (final line in value.split(RegExp(r'\r?\n'))) {
        final normalized = line.trim();
        if (normalized.isEmpty) continue;
        final key = normalized.toLowerCase();
        if (seen.add(key)) lines.add(normalized);
      }
    }

    add(processOutput);
    add(resultOutput);
    lines.insert(0, 'PowerShell installer exit code: $exitCode');
    lines.insert(1, 'Installer result file exists: $resultFileExists');
    if (resultFilePath != null && resultFilePath.isNotEmpty) {
      lines.insert(2, 'Installer result file path: $resultFilePath');
    }
    lines.insert(3,
        'Requested Windows roles: ${requestedRoles.isEmpty ? 'none' : requestedRoles}');
    if (architecture.isNotEmpty) {
      lines.insert(4, 'Requested Windows architecture: $architecture');
    }
    if (!resultFileExists) {
      lines.add(
          'Installer result file was not created. The elevated process may not have started.');
    } else if (resultOutput.isEmpty) {
      lines.add(
          'Installer result file was created but contains no diagnostic output.');
    }
    return lines.join('\n');
  }

  /// Human readable reason why a host has no bundled resource set.
  String unsupportedMessage(String architecture) {
    if (Platform.isWindows && architecture == 'x86') {
      return '检测到 32 位 Windows（x86）。usbipd-win 和 usbip-win2 均未发布 32 位版本，'
          'USB/IP 的 Windows 虚拟总线驱动只有 x64 和 ARM64 内核驱动，因此无法离线安装 32 位组件。'
          '请在 64 位 Windows 上使用本工具，或改用 Linux 端作为服务端。';
    }
    if (Platform.isLinux && !_isKali() && !_isDebianBookworm()) {
      return '当前 Linux 发行版没有匹配的离线包。当前已适配 Kali 系多种架构和 Debian 12 amd64；'
          'Ubuntu、Fedora、Arch、Alpine 等系统必须使用各自发行版的 USB/IP 包，不能直接安装 Kali 的 .deb。';
    }
    final available =
        (Platform.isWindows ? windowsBundles : linuxBundles).keys.join('、');
    return '离线包中没有匹配当前架构（$architecture）的资源。当前内置架构：$available。';
  }

  Future<bool> _commandExists(String command) async {
    try {
      final result = await Process.run('sh', ['-c', 'command -v "$command"']);
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _isRoot() async {
    if (!Platform.isLinux) return false;
    try {
      final result = await Process.run('id', ['-u']);
      return result.exitCode == 0 && result.stdout.toString().trim() == '0';
    } catch (_) {
      return false;
    }
  }

  Future<CommandResult> _run(String executable, List<String> args,
      {void Function(String line)? onOutput}) async {
    final command = ([executable, ...args]).join(' ');
    try {
      final process = await Process.start(executable, args);
      final output = StringBuffer();
      Future<void> collect(Stream<List<int>> stream) async {
        final bytes = <int>[];
        await for (final chunk in stream) {
          bytes.addAll(chunk);
        }
        final decoded = UsbIpService.decodeProcessOutput(
          bytes,
          windows: Platform.isWindows,
        );
        for (final line in const LineSplitter().convert(decoded)) {
          final value = line.trim();
          if (value.isEmpty) continue;
          output.writeln(value);
          onOutput?.call(value);
        }
      }

      final stdoutDone = collect(process.stdout);
      final stderrDone = collect(process.stderr);
      final code = await process.exitCode.timeout(const Duration(minutes: 10),
          onTimeout: () {
        process.kill(ProcessSignal.sigterm);
        return 124;
      });
      await Future.wait([stdoutDone, stderrDone]);
      return CommandResult(
          command: command, code: code, output: output.toString().trim());
    } catch (error) {
      return CommandResult(
          command: command, code: 1, output: '离线安装启动失败：$error');
    }
  }
}
