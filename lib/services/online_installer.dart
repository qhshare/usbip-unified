import 'dart:convert';
import 'dart:io';

import 'offline_installer.dart';
import 'usbip_service.dart';

/// Installs the native USB/IP components.
///
/// Windows uses winget for the server as a first attempt, then falls back to
/// the signed MSI bundled in the portable release. The Windows client always
/// uses the bundled official installer because the client driver and virtual
/// USB device cannot be provided by a plain portable executable.
class OnlineInstaller {
  final UsbIpService _usbIpService = UsbIpService();

  Future<CommandResult> install(
      {required bool server,
      required bool client,
      void Function(String line)? onOutput}) async {
    if (!Platform.isLinux && !Platform.isWindows) {
      return const CommandResult(
          command: 'online installer',
          code: 2,
          output: '在线安装目前仅支持 Linux 和 Windows。');
    }
    if (Platform.isLinux) {
      return _installLinux(server: server, client: client, onOutput: onOutput);
    }
    return _installWindows(server: server, client: client, onOutput: onOutput);
  }

  Future<CommandResult> check(
      {bool? server,
      bool? client,
      String customPath = '',
      String serverPath = '',
      String clientPath = ''}) async {
    final checkServer = server ?? true;
    final checkClient = client ?? true;
    // Keep customPath for callers built against the earlier API. New callers
    // should pass role-specific paths so server and client executables cannot
    // be mixed accidentally.
    final effectiveServerPath = serverPath.trim().isNotEmpty
        ? serverPath
        : (customPath.trim().isNotEmpty ? customPath : '');
    final effectiveClientPath = clientPath.trim().isNotEmpty
        ? clientPath
        : (customPath.trim().isNotEmpty ? customPath : '');
    final found = <String>[];
    final missing = <String>[];
    final notReady = <String>[];
    final warnings = <String>[];
    if (Platform.isWindows) {
      if (checkServer) {
        final executable = await _usbIpService.findExecutable(
            UsbIpRole.windowsServer,
            customPath: effectiveServerPath);
        if (executable != null) {
          final probe = await _usbIpService
              .run(UsbIpRole.windowsServer, ['list'], customPath: executable);
          if (probe.ok) {
            found.add('Windows 共享端：$executable（usbipd list 正常）');
          } else {
            found.add('Windows 共享端文件：$executable');
            warnings.add('usbipd list 执行失败（退出码 ${probe.code}）：'
                '${probe.output.isEmpty ? '无输出' : probe.output}');
            final diagnostics = await _usbIpService.windowsToolDiagnostics(
                UsbIpRole.windowsServer,
                customPath: executable);
            if (diagnostics.isNotEmpty) {
              warnings.add('Windows 工具诊断：${diagnostics.join('；')}');
            }
          }
        } else {
          missing.add('Windows 共享端 usbipd.exe');
          final diagnostics = await _usbIpService.windowsToolDiagnostics(
              UsbIpRole.windowsServer,
              customPath: effectiveServerPath);
          if (diagnostics.isNotEmpty) {
            warnings.add('Windows 工具诊断：${diagnostics.join('；')}');
          }
        }
      }
      if (checkClient) {
        final executable = await _usbIpService.findExecutable(
            UsbIpRole.windowsClient,
            customPath: effectiveClientPath);
        if (executable != null) {
          final compatibility = executable.toLowerCase().endsWith('usbip.exe');
          final probe = await _usbIpService.probeWindowsClient(executable);
          if (probe.started && probe.ok) {
            found.add('Windows 客户端工具可运行：$executable'
                '${compatibility ? '（兼容模式）' : ''}');
          } else if (probe.started) {
            // `usbipw.exe port` can return non-zero when its config file or
            // local virtual port is not initialized yet. The process did
            // start, so this is a warning rather than a missing executable.
            found.add('Windows 客户端工具已启动：$executable'
                '${compatibility ? '（兼容模式）' : ''}');
            warnings.add('Windows 客户端 usbipw.exe port 返回非零（退出码 ${probe.code}），'
                '但进程已成功启动；这通常表示尚未配置远程连接或本机还没有 USB/IP 端口：'
                '${probe.output.isEmpty ? '无输出' : probe.output}');
          } else {
            missing.add('Windows 客户端工具（usbipw.exe 无法启动）');
            warnings.add('Windows 客户端文件已找到，但 usbipw.exe port 启动失败'
                '（退出码 ${probe.code}）：${probe.output.isEmpty ? '无输出' : probe.output}');
            final diagnostics = await _usbIpService.windowsToolDiagnostics(
                UsbIpRole.windowsClient,
                customPath: executable);
            if (diagnostics.isNotEmpty) {
              warnings.add('Windows 客户端诊断：${diagnostics.join('；')}');
            }
          }

          final driver = await _usbIpService.checkWindowsClientDriver();
          if (driver.servicesDetected) {
            found.add('Windows 客户端驱动服务已注册');
          }
          if (driver.virtualDeviceDetected) {
            found.add('Windows 客户端虚拟 USB 设备节点已创建');
          }
          if (driver.missing) {
            if (!driver.servicesDetected) {
              missing.add('Windows 客户端驱动服务');
            }
            if (!driver.virtualDeviceDetected) {
              missing.add('Windows 客户端虚拟 USB 设备节点');
            }
            warnings.add('Windows 客户端驱动链不完整：'
                '${driver.output.isEmpty ? '请以管理员身份重新安装客户端驱动，并在必要时重启 Windows' : driver.output}');
          } else if (driver.pendingRestart) {
            notReady.add('Windows 客户端虚拟 USB 设备节点（待重启/枚举）');
            warnings.add('Windows 客户端驱动服务已经注册，但虚拟 USB 设备节点尚未枚举：'
                '请重启 Windows，或在设备管理器中扫描硬件改动后重新检查。');
          } else if (!driver.available) {
            // A failed CIM/PnP query is not evidence that the driver is
            // missing. Keep the known pieces visible and ask the user to
            // inspect the diagnostic output instead of blocking the tool.
            warnings.add('Windows 客户端驱动状态未知：'
                '${driver.output.isEmpty ? '无法查询驱动服务或虚拟 USB 设备节点' : driver.output}');
          }
        } else {
          missing.add('Windows 客户端 usbipw.exe/usbip.exe/usbip-win2.exe');
          final diagnostics = await _usbIpService.windowsToolDiagnostics(
              UsbIpRole.windowsClient,
              customPath: effectiveClientPath);
          if (diagnostics.isNotEmpty) {
            warnings.add('Windows 工具诊断：${diagnostics.join('；')}');
          }
        }
      }
    } else if (Platform.isLinux) {
      if (await _exists('usbip')) {
        found.add('usbip');
      } else {
        missing.add('usbip');
      }
    }
    return CommandResult(
      command: 'environment check',
      // Warnings describe a started command or an unavailable diagnostic
      // query. Only an explicitly missing required component fails the check.
      code: missing.isEmpty && notReady.isEmpty ? 0 : 1,
      output: [
        if (Platform.isWindows &&
            effectiveServerPath.trim().isNotEmpty &&
            checkServer)
          '共享端工具路径：${effectiveServerPath.trim()}',
        if (Platform.isWindows &&
            effectiveClientPath.trim().isNotEmpty &&
            checkClient)
          '客户端工具路径：${effectiveClientPath.trim()}',
        if (found.isNotEmpty) '已检测到：${found.join(', ')}',
        if (missing.isNotEmpty) '未检测到：${missing.join(', ')}',
        if (notReady.isNotEmpty) '暂未就绪：${notReady.join(', ')}',
        if (Platform.isWindows && missing.isNotEmpty)
          '已检查 PATH、Program Files\\usbipd-win、Program Files\\USBip/usbip-win2 等位置。',
        if (warnings.isNotEmpty) '环境检查警告：${warnings.join('\n')}',
        if (Platform.isWindows && checkClient)
          'Windows 客户端必须同时具备可运行的 usbipw.exe、已注册的驱动服务和已创建的虚拟 USB 设备节点；安装后如节点缺失，请以管理员身份重新安装并按提示重启 Windows。',
      ].join('\n'),
    );
  }

