import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'services/usbip_service.dart';
import 'services/offline_installer.dart';
import 'services/online_installer.dart';
import 'services/app_settings.dart';

const appBuild = '0.1.0+20261010.17';

class _InstallRoles {
  const _InstallRoles({required this.server, required this.client});

  final bool server;
  final bool client;
}

void main() => runApp(const UsbIpApp());

class UsbIpApp extends StatelessWidget {
  const UsbIpApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'USBIP Unified Manager $appBuild',
        theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
                seedColor: const Color(0xff1769aa),
                brightness: Brightness.light),
            useMaterial3: true),
        darkTheme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
                seedColor: const Color(0xff71b7e6),
                brightness: Brightness.dark),
            useMaterial3: true),
        themeMode: ThemeMode.system,
        home: const ManagerPage(),
      );
}

class ManagerPage extends StatefulWidget {
  const ManagerPage({super.key, this.autoRefresh = true});
  final bool autoRefresh;
  @override
  State<ManagerPage> createState() => _ManagerPageState();
}

class _ManagerPageState extends State<ManagerPage> {
  final service = UsbIpService();
  final offlineInstaller = OfflineInstaller();
  final onlineInstaller = OnlineInstaller();
  final settingsStore = AppSettingsStore();
  final remoteHost = TextEditingController();
  // Windows uses different executables for the two directions. Keep these
  // paths independent when the user switches roles in one session.
  final serverToolPath = TextEditingController();
  final clientToolPath = TextEditingController();
  final serverPort = TextEditingController(text: '3240');
  final clientPort = TextEditingController(text: '3240');
  UsbIpRole role =
      Platform.isWindows ? UsbIpRole.windowsServer : UsbIpRole.linuxServer;
  List<UsbDevice> devices = [];
  UsbDevice? selected;
  List<String> logs = [];
  List<String> localAddresses = [];
  OfflineTargetInfo? offlineTarget;
  bool busy = false;
  int tab = 0;
  Timer? _settingsSaveTimer;

  String get roleName => switch (role) {
        UsbIpRole.linux => 'Linux 原生 USB/IP',
        UsbIpRole.linuxServer => 'Linux 共享端',
        UsbIpRole.linuxClient => 'Linux 客户端',
        UsbIpRole.windowsServer => 'Windows 共享端',
        UsbIpRole.windowsClient => 'Windows 客户端'
      };
  String get roleDescription => switch (role) {
        UsbIpRole.linux => '兼容模式：根据是否填写远程主机决定本地共享或远程连接。',
        UsbIpRole.linuxServer => '列出本机 USB 设备，并通过 Linux usbipd 导出给其他设备。',
        UsbIpRole.linuxClient => '列出远程服务端设备，并将选中的设备连接到本机。',
        UsbIpRole.windowsServer => '通过 usbipd-win 将本机 USB 设备共享给网络客户端。',
        UsbIpRole.windowsClient => '通过 usbip-win2 将远程 USB/IP 设备连接到本机。',
      };
  bool get isClient => service.isClient(role);
  bool get isServer => service.isServer(role);
  TextEditingController get activeToolPathController =>
      isClient ? clientToolPath : serverToolPath;
  String get activeToolPath => activeToolPathController.text;
  int get sharePort => int.tryParse(serverPort.text.trim()) ?? 0;
  int get remotePort => int.tryParse(clientPort.text.trim()) ?? 0;
  int get effectiveSharePort => Platform.isWindows ? 3240 : sharePort;
  List<UsbIpRole> get availableRoles => Platform.isWindows
      ? const [UsbIpRole.windowsServer, UsbIpRole.windowsClient]
      : const [UsbIpRole.linuxServer, UsbIpRole.linuxClient];
  String get shareAddress {
    if (isClient) {
      final host = remoteHost.text.trim();
      if (host.isEmpty) return '未设置远程服务端';
      return '${_formatHost(host)}:$remotePort';
    }
    if (localAddresses.isEmpty) return '未检测到局域网地址';
    return localAddresses
        .map((address) => '$address:$effectiveSharePort')
        .join('\n');
  }

  String _formatHost(String host) =>
      host.contains(':') && !host.startsWith('[') ? '[$host]' : host;

