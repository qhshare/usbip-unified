import 'dart:async';
import 'dart:convert';
import 'dart:io';

enum UsbIpRole { linux, linuxServer, linuxClient, windowsServer, windowsClient }

class UsbDevice {
  static const Object _keepAttachedPort = Object();

  const UsbDevice(
      {required this.id,
      required this.name,
      this.detail = '',
      this.bound = false,
      this.attached = false,
      this.state = '',
      this.attachedPort,
      this.connectionStateKnown = true});
  final String id;
  final String name;
  final String detail;

  /// True when a server has exported this device through USB/IP.
  final bool bound;

  /// True when a client has attached this device locally.
  final bool attached;

  /// Native state text, for example `Shared` or `Not shared`.
  final String state;

  /// Client-side USB/IP port used to detach this device.
  final String? attachedPort;

  /// False when the client could not query `usbip port` and the connection
  /// state must not be treated as disconnected.
  final bool connectionStateKnown;

  bool get isPort => attachedPort == id && RegExp(r'^\d+$').hasMatch(id);

  UsbDevice copyWith({
    bool? bound,
    bool? attached,
    String? state,
    Object? attachedPort = _keepAttachedPort,
    bool? connectionStateKnown,
  }) =>
      UsbDevice(
          id: id,
          name: name,
          detail: detail,
          bound: bound ?? this.bound,
          attached: attached ?? this.attached,
          state: state ?? this.state,
          attachedPort: identical(attachedPort, _keepAttachedPort)
              ? this.attachedPort
              : attachedPort as String?,
          connectionStateKnown:
              connectionStateKnown ?? this.connectionStateKnown);
}

class CommandResult {
  const CommandResult(
      {required this.command,
      required this.code,
      required this.output,
      this.started = true});
  final String command;
  final int code;
  final String output;

  /// False when the operating system could not create the process at all.
  /// A started command may still return a non-zero business/configuration
  /// status, which is different from a missing DLL or wrong executable.
  final bool started;
  bool get ok => code == 0;
}

/// One uninstall entry returned by `reg.exe query ... /s` on Windows.
///
/// USB/IP client installers do not use one universal install directory. The
/// uninstall entry is therefore a more reliable source than guessing a small
/// list of Program Files subdirectories.
class WindowsUninstallEntry {
  const WindowsUninstallEntry({
    required this.key,
    this.displayName,
    this.installLocation,
    this.displayIcon,
    this.uninstallString,
    this.quietUninstallString,
  });

  final String key;
  final String? displayName;
  final String? installLocation;
  final String? displayIcon;
  final String? uninstallString;
  final String? quietUninstallString;
}

/// Result of checking whether the Windows USB/IP client driver is registered.
///
/// A USB/IP client executable can start successfully even when its virtual
/// USB bus driver is absent. Keep that state separate so the environment
/// checker does not report a client as fully usable based on the EXE alone.
class WindowsClientDriverCheck {
  const WindowsClientDriverCheck({
    required this.status,
    required this.output,
    this.servicesDetected = false,
    this.virtualDeviceDetected = false,
  });

  /// One of `available`, `missing`, `pending_restart`, or `unknown`.
  final String status;
  final String output;

  /// True when all required usbip-win2 driver services are registered.
  ///
  /// usbip2_ude and usbip2_filter form one driver chain. Finding only one of
  /// them is an incomplete installation and must not be reported as ready.
  final bool servicesDetected;

  /// True when Windows has enumerated the virtual USB bus device required by
  /// the USB/IP client. A driver package can be installed without this node.
  final bool virtualDeviceDetected;

  bool get available =>
      status == 'available' && servicesDetected && virtualDeviceDetected;
  bool get missing => status == 'missing';
  bool get pendingRestart => status == 'pending_restart';

