import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'services/usbip_service.dart';
import 'services/offline_installer.dart';
import 'services/online_installer.dart';

void main() => runApp(const UsbIpApp());

class UsbIpApp extends StatelessWidget {
  const UsbIpApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'USBIP Unified Manager',
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
  final remoteHost = TextEditingController();
  final path = TextEditingController();
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
      await refreshLocalAddresses();
      await inspectOfflineTarget();
      if (widget.autoRefresh) await refresh();
    });
  }

  @override
  void dispose() {
    remoteHost.dispose();
    path.dispose();
    serverPort.dispose();
    clientPort.dispose();
    super.dispose();
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
      await refreshLocalAddresses();
      final host = isClient ? remoteHost.text.trim() : '';
      final result = await service.list(role, host,
          remotePort: remotePort, customPath: path.text);
      CommandResult? ports;
      if (isClient && result.ok) {
        ports = await service.listPorts(role, customPath: path.text);
      }
      if (!mounted) return;

      var parsed = service.parse(result.output, role: role);
      if (isClient && ports != null) {
        final attached = service.attachedPorts(ports.output);
        parsed = [
          for (final item in parsed)
            item.copyWith(
                attached: attached.containsKey(item.id),
                attachedPort: attached[item.id],
                state: !ports.ok
                    ? '连接状态未知'
                    : attached.containsKey(item.id)
                        ? '已连接'
                        : '未连接',
                connectionStateKnown: ports.ok)
        ];
        log('\$ ${ports.command}');
        if (ports.output.isNotEmpty) log('命令输出：${ports.output}');
        if (!ports.ok) {
          log('客户端端口查询失败：${ports.output}');
          log('为避免误操作，连接和断开按钮已禁用；请修复工具/权限后重新刷新。');
        }
      } else if (isServer && service.isLinux(role)) {
        parsed = [
          for (final item in parsed)
            _withLinuxBoundState(item, await service.isBound(role, item.id))
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
      customPath: path.text,
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
    final result = await service.unbind(role, item.id, customPath: path.text);
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
    final result = await service.detach(role, port, customPath: path.text);
    log('命令完成：${result.command}（退出码 ${result.code}）');
    if (result.output.isNotEmpty) log('命令输出：${result.output}');
    log(result.ok ? '断开操作完成，设备已从本机卸载。' : '断开失败，设备可能仍处于连接状态。');
    return result;
  }

  Future<void> installOffline() async {
    if (busy) return;
    final server = isServer;
    final client = isClient;
    setState(() => busy = true);
    log('正在执行离线组件安装...');
    try {
      final result =
          await offlineInstaller.install(server: server, client: client);
      if (!mounted) return;
      log(result.output.isEmpty ? result.command : result.output);
      if (!result.ok) {
        _message(result.code == 3 ? '包管理器正在使用' : '离线安装失败', result.output);
      } else {
        _message('离线安装完成', '底层组件安装完成。重新点击刷新设备即可检查状态。');
      }
    } catch (error) {
      if (mounted) {
        log('离线安装异常：$error');
        _message('离线安装失败', '$error');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void showManualInstallGuide() {
    _message('手动安装指引', offlineInstaller.manualInstallGuide());
  }

  Future<void> checkEnvironment() async {
    if (busy) return;
    setState(() => busy = true);
    try {
      final result =
          await onlineInstaller.check(server: isServer, client: isClient);
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
    final server = isServer;
    final client = isClient;
    setState(() => busy = true);
    log('正在通过系统包管理器在线安装...');
    try {
      final result =
          await onlineInstaller.install(server: server, client: client);
      if (!mounted) return;
      log(result.output.isEmpty ? result.command : result.output);
      if (!result.ok) {
        _message('在线安装失败', result.output);
      } else {
        _message('在线安装完成', '组件安装完成。重新点击刷新设备即可检查状态。');
      }
    } catch (error) {
      if (mounted) {
        log('在线安装异常：$error');
        _message('在线安装失败', '$error');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
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
                remotePort: remotePort, customPath: path.text));
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

  Widget _topbar() => Padding(
      padding: const EdgeInsets.fromLTRB(28, 18, 28, 12),
      child: Row(children: [
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('USBIP Unified',
              style: Theme.of(context)
                  .textTheme
                  .headlineSmall
                  ?.copyWith(fontWeight: FontWeight.w700)),
          Text('跨平台 USB/IP 管理中心', style: Theme.of(context).textTheme.bodySmall)
        ]),
        const Spacer(),
        _roleSelector(compact: true),
        const SizedBox(width: 14),
        Chip(
            avatar: Icon(Icons.circle,
                size: 10, color: busy ? Colors.orange : Colors.green),
            label: Text(busy ? '执行中' : '就绪'))
      ]));

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
                            onChanged: (_) => setState(() {})),
                        const SizedBox(height: 12),
                        TextField(
                            controller: clientPort,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                                labelText: '远程服务端端口',
                                hintText: '默认 3240，范围 1-65535',
                                helperText: '必须与远程服务端监听端口或 FRP 映射端口一致',
                                border: OutlineInputBorder()),
                            onChanged: (_) => setState(() {})),
                      ],
                      if (!isServer && !isClient)
                        const Text('当前角色没有可配置的连接方向，请切换到共享端或客户端。'),
                      const SizedBox(height: 16),
                      TextField(
                          controller: path,
                          decoration: InputDecoration(
                              labelText: '工具路径（可选）',
                              hintText: Platform.isWindows
                                  ? (role == UsbIpRole.windowsServer
                                      ? '留空使用 PATH 中的 usbipd'
                                      : '留空使用 PATH 中的 usbipw.exe')
                                  : '留空使用 PATH 中的 usbip',
                              border: const OutlineInputBorder())),
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
                            label: const Text('在线安装')),
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
                      ])
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