  Future<CommandResult> _installLinux(
      {required bool server,
      required bool client,
      void Function(String line)? onOutput}) async {
    final manager = await _linuxManager();
    if (manager == null) {
      return const CommandResult(
        command: 'online installer',
        code: 2,
        output: '未识别 Linux 包管理器。支持 apt、dnf、pacman、apk；请手动安装 usbip。',
      );
    }
    // Linux distributions generally ship both roles in the same usbip tools.
    final command = manager.executable;
    final args = [...manager.prefix, ...manager.installArgs, 'usbip'];
    return _elevated(command, args, manager.needsElevation, onOutput: onOutput);
  }

  Future<CommandResult> _installWindows(
      {required bool server,
      required bool client,
      void Function(String line)? onOutput}) async {
    if (!server && !client) {
      return const CommandResult(
        command: 'online installer',
        code: 2,
        output: '至少选择 Windows 共享端或客户端组件。',
      );
    }

    if (client) {
      final offlineInstaller = OfflineInstaller();
      final architecture = offlineInstaller.detectArchitecture();
      onOutput?.call('检查 Windows 客户端离线资源：架构=$architecture');
      final missing = await offlineInstaller.missingWindowsClientAssets(
          overrideArchitecture: architecture);
      if (missing.isNotEmpty) {
        final output =
            offlineInstaller.windowsClientBundlePreflightMessage(missing);
        onOutput?.call(output);
        return CommandResult(
          command: 'Windows client bundle preflight',
          code: 2,
          output: output,
        );
      }
      onOutput?.call(
          'Windows 客户端资源检查通过：官方 USBip-0.9.8.0-x64.exe 和 VC++ Runtime 已打包。');
    }

    onOutput?.call(
        'Windows 安装角色：共享端=${server ? '是' : '否'}，客户端=${client ? '是' : '否'}');

    CommandResult? serverResult;
    if (server) {
      if (!await _exists('winget')) {
        onOutput?.call('阶段 1/3：未找到 winget，跳过在线尝试。');
        onOutput?.call('阶段 2/3：改用便携包内的 usbipd-win MSI（本地资源）。');
        serverResult = await _installBundledWindowsServer(onOutput: onOutput);
      } else {
        onOutput?.call('阶段 1/3：在线尝试使用 winget 安装 Windows 共享端。');
        onOutput?.call(
            '在线安装 Windows 共享端：winget install --id dorssel.usbipd-win --source winget');
        final wingetResult = await _elevated(
            'winget',
            [
              'install',
              '--id',
              'dorssel.usbipd-win',
              '--exact',
              // The Microsoft Store source can fail certificate validation on
              // restricted or intercepted networks. usbipd-win is published in
              // the community winget source, so avoid probing msstore at all.
              '--source',
              'winget',
              '--silent',
              '--disable-interactivity',
              '--accept-source-agreements',
              '--accept-package-agreements',
            ],
            false,
            onOutput: onOutput);
        if (wingetResult.ok) {
          serverResult = _addOutput(
            wingetResult,
            'Windows 共享端安装来源：winget 在线安装成功。',
          );
          onOutput?.call('阶段 1/3：winget 在线安装成功。');
        } else {
          // App Installer keeps a local cache for the winget sources. On
          // older Windows 10 installations that cache can fail with
          // 0x8A15000F/0x8A15005E even when the network and package are fine.
          // The portable release already contains the signed usbipd-win MSI,
          // so do not leave the user with a half-installed client/server pair.
          onOutput?.call('阶段 1/3：winget 在线安装失败，退出码 ${wingetResult.code}。');
          onOutput?.call('阶段 2/3：改用便携包内的 usbipd-win MSI（本地资源，不再依赖 winget 源）。');
          final fallback =
              await _installBundledWindowsServer(onOutput: onOutput);
          serverResult = CommandResult(
            command:
                '${wingetResult.command} || bundled usbipd-win MSI installer',
            code: fallback.code,
            started: fallback.started,
            output: [
              'Windows 共享端安装来源：便携包内 usbipd-win MSI 回退安装。',
              'winget 首次尝试：退出码 ${wingetResult.code}',
              if (wingetResult.output.trim().isNotEmpty) wingetResult.output,
              '已执行内置 MSI 回退安装。',
              fallback.output,
            ].join('\n'),
          );
        }
      }
    }

    CommandResult? clientResult;
    if (client) {
      // There is no stable winget package for usbip-win2. The release contains
      // the matching official installer and VC++ runtime, so use the same
      // installer as the explicit offline action. The installer itself owns
      // the client files, signed drivers, service registration, and virtual
      // USB device creation; do not copy usbipw.exe or call pnputil here.
      onOutput?.call('阶段 3/3：使用便携包内官方 USBip-win2 安装器注册客户端、驱动和虚拟 USB 设备。');
      final bundledClientResult = await OfflineInstaller()
          .install(server: false, client: true, onOutput: onOutput);
      clientResult = _addOutput(
        bundledClientResult,
        'Windows 客户端安装来源：便携包内官方 USBip-win2 安装器。',
      );
      onOutput?.call('Windows 客户端实际命令：${clientResult.command}');
    }

    if (!server) {
      onOutput?.call('Windows 共享端未请求，本次不会执行 winget 安装。');
    }
    if (!client) {
      onOutput
          ?.call('Windows 客户端未请求，本次不会执行 install-windows-offline.ps1 -Client。');
    }

    return combineWindowsRoleResults(
        server: server,
        client: client,
        serverResult: serverResult,
        clientResult: clientResult);
  }