  bool get canCopyAddress => isServer
      ? localAddresses.isNotEmpty
      : remoteHost.text.trim().isNotEmpty &&
          remotePort >= (Platform.isWindows ? 1024 : 1) &&
          remotePort <= 65535;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      log('应用版本：$appBuild');
      await _loadSettings();
      final runtime = await offlineInstaller.runtimeDiagnostics();
      for (final line in runtime) {
        log(line);
      }
      if (offlineInstaller.runtimePlatformMismatch() != null) {
        log('已停止自动刷新：当前便携包的 Dart 前端与宿主系统不匹配。'
            '请删除旧解压目录，并使用原生 Windows + Visual Studio 重新构建的最新 ZIP。');
        return;
      }
      await refreshLocalAddresses();
      await inspectOfflineTarget();
      if (widget.autoRefresh) await refresh();
    });
  }

  @override
  void dispose() {
    _settingsSaveTimer?.cancel();
    remoteHost.dispose();
    serverToolPath.dispose();
    clientToolPath.dispose();
    serverPort.dispose();
    clientPort.dispose();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    final settings = await settingsStore.load();
    if (!mounted) return;
    serverToolPath.text = settings.serverToolPath;
    clientToolPath.text = settings.clientToolPath;
    remoteHost.text = settings.remoteHost;
    if (settings.serverPort.trim().isNotEmpty) {
      serverPort.text = settings.serverPort;
    }
    if (settings.clientPort.trim().isNotEmpty) {
      clientPort.text = settings.clientPort;
    }
    final configured = <String>[
      if (settings.serverToolPath.isNotEmpty) '共享端路径已加载',
      if (settings.clientToolPath.isNotEmpty) '客户端路径已加载',
    ];
    log(configured.isEmpty
        ? '未找到本地工具路径配置，将执行自动探测。'
        : '已加载本地配置：${configured.join('、')}');
  }

  void _scheduleSaveSettings() {
    _settingsSaveTimer?.cancel();
    _settingsSaveTimer = Timer(const Duration(milliseconds: 400), () {
      _saveSettings();
    });
  }

  Future<void> _saveSettings() async {
    try {
      await settingsStore.save(AppSettings(
        serverToolPath: serverToolPath.text.trim(),
        clientToolPath: clientToolPath.text.trim(),
        remoteHost: remoteHost.text.trim(),
        serverPort: serverPort.text.trim(),
        clientPort: clientPort.text.trim(),
      ));
    } catch (error) {
      if (mounted) log('本地配置保存失败：$error');
    }
  }

  void log(String value) {
    if (!mounted) return;
    setState(() {
      logs = [
        ...logs,
        '[${DateTime.now().toLocal().toString().substring(11, 19)}] $value'
      ];
    });
  }

  Future<void> _changeRole(UsbIpRole? next) async {
    if (next == null || next == role || busy) return;
    setState(() {
      role = next;
      devices = [];
      selected = null;
      if (next == UsbIpRole.windowsServer) serverPort.text = '3240';
    });
    log('已切换运行角色：$roleName');
    await refresh();
  }

  Future<void> refreshLocalAddresses() async {
    try {
      final interfaces = await NetworkInterface.list(
          type: InternetAddressType.IPv4, includeLoopback: false);
      final addresses = <String>{};
      for (final networkInterface in interfaces) {
        for (final address in networkInterface.addresses) {
          if (!address.isLoopback && address.address != '0.0.0.0') {
            addresses.add(address.address);
          }
        }
      }
      if (mounted) setState(() => localAddresses = addresses.toList()..sort());
    } catch (_) {
      if (mounted) setState(() => localAddresses = []);
    }
  }

  Future<void> inspectOfflineTarget() async {
    final target = offlineInstaller.inspectTarget();
    if (mounted) setState(() => offlineTarget = target);
  }

  Future<void> refresh() async {
    if (busy) return;
    setState(() => busy = true);
    log('正在刷新 $roleName ...');
    try {
      await _saveSettings();
      await refreshLocalAddresses();
      final host = isClient ? remoteHost.text.trim() : '';
      final requestedToolPath = activeToolPath.trim();
      final defaultTool = service.executable(role, '');
      log('当前运行角色：$roleName');
      log('当前需要的工具：$defaultTool');
      log('已保存的工具路径：${requestedToolPath.isEmpty ? '未设置（自动探测）' : requestedToolPath}');
      final detectedTool =
          await service.findExecutable(role, customPath: activeToolPath);
      if (detectedTool == null) {
        log('工具探测失败：未找到 $roleName 可执行文件。请查看下方命令输出中的已检查路径。');
        if (Platform.isWindows) {
          final diagnostics = await service.windowsToolDiagnostics(role,
              customPath: activeToolPath);
          for (final line in diagnostics) {
            log(line);
          }
        }
      } else {
        log('工具探测成功：$detectedTool');
        if (requestedToolPath.isNotEmpty &&
            !_sameExecutablePath(requestedToolPath, detectedTool)) {
          activeToolPathController.text = detectedTool;
          await _saveSettings();
          log('已将失效的旧工具路径替换为自动探测到的路径：$detectedTool');
        }
      }
      // Use the path returned by discovery for every command in this refresh.
      // Otherwise a stale saved path could pass the probe but still be sent
      // to list()/port() and make the UI report a false tool failure.
      final toolPathForCommand = detectedTool ?? activeToolPath;
      log('本次刷新最终使用的工具路径：${toolPathForCommand.trim().isEmpty ? '未解析，将由执行器再次探测' : toolPathForCommand}');
      final result = await service.list(role, host,
          remotePort: remotePort, customPath: toolPathForCommand);
      if (Platform.isWindows && detectedTool != null && result.code == 127) {
        log('工具文件已找到，但启动失败；开始输出 Windows 诊断信息。');
        final diagnostics = await service.windowsToolDiagnostics(role,
            customPath: toolPathForCommand);
        for (final line in diagnostics) {
          log(line);
        }
      }
      CommandResult? ports;
      if (isClient && result.ok) {
        ports = await service.listPorts(role, customPath: toolPathForCommand);
      }
      if (!mounted) return;

      var parsed = service.parse(result.output, role: role);
      if (isClient && ports != null) {
        parsed =
            service.mergeClientDevices(parsed, ports.output, portsOk: ports.ok);
        log('\$ ${ports.command}');
        if (ports.output.isNotEmpty) log('命令输出：${ports.output}');
        if (!ports.ok) {
          log('客户端端口查询失败：${ports.output}');
          log('为避免误操作，连接和断开按钮已禁用；请修复工具/权限后重新刷新。');
        }
      } else if (isServer && service.isLinux(role)) {
        parsed = [
          for (final item in parsed)
            _withLinuxBoundState(
                item,
                await service.isBound(role, item.id,
                    customPath: toolPathForCommand))
        ];
      }
      setState(() {
        devices = parsed;
        selected = null;
      });
      log('\$ ${result.command}');
      if (result.output.isNotEmpty) log('命令输出：${result.output}');
      log(result.ok ? '刷新完成，发现 ${parsed.length} 项' : '刷新失败：${result.output}');
    } catch (error) {
      if (mounted) {
        log('刷新异常：$error');
        _message('刷新失败', '$error');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  UsbDevice _withLinuxBoundState(UsbDevice item, bool bound) =>
      item.copyWith(bound: bound, state: bound ? '已共享' : '未共享');

  bool _sameExecutablePath(String first, String second) {
    String normalize(String value) =>
        value.trim().replaceAll('\\', '/').replaceAll(RegExp(r'/+'), '/');
    final left = normalize(first);
    final right = normalize(second);
    return Platform.isWindows
        ? left.toLowerCase() == right.toLowerCase()
        : left == right;
  }

  Future<void> execute(
      String name, Future<CommandResult> Function() task) async {
    if (busy) return;
    setState(() => busy = true);
    log('$name 执行中...');
    try {
      final result = await task();
      if (!mounted) return;
      log('\$ ${result.command}');
      log(result.output.isEmpty ? (result.ok ? '完成' : '无输出') : result.output);
      if (!result.ok) _message('$name失败', result.output);
    } catch (error) {
      if (mounted) {
        log('$name异常：$error');
        _message('$name失败', '$error');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
    if (mounted) await refresh();
  }

  Future<CommandResult> _shareWithLogs(UsbDevice item) {
    return service.share(
      role,
      item.id,
      customPath: activeToolPath,
      port: effectiveSharePort,
      onStep: (step) {
        if (mounted) log(step);
      },
    );
  }

  Future<CommandResult> _unbindWithLogs(UsbDevice item) async {
    if (!isServer) {
      log('跳过解绑：当前是客户端模式。');
      return const CommandResult(
          command: 'usbip unbind (skipped)', code: 2, output: '客户端模式不能解绑设备。');
    }
    if (!item.bound) {
      log('跳过解绑：BUSID=${item.id} 当前未共享。');
      return const CommandResult(
          command: 'usbip unbind (skipped)', code: 2, output: '设备当前未共享，未执行解绑。');
    }
    if (item.attached) {
      log('跳过解绑：BUSID=${item.id} 当前有客户端连接，请先断开客户端。');
      return const CommandResult(
          command: 'usbip unbind (skipped)',
          code: 2,
          output: '设备当前有客户端连接，请先断开客户端。');
    }
    log('准备解绑设备：BUSID=${item.id}');
    final result =
        await service.unbind(role, item.id, customPath: activeToolPath);
    log('命令完成：${result.command}（退出码 ${result.code}）');
    if (result.output.isNotEmpty) log('命令输出：${result.output}');
    log(result.ok ? '解绑操作完成，设备不再由 USB/IP 导出。' : '解绑失败，设备仍可能处于共享状态。');
    return result;
  }

  Future<CommandResult> _detachWithLogs(UsbDevice item) async {
    final port = item.attachedPort;
    if (port == null || port.isEmpty) {
      log('跳过断开：BUSID=${item.id} 没有可用的本机 USB/IP 端口。');
      return const CommandResult(
          command: 'usbip detach (skipped)',
          code: 2,
          output: '未找到本机 USB/IP 端口。请先刷新客户端连接状态。');
    }
    log('准备断开：BUSID=${item.id}，本机端口=$port');
    final result = await service.detach(role, port, customPath: activeToolPath);
    log('命令完成：${result.command}（退出码 ${result.code}）');
    if (result.output.isNotEmpty) log('命令输出：${result.output}');
    log(result.ok ? '断开操作完成，设备已从本机卸载。' : '断开失败，设备可能仍处于连接状态。');
    return result;
  }

  Future<void> installOffline() async {
    if (busy) return;
    final roles = await _selectInstallRoles('离线安装');
    if (roles == null) return;
    final server = roles.server;
    final client = roles.client;
    setState(() => busy = true);
    log('正在执行离线组件安装（${_installRolesLabel(roles)}）...');
    log('离线安装角色：共享端=${server ? '是' : '否'}，客户端=${client ? '是' : '否'}');
    try {
      final result =
          await offlineInstaller.install(server: server, client: client);
      if (!mounted) return;
      log(result.output.isEmpty ? result.command : result.output);
      if (!result.ok) {
        _message(result.code == 3 ? '包管理器正在使用' : '离线安装失败', result.output);
      } else {
        var message = '底层组件安装完成。';
        if (Platform.isWindows) {
          final installStatus =
              WindowsOfflineInstallStatus.parse(result.output);
          log('安装结果文件：${_installerResultLine(result.output)}');
          log('安装状态：${installStatus.hasStructuredStatus ? installStatus.installStatus : '旧版安装脚本未返回结构化状态'}');
          log('安装角色状态：${installStatus.summary(serverRequested: server, clientRequested: client)}');
          final installedTools = InstalledToolPaths.parse(result.output);
          // The installer has verified these paths after UAC/MSI completes.
          // Always replace a stale persisted path: retaining it makes the
          // next refresh ignore the executable that was just installed.
          if (installedTools.server != null) {
            serverToolPath.text = installedTools.server!;
            log('安装器已确认 Windows 共享端路径：${installedTools.server}');
          }
          if (installedTools.client != null) {
            clientToolPath.text = installedTools.client!;
            log('安装器已确认 Windows 客户端路径：${installedTools.client}');
          }
          if (server && installedTools.server == null) {
            log('安装器没有确认 Windows 共享端可执行文件路径，请查看完整安装日志。');
          }
          if (client && installedTools.client == null) {
            log('安装器没有确认 Windows 客户端可执行文件路径，请查看完整安装日志。');
          }
          await _saveSettings();
          // An MSI can update PATH while this Flutter process keeps its old
          // environment. Check the installed locations immediately and show
          // an actionable result before the automatic refresh.
          final check = await onlineInstaller.check(
              server: server,
              client: client,
              serverPath: serverToolPath.text,
              clientPath: clientToolPath.text);
          log('安装后环境检查：${check.output}');
          final statusPrefix = installStatus.restartRequired
              ? '安装文件已完成，但 Windows 要求重启后才能枚举客户端虚拟 USB 设备。'
              : installStatus.partial
                  ? '安装文件已写入，但所选组件尚未全部就绪。'
                  : installStatus.failed
                      ? '安装脚本报告失败。'
                      : '';
          if (check.ok &&
              installStatus.success &&
              !installStatus.restartRequired) {
            message = '底层组件安装完成，已检测到可用组件。\n${check.output}';
          } else {
            message = [
              if (statusPrefix.isNotEmpty) statusPrefix,
              if (!installStatus.hasStructuredStatus)
                '当前安装脚本没有返回结构化状态，可能仍在运行旧版 Release。',
              '安装状态：${installStatus.summary(serverRequested: server, clientRequested: client)}',
              '安装后环境检查：${check.output}',
              if (installStatus.restartRequired)
                '请重启 Windows，然后重新启动完整的新 Release 并点击“检查环境”。',
              if (client && installStatus.clientDeviceStatus != 'available')
                '客户端必须同时具备 usbipw.exe、驱动服务和虚拟 USB 设备节点；只安装 -Server 不会提供客户端。',
              '若仍然失败，请完全关闭旧版便携包，解压并运行重新构建的完整目录；也可以在“工具路径”中填写实际 exe 的完整路径。',
            ].join('\n');
          }
        } else {
          message = '底层组件安装完成。重新点击刷新设备即可检查状态。';
        }
        _message('离线安装完成', message);
      }
    } catch (error) {
      if (mounted) {
        log('离线安装异常：$error');
        _message('离线安装失败', '$error');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
    if (mounted) await refresh();
  }

  String _installerResultLine(String output) {
    final match = RegExp(r'^Installer result file path:\s*(.+)$',
            multiLine: true, caseSensitive: false)
        .firstMatch(output);
    return match?.group(1)?.trim() ?? '未返回';
  }

  void showManualInstallGuide() {
    _message('手动安装指引', offlineInstaller.manualInstallGuide());
  }

  Future<void> checkEnvironment() async {
    if (busy) return;
    setState(() => busy = true);
    try {
      final result = await onlineInstaller.check(
          server: isServer,
          client: isClient,
          serverPath: serverToolPath.text,
          clientPath: clientToolPath.text);
      if (!mounted) return;
      log(result.output);
      _message(result.ok ? '环境检查完成' : '未检测到组件', result.output);
    } catch (error) {
      if (mounted) {
        log('环境检查异常：$error');
        _message('环境检查失败', '$error');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> installOnline() async {
    if (busy) return;
    // Windows online setup is intentionally complete. The server package and
    // the bundled usbip-win2 client are separate installers; allowing this
    // entry point to install only the server is how a portable package can
    // appear to succeed while usbipw.exe and its driver are still absent.
    final roles = Platform.isWindows
        ? const _InstallRoles(server: true, client: true)
        : await _selectInstallRoles('自动安装组件');
    if (roles == null) return;
    final server = roles.server;
    final client = roles.client;
    setState(() => busy = true);
    log('正在自动安装系统组件（${_installRolesLabel(roles)}）...');
    log('安装角色：共享端=${server ? '是' : '否'}，客户端=${client ? '是' : '否'}');
    if (Platform.isWindows) {
      log('Windows 自动安装固定执行完整安装，不提供仅共享端模式。');
      log('本次必须执行：共享端 usbipd-win + 客户端 usbipw.exe + 客户端驱动。');
      log('说明：Flutter 应用本身是免安装便携版；本次操作会向 Windows 注册 USB/IP 服务、驱动和虚拟 USB 设备。');
    }
    var streamedOutput = false;
    try {
      if (Platform.isWindows) {
        log('正在检查 winget；Windows 服务端优先尝试在线安装，失败后自动使用包内 MSI。');
        log('Windows 安装来源策略：服务端=winget，失败时=便携包内 usbipd-win MSI；客户端=便携包内官方 USBip-win2 安装器。');
        log('Windows 共享端安装请求：${server ? '是' : '否'}');
        log('Windows 客户端安装请求：${client ? '是' : '否'}');
        if (client) {
          log('Windows 客户端没有统一的 winget 安装包，将使用应用内客户端资源安装。');
        } else {
          log('winget 将以静默、非交互方式运行；如果出现 UAC，请在系统提示中确认。');
        }
      } else {
        log('正在检测 Linux 包管理器并安装 usbip...');
      }
      final result = await onlineInstaller.install(
          server: server,
          client: client,
          onOutput: (line) {
            if (mounted && line.trim().isNotEmpty) {
              streamedOutput = true;
              log(line);
            }
          });
      if (!mounted) return;
      // Keep streamed output responsive, then print the merged final result
      // as well. The final result contains the elevated PowerShell output and
      // the structured client/driver/device status that may not be visible in
      // the parent process stream.
      if (streamedOutput) {
        log('自动安装最终汇总：');
      }
      log(result.output.isEmpty ? result.command : result.output);
      if (Platform.isWindows) {
        log('Windows 安装来源确认：服务端已按 winget -> 包内 MSI 回退策略执行；客户端使用包内官方 USBip-win2 安装器。');
        final installedTools = InstalledToolPaths.parse(result.output);
        final installStatus = WindowsOfflineInstallStatus.parse(result.output);
        if (installedTools.server != null) {
          serverToolPath.text = installedTools.server!;
          log('安装器已确认 Windows 共享端路径：${installedTools.server}');
        }
        if (installedTools.client != null) {
          clientToolPath.text = installedTools.client!;
          log('安装器已确认 Windows 客户端路径：${installedTools.client}');
        }
        log('安装角色状态：${installStatus.summary(serverRequested: server, clientRequested: client)}');
        if (client && !installStatus.hasStructuredStatus) {
          log('客户端安装没有返回结构化状态；当前运行的可能是旧版 Release，无法确认驱动和虚拟 USB 设备。');
        }
        await _saveSettings();
      }
      final check = await onlineInstaller.check(
          server: server,
          client: client,
          serverPath: serverToolPath.text,
          clientPath: clientToolPath.text);
      log('安装后环境检查：${check.output}');
      if (!result.ok || !check.ok) {
        _message(
            '自动安装需要重新检查',
            '安装命令退出码：${result.code}\n'
                '${result.output.isEmpty ? result.command : result.output}\n'
                '安装后环境检查：${check.output}\n'
                '${client ? '本次包含 Windows 客户端安装；客户端必须同时具备 usbipw.exe、驱动服务和虚拟 USB 设备节点。\n' : ''}'
                '请根据日志补齐失败的角色；Windows 客户端如缺少驱动服务或虚拟 USB 设备，请以管理员身份重试并按提示重启。');
      } else {
        _message('组件安装完成', 'USB/IP 系统组件安装完成，已检测到可用工具。应用本身无需安装，重新点击刷新设备即可使用。');
      }
    } catch (error) {
      if (mounted) {
        log('在线安装异常：$error');
        _message('自动安装组件失败', '$error');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  String _installRolesLabel(_InstallRoles roles) {
    if (roles.server && roles.client) return 'Windows 服务端 + 客户端';
    if (roles.server) return '共享端';
    if (roles.client) return '客户端';
    return '未选择角色';
  }

  Future<_InstallRoles?> _selectInstallRoles(String actionName) async {
    if (!Platform.isWindows) {
      return _InstallRoles(server: isServer, client: isClient);
    }

    final selected = await showDialog<_InstallRoles>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('$actionName范围'),
        content: const Text('Windows 共享端和客户端是两套独立组件。\n\n'
            '完整功能需要同时安装两者：共享端优先通过 winget 安装，失败时使用应用内 MSI；客户端使用应用内资源安装，'
            '包括 usbipw.exe、驱动服务和虚拟 USB 设备节点。\n\n'
            '仅安装共享端不会安装 Windows 客户端。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext,
                const _InstallRoles(server: true, client: false)),
            child: const Text('仅共享端'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext,
                const _InstallRoles(server: false, client: true)),
            child: const Text('仅客户端'),
          ),
          FilledButton(
            autofocus: true,
            onPressed: () => Navigator.pop(
                dialogContext, const _InstallRoles(server: true, client: true)),
            child: const Text('完整安装（推荐）'),
          ),
        ],
      ),
    );
    return selected;
  }

  void _message(String title, String body) => showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
              title: Text(title),
              content: SelectableText(body),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('关闭'))
              ]));
  void action(String type) {
    final item = selected;
    if (item == null) {
      _message('未选择设备', '请先从设备列表选择一项。');
      return;
    }
    if (type == 'attach' && remoteHost.text.trim().isEmpty) {
      _message('缺少远程主机', '客户端模式需要填写远程主机 IP 或主机名。');
      return;
    }
    if (type == 'bind' && (!isServer || item.bound)) {
      _message('设备已共享', '当前设备已经处于共享状态，不能重复绑定。');
      return;
    }
    if (type == 'unbind' && (!isServer || !item.bound)) {
      _message('设备未共享', '当前设备没有处于共享状态，未执行解绑。');
      return;
    }
    if ((type == 'attach' || type == 'detach') && !item.connectionStateKnown) {
      _message('连接状态未知', '无法确认本机 USB/IP 端口状态，请修复权限或工具后重新刷新。');
      return;
    }
    if (type == 'detach' && (!isClient || !item.attached)) {
      _message('设备未连接', '当前设备没有检测到本机 USB/IP 连接。请先刷新状态。');
      return;
    }
    switch (type) {
      case 'bind':
        execute('绑定/共享', () => _shareWithLogs(item));
        break;
      case 'unbind':
        execute('解绑', () => _unbindWithLogs(item));
        break;
      case 'attach':
        execute(
            '连接',
            () => service.attach(role, remoteHost.text, item.id,
                remotePort: remotePort, customPath: activeToolPath));
        break;
      case 'detach':
        execute('断开', () => _detachWithLogs(item));
        break;
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
            child: Row(children: [
          _sidebar(),
          Expanded(
              child: Column(children: [_topbar(), Expanded(child: _content())]))
        ])),
      );

  Widget _sidebar() => NavigationRail(
        selectedIndex: tab,
        onDestinationSelected: (value) => setState(() => tab = value),
        labelType: NavigationRailLabelType.all,
        leading: Padding(
            padding: const EdgeInsets.only(bottom: 22),
            child: Icon(Icons.usb_rounded,
                size: 34, color: Theme.of(context).colorScheme.primary)),
        destinations: const [
          NavigationRailDestination(
              icon: Icon(Icons.dashboard_outlined),
              selectedIcon: Icon(Icons.dashboard),
              label: Text('概览')),
          NavigationRailDestination(
              icon: Icon(Icons.usb_outlined),
              selectedIcon: Icon(Icons.usb),
              label: Text('设备')),
          NavigationRailDestination(
              icon: Icon(Icons.terminal_outlined),
              selectedIcon: Icon(Icons.terminal),
              label: Text('日志')),
          NavigationRailDestination(
              icon: Icon(Icons.settings_outlined),
              selectedIcon: Icon(Icons.settings),
              label: Text('设置'))
        ],
      );

  Widget _topbar() => LayoutBuilder(builder: (context, constraints) {
        final title =
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('USBIP Unified',
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context)
                  .textTheme
                  .headlineSmall
                  ?.copyWith(fontWeight: FontWeight.w700)),
          Text('跨平台 USB/IP 管理中心 · $appBuild',
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall)
        ]);
        final controls = Wrap(
            alignment: WrapAlignment.end,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 14,
            runSpacing: 4,
            children: [
              _roleSelector(compact: true),
              Chip(
                  avatar: Icon(Icons.circle,
                      size: 10, color: busy ? Colors.orange : Colors.green),
                  label: Text(busy ? '执行中' : '就绪'))
            ]);
        return Padding(
            padding: const EdgeInsets.fromLTRB(28, 18, 28, 12),
            child: constraints.maxWidth < 760
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                        title,
                        const SizedBox(height: 8),
                        Align(alignment: Alignment.centerRight, child: controls)
                      ])
                : Row(children: [Expanded(child: title), controls]));
      });

  Widget _roleSelector({bool compact = false}) => DropdownButtonHideUnderline(
          child: DropdownButton<UsbIpRole>(
        value: role,
        onChanged: busy ? null : _changeRole,
        icon: const Icon(Icons.swap_horiz),
        items: [
          for (final item in availableRoles)
            DropdownMenuItem(
                value: item,
                child: Text(_roleLabel(item), overflow: TextOverflow.ellipsis))
        ],
      ));

  String _roleLabel(UsbIpRole value) => switch (value) {
        UsbIpRole.linux => 'Linux 原生 USB/IP',
        UsbIpRole.linuxServer => 'Linux 共享端',
        UsbIpRole.linuxClient => 'Linux 客户端',
        UsbIpRole.windowsServer => 'Windows 共享端',
        UsbIpRole.windowsClient => 'Windows 客户端',
      };

  Widget _content() => Padding(
      padding: const EdgeInsets.fromLTRB(28, 8, 28, 28),
      child: switch (tab) {
        0 => _overview(),
        1 => _devicesPage(),
        2 => _logsPage(),
        _ => _settingsPage()
      });

  Widget _overview() => ListView(children: [
        _hero(),
        const SizedBox(height: 18),
        Row(children: [
          Expanded(
              child: _stat(
                  Icons.devices_other, '设备项目', '${devices.length}', '当前列表')),
          const SizedBox(width: 14),
          Expanded(child: _stat(Icons.hub_outlined, '运行角色', roleName, '当前后端')),
          const SizedBox(width: 14),
          Expanded(
              child: _stat(
                  Icons.public,
                  isServer ? '本机地址' : '远程主机',
                  isServer
                      ? (localAddresses.isEmpty ? '未检测到' : localAddresses.first)
                      : (remoteHost.text.trim().isEmpty
                          ? '未设置'
                          : remoteHost.text.trim()),
                  isServer ? '服务端网卡' : '客户端连接目标')),
        ]),
        const SizedBox(height: 18),
        _shareAddressPanel(),
        const SizedBox(height: 18),
        _recentLog(),
      ]);

  Widget _shareAddressPanel() => Card(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.lan_outlined,
                color: Theme.of(context).colorScheme.primary, size: 28),
            const SizedBox(width: 14),
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text(isServer ? '本机 USB/IP 共享地址' : '远程 USB/IP 服务端',
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 5),
                  Text(
                      isServer
                          ? '其他设备连接本机已共享设备时使用以下地址。当前服务端端口为 TCP $effectiveSharePort。'
                          : '当前客户端连接目标为以下远程地址。远程端口可在设置中修改。',
                      style: Theme.of(context).textTheme.bodySmall),
                  const SizedBox(height: 10),
                  SelectableText(shareAddress,
                      style: const TextStyle(
                          fontFamily: 'monospace',
                          fontWeight: FontWeight.w600)),
                  if (isServer && localAddresses.isEmpty) ...[
                    const SizedBox(height: 8),
                    const Text('请确认网卡已联网；127.0.0.1 只能供本机使用。',
                        style: TextStyle(color: Colors.orange)),
                  ],
                ])),
            IconButton(
                tooltip: isServer ? '复制共享地址' : '复制远程地址',
                onPressed: canCopyAddress ? _copyShareAddress : null,
                icon: const Icon(Icons.copy_outlined)),
            IconButton(
                tooltip: '刷新地址',
                onPressed: busy ? null : refreshLocalAddresses,
                icon: const Icon(Icons.refresh)),
          ]),
        ),
      );

  Future<void> _copyShareAddress() async {
    await Clipboard.setData(ClipboardData(text: shareAddress));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('共享地址已复制')));
  }

  Widget _hero() => Card(
      child: Padding(
          padding: const EdgeInsets.all(24),
          child: Row(children: [
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text('统一管理本机与远程 USB 设备',
                      style: Theme.of(context)
                          .textTheme
                          .titleLarge
                          ?.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  const Text('通过原生 USB/IP 工具完成发现、共享、连接和断开。平台驱动由系统单独提供。'),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                      onPressed: busy ? null : refresh,
                      icon: const Icon(Icons.refresh),
                      label: const Text('刷新设备'))
                ])),
            Icon(Icons.account_tree_rounded,
                size: 84,
                color: Theme.of(context)
                    .colorScheme
                    .primary
                    .withValues(alpha: .75))
          ])));
  Widget _stat(IconData icon, String title, String value, String sub) => Card(
      child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(children: [
            Icon(icon, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 13),
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text(title, style: Theme.of(context).textTheme.labelMedium),
                  Text(value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700)),
                  Text(sub, style: Theme.of(context).textTheme.bodySmall)
                ]))
          ])));
  Widget _recentLog() => Card(
      child: Padding(
          padding: const EdgeInsets.all(18),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('最近活动',
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Text(logs.isEmpty ? '暂无活动记录' : logs.last,
                maxLines: 3, overflow: TextOverflow.ellipsis)
          ])));

  Widget _devicesPage() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Text('设备管理',
                style: Theme.of(context)
                    .textTheme
                    .headlineSmall
                    ?.copyWith(fontWeight: FontWeight.w700)),
            const Spacer(),
            FilledButton.icon(
                onPressed: busy ? null : refresh,
                icon: const Icon(Icons.refresh),
                label: const Text('刷新')),
          ]),
          const SizedBox(height: 16),
          Expanded(
            child: Card(
              child: devices.isEmpty
                  ? Center(child: Text(busy ? '正在读取设备...' : '没有设备数据，请检查工具和权限。'))
                  : ListView.separated(
                      itemCount: devices.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (_, index) {
                        final item = devices[index];
                        final active = selected?.id == item.id;
                        return ListTile(
                          selected: active,
                          onTap: () => setState(() => selected = item),
                          leading: CircleAvatar(
                              child: Icon(active ? Icons.check : Icons.usb)),
                          title: Text(item.name),
                          subtitle: Text(
                              '${item.id}  ·  ${item.state.isEmpty ? '状态未知' : item.state}${item.attachedPort == null ? '' : '  ·  本机端口 ${item.attachedPort}'}\n${item.detail}',
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis),
                          trailing: Wrap(spacing: 3, children: [
                            if (isServer) ...[
                              IconButton(
                                tooltip: item.bound ? '已共享' : '绑定/共享',
                                onPressed: busy || item.bound
                                    ? null
                                    : () {
                                        setState(() => selected = item);
                                        action('bind');
                                      },
                                icon: const Icon(Icons.share),
                              ),
                              IconButton(
                                tooltip: item.bound ? '解绑' : '未共享',
                                onPressed: busy || !item.bound || item.attached
                                    ? null
                                    : () {
                                        setState(() => selected = item);
                                        action('unbind');
                                      },
                                icon: const Icon(Icons.stop_circle_outlined),
                              ),
                            ],
                            if (isClient) ...[
                              IconButton(
                                tooltip: !item.connectionStateKnown
                                    ? '连接状态未知'
                                    : item.attached
                                        ? '已连接'
                                        : '连接',
                                onPressed: busy ||
                                        !item.connectionStateKnown ||
                                        item.attached
                                    ? null
                                    : () {
                                        setState(() => selected = item);
                                        action('attach');
                                      },
                                icon: const Icon(Icons.link),
                              ),
                              IconButton(
                                tooltip: !item.connectionStateKnown
                                    ? '连接状态未知'
                                    : item.attached
                                        ? '断开'
                                        : '未连接',
                                onPressed: busy ||
                                        !item.connectionStateKnown ||
                                        !item.attached
                                    ? null
                                    : () {
                                        setState(() => selected = item);
                                        action('detach');
                                      },
                                icon: const Icon(Icons.link_off),
                              ),
                            ],
                          ]),
                        );
                      },
                    ),
            ),
          ),
        ],
      );
  Widget _logsPage() =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text('命令日志',
              style: Theme.of(context)
                  .textTheme
                  .headlineSmall
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const Spacer(),
          IconButton(
              tooltip: '复制全部日志',
              onPressed: logs.isEmpty ? null : _copyLogs,
              icon: const Icon(Icons.copy_all_outlined))
        ]),
        const SizedBox(height: 16),
        Expanded(
            child: Card(
                child: SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: SelectableText(
                        logs.isEmpty ? '暂无日志' : logs.join('\n'),
                        style: const TextStyle(fontFamily: 'monospace')))))
      ]);

  Future<void> _copyLogs() async {
    await Clipboard.setData(ClipboardData(text: logs.join('\n')));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('日志已复制到剪贴板')));
  }

  Widget _settingsPage() => ListView(children: [
        Text('连接设置',
            style: Theme.of(context)
                .textTheme
                .headlineSmall
                ?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 16),
        Card(
            child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('运行角色',
                          style: Theme.of(context)
                              .textTheme
                              .titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700)),
                      const SizedBox(height: 8),
                      Text(roleDescription,
                          style: Theme.of(context).textTheme.bodySmall),
                      const SizedBox(height: 12),
                      _roleSelector(),
                      const SizedBox(height: 22),
                      if (isServer) ...[
                        Text('服务端设置',
                            style: Theme.of(context)
                                .textTheme
                                .titleMedium
                                ?.copyWith(fontWeight: FontWeight.w700)),
                        const SizedBox(height: 8),
                        Text(
                            Platform.isWindows
                                ? 'usbipd-win 的 USB/IP 服务固定监听 TCP 3240，Windows 服务端不支持在此修改端口。'
                                : '本机对外共享设备时使用。Linux usbipd 可以监听 1-65535 范围内的端口。',
                            style: Theme.of(context).textTheme.bodySmall),
                        const SizedBox(height: 12),
                        TextField(
                            controller: serverPort,
                            enabled: Platform.isLinux,
                            keyboardType: TextInputType.number,
                            decoration: InputDecoration(
                                labelText: '服务端监听端口',
                                hintText: Platform.isWindows
                                    ? '固定 3240'
                                    : '默认 3240，范围 1-65535',
                                helperText: Platform.isWindows
                                    ? 'Windows usbipd-win 固定端口'
                                    : '绑定/共享时启动或复用 usbipd',
                                border: const OutlineInputBorder()),
                            onChanged: (_) => setState(() {})),
                      ],
                      if (isServer && isClient) const SizedBox(height: 22),
                      if (isClient) ...[
                        Text('客户端设置',
                            style: Theme.of(context)
                                .textTheme
                                .titleMedium
                                ?.copyWith(fontWeight: FontWeight.w700)),
                        const SizedBox(height: 8),
                        Text(
                            '连接远程 USB/IP 服务端时使用。服务端端口由对方配置；标准 USB/IP 客户端支持通过 TCP 端口参数连接。',
                            style: Theme.of(context).textTheme.bodySmall),
                        const SizedBox(height: 12),
                        TextField(
                            controller: remoteHost,
                            decoration: const InputDecoration(
                                labelText: '远程服务端地址',
                                hintText: '例如 192.168.1.20 或主机名',
                                border: OutlineInputBorder()),
                            onChanged: (_) {
                              _scheduleSaveSettings();
                              setState(() {});
                            }),
                        const SizedBox(height: 12),
                        TextField(
                            controller: clientPort,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                                labelText: '远程服务端端口',
                                hintText: '默认 3240，范围 1-65535',
                                helperText: '必须与远程服务端监听端口或 FRP 映射端口一致',
                                border: OutlineInputBorder()),
                            onChanged: (_) {
                              _scheduleSaveSettings();
                              setState(() {});
                            }),
                      ],
                      if (!isServer && !isClient)
                        const Text('当前角色没有可配置的连接方向，请切换到共享端或客户端。'),
                      const SizedBox(height: 16),
                      TextField(
                          controller: activeToolPathController,
                          decoration: InputDecoration(
                              labelText:
                                  isServer ? '共享端工具路径（可选）' : '客户端工具路径（可选）',
                              hintText: Platform.isWindows
                                  ? (isServer
                                      ? '留空自动查找 usbipd.exe'
                                      : '留空自动查找 usbipw.exe、usbip.exe 或 usbip-win2.exe')
                                  : '留空自动查找 usbip',
                              helperText: isServer
                                  ? '仅用于当前共享端角色；不会覆盖客户端路径'
                                  : '仅用于当前客户端角色；不会覆盖共享端路径',
                              border: const OutlineInputBorder()),
                          onChanged: (_) => _scheduleSaveSettings()),
                      const SizedBox(height: 18),
                      Align(
                          alignment: Alignment.centerLeft,
                          child: Text('底层组件安装',
                              style: Theme.of(context)
                                  .textTheme
                                  .titleMedium
                                  ?.copyWith(fontWeight: FontWeight.w700))),
                      const SizedBox(height: 10),
                      if (offlineTarget != null)
                        _offlineTargetCard(offlineTarget!),
                      if (offlineTarget != null) const SizedBox(height: 10),
                      Wrap(spacing: 10, runSpacing: 10, children: [
                        OutlinedButton.icon(
                            onPressed: busy ? null : checkEnvironment,
                            icon: const Icon(Icons.health_and_safety_outlined),
                            label: const Text('检查环境')),
                        FilledButton.icon(
                            onPressed: busy ? null : installOnline,
                            icon: const Icon(Icons.cloud_download_outlined),
                            label: const Text('自动安装组件')),
                        OutlinedButton.icon(
                            onPressed: busy || offlineTarget?.supported != true
                                ? null
                                : installOffline,
                            icon: const Icon(Icons.download_for_offline),
                            label: const Text('离线安装')),
                        if (Platform.isLinux)
                          OutlinedButton.icon(
                              onPressed: showManualInstallGuide,
                              icon: const Icon(Icons.menu_book_outlined),
                              label: const Text('手动安装指引')),
                        FilledButton.icon(
                            onPressed: busy ? null : refresh,
                            icon: const Icon(Icons.refresh),
                            label: const Text('应用并刷新'))
                      ]),
                      const SizedBox(height: 8),
                      Text(
                          Platform.isWindows
                              ? '应用本身是免安装便携版。“检查环境”不会修改系统；“自动安装组件”会以管理员权限注册 usbipd-win 服务、USB/IP 客户端驱动和虚拟 USB 设备。若目标机已经安装这些组件，可只检查环境或填写工具路径。'
                              : '“检查环境”不会安装任何组件；安装按钮只用于安装系统 USB/IP 工具。',
                          style: Theme.of(context).textTheme.bodySmall),
                    ]))),
        const SizedBox(height: 18),
        Card(
            child: ListTile(
                leading: const Icon(Icons.info_outline),
                title: Text(isServer ? '共享端提示' : '客户端提示'),
                subtitle: Text(isServer
                    ? (Platform.isWindows
                        ? 'Windows 服务端固定使用 TCP 3240。需要其他端口时，请在 FRP、路由器或 VPN 层做端口映射。'
                        : 'Linux 服务端端口可以自定义；远程客户端填写相同端口。不要把 USB/IP 端口直接暴露到不可信公网。')
                    : '客户端刷新会查询远程设备和本机 USB/IP 端口。断开操作使用本机端口号，不是远程 BUSID。')))
      ]);

  Widget _offlineTargetCard(OfflineTargetInfo target) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: (target.supported ? Colors.green : Colors.orange)
              .withValues(alpha: .10),
          border: Border.all(
              color: (target.supported ? Colors.green : Colors.orange)
                  .withValues(alpha: .45)),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(
              target.supported
                  ? Icons.check_circle_outline
                  : Icons.warning_amber,
              color: target.supported ? Colors.green : Colors.orange),
          const SizedBox(width: 10),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(
                    '当前目标：${target.platform} · ${target.distribution} · ${target.architecture}',
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text(target.message),
                if (!target.supported && Platform.isLinux) ...[
                  const SizedBox(height: 4),
                  const Text('离线安装已禁用。可使用在线安装或查看手动安装指引。'),
                ],
              ])),
          IconButton(
              tooltip: '重新检测',
              onPressed: busy ? null : inspectOfflineTarget,
              icon: const Icon(Icons.refresh)),
        ]),
      );
}
