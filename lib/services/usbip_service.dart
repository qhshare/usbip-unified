import 'dart:async';
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
      {required this.command, required this.code, required this.output});
  final String command;
  final int code;
  final String output;
  bool get ok => code == 0;
}

class UsbIpService {
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
    if (role == UsbIpRole.windowsClient) {
      // usbip-win2's current executable is usbipw.exe. Some older installs
      // expose the compatibility name usbip.exe, so keep it as a fallback.
      return const ['usbipw.exe', 'usbip.exe'];
    }
    return [executable(role, customPath)];
  }

  Future<CommandResult> run(UsbIpRole role, List<String> args,
      {String customPath = ''}) async {
    final elevated = _requiresElevation(role, args) && !await _isRoot();
    CommandResult? missing;
    for (final exe in _executableCandidates(role, customPath)) {
      final result = await _runExecutable(exe, args, elevated: elevated);
      if (result.code != 127) return result;
      missing = result;
    }
    return missing ??
        const CommandResult(
            command: 'usbip', code: 127, output: '未找到 USB/IP 工具。');
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
      final result = await Process.run('id', ['-u']);
      return result.exitCode == 0 && result.stdout.toString().trim() == '0';
    } catch (_) {
      return false;
    }
  }

  Future<bool> _commandExists(String command) async {
    if (command.trim().isEmpty) return false;
    try {
      final result = await Process.run(Platform.isWindows ? 'where.exe' : 'sh',
          Platform.isWindows ? [command] : ['-c', 'command -v "$command"']);
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

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
      {bool elevated = false}) async {
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
    final command = ([actualExecutable, ...actualArgs]).join(' ');
    try {
      final process = await Process.start(actualExecutable, actualArgs);
      final stdout =
          process.stdout.transform(const SystemEncoding().decoder).join();
      final stderr =
          process.stderr.transform(const SystemEncoding().decoder).join();
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
          command: command, code: 127, output: '找不到或无法执行工具：${error.message}');
    } catch (error) {
      return CommandResult(command: command, code: 1, output: '执行失败：$error');
    }
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