  CommandResult _addOutput(CommandResult result, String line) {
    return CommandResult(
      command: result.command,
      code: result.code,
      started: result.started,
      output:
          [line, if (result.output.trim().isNotEmpty) result.output].join('\n'),
    );
  }

  Future<CommandResult> _installBundledWindowsServer(
      {void Function(String line)? onOutput}) async {
    onOutput?.call('正在使用便携包内的 usbipd-win MSI 安装 Windows 共享端。');
    final result = await OfflineInstaller()
        .install(server: true, client: false, onOutput: onOutput);
    onOutput?.call('Windows 共享端 MSI 回退命令：${result.command}');
    return result;
  }

  /// Combines the two independent Windows role installations into one result.
  ///
  /// The offline client script can return process exit code 0 while reporting
  /// `INSTALL_STATUS|partial` (for example, the driver service exists but the
  /// virtual device still needs a reboot). Treat that as an unsuccessful
  /// client installation so the UI does not claim that the complete request
  /// succeeded merely because winget succeeded.
  CommandResult combineWindowsRoleResults({
    required bool server,
    required bool client,
    CommandResult? serverResult,
    CommandResult? clientResult,
  }) {
    final sections = <String>[];
    if (server && serverResult != null) {
      sections.add(_resultSection('Windows 共享端', serverResult));
    }
    if (client && clientResult != null) {
      sections.add(_resultSection('Windows 客户端', clientResult));
    }

    final failedCodes = <int>[
      if (serverResult != null && !serverResult.ok) serverResult.code,
      if (clientResult != null &&
          (!_clientInstallSucceeded(clientResult) || !clientResult.ok))
        clientResult.code == 0 ? 1 : clientResult.code,
    ];
    final code = failedCodes.isEmpty ? 0 : failedCodes.first;
    final clientStatus = clientResult == null
        ? null
        : WindowsOfflineInstallStatus.parse(clientResult.output);
    final clientInstalled = clientResult != null &&
        clientResult.ok &&
        _clientInstallSucceeded(clientResult);
    final clientStatusValue = clientStatus?.hasStructuredStatus == true
        ? clientStatus!.clientStatus
        : (clientInstalled ? 'installed' : 'failed');
    final driverStatusValue = clientStatus?.hasStructuredStatus == true
        ? clientStatus!.clientDriverStatus
        : (clientInstalled ? 'available' : 'unknown');
    final deviceStatusValue = clientStatus?.hasStructuredStatus == true
        ? clientStatus!.clientDeviceStatus
        : (clientInstalled ? 'available' : 'unknown');
    final overallStatus = code == 0
        ? 'success'
        : (clientStatus?.partial == true ||
                clientStatus?.restartRequired == true
            ? 'partial'
            : 'failed');
    return CommandResult(
      command: sections.map((_) => 'Windows role installation').join(' + '),
      code: code,
      // Append one normalized marker block after both role sections. The
      // client-only PowerShell invocation legitimately reports
      // SERVER_STATUS|not_requested; without this final block that marker
      // would overwrite a successful winget/MSI server result when the GUI
      // parses the combined log.
      output: [
        ...sections,
        '=== Windows role installation summary ===',
        'SERVER_STATUS|${server ? (serverResult?.ok == true ? 'installed' : 'failed') : 'not_requested'}',
        if (client) 'CLIENT_STATUS|$clientStatusValue',
        if (client) 'CLIENT_DRIVER_STATUS|$driverStatusValue',
        if (client) 'CLIENT_DEVICE_STATUS|$deviceStatusValue',
        'INSTALL_STATUS|$overallStatus',
        'RESTART_REQUIRED|${clientStatus?.restartRequired == true}',
      ].join('\n'),
      started:
          (serverResult?.started ?? true) && (clientResult?.started ?? true),
    );
  }