  /// Parses the stable markers emitted by the PowerShell environment probe.
  ///
  /// Keeping this parser platform-independent makes the distinction between
  /// a registered service and an enumerated PnP device testable on Linux.
  static WindowsClientDriverCheck parseProbeOutput(String output,
      {int exitCode = 0}) {
    const requiredServiceNames = <String>{'usbip2_ude', 'usbip2_filter'};
    final lines = output
        .split(RegExp(r'[\r\n]+'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
    final services = lines
        .where((line) => line.toUpperCase().startsWith('SERVICE|'))
        .toList();
    final devices = lines
        .where((line) => line.toUpperCase().startsWith('DEVICE|'))
        .toList();
    final hasServiceError = lines
        .any((line) => line.toUpperCase().startsWith('SERVICE_QUERY_ERROR|'));
    final hasDeviceError = lines
        .any((line) => line.toUpperCase().startsWith('DEVICE_QUERY_ERROR|'));
    final serviceNames = services
        .map((line) => line.substring('SERVICE|'.length).split('|').first)
        .map((name) => name.trim().toLowerCase())
        .where((name) => name.isNotEmpty)
        .toSet();
    final servicesDetected = requiredServiceNames.every(serviceNames.contains);
    final virtualDeviceDetected = devices.isNotEmpty;
    final serviceDescription =
        services.isEmpty ? '未注册' : (servicesDetected ? '已注册' : '注册不完整');
    final detail = <String>[
      '驱动服务：$serviceDescription',
      if (services.isNotEmpty)
        '（${services.map((line) => line.substring('SERVICE|'.length)).join('；')}）',
      '虚拟 USB 设备节点：${virtualDeviceDetected ? '已创建' : '未创建'}',
      if (devices.isNotEmpty)
        '（${devices.map((line) => line.substring('DEVICE|'.length)).join('；')}）',
      if (hasServiceError) '驱动服务查询异常',
      if (hasDeviceError) '虚拟 USB 设备节点查询异常',
    ].join(' ');

    if (hasServiceError ||
        hasDeviceError ||
        (exitCode != 0 &&
            !lines.contains('NO_USBIP_DRIVER') &&
            !lines.contains('NO_USBIP_DEVICE'))) {
      return WindowsClientDriverCheck(
        status: 'unknown',
        output: detail,
        servicesDetected: servicesDetected,
        virtualDeviceDetected: virtualDeviceDetected,
      );
    }
    if (servicesDetected && virtualDeviceDetected) {
      return WindowsClientDriverCheck(
        status: 'available',
        output: detail,
        servicesDetected: true,
        virtualDeviceDetected: true,
      );
    }
    // Driver package registration and PnP device enumeration are separate
    // operations. A successful install can leave the service visible while
    // the root-enumerated virtual USB device is waiting for a reboot or a
    // fresh PnP scan. Keep that actionable state distinct from a missing
    // driver package.
    if (servicesDetected && !virtualDeviceDetected) {
      return WindowsClientDriverCheck(
        status: 'pending_restart',
        output: '$detail；客户端驱动服务已注册，但虚拟 USB 设备节点尚未枚举，可能需要重启 Windows。',
        servicesDetected: true,
        virtualDeviceDetected: false,
      );
    }
    return WindowsClientDriverCheck(
      status: 'missing',
      output: detail,
      servicesDetected: servicesDetected,
      virtualDeviceDetected: virtualDeviceDetected,
    );
  }
}

class UsbIpService {
  /// Decode output from a USB/IP process without corrupting localized names.
  ///
  /// Recent usbipd-win builds emit redirected output as UTF-8. Dart's
  /// [systemEncoding] follows the active Windows code page, which turns
  /// UTF-8 Chinese such as `输入设备` into mojibake such as `杈撳叆璁惧` on
  /// Simplified Chinese Windows. Keep a fallback for older native builds that
  /// still emit the active system code page.
  static String decodeProcessOutput(List<int> bytes,
      {bool windows = false, Encoding? fallbackEncoding}) {
    if (bytes.isEmpty) return '';
    if (!windows) return systemEncoding.decode(bytes);
    // Do not use Process.run's String output on Windows. It decodes before
    // this service can choose an encoding, which turns UTF-8 device names
    // such as `输入设备` into `杈撳叆璁惧`. Some native tools still mix a
    // code-page line into otherwise UTF-8 output, so decode each line on its
    // original byte boundary instead of letting one bad byte downgrade the
    // complete command output.
    final fallback = fallbackEncoding ?? systemEncoding;
    final output = StringBuffer();
    var lineStart = 0;
    for (var index = 0; index < bytes.length; index++) {
      if (bytes[index] != 0x0a) continue;
      output.write(_decodeWindowsLine(bytes, lineStart, index, fallback));
      output.write('\n');
      lineStart = index + 1;
    }
    if (lineStart < bytes.length) {
      output
          .write(_decodeWindowsLine(bytes, lineStart, bytes.length, fallback));
    }
    return output.toString();
  }

  static String _decodeWindowsLine(
      List<int> bytes, int start, int end, Encoding fallback) {
    // A CR belongs to the line ending and is valid UTF-8, so keeping it in
    // the slice preserves CRLF output without affecting the strict check.
    final line = bytes.sublist(start, end);
    try {
      return utf8.decode(line, allowMalformed: false);
    } on FormatException {
      // Compatibility with older native builds that emit the active Windows
      // code page. The fallback is limited to this line so a single malformed
      // diagnostic cannot corrupt valid UTF-8 device names elsewhere.
      return fallback.decode(line);
    }
  }

  /// Client executable names used by the different usbip-win2 releases.
  /// Keep the aliases together so discovery, diagnostics, and custom install
  /// directory lookup cannot drift apart.
  static const windowsClientExecutableNames = <String>[
    'usbipw.exe',
    'usbip.exe',
    'usbip-win2.exe',
  ];

  static const windowsServerExecutableNames = <String>[
    'usbipd.exe',
    'usbipd',
  ];

  static const windowsClientDriverServiceNames = <String>[
    'usbip2_ude',
    'usbip2_filter',
  ];

  bool isLinux(UsbIpRole role) =>
      role == UsbIpRole.linux ||
      role == UsbIpRole.linuxServer ||
      role == UsbIpRole.linuxClient;

  bool isServer(UsbIpRole role) =>
      role == UsbIpRole.linux ||
      role == UsbIpRole.linuxServer ||
      role == UsbIpRole.windowsServer;

  bool isClient(UsbIpRole role) =>
      role == UsbIpRole.linuxClient || role == UsbIpRole.windowsClient;

  String executable(UsbIpRole role, String customPath) {
    if (customPath.trim().isNotEmpty) return customPath.trim();
    if (role == UsbIpRole.windowsServer) return 'usbipd';
    if (role == UsbIpRole.windowsClient) return 'usbipw.exe';
    return 'usbip';
  }

  List<String> _executableCandidates(UsbIpRole role, String customPath) {
    if (customPath.trim().isNotEmpty) return [customPath.trim()];
    if (Platform.isWindows &&
        (role == UsbIpRole.windowsServer || role == UsbIpRole.windowsClient)) {
      return _windowsExecutableCandidates(role);
    }
    return [executable(role, customPath)];
  }

  /// Returns the candidate executable names and install locations used by
  /// this service. Keeping this public lets the environment checker explain
  /// exactly which Windows locations were inspected.
  List<String> executableCandidates(UsbIpRole role, {String customPath = ''}) {
    return _executableCandidates(role, customPath);
  }

  /// Checks whether a Windows executable belongs to the requested role.
  ///
  /// Keep this check independent of [Platform.isWindows] so it can be tested
  /// on Linux and so a saved Windows path cannot accidentally be reused for a
  /// different role after the user switches the UI selector.
  bool isExpectedWindowsExecutable(String path, UsbIpRole role) {
    if (role != UsbIpRole.windowsServer && role != UsbIpRole.windowsClient) {
      return true;
    }
    final normalized = path.trim().replaceAll('\\', '/');
    final separator = normalized.lastIndexOf('/');
    final name =
        (separator < 0 ? normalized : normalized.substring(separator + 1))
            .toLowerCase();
    final names = role == UsbIpRole.windowsServer
        ? windowsServerExecutableNames
        : windowsClientExecutableNames;
    return names.any((candidate) => candidate.toLowerCase() == name);
  }

  /// Resolves a usable executable without relying solely on the environment
  /// inherited when the Flutter process was started. This matters on Windows:
  /// an MSI can update PATH while an already-running GUI still has the old
  /// PATH value.
  Future<String?> findExecutable(UsbIpRole role,
      {String customPath = ''}) async {
    if (customPath.trim().isNotEmpty) {
      // The settings field accepts either an executable path or an install
      // directory. Keep environment checking consistent with run(), which
      // already resolves both forms.
      final resolved = await _resolveCustomExecutable(role, customPath.trim());
      if (resolved != null) return resolved;
      // A portable build can keep a path from another machine in its per-user
      // settings. A stale path must not hide a newly installed tool that is
      // available through PATH, the registry, or the usbipd service.
    }
    // A missing saved path is only a hint, not an override.  Build the
    // fallback list without it so PATH and platform-specific discovery can
    // still find a tool installed since the last application run.
    final candidates = _executableCandidates(role, '');
    final registryEntries = Platform.isWindows
        ? await _windowsRegistryUninstallEntries()
        : const <WindowsUninstallEntry>[];
    if (Platform.isWindows) {
      // A running Flutter process keeps the PATH it inherited at startup.
      // Read the machine/user PATH from the registry as an additional source
      // so an install completed while the app was open is still discoverable.
      candidates.addAll(await _windowsRegistryExecutableCandidates(role));
      // usbipd-win and some usbip-win2 installers keep their install metadata
      // outside the normal Add/Remove Programs tree. Query those vendor keys
      // directly as well.
      candidates
          .addAll(await _windowsDedicatedRegistryExecutableCandidates(role));
      if (role == UsbIpRole.windowsServer) {
        // usbipd-win is registered as a Windows service. Its service command
        // is authoritative even when the installer uses a custom location.
        candidates.addAll(await _windowsServiceExecutableCandidates());
        candidates.addAll(await _windowsServiceRegistryExecutableCandidates());
      }
      candidates
          .addAll(_windowsUninstallExecutableCandidates(registryEntries, role));
    }
    for (final candidate in candidates) {
      final resolved = await _resolveExecutable(candidate);
      if (resolved != null) return resolved;
    }
    if (Platform.isWindows) {
      final discovered = await _findWindowsExecutableBelow(
          _windowsUninstallInstallDirectories(registryEntries, role),
          _windowsExecutableNames(role));
      if (discovered != null) return discovered;
    }
    return null;
  }

  /// Returns actionable Windows lookup information for the GUI log.
  ///
  /// A Windows process keeps the PATH inherited at startup.  In addition,
  /// usbipd-win is installed as a service and may not be present in PATH at
  /// all.  Keep this diagnostic separate from [findExecutable] so normal
  /// refreshes remain quiet while a missing-tool failure explains every
  /// lookup source that was actually inspected.
  Future<List<String>> windowsToolDiagnostics(UsbIpRole role,
      {String customPath = ''}) async {
    if (!Platform.isWindows) return const [];
    final lines = <String>[];
    if (customPath.trim().isNotEmpty) {
      final value = customPath.trim();
      final normalized = _unquote(value);
      final file = File(normalized);
      final directory = Directory(normalized);
      lines.add('自定义工具路径：$value');
      lines.add('自定义路径文件存在：${await file.exists()}');
      lines.add('自定义路径目录存在：${await directory.exists()}');
      if (await file.exists()) {
        lines.add('自定义路径角色匹配：'
            '${isExpectedWindowsExecutable(normalized, role) ? '通过' : '失败（当前角色不接受此文件名）'}');
        lines.addAll(await _windowsFileDiagnostics('自定义工具', normalized));
      }
    }

    final names = role == UsbIpRole.windowsServer
        ? windowsServerExecutableNames
        : windowsClientExecutableNames;
    // Keep the well-known installer locations visible even when none of them
    // exists. This makes an offline-install failure immediately actionable:
    // the log shows whether files were written to the expected directory.
    final fixedPaths = _windowsFixedExecutableCandidates(role);
    lines.add('固定安装路径检查：${fixedPaths.length} 项');
    for (final path in fixedPaths) {
      lines.addAll(await _windowsFileDiagnostics('固定安装路径', path));
    }

    final whereCandidates = <String>[];
    final where = await _windowsSystemExecutable('where.exe');
    if (where == null) {
      lines.add('where.exe：未找到');
    } else {
      lines.add('where.exe：$where');
      for (final name in names) {
        try {
          final result = await _runProcess(where, [name]);
          final output = result.stdout.toString().trim();
          whereCandidates.addAll(output
              .split(RegExp(r'[\r\n]+'))
              .map((line) => line.trim())
              .where((line) => line.isNotEmpty));
          lines.add('where $name：退出码 ${result.exitCode}'
              '${output.isEmpty ? '' : '，$output'}');
        } catch (error) {
          lines.add('where $name：执行异常：$error');
        }
      }
    }

    final knownPaths = _executableCandidates(role, '').where(_looksLikePath);
    final existingPaths = <String>[];
    for (final candidate in knownPaths) {
      if (await File(_unquote(candidate)).exists()) {
        existingPaths.add(candidate);
      }
    }
    lines.add(existingPaths.isEmpty
        ? '标准安装目录：未发现可执行文件'
        : '标准安装目录已发现：${existingPaths.join('；')}');
    for (final path in existingPaths) {
      lines.addAll(await _windowsFileDiagnostics('标准安装目录工具', path));
    }

    final registryEntries = await _windowsRegistryUninstallEntries();
    final dedicatedRegistryCandidates =
        await _windowsDedicatedRegistryExecutableCandidates(role);
    final existingDedicatedRegistryPaths = <String>[];
    for (final candidate in dedicatedRegistryCandidates) {
      if (await File(_unquote(candidate)).exists()) {
        existingDedicatedRegistryPaths.add(candidate);
      }
    }
    lines.add(existingDedicatedRegistryPaths.isEmpty
        ? 'USB/IP 专用注册表：未发现可执行文件'
        : 'USB/IP 专用注册表候选路径已发现：${existingDedicatedRegistryPaths.join('；')}');
    for (final path in existingDedicatedRegistryPaths) {
      lines.addAll(await _windowsFileDiagnostics('专用注册表工具', path));
    }
    final registryCandidates =
        _windowsUninstallExecutableCandidates(registryEntries, role);
    final existingRegistryPaths = <String>[];
    for (final candidate in registryCandidates) {
      if (await File(_unquote(candidate)).exists()) {
        existingRegistryPaths.add(candidate);
      }
    }
    final registryNames = registryEntries
        .where((entry) => _matchesWindowsUninstallRole(entry.displayName, role))
        .map((entry) => entry.displayName ?? entry.key)
        .toSet()
        .toList();
    lines.add(registryNames.isEmpty
        ? '卸载注册表：未找到匹配 USB/IP 安装项'
        : '卸载注册表安装项：${registryNames.join('；')}');
    lines.add(existingRegistryPaths.isEmpty
        ? '卸载注册表候选路径：未发现可执行文件'
        : '卸载注册表候选路径已发现：${existingRegistryPaths.join('；')}');
    for (final path in existingRegistryPaths) {
      lines.addAll(await _windowsFileDiagnostics('卸载注册表工具', path));
    }
    if (role == UsbIpRole.windowsClient) {
      final clientPaths = <String>{
        ...existingPaths,
        ...existingDedicatedRegistryPaths,
        ...existingRegistryPaths,
      };
      for (final path in clientPaths) {
        lines.addAll(await _windowsClientDependencyDiagnostics(path));
      }
      final driver = await checkWindowsClientDriver();
      lines.add('Windows 客户端驱动服务：'
          '${driver.servicesDetected ? '已注册' : '未注册'}');
      lines.add('Windows 客户端虚拟 USB 设备节点：'
          '${driver.virtualDeviceDetected ? '已创建' : '未创建'}');
      lines.add('Windows 客户端虚拟 USB 驱动总状态：${driver.status}');
      if (driver.output.isNotEmpty) {
        lines.add('Windows 客户端驱动查询：${driver.output}');
      }
    }
    final registryDirectories =
        _windowsUninstallInstallDirectories(registryEntries, role);
    lines.add(registryDirectories.isEmpty
        ? '卸载注册表安装目录：未解析到'
        : '卸载注册表安装目录：${registryDirectories.join('；')}');

    if (role == UsbIpRole.windowsServer) {
      final serviceCandidates = await _windowsServiceExecutableCandidates();
      final serviceRegistryCandidates =
          await _windowsServiceRegistryExecutableCandidates();
      lines.add(serviceCandidates.isEmpty
          ? 'usbipd 服务配置：未解析出可执行文件'
          : 'usbipd 服务配置：${serviceCandidates.join('；')}');
      lines.add(serviceRegistryCandidates.isEmpty
          ? 'usbipd 服务注册表：未解析出可执行文件'
          : 'usbipd 服务注册表：${serviceRegistryCandidates.join('；')}');
      for (final path in serviceCandidates) {
        lines.addAll(await _windowsFileDiagnostics('usbipd 服务配置工具', path));
      }
      for (final path in serviceRegistryCandidates) {
        lines.addAll(await _windowsFileDiagnostics('usbipd 服务注册表工具', path));
      }
      final sc = await _windowsSystemExecutable('sc.exe');
      if (sc == null) {
        lines.add('sc.exe：未找到');
      } else {
        try {
          final query = await _runProcess(sc, ['query', 'usbipd']);
          final state = RegExp(r'STATE\s*:\s*\d+\s+(\w+)', caseSensitive: false)
              .firstMatch(query.stdout.toString())
              ?.group(1);
          final queryOutput = '${query.stdout}\n${query.stderr}'.trim();
          lines.add('usbipd 服务是否存在：${query.exitCode == 0 ? '是' : '否'}');
          lines.add('usbipd 服务状态：退出码 ${query.exitCode}'
              '${state == null ? '' : '，$state'}');
          if (queryOutput.isNotEmpty) lines.add('usbipd 服务查询输出：$queryOutput');

          final config = await _runProcess(sc, ['qc', 'usbipd']);
          final configOutput = '${config.stdout}\n${config.stderr}'.trim();
          final configuredPath =
              parseWindowsServiceExecutable(config.stdout.toString());
          lines.add('usbipd 服务注册路径：${configuredPath ?? '未解析'}');
          if (configOutput.isNotEmpty) {
            lines.add('usbipd 服务配置输出：$configOutput');
          }
        } catch (error) {
          lines.add('usbipd 服务状态：执行异常：$error');
        }
      }

      final listCandidates = _uniqueWindowsPaths([
        ...whereCandidates,
        ...fixedPaths,
        ...serviceCandidates,
        ...serviceRegistryCandidates,
        ...existingPaths,
        ...existingDedicatedRegistryPaths,
        ...existingRegistryPaths,
      ]);
      String? listExecutable;
      for (final candidate in listCandidates) {
        final path = _unquote(candidate);
        if (await File(path).exists()) {
          listExecutable = path;
          break;
        }
      }
      if (listExecutable == null) {
        lines.add('usbipd list：未找到可执行文件，无法查询服务端设备列表');
      } else {
        lines.add('usbipd list 使用路径：$listExecutable');
        try {
          final list = await _runProcess(listExecutable, ['list']);
          final output = '${list.stdout}\n${list.stderr}'.trim();
          lines.add('usbipd list 退出码：${list.exitCode}');
          lines.add(
              output.isEmpty ? 'usbipd list 输出：<空>' : 'usbipd list 输出：$output');
        } catch (error) {
          lines.add('usbipd list 执行异常：$error');
        }
      }
    }
    return lines;
  }

  /// Returns locations used by the bundled/offline Windows installers.
  /// Include the C: default even when the process has an unusual environment,
  /// and also inspect the active system drive when it is different.
  List<String> _windowsFixedExecutableCandidates(UsbIpRole role) {
    final drives = <String>{'C:'};
    final systemDrive = Platform.environment['SystemDrive']?.trim();
    if (systemDrive != null && systemDrive.isNotEmpty) drives.add(systemDrive);
    final paths = <String>[];
    for (final drive in drives) {
      if (role == UsbIpRole.windowsServer) {
        paths.add('$drive\\Program Files\\usbipd-win\\usbipd.exe');
        paths.add('$drive\\Program Files\\usbipd-win\\bin\\usbipd.exe');
      } else if (role == UsbIpRole.windowsClient) {
        paths.add('$drive\\Program Files\\USBip\\usbipw.exe');
        paths.add('$drive\\Program Files\\USBip\\usbip.exe');
        paths.add('$drive\\Program Files\\usbip-win2\\usbipw.exe');
        paths.add('$drive\\Program Files\\usbip-win2\\usbip.exe');
      }
    }
    return _uniqueWindowsPaths(paths);
  }

  List<String> _windowsExecutableCandidates(UsbIpRole role) {
    final names = role == UsbIpRole.windowsServer
        ? windowsServerExecutableNames
        : windowsClientExecutableNames;
    final candidates = <String>[...names];
    final environment = Platform.environment;
    final roots = <String>{
      environment['ProgramW6432'] ?? '',
      environment['ProgramFiles'] ?? '',
      environment['ProgramFiles(x86)'] ?? '',
      environment['LOCALAPPDATA'] ?? '',
      environment['ProgramData'] ?? '',
      environment['APPDATA'] ?? '',
      environment['USERPROFILE'] ?? '',
    }..removeWhere((value) => value.trim().isEmpty);
    // ProgramFiles normally covers this already. The SystemDrive fallback is
    // useful when a portable launcher inherits a reduced environment and also
    // keeps the search valid when Windows is installed on a drive other than C:.
    final systemDrive = environment['SystemDrive']?.trim() ?? '';
    if (systemDrive.isNotEmpty) {
      roots.add('$systemDrive\\Program Files');
      roots.add('$systemDrive\\Program Files (x86)');
    }

    final directories = role == UsbIpRole.windowsServer
        ? const ['usbipd-win', r'usbipd-win\bin']
        : const [
            'USBip',
            r'USBip\bin',
            'USBIP',
            r'USBIP\bin',
            'usbip-win2',
            r'usbip-win2\bin',
            'USBip-win2',
            r'USBip-win2\bin',
            'Programs\\USBip',
            r'Programs\USBip\bin',
            'Programs\\USBIP',
            r'Programs\USBIP\bin',
            'Programs\\usbip-win2',
            r'Programs\usbip-win2\bin',
            'AppData\\Local\\Programs\\USBip',
            r'AppData\Local\Programs\USBip\bin',
          ];
    for (final root in roots) {
      for (final directory in directories) {
        for (final name in names.where((value) => value.endsWith('.exe'))) {
          candidates.add('$root\\$directory\\$name');
        }
      }
    }

    // Preserve order while avoiding duplicate paths from equivalent Windows
    // environment variables.
    final seen = <String>{};
    return [
      for (final candidate in candidates)
        if (seen.add(candidate.toLowerCase())) candidate,
    ];
  }

  List<String> _windowsExecutableNames(UsbIpRole role) {
    return role == UsbIpRole.windowsServer
        ? windowsServerExecutableNames
        : windowsClientExecutableNames;
  }

  Future<List<String>> _windowsServiceExecutableCandidates() async {
    final result = <String>[];
    final sc = await _windowsSystemExecutable('sc.exe');
    if (sc == null) return result;
    for (final serviceName in const ['usbipd', 'usbipd-win']) {
      try {
        final query = await _runProcess(sc, ['qc', serviceName]);
        if (query.exitCode != 0) continue;
        final path = parseWindowsServiceExecutable(query.stdout.toString());
        if (path != null && path.isNotEmpty) result.add(path);
      } catch (_) {
        // The service query is only an additional fallback. Common install
        // paths and PATH remain sufficient when the service query is denied.
      }
    }
    return result;
  }

  /// Reads install-directory metadata written by the native installers.
  /// `usbipd-win` currently uses `HKLM\SOFTWARE\usbipd-win`; relying only on
  /// Add/Remove Programs misses installations repaired by MSI or installed
  /// with a custom directory.
  Future<List<String>> _windowsDedicatedRegistryExecutableCandidates(
      UsbIpRole role) async {
    if (!Platform.isWindows) return const [];
    final reg = await _windowsSystemExecutable('reg.exe');
    if (reg == null) return const [];
    final keys = role == UsbIpRole.windowsServer
        ? const [
            r'HKLM\SOFTWARE\usbipd-win',
            r'HKLM\SOFTWARE\WOW6432Node\usbipd-win',
            r'HKCU\SOFTWARE\usbipd-win',
          ]
        : const [
            r'HKLM\SOFTWARE\USBip',
            r'HKLM\SOFTWARE\WOW6432Node\USBip',
            r'HKCU\SOFTWARE\USBip',
            r'HKLM\SOFTWARE\usbip-win2',
            r'HKLM\SOFTWARE\WOW6432Node\usbip-win2',
            r'HKCU\SOFTWARE\usbip-win2',
          ];
    final values = <String>[];
    for (final key in keys) {
      for (final valueName in const [
        'InstallLocation',
        'InstallDir',
        'InstallPath',
        'Path'
      ]) {
        try {
          final query = await _runProcess(reg, ['query', key, '/v', valueName]);
          if (query.exitCode != 0) continue;
          final value =
              _parseWindowsRegistryValue(query.stdout.toString(), valueName);
          final directory = _cleanWindowsDirectory(value);
          if (directory == null) continue;
          for (final name in _windowsExecutableNames(role)) {
            values.add('$directory\\$name');
          }
        } catch (_) {
          // A missing registry view is expected on some Windows versions.
        }
      }
    }
    return _uniqueWindowsPaths(values);
  }

  Future<List<String>> _windowsServiceRegistryExecutableCandidates() async {
    if (!Platform.isWindows) return const [];
    final reg = await _windowsSystemExecutable('reg.exe');
    if (reg == null) return const [];
    final result = <String>[];
    for (final key in const [
      r'HKLM\SYSTEM\CurrentControlSet\Services\usbipd',
      r'HKLM\SYSTEM\CurrentControlSet\Services\usbipd-win',
    ]) {
      try {
        final query = await _runProcess(reg, ['query', key, '/v', 'ImagePath']);
        if (query.exitCode != 0) continue;
        final command =
            _parseWindowsRegistryValue(query.stdout.toString(), 'ImagePath');
        final executable = _extractWindowsExecutablePath(command);
        if (executable != null) result.add(executable);
      } catch (_) {
        // `sc.exe qc` remains another service lookup fallback.
      }
    }
    return _uniqueWindowsPaths(result);
  }

  String? _parseWindowsRegistryValue(String output, String valueName) {
    final escaped = RegExp.escape(valueName);
    return RegExp(r'^\s*' + escaped + r'\s+REG_[A-Z0-9_]+\s+(.+?)\s*$',
            caseSensitive: false, multiLine: true)
        .firstMatch(output)
        ?.group(1)
        ?.trim();
  }

  Future<List<String>> _windowsRegistryExecutableCandidates(
      UsbIpRole role) async {
    if (!Platform.isWindows) return const [];
    final reg = await _windowsSystemExecutable('reg.exe');
    if (reg == null) return const [];
    final roots = <String>[];
    for (final key in const [
      r'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment',
      r'HKCU\Environment',
    ]) {
      try {
        final query = await _runProcess(reg, ['query', key, '/v', 'Path']);
        if (query.exitCode != 0) continue;
        final line = RegExp(r'^\s*Path\s+REG_[A-Z0-9_]+\s+(.+?)\s*$',
                caseSensitive: false, multiLine: true)
            .firstMatch(query.stdout.toString())
            ?.group(1);
        if (line == null) continue;
        roots.addAll(_expandWindowsPath(line).split(';'));
      } catch (_) {
        // Registry lookup is only a fallback. Standard locations and PATH
        // remain usable when policy blocks registry queries.
      }
    }

    final names = role == UsbIpRole.windowsServer
        ? const ['usbipd.exe']
        : windowsClientExecutableNames;
    final result = <String>[];
    for (final root in roots) {
      final directory = root.trim();
      if (directory.isEmpty) continue;
      for (final name in names) {
        result.add('$directory\\$name');
      }
    }
    return result;
  }

  Future<List<WindowsUninstallEntry>> _windowsRegistryUninstallEntries() async {
    if (!Platform.isWindows) return const [];
    final reg = await _windowsSystemExecutable('reg.exe');
    if (reg == null) return const [];
    const roots = [
      r'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
      r'HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
      r'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
    ];
    final entries = <WindowsUninstallEntry>[];
    for (final root in roots) {
      try {
        final query = await _runProcess(reg, ['query', root, '/s']);
        if (query.exitCode == 0) {
          entries.addAll(parseWindowsUninstallEntries(query.stdout.toString()));
        }
      } catch (_) {
        // Registry access is an optional fallback. PATH and fixed locations
        // remain available when policy blocks one of the registry views.
      }
    }
    final seen = <String>{};
    return [
      for (final entry in entries)
        if (seen.add(entry.key.toLowerCase())) entry,
    ];
  }

  /// Parses the text format emitted by `reg.exe query KEY /s`.
  ///
  /// This parser is platform-independent so it can be tested on Linux. It
  /// intentionally reads only the fields needed to locate an installed USB/IP
  /// executable and ignores unrelated registry values.
  List<WindowsUninstallEntry> parseWindowsUninstallEntries(String output) {
    final entries = <WindowsUninstallEntry>[];
    String? key;
    String? displayName;
    String? installLocation;
    String? displayIcon;
    String? uninstallString;
    String? quietUninstallString;

    void flush() {
      if (key == null) return;
      entries.add(WindowsUninstallEntry(
        key: key!,
        displayName: displayName,
        installLocation: installLocation,
        displayIcon: displayIcon,
        uninstallString: uninstallString,
        quietUninstallString: quietUninstallString,
      ));
      key = null;
      displayName = null;
      installLocation = null;
      displayIcon = null;
      uninstallString = null;
      quietUninstallString = null;
    }

    for (final line in output.split(RegExp(r'\r?\n'))) {
      final keyMatch = RegExp(r'^\s*(HKEY_[^\r\n]+)\s*$', caseSensitive: false)
          .firstMatch(line);
      if (keyMatch != null) {
        flush();
        key = keyMatch.group(1)!.trim();
        continue;
      }
      final valueMatch = RegExp(r'^\s+(\S+)\s+REG_[A-Z0-9_]+\s*(.*?)\s*$',
              caseSensitive: false)
          .firstMatch(line);
      if (valueMatch == null) continue;
      final name = valueMatch.group(1)!.toLowerCase();
      final value = valueMatch.group(2)!.trim();
      if (name == 'displayname') {
        displayName = value;
      } else if (name == 'installlocation') {
        installLocation = value;
      } else if (name == 'displayicon') {
        displayIcon = value;
      } else if (name == 'uninstallstring') {
        uninstallString = value;
      } else if (name == 'quietuninstallstring') {
        quietUninstallString = value;
      }
    }
    flush();
    return entries;
  }

  List<String> _windowsUninstallExecutableCandidates(
      List<WindowsUninstallEntry> entries, UsbIpRole role) {
    final names = _windowsExecutableNames(role);
    final result = <String>[];
    for (final entry in entries) {
      if (!_matchesWindowsUninstallRole(entry.displayName, role)) continue;
      final installDirectory = _cleanWindowsDirectory(entry.installLocation);
      if (installDirectory != null) {
        for (final name in names) {
          result.add('$installDirectory\\$name');
        }
      }
      for (final command in [
        entry.displayIcon,
        entry.uninstallString,
        entry.quietUninstallString
      ]) {
        final executable = _extractWindowsExecutablePath(command);
        if (executable == null) continue;
        final base = executable.split(RegExp(r'[\\/]')).last.toLowerCase();
        if (names.any((name) => name.toLowerCase() == base)) {
          result.add(executable);
          continue;
        }
        final index = _lastWindowsSeparatorIndex(executable);
        if (index > 0) {
          final parent = _cleanWindowsDirectory(executable.substring(0, index));
          if (parent != null) {
            for (final name in names) {
              result.add('$parent\\$name');
            }
          }
        }
      }
    }
    return _uniqueWindowsPaths(result);
  }

  List<String> _windowsUninstallInstallDirectories(
      List<WindowsUninstallEntry> entries, UsbIpRole role) {
    final result = <String>[];
    for (final entry in entries) {
      if (!_matchesWindowsUninstallRole(entry.displayName, role)) continue;
      final install = _cleanWindowsDirectory(entry.installLocation);
      if (install != null) result.add(install);
      for (final command in [
        entry.displayIcon,
        entry.uninstallString,
        entry.quietUninstallString
      ]) {
        final executable = _extractWindowsExecutablePath(command);
        if (executable == null) continue;
        final index = _lastWindowsSeparatorIndex(executable);
        if (index > 0) {
          final parent = _cleanWindowsDirectory(executable.substring(0, index));
          if (parent != null) result.add(parent);
        }
      }
    }
    return _uniqueWindowsPaths(result);
  }

  bool _matchesWindowsUninstallRole(String? displayName, UsbIpRole role) {
    final value = displayName?.toLowerCase() ?? '';
    // Registry display names are seen as both `USBip` and `USB/IP`. Removing
    // punctuation makes both forms match without accidentally treating an
    // unrelated product as a USB/IP installation.
    final normalized = value.replaceAll(RegExp(r'[^a-z0-9]'), '');
    if (!normalized.contains('usbip')) return false;
    if (role == UsbIpRole.windowsServer) return normalized.contains('usbipd');
    return role == UsbIpRole.windowsClient && !normalized.contains('usbipd');
  }

  String? _extractWindowsExecutablePath(String? value) {
    if (value == null || value.trim().isEmpty) return null;
    final quoted =
        RegExp(r'^\s*"([^"]+\.exe)', caseSensitive: false).firstMatch(value);
    final raw = quoted?.group(1) ??
        RegExp(r'(?:[A-Za-z]:\\|\\\\)[^\r\n"]*?\.exe', caseSensitive: false)
            .firstMatch(value)
            ?.group(0);
    if (raw == null || raw.trim().isEmpty) return null;
    return _expandWindowsPath(raw.trim()).replaceAll('/', '\\');
  }

  int _lastWindowsSeparatorIndex(String value) {
    final slash = value.lastIndexOf('/');
    final backslash = value.lastIndexOf('\\');
    return slash > backslash ? slash : backslash;
  }

  String? _cleanWindowsDirectory(String? value) {
    if (value == null || value.trim().isEmpty) return null;
    var directory = _expandWindowsPath(value.trim());
    if (directory.length >= 2 &&
        directory.startsWith('"') &&
        directory.endsWith('"')) {
      directory = directory.substring(1, directory.length - 1);
    }
    directory = directory.trim().replaceAll('/', '\\');
    while (directory.length > 3 && directory.endsWith('\\')) {
      directory = directory.substring(0, directory.length - 1);
    }
    return directory.isEmpty ? null : directory;
  }

  List<String> _uniqueWindowsPaths(Iterable<String> values) {
    final seen = <String>{};
    return [
      for (final value in values)
        if (value.trim().isNotEmpty && seen.add(value.toLowerCase())) value,
    ];
  }

  Future<String?> _findWindowsExecutableBelow(
      List<String> directories, List<String> names) async {
    final queue = <({String path, int depth})>[];
    final seen = <String>{};
    for (final directory in directories) {
      if (await Directory(directory).exists()) {
        queue.add((path: directory, depth: 0));
      }
    }
    for (var index = 0; index < queue.length; index++) {
      final item = queue[index];
      if (!seen.add(item.path.toLowerCase())) continue;
      for (final name in names) {
        final candidate = '${item.path}${Platform.pathSeparator}$name';
        if (await File(candidate).exists()) return candidate;
      }
      if (item.depth >= 3) continue;
      try {
        await for (final child in Directory(item.path)
            .list(followLinks: false, recursive: false)) {
          if (child is Directory) {
            queue.add((path: child.path, depth: item.depth + 1));
          }
        }
      } catch (_) {
        // Ignore inaccessible subdirectories and keep checking other roots.
      }
    }
    return null;
  }

  String _expandWindowsPath(String value) {
    var expanded = value;
    final environment = <String, String>{
      ...Platform.environment,
      'SystemRoot': Platform.environment['WINDIR'] ?? r'C:\Windows',
    };
    for (final entry in environment.entries) {
      // Environment variable names are case-insensitive on Windows. Use a
      // regex so values such as `%programfiles%` expand as well as the usual
      // `%ProgramFiles%` spelling.
      expanded = expanded.replaceAllMapped(
          RegExp('%${RegExp.escape(entry.key)}%', caseSensitive: false),
          (_) => entry.value);
    }
    return expanded;
  }

  /// Extracts the executable from `sc.exe qc` output. Service command lines
  /// may use a quoted path and append arguments, for example:
  /// `"C:\\Program Files\\usbipd-win\\usbipd.exe" --service`.
  ///
  /// This is public so the parser can be covered by platform-independent
  /// tests without pretending that a Linux test runner is Windows.
  String? parseWindowsServiceExecutable(String output) {
    final line = RegExp(r'^\s*BINARY_PATH_NAME\s*:\s*(.+?)\s*$',
            caseSensitive: false, multiLine: true)
        .firstMatch(output)
        ?.group(1)
        ?.trim();
    if (line == null || line.isEmpty) return null;

    if (line.startsWith('"')) {
      final closingQuote = line.indexOf('"', 1);
      if (closingQuote > 1) return line.substring(1, closingQuote);
    }

    // Unquoted Windows paths can contain spaces, so stop at the first .exe
    // rather than splitting on whitespace.
    final exe =
        RegExp(r'(?:\\\\\?\\)?[A-Za-z]:\\.*?\.exe', caseSensitive: false)
            .firstMatch(line)
            ?.group(0);
    return exe?.trim();
  }

  Future<String?> _windowsSystemExecutable(String name) async {
    if (!Platform.isWindows) return null;
    final windowsRoot = Platform.environment['WINDIR'] ?? r'C:\Windows';
    final absolute = '$windowsRoot\\System32\\$name';
    if (await File(absolute).exists()) return absolute;
    // `_resolveExecutable` uses `_windowsSystemExecutable` to locate
    // `where.exe`; calling it here would recurse when System32 is not
    // available through the current environment. Invoke where.exe directly
    // as the final fallback instead.
    try {
      final result = await _runProcess('where.exe', [name]);
      if (result.exitCode != 0) return null;
      final first = result.stdout
          .toString()
          .split(RegExp(r'[\r\n]+'))
          .map((line) => line.trim())
          .firstWhere((line) => line.isNotEmpty, orElse: () => '');
      return first.isEmpty ? null : first;
    } catch (_) {
      return null;
    }
  }

  Future<CommandResult> run(UsbIpRole role, List<String> args,
      {String customPath = ''}) async {
    final elevated = _requiresElevation(role, args) && !await _isRoot();
    // A user-supplied path is authoritative. Preserve the detailed process
    // error for a typo or a missing DLL instead of hiding it behind another
    // candidate.
    if (customPath.trim().isNotEmpty) {
      final resolvedCustomPath =
          await _resolveCustomExecutable(role, customPath.trim());
      if (resolvedCustomPath == null) {
        return CommandResult(
            command: '${customPath.trim()} ${args.join(' ')}',
            code: 127,
            output: '工具路径不存在或不是可执行文件：${customPath.trim()}\n'
                '请填写 exe 的完整路径，或填写包含对应 USB/IP exe 的安装目录。');
      }
      return _runExecutable(resolvedCustomPath, args,
          elevated: elevated, role: role);
    }

    final resolved = await findExecutable(role);
    if (resolved == null) {
      final candidates = _executableCandidates(role, '');
      final serviceCandidates =
          Platform.isWindows && role == UsbIpRole.windowsServer
              ? await _windowsServiceExecutableCandidates()
              : const <String>[];
      return CommandResult(
          command: '${executable(role, '')} ${args.join(' ')}',
          code: 127,
          output: '未找到 USB/IP 工具。已检查：'
              '${[...candidates, ...serviceCandidates].join('；')}\n'
              '请安装对应组件，或在“设置 > 工具路径”中填写可执行文件的完整路径。');
    }
    return _runExecutable(resolved, args, elevated: elevated, role: role);
  }

  /// Starts the Windows client with a harmless read-only command.
  ///
  /// Finding `usbipw.exe` on disk is insufficient: missing VC++ runtime DLLs,
  /// a wrong architecture, or a damaged install can all make the process
  /// fail before the GUI can use it. `port` does not change device state.
  /// Some usbip-win2 builds return non-zero when no config file or local
  /// virtual port exists, so callers must inspect [CommandResult.started]
  /// instead of treating every non-zero `port` result as a missing tool.
  Future<CommandResult> probeWindowsClient(String executable) {
    if (!Platform.isWindows) {
      return Future.value(const CommandResult(
          command: 'usbipw.exe port',
          code: 2,
          output: 'Windows 客户端探测只能在 Windows 上执行。'));
    }
    return run(UsbIpRole.windowsClient, ['port'], customPath: executable);
  }

  /// Reports the files that must be loadable before `usbipw.exe` can start.
  ///
  /// The Windows loader searches the executable directory, the system
  /// directories, and PATH. We intentionally report locations rather than
  /// copying Microsoft runtime DLLs into the project: those DLLs are covered
  /// by Microsoft's redistribution terms and should be installed through the
  /// official Visual C++ Redistributable package.
  Future<List<String>> _windowsClientDependencyDiagnostics(
      String executable) async {
    final normalized = _unquote(executable);
    final directory = File(normalized).parent.path;
    final lines = <String>[
      'Windows 客户端依赖目录：$directory',
    ];
    const bundledFiles = <String>[
      'usbipw.exe',
      'libusbip.dll',
      'resources.dll',
      'usb.ids',
    ];
    const runtimeFiles = <String>[
      'MSVCP140.dll',
      'VCRUNTIME140.dll',
      'VCRUNTIME140_1.dll',
      'api-ms-win-crt-runtime-l1-1-0.dll',
      'api-ms-win-crt-heap-l1-1-0.dll',
      'api-ms-win-crt-stdio-l1-1-0.dll',
      'api-ms-win-crt-string-l1-1-0.dll',
    ];

    Future<String?> locate(String name) async {
      final local = File('$directory${Platform.pathSeparator}$name');
      if (await local.exists()) return local.path;
      final windowsRoot = Platform.environment['WINDIR'] ?? r'C:\Windows';
      for (final systemDirectory in <String>[
        '$windowsRoot${Platform.pathSeparator}System32',
        '$windowsRoot${Platform.pathSeparator}SysWOW64',
      ]) {
        final systemFile =
            File('$systemDirectory${Platform.pathSeparator}$name');
        if (await systemFile.exists()) return systemFile.path;
      }
      final pathValue = Platform.environment['PATH'] ?? '';
      for (final pathEntry in pathValue.split(';')) {
        final trimmed = pathEntry.trim();
        if (trimmed.isEmpty) continue;
        final pathFile = File('$trimmed${Platform.pathSeparator}$name');
        if (await pathFile.exists()) return pathFile.path;
      }
      return null;
    }

    for (final name in bundledFiles) {
      final path = await locate(name);
      lines.add(path == null ? '$name 缺失' : '$name 存在：$path');
    }
    for (final name in runtimeFiles) {
      final path = await locate(name);
      lines.add(path == null
          ? '$name 缺失（请安装匹配架构的 Microsoft Visual C++ Redistributable）'
          : '$name 存在：$path');
    }
    return lines;
  }

  /// Parses the state token from `sc.exe query` output.
  ///
  /// The numeric state is deliberately ignored. Demand-start kernel drivers
  /// normally report STOPPED until the first attach operation, so callers
  /// only need the registered service name and the textual state.
  String? _parseWindowsServiceState(String output) {
    return RegExp(r'\bSTATE\s*:\s*\d+\s+([A-Z_]+)', caseSensitive: false)
        .firstMatch(output)
        ?.group(1)
        ?.toUpperCase();
  }

  /// Checks whether the Windows USB/IP client is actually enumerable.
  ///
  /// The user-mode executable and the driver service are not sufficient on
  /// their own. usbip-win2 also needs a root-enumerated virtual USB device
  /// (normally `ROOT\\USBIP_WIN2\\UDE`) before attach can create a local port.
  /// The PowerShell probe emits stable ASCII markers so the result remains
  /// parseable even when Windows localizes its command output.
  Future<WindowsClientDriverCheck> checkWindowsClientDriver() async {
    if (!Platform.isWindows) {
      return const WindowsClientDriverCheck(
          status: 'unknown', output: '当前平台不是 Windows。');
    }
    final powershell = await _windowsSystemExecutable('powershell.exe');
    if (powershell != null) {
      const script = r'''
$serviceNames = @('usbip2_ude', 'usbip2_filter')
$serviceQueryFailed = $false
$services = @()
try {
  $services = @(Get-CimInstance Win32_SystemDriver -ErrorAction Stop |
    Where-Object { $serviceNames -contains $_.Name })
} catch {
  $serviceQueryFailed = $true
  Write-Output ('SERVICE_QUERY_ERROR|' + $_.Exception.Message)
}
if ($services.Count -eq 0 -and -not $serviceQueryFailed) {
  Write-Output 'NO_USBIP_DRIVER'
}
foreach ($service in $services) {
  Write-Output ("SERVICE|$($service.Name)|$($service.State)|$($service.Status)")
}

$deviceQueryFailed = $false
$devices = @()
$devicePattern = '(?i)^(ROOT\\USBIP_WIN2\\|USBIPWIN\\|USB\\ROOT_HUB&VID_1209&PID_8250)'
try {
  $devices = @(Get-CimInstance Win32_PnPEntity -ErrorAction Stop |
    Where-Object {
      $instanceId = [string]$_.PNPDeviceID
      $hardwareIds = @($_.HardwareID | ForEach-Object { [string]$_ })
        $instanceId -match $devicePattern -or
        $hardwareIds -contains 'ROOT\USBIP_WIN2\UDE'
    })
} catch {
  try {
    $devices = @(Get-PnpDevice -PresentOnly:$false -ErrorAction Stop |
      Where-Object { ([string]$_.InstanceId) -match $devicePattern })
  } catch {
    $deviceQueryFailed = $true
    Write-Output ('DEVICE_QUERY_ERROR|' + $_.Exception.Message)
  }
}
if ($devices.Count -eq 0 -and -not $deviceQueryFailed) {
  Write-Output 'NO_USBIP_DEVICE'
}
foreach ($device in $devices) {
  $id = [string]$device.PNPDeviceID
  if ([string]::IsNullOrWhiteSpace($id)) { $id = [string]$device.InstanceId }
  Write-Output ("DEVICE|$id|$([string]$device.Name)|$([string]$device.Status)")
}
''';
      try {
        final result = await _runProcess(powershell, [
          '-NoProfile',
          '-NonInteractive',
          '-ExecutionPolicy',
          'Bypass',
          '-Command',
          script,
        ]);
        final output = '${result.stdout}\n${result.stderr}'.trim();
        final parsed = WindowsClientDriverCheck.parseProbeOutput(output,
            exitCode: result.exitCode);
        if (result.exitCode == 0 ||
            parsed.status != 'unknown' ||
            parsed.servicesDetected ||
            parsed.virtualDeviceDetected) {
          return parsed;
        }
      } catch (error) {
        // Fall through to sc.exe. It is available on supported Windows
        // versions even when the CIM/PowerShell module is restricted.
      }
    }

    final sc = await _windowsSystemExecutable('sc.exe');
    if (sc == null) {
      return const WindowsClientDriverCheck(
          status: 'unknown', output: '未找到 powershell.exe 或 sc.exe。');
    }
    final found = <String>[];
    final details = <String>[];
    for (final name in windowsClientDriverServiceNames) {
      try {
        final result = await _runProcess(sc, ['query', name]);
        final output = '${result.stdout}\n${result.stderr}'.trim();
        if (result.exitCode == 0 && output.contains('SERVICE_NAME')) {
          found.add(name);
          details
              .add('$name: ${_parseWindowsServiceState(output) ?? 'unknown'}');
        }
      } catch (_) {
        // Continue with the remaining service aliases.
      }
    }
    final allServicesDetected =
        windowsClientDriverServiceNames.every(found.contains);
    if (found.isNotEmpty) {
      return WindowsClientDriverCheck(
          status: 'unknown',
          output: allServicesDetected
              ? '驱动服务已注册（${details.join('; ')}），但无法查询虚拟 USB 设备节点。'
              : '驱动服务注册不完整（${details.join('; ')}），且无法查询虚拟 USB 设备节点。',
          servicesDetected: allServicesDetected);
    }
    return const WindowsClientDriverCheck(
        status: 'missing', output: '未发现 USB/IP 虚拟 USB 驱动服务。');
  }

  Future<CommandResult> list(UsbIpRole role, String host,
      {int remotePort = 3240, String customPath = ''}) {
    // The old `linux` role is an auto mode kept for persisted settings and
    // older callers. An empty host means local listing in that mode; only an
    // explicit client role requires a remote host.
    if (isClient(role) && host.trim().isEmpty) {
      return Future.value(const CommandResult(
          command: 'usbip list', code: 2, output: '客户端模式必须填写远程服务端地址。'));
    }
    if (role == UsbIpRole.windowsServer) {
      return run(role, ['list'], customPath: customPath);
    }
    if (role == UsbIpRole.linuxServer) {
      return run(role, ['list', '-l'], customPath: customPath);
    }
    if (isClient(role)) {
      final portError = _validateClientPort(role, remotePort);
      if (portError != null) return Future.value(portError);
      return run(role, ['--tcp-port', '$remotePort', 'list', '-r', host.trim()],
          customPath: customPath);
    }
    // `linux` is retained as a backwards-compatible auto role: an empty host
    // lists local devices, while a host lists remote exportable devices.
    if (host.trim().isEmpty) {
      return run(role, ['list', '-l'], customPath: customPath);
    }
    final portError = _validateClientPort(role, remotePort);
    if (portError != null) return Future.value(portError);
    return run(role, ['--tcp-port', '$remotePort', 'list', '-r', host.trim()],
        customPath: customPath);
  }

  Future<CommandResult> listPorts(UsbIpRole role, {String customPath = ''}) {
    if (role == UsbIpRole.windowsServer || role == UsbIpRole.linuxServer) {
      return Future.value(const CommandResult(
          command: 'usbip port',
          code: 2,
          output: '共享端没有本地 USB/IP 客户端端口；请切换到客户端角色后查询连接状态。'));
    }
    return run(role, ['port'], customPath: customPath);
  }

  Future<CommandResult> bind(UsbIpRole role, String id,
      {String customPath = ''}) {
    if (!isServer(role)) {
      return Future.value(const CommandResult(
          command: 'usbip bind', code: 2, output: '客户端模式不能绑定本机设备。'));
    }
    return role == UsbIpRole.windowsServer
        ? run(role, ['bind', '--busid', id], customPath: customPath)
        : run(role, ['bind', '-b', id], customPath: customPath);
  }

  /// Linux `usbip bind` only attaches usbip-host to the device.  The TCP
  /// server is a separate process, so make sure it is listening after a
  /// successful share operation.
  Future<CommandResult> share(UsbIpRole role, String id,
      {String customPath = '',
      int port = 3240,
      void Function(String step)? onStep}) async {
    if (port < 1 || port > 65535) {
      return const CommandResult(
          command: 'usbipd', code: 2, output: '端口必须在 1 到 65535 之间。');
    }
    if (!isServer(role)) {
      return const CommandResult(
          command: 'usbip bind', code: 2, output: '客户端模式不能执行绑定/共享。');
    }
    if (role == UsbIpRole.windowsServer && port != 3240) {
      return const CommandResult(
          command: 'usbipd bind',
          code: 2,
          output: 'usbipd-win 使用固定的 USB/IP TCP 端口 3240，Windows 共享端不能改用其他端口。');
    }
    onStep?.call('准备绑定设备：BUSID=$id');
    if (await isBound(role, id, customPath: customPath)) {
      onStep?.call('检测到设备已经绑定到 usbip-host，不再重复执行绑定。');
      if (!isLinux(role) || await _isListening(port)) {
        onStep?.call(isLinux(role) ? 'TCP $port 已在监听，设备已经共享。' : '设备已经共享。');
        return const CommandResult(
            command: 'usbip bind (skipped: already bound)',
            code: 0,
            output: '设备已经绑定，无需重复绑定。');
      }
      onStep?.call('设备已绑定但 TCP $port 未监听，继续启动 USB/IP 服务端。');
    }
    final bound = await bind(role, id, customPath: customPath);
    onStep?.call('命令完成：${bound.command}（退出码 ${bound.code}）');
    if (bound.output.isNotEmpty) onStep?.call('命令输出：${bound.output}');
    final alreadyBound = _isAlreadyBound(bound.output);
    if (alreadyBound) {
      onStep?.call(isLinux(role)
          ? '设备已经绑定到 usbip-host，跳过重复绑定，继续检查服务端。'
          : '设备已经由 usbipd-win 共享，跳过重复绑定。');
    }
    if (!bound.ok && !alreadyBound) return bound;
    if (!isLinux(role)) {
      return alreadyBound
          ? CommandResult(
              command: bound.command,
              code: 0,
              output: '${bound.output}\n设备已经共享，无需重复绑定。')
          : bound;
    }

    onStep?.call('检查 USB/IP 服务端端口：TCP $port');
    if (await _isListening(port)) {
      onStep?.call('TCP $port 已在监听，复用现有 usbipd。');
      return CommandResult(
        command: '${bound.command}; usbipd already listening on $port',
        code: 0,
        output: '${bound.output}\nUSB/IP 服务端已在 $port 端口监听。设备已共享。',
      );
    }

    // `usbipd` is a separate Linux executable, not a subcommand of `usbip`.
    // If the user supplied a custom usbip path, use its sibling usbipd too.
    final daemonExecutable = _daemonExecutable(customPath);
    onStep
        ?.call('未发现 TCP $port 监听，启动服务端：$daemonExecutable --tcp-port $port -D');
    final daemon = await _runExecutable(
        daemonExecutable, ['--tcp-port', '$port', '-D'],
        elevated: !await _isRoot());
    onStep?.call('命令完成：${daemon.command}（退出码 ${daemon.code}）');
    if (daemon.output.isNotEmpty) onStep?.call('命令输出：${daemon.output}');
    if (daemon.ok && await _waitForListening(port)) {
      onStep?.call('确认 TCP $port 已开始监听，设备共享完成。');
      return CommandResult(
        command: '${bound.command}; ${daemon.command}',
        code: 0,
        output: '${bound.output}\nUSB/IP 服务端已启动，监听端口 $port。设备已共享。',
      );
    }
    onStep?.call('警告：设备已绑定，但未确认 usbipd 正在监听 TCP $port。');
    return CommandResult(
      command: '${bound.command}; ${daemon.command}',
      code: daemon.code,
      output: '${bound.output}\n设备已绑定，但 usbipd 启动失败：${daemon.output}',
    );
  }

  Future<CommandResult> unbind(UsbIpRole role, String id,
      {String customPath = ''}) {
    if (!isServer(role)) {
      return Future.value(const CommandResult(
          command: 'usbip unbind', code: 2, output: '客户端模式不能解绑本机设备。'));
    }
    return role == UsbIpRole.windowsServer
        ? run(role, ['unbind', '--busid', id], customPath: customPath)
        : run(role, ['unbind', '-b', id], customPath: customPath);
  }

  Future<bool> isBound(UsbIpRole role, String id,
      {String customPath = ''}) async {
    if (id.trim().isEmpty) return false;
    if (role == UsbIpRole.windowsServer) {
      final result = await run(role, ['list'], customPath: customPath);
      if (!result.ok) return false;
      return parse(result.output, role: role)
          .any((device) => device.id == id.trim() && device.bound);
    }
    if (!isLinux(role)) return false;
    try {
      final link = Link('/sys/bus/usb/devices/${id.trim()}/driver');
      return (await link.resolveSymbolicLinks())
              .split(Platform.pathSeparator)
              .last ==
          'usbip-host';
    } catch (_) {
      return false;
    }
  }

  Future<CommandResult> attach(UsbIpRole role, String host, String id,
      {int remotePort = 3240, String customPath = ''}) {
    // Keep the old Linux auto role usable for callers that still persisted it.
    // The UI only exposes the explicit Linux client/server roles.
    if (role != UsbIpRole.linux && !isClient(role)) {
      return Future.value(const CommandResult(
          command: 'usbip attach', code: 2, output: '服务端模式不能执行客户端连接。'));
    }
    if (host.trim().isEmpty) {
      return Future.value(const CommandResult(
          command: 'usbip attach', code: 2, output: '客户端连接必须填写远程主机地址。'));
    }
    final portError = _validateClientPort(role, remotePort);
    if (portError != null) return Future.value(portError);
    return run(role,
        ['--tcp-port', '$remotePort', 'attach', '-r', host.trim(), '-b', id],
        customPath: customPath);
  }

  Future<CommandResult> detach(UsbIpRole role, String port,
      {String customPath = ''}) {
    if (role != UsbIpRole.linux && !isClient(role)) {
      return Future.value(const CommandResult(
          command: 'usbip detach', code: 2, output: '服务端模式不能执行客户端断开。'));
    }
    return run(role, ['detach', '-p', port], customPath: customPath);
  }

  CommandResult? _validateClientPort(UsbIpRole role, int port) {
    final minimum = role == UsbIpRole.windowsClient ? 1024 : 1;
    if (port < minimum || port > 65535) {
      final range =
          role == UsbIpRole.windowsClient ? '1024 到 65535' : '1 到 65535';
      return CommandResult(
          command: 'usbip client', code: 2, output: '远程服务端端口必须在 $range 之间。');
    }
    return null;
  }

  bool _requiresElevation(UsbIpRole role, List<String> args) {
    if (!isLinux(role) || args.isEmpty) return false;
    // Client commands may start with global options such as `--tcp-port`.
    // Look through all arguments so `usbip --tcp-port 4000 attach ...` is
    // elevated just like the shorter `usbip attach ...` form.
    return args.any(const {'bind', 'unbind', 'attach', 'detach'}.contains);
  }

  Future<bool> _isRoot() async {
    if (!Platform.isLinux) return false;
    try {
      final result = await _runProcess('id', ['-u']);
      return result.exitCode == 0 && result.stdout.toString().trim() == '0';
    } catch (_) {
      return false;
    }
  }

  Future<bool> _commandExists(String command) async {
    if (command.trim().isEmpty) return false;
    try {
      final result = await _runProcess(Platform.isWindows ? 'where.exe' : 'sh',
          Platform.isWindows ? [command] : ['-c', 'command -v "$command"']);
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  Future<String?> _resolveExecutable(String candidate) async {
    candidate = _unquote(candidate.trim());
    if (candidate.isEmpty) return null;
    if (_looksLikePath(candidate)) {
      return await File(candidate).exists() ? candidate : null;
    }
    try {
      final where = Platform.isWindows ? await _windowsWhereExecutable() : null;
      final result = await _runProcess(
          where ?? (Platform.isWindows ? 'where.exe' : 'sh'),
          Platform.isWindows ? [candidate] : ['-c', 'command -v "$candidate"']);
      if (result.exitCode != 0) return null;
      final first = result.stdout
          .toString()
          .split(RegExp(r'[\r\n]+'))
          .map((line) => line.trim())
          .firstWhere((line) => line.isNotEmpty, orElse: () => '');
      return first.isEmpty ? candidate : first;
    } catch (_) {
      return null;
    }
  }

  Future<String?> _resolveCustomExecutable(
      UsbIpRole role, String customPath) async {
    final unquoted = _unquote(customPath);
    if (await File(unquoted).exists()) {
      if (!isExpectedWindowsExecutable(unquoted, role)) return null;
      return unquoted;
    }
    if (!await Directory(unquoted).exists()) {
      // The settings field also documents executable names such as
      // `usbipd.exe`. Resolve those through PATH and the Windows registry
      // fallbacks instead of treating the name as a literal relative path.
      if (!_looksLikePath(unquoted)) {
        final resolved = await _resolveExecutable(unquoted);
        if (resolved != null && isExpectedWindowsExecutable(resolved, role)) {
          return resolved;
        }
      }
      return null;
    }

    final names = role == UsbIpRole.windowsServer
        ? const ['usbipd.exe', 'usbipd']
        : role == UsbIpRole.windowsClient
            ? windowsClientExecutableNames
            : const ['usbip'];
    for (final name in names) {
      final candidate = '$unquoted${Platform.pathSeparator}$name';
      if (await File(candidate).exists()) return candidate;
    }
    return null;
  }

  Future<String?> _windowsWhereExecutable() async {
    if (!Platform.isWindows) return null;
    return _windowsSystemExecutable('where.exe');
  }

  String _unquote(String value) {
    var result = value.trim();
    if (result.length >= 2 && result.startsWith('"') && result.endsWith('"')) {
      result = result.substring(1, result.length - 1);
    }
    return Platform.isWindows ? _expandWindowsPath(result) : result;
  }

  bool _looksLikePath(String value) =>
      value.contains('/') ||
      value.contains('\\') ||
      RegExp(r'^[A-Za-z]:').hasMatch(value);

  Future<bool> _isListening(int port) async {
    try {
      final socket = await Socket.connect(InternetAddress.loopbackIPv4, port,
          timeout: const Duration(milliseconds: 400));
      await socket.close();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _waitForListening(int port) async {
    for (var attempt = 0; attempt < 10; attempt++) {
      if (await _isListening(port)) return true;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    return false;
  }

  String _daemonExecutable(String customPath) {
    final trimmed = customPath.trim();
    if (trimmed.isEmpty) return 'usbipd';
    if (!trimmed.contains('/') && !trimmed.contains('\\')) return 'usbipd';
    final file = File(trimmed);
    final name =
        file.uri.pathSegments.isEmpty ? trimmed : file.uri.pathSegments.last;
    if (name.toLowerCase() == 'usbipd' || name.toLowerCase() == 'usbipd.exe') {
      return trimmed;
    }
    return '${file.parent.path}${Platform.pathSeparator}usbipd';
  }

  bool _isAlreadyBound(String output) {
    final text = output.toLowerCase();
    return text.contains('already bound') ||
        text.contains('already shared') ||
        text.contains('already exported') ||
        text.contains('已绑定') ||
        text.contains('已共享');
  }

  Future<CommandResult> _runExecutable(String executable, List<String> args,
      {bool elevated = false, UsbIpRole? role}) async {
    var actualExecutable = executable;
    var actualArgs = args;
    if (elevated && Platform.isLinux) {
      if (await _commandExists('pkexec')) {
        actualExecutable = 'pkexec';
        actualArgs = [executable, ...args];
      } else if (await _commandExists('sudo')) {
        actualExecutable = 'sudo';
        actualArgs = [executable, ...args];
      } else {
        return CommandResult(
            command: '$executable ${args.join(' ')}',
            code: 126,
            output: '执行 USB/IP 操作需要 root 权限；未找到 pkexec 或 sudo。');
      }
    }
    final command = _formatCommand([actualExecutable, ...actualArgs]);
    final workingDirectory =
        Platform.isWindows && _looksLikePath(actualExecutable)
            ? File(_unquote(actualExecutable)).parent.path
            : null;
    try {
      final process = await Process.start(actualExecutable, actualArgs,
          workingDirectory: workingDirectory);
      final stdout = _collectProcessOutput(process.stdout);
      final stderr = _collectProcessOutput(process.stderr);
      final code = await process.exitCode.timeout(const Duration(seconds: 30),
          onTimeout: () {
        process.kill(ProcessSignal.sigterm);
        return 124;
      });
      return CommandResult(
          command: command,
          code: code,
          output: '${await stdout}${await stderr}'.trim());
    } on ProcessException catch (error) {
      return CommandResult(
          command: command,
          code: 127,
          started: false,
          output: [
            '找不到或无法执行工具：${error.message}',
            '系统错误码：${error.errorCode}',
            '实际可执行文件：$actualExecutable',
            if (workingDirectory != null) '启动工作目录：$workingDirectory',
            if (Platform.isWindows)
              ...await _windowsLaunchDiagnostics(actualExecutable, role: role),
            '请确认路径指向已安装的 USB/IP 可执行文件，而不是 MSI/EXE 安装器；也请检查 DLL、系统架构和权限。',
          ].join('\n'));
    } catch (error) {
      return CommandResult(
          command: command, code: 1, started: false, output: '执行失败：$error');
    }
  }

  /// Runs short diagnostic commands while preserving the bytes emitted by the
  /// child process. `Process.run` decodes output before this service can choose
  /// the Windows encoding, which turns UTF-8 device names into mojibake on
  /// code-page based systems.
  Future<ProcessResult> _runProcess(String executable, List<String> args,
      {String? workingDirectory}) async {
    final process = await Process.start(executable, args,
        workingDirectory: workingDirectory);
    final stdoutBytes = <int>[];
    final stderrBytes = <int>[];

    final stdoutDone = () async {
      await for (final chunk in process.stdout) {
        stdoutBytes.addAll(chunk);
      }
    }();
    final stderrDone = () async {
      await for (final chunk in process.stderr) {
        stderrBytes.addAll(chunk);
      }
    }();
    final code = await process.exitCode;
    await Future.wait([stdoutDone, stderrDone]);

    return ProcessResult(
      process.pid,
      code,
      decodeProcessOutput(stdoutBytes, windows: Platform.isWindows),
      decodeProcessOutput(stderrBytes, windows: Platform.isWindows),
    );
  }

  Future<String> _collectProcessOutput(Stream<List<int>> stream) async {
    final bytes = <int>[];
    await for (final chunk in stream) {
      bytes.addAll(chunk);
    }
    return decodeProcessOutput(bytes, windows: Platform.isWindows);
  }

  String _formatCommand(List<String> parts) {
    return parts
        .map((part) => part.contains(RegExp(r'[\s"]'))
            ? '"${part.replaceAll('"', '\\"')}"'
            : part)
        .join(' ');
  }

  Future<List<String>> _windowsFileDiagnostics(
      String label, String path) async {
    final normalized = _unquote(path);
    final file = File(normalized);
    final lines = <String>['$label：$normalized'];
    final exists = await file.exists();
    lines.add('$label 文件存在：$exists');
    if (!exists) return lines;
    try {
      final stat = await file.stat();
      lines.add('$label 文件大小：${stat.size} 字节');
    } catch (error) {
      lines.add('$label 文件属性读取失败：$error');
    }
    return lines;
  }

  Future<List<String>> _windowsLaunchDiagnostics(String executable,
      {UsbIpRole? role}) async {
    final normalized = _unquote(executable);
    final roleName = role == UsbIpRole.windowsServer
        ? 'Windows 服务端'
        : role == UsbIpRole.windowsClient
            ? 'Windows 客户端'
            : '当前角色';
    final lines = <String>[
      '启动文件存在：${await File(normalized).exists()}',
      if (role == null ||
          (role != UsbIpRole.windowsServer && role != UsbIpRole.windowsClient))
        '启动文件角色：未指定 Windows 角色'
      else
        '启动文件名符合$roleName：${isExpectedWindowsExecutable(normalized, role)}',
      '启动文件父目录：${File(normalized).parent.path}',
      '当前工作目录：${Directory.current.path}',
    ];
    try {
      final stat = await File(normalized).stat();
      lines.add('启动文件大小：${stat.size} 字节');
    } catch (error) {
      lines.add('启动文件属性读取失败：$error');
    }
    return lines;
  }

  List<UsbDevice> parse(String output, {UsbIpRole? role}) {
    final devices = <UsbDevice>[];
    for (final source in output.split('\n')) {
      final line = source.trim();
      if (line.isEmpty) continue;
      final port = RegExp(r'^Port\s+(\d+)\s*:?\s*(.*)', caseSensitive: false)
          .firstMatch(line);
      if (port != null) {
        final description = port.group(2)!.trim();
        final inUse = RegExp(r'port\s+in\s+use|attached|\bin\s+use\b',
                caseSensitive: false)
            .hasMatch(description);
        devices.add(UsbDevice(
            id: port.group(1)!,
            name: description.isEmpty ? '已连接端口' : description,
            detail: line,
            attached: inUse,
            state: inUse ? '已连接' : '未连接',
            attachedPort: port.group(1)!));
        continue;
      }

      // usbipd-win prints a table such as:
      // 1-2  046d:c52b  USB Input Device  Shared
      final windows = RegExp(
              r'^(\d+-[\d.]+)\s+([0-9a-f]{4}:[0-9a-f]{4})\s+(.+?)\s+(Not shared|Shared(?:\s+\(forced\))?|Attached|Incompatible hub)\s*$',
              caseSensitive: false)
          .firstMatch(line);
      if (windows != null) {
        final state = windows.group(4)!.trim();
        final normalizedState = state.toLowerCase();
        final attached = normalizedState == 'attached';
        final bound = normalizedState == 'shared' ||
            normalizedState == 'shared (forced)' ||
            normalizedState == 'attached';
        devices.add(UsbDevice(
            id: windows.group(1)!,
            name: windows.group(3)!.trim(),
            detail: line,
            bound: bound,
            attached: attached,
            state: state));
        continue;
      }
      // Linux usbip versions commonly print either `2-1 ...` or
      // `- busid 2-1 (...)`; accept both forms.
      final bus = RegExp(
              r'^(?:[-+]\s*)?(?:busid\s+)?(\d+-\d+(?:\.\d+)?)\s*(.*)',
              caseSensitive: false)
          .firstMatch(line);
      if (bus != null && bus.group(1) != '0-0') {
        final name =
            bus.group(2)!.replaceFirst(RegExp(r'^[:()\-\s]+'), '').trim();
        devices.add(UsbDevice(
            id: bus.group(1)!,
            name: name.isEmpty ? 'USB 设备' : name,
            detail: line,
            state: role == UsbIpRole.windowsServer ? '未知' : '未绑定'));
      }
    }
    return devices;
  }

  /// Maps a remote BUSID to the local client port reported by `usbip port`.
  Map<String, String> attachedPorts(String output) {
    final result = <String, String>{};
    String? currentPort;
    bool currentPortInUse = false;

    // `usbip port` places the remote BUSID on a later indented line.  For
    // example:
    //
    //   Port 00: <Port in Use> at High Speed(480Mbps)
    //          1-2 -> usbip://192.168.1.20-1-2 (1-2)
    //
    // Keep the active port while walking the block instead of looking only at
    // the Port header. This also handles clients that print `busid 1-2`.
    for (final source in output.split('\n')) {
      final line = source.trim();
      if (line.isEmpty) continue;
      final port = RegExp(r'^Port\s+(\d+)\s*:?\s*(.*)', caseSensitive: false)
          .firstMatch(line);
      if (port != null) {
        currentPort = port.group(1);
        currentPortInUse = RegExp(r'port\s+in\s+use|attached|\bin\s+use\b',
                caseSensitive: false)
            .hasMatch(port.group(2)!);
        continue;
      }
      if (currentPort == null || !currentPortInUse) continue;

      final bus = _extractBusId(line);
      final portNumber = currentPort;
      if (bus != null) result[bus] = portNumber;
    }
    return result;
  }

  /// Parses the client-side ports into devices that can be shown in the UI.
  ///
  /// A client removes an attached device from `usbip list -r` on many
  /// implementations, so the remote list cannot be the only source of truth
  /// after an attach. Keep the local port number for `detach -p` and use the
  /// remote BUSID when the client output provides one. A port-only fallback is
  /// still useful because it lets the user disconnect an incompletely
  /// described device instead of leaving it stuck in the virtual USB bus.
  List<UsbDevice> parseAttachedPorts(String output) {
    final devices = <UsbDevice>[];
    final block = <String>[];
    String? portNumber;
    bool inUse = false;

    void finishBlock() {
      if (portNumber == null || !inUse || block.isEmpty) return;

      final detail = block.join('\n').trim();
      final remoteBusId = _extractBusIdFromBlock(block);
      final name = _attachedDeviceName(block);
      devices.add(UsbDevice(
        id: remoteBusId ?? 'port-$portNumber',
        name: name,
        detail: detail,
        attached: true,
        state: '已连接',
        attachedPort: portNumber,
        connectionStateKnown: true,
      ));
    }

    for (final source in output.split(RegExp(r'\r?\n'))) {
      final port = RegExp(r'^\s*Port\s+(\d+)\s*:?\s*(.*)', caseSensitive: false)
          .firstMatch(source);
      if (port != null) {
        finishBlock();
        portNumber = port.group(1);
        final header = port.group(2)!.trim();
        inUse = RegExp(r'port\s+in\s+use|attached|\bin\s+use\b',
                caseSensitive: false)
            .hasMatch(header);
        block
          ..clear()
          ..add(source.trimRight());
        continue;
      }
      if (portNumber != null) block.add(source.trimRight());
    }
    finishBlock();
    return devices;
  }

  /// Merges remote exportable devices with local client attachment state.
  ///
  /// [portsOk] is kept explicit so a failed `usbip port` query never turns an
  /// existing connection into a false "not connected" state. When the query
  /// succeeds, attached-only records are appended even if the remote list is
  /// empty after attach.
  List<UsbDevice> mergeClientDevices(
      List<UsbDevice> remoteDevices, String portsOutput,
      {required bool portsOk}) {
    if (!portsOk) {
      return [
        for (final item in remoteDevices)
          item.copyWith(
            attached: false,
            attachedPort: null,
            state: '连接状态未知',
            connectionStateKnown: false,
          ),
      ];
    }

    final attachedDevices = parseAttachedPorts(portsOutput);
    final attachedById = <String, UsbDevice>{
      for (final item in attachedDevices) item.id: item,
    };
    final merged = <UsbDevice>[];
    final seen = <String>{};

    for (final item in remoteDevices) {
      final attached = attachedById[item.id];
      merged.add(item.copyWith(
        attached: attached != null,
        attachedPort: attached?.attachedPort,
        state: attached == null ? '未连接' : '已连接',
        connectionStateKnown: true,
      ));
      seen.add(item.id);
    }

    for (final item in attachedDevices) {
      if (seen.add(item.id)) merged.add(item);
    }
    return merged;
  }

  String? _extractBusIdFromBlock(List<String> block) {
    for (final line in block.skip(1)) {
      final bus = _extractBusId(line.trim());
      if (bus != null) return bus;
    }
    return null;
  }

  String _attachedDeviceName(List<String> block) {
    for (final source in block.skip(1)) {
      final line = source.trim();
      if (line.isEmpty ||
          line.startsWith('->') ||
          line.contains('-> usbip://') ||
          RegExp(r'^(?:remote\s+)?bus/dev\b', caseSensitive: false)
              .hasMatch(line) ||
          RegExp(r'^(?:serial|mode)\s*:', caseSensitive: false)
              .hasMatch(line)) {
        continue;
      }
      return line;
    }
    return '已连接 USB 设备';
  }

  String? _extractBusId(String line) {
    final explicit =
        RegExp(r'\bbusid\s*[:=]?\s*([\d]+-[\d.]+)', caseSensitive: false)
            .firstMatch(line)
            ?.group(1);
    if (explicit != null) return explicit;

    // Current usbip clients commonly print `1-2 -> usbip://... (1-2)`.
    // The URL contains the remote BUSID. The value before `->` is the local
    // USB topology and must not be used for detach. Some versions encode the
    // remote BUSID after the host port instead of after a slash:
    // `usbip://192.168.1.20:3240-1-2`.
    final url =
        RegExp(r'\busbip://[^/\s]+/([\d]+-[\d.]+)', caseSensitive: false)
            .firstMatch(line)
            ?.group(1);
    if (url != null) return url;

    final compactUrl =
        RegExp(r'\busbip://[^\s/]+-(\d+-\d+(?:\.\d+)?)\b', caseSensitive: false)
            .firstMatch(line)
            ?.group(1);
    if (compactUrl != null) return compactUrl;

    final arrow =
        RegExp(r'^(?:[-+]\s*)?([\d]+-[\d.]+)\s*->').firstMatch(line)?.group(1);
    if (arrow != null) return arrow;

    // Older clients omit the arrow but retain the BUSID in parentheses.
    final trailing =
        RegExp(r'\(([\d]+-[\d.]+)\)\s*$').firstMatch(line)?.group(1);
    return trailing;
  }
}