  String _resultSection(String title, CommandResult result) {
    final body = result.output.trim();
    return [
      '[$title] 退出码：${result.code}',
      '[$title] 实际命令：${result.command}',
      if (body.isNotEmpty) body,
    ].join('\n');
  }

  bool _clientInstallSucceeded(CommandResult result) {
    final status = WindowsOfflineInstallStatus.parse(result.output);
    // A client installation is not complete unless the current installer
    // reported all verification markers. Older bundles only copied or ran a
    // server installer and returned exit code 0, which must not be accepted
    // as a successful complete installation.
    return status.hasStructuredStatus && status.success;
  }

  Future<_LinuxManager?> _linuxManager() async {
    if (await _exists('apt-get')) {
      // Fail fast when another apt/dpkg operation owns the lock. Waiting for
      // an unknown amount of time makes the UI look frozen.
      return const _LinuxManager(
          'apt-get', ['-y', '-o', 'DPkg::Lock::Timeout=0'], ['install'], true);
    }
    if (await _exists('dnf')) {
      return const _LinuxManager('dnf', [], ['install', '-y'], true);
    }
    if (await _exists('pacman')) {
      return const _LinuxManager('pacman', [], ['-S', '--noconfirm'], true);
    }
    if (await _exists('apk')) {
      return const _LinuxManager('apk', [], ['add'], true);
    }
    return null;
  }

  Future<CommandResult> _elevated(
      String executable, List<String> args, bool needsElevation,
      {void Function(String line)? onOutput}) async {
    if (!needsElevation || await _isRoot()) {
      return _run(executable, args, onOutput: onOutput);
    }
    if (await _exists('pkexec')) {
      return _run('pkexec', [executable, ...args], onOutput: onOutput);
    }
    if (await _exists('sudo')) {
      return _run('sudo', [executable, ...args], onOutput: onOutput);
    }
    return const CommandResult(
        command: 'privilege elevation',
        code: 127,
        output: '未找到 pkexec 或 sudo，请在管理员终端手动安装。');
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

  Future<bool> _exists(String command) async =>
      (await _resolveCommand(command)) != null;

  Future<String?> _resolveCommand(String command) async {
    if (command.trim().isEmpty) return null;
    try {
      final result = await Process.run(Platform.isWindows ? 'where.exe' : 'sh',
          Platform.isWindows ? [command] : ['-c', 'command -v "$command"']);
      if (result.exitCode != 0) return null;
      final first = result.stdout
          .toString()
          .split(RegExp(r'[\r\n]+'))
          .map((line) => line.trim())
          .firstWhere((line) => line.isNotEmpty, orElse: () => '');
      return first.isEmpty ? command : first;
    } catch (_) {
      return null;
    }
  }

  Future<CommandResult> _run(String executable, List<String> args,
      {void Function(String line)? onOutput}) async {
    final command = ([executable, ...args]).join(' ');
    final isWinget = _isWingetCommand(executable);
    try {
      final environment = <String, String>{
        ...Platform.environment,
        if (isWinget) 'NO_COLOR': '1',
      };
      final process =
          await Process.start(executable, args, environment: environment);
      final output = StringBuffer();
      Future<void> collect(Stream<List<int>> stream) async {
        // winget writes UTF-8 when its output is redirected to a pipe. Keep
        // malformed bytes readable, but never stream its terminal progress
        // renderer directly into the Flutter log.
        await for (final line in stream
            .transform(const Utf8Decoder(allowMalformed: true))
            .transform(const LineSplitter())) {
          final cleaned = _cleanOutputLine(line);
          if (cleaned.isEmpty || (isWinget && _isWingetProgress(cleaned))) {
            continue;
          }
          output.writeln(cleaned);
          // winget's download renderer can still contain box-drawing or
          // mojibake characters even with --silent and NO_COLOR. Show its
          // final cleaned result after the process exits instead of forwarding
          // those transient lines while it is running.
          if (!isWinget) onOutput?.call(cleaned);
        }
      }

      final stdoutDone = collect(process.stdout);
      final stderrDone = collect(process.stderr);
      var timedOut = false;
      final code = await process.exitCode.timeout(const Duration(minutes: 15),
          onTimeout: () {
        timedOut = true;
        process.kill(ProcessSignal.sigterm);
        return 124;
      });
      // A package manager can leave a child process alive after its parent is
      // terminated. Do not keep the Flutter UI waiting forever for inherited
      // stdout/stderr handles in that case.
      await Future.wait([stdoutDone, stderrDone]).timeout(
        timedOut ? const Duration(seconds: 5) : const Duration(seconds: 30),
        onTimeout: () => <void>[],
      );
      return CommandResult(
          command: command, code: code, output: output.toString().trim());
    } on ProcessException catch (error) {
      return CommandResult(
          command: command, code: 127, output: '无法执行在线安装命令：${error.message}');
    } catch (error) {
      return CommandResult(command: command, code: 1, output: '在线安装失败：$error');
    }
  }

  bool _isWingetCommand(String executable) {
    final normalized = executable.replaceAll('\\', '/').toLowerCase();
    return normalized == 'winget' || normalized.endsWith('/winget.exe');
  }

  String _cleanOutputLine(String line) {
    // Package managers may emit cursor movement and color control sequences
    // when their output is redirected to the Flutter process.
    return line
        .replaceAll(RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]'), '')
        .replaceAll('\r', '')
        .trim();
  }

  bool _isWingetProgress(String line) {
    if (RegExp(r'^[-\\|/]+$').hasMatch(line)) return true;
    if (RegExp(
            r'\b\d+(?:\.\d+)?\s*(?:KB|MB|GB)\s*/\s*'
            r'\d+(?:\.\d+)?\s*(?:KB|MB|GB)\b',
            caseSensitive: false)
        .hasMatch(line)) {
      return true;
    }
    return RegExp(r'\b\d{1,3}%$').hasMatch(line);
  }
}

class _LinuxManager {
  const _LinuxManager(
      this.executable, this.prefix, this.installArgs, this.needsElevation);
  final String executable;
  final List<String> prefix;
  final List<String> installArgs;
  final bool needsElevation;
}
