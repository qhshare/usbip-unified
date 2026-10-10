import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:usbip_unified/services/offline_installer.dart';
import 'package:usbip_unified/services/online_installer.dart';
import 'package:usbip_unified/services/usbip_service.dart';

void main() {
  final service = UsbIpService();

  test('CommandResult defaults to started', () {
    const result = CommandResult(
      command: 'test',
      code: 1,
      output: 'warning',
    );
    expect(result.started, isTrue);
    expect(result.ok, isFalse);
  });

  test('CommandResult can represent process start failure', () {
    const result = CommandResult(
      command: 'test',
      code: 127,
      output: 'missing executable',
      started: false,
    );
    expect(result.started, isFalse);
    expect(result.ok, isFalse);
  });

  test('decodes UTF-8 Windows device names without mojibake', () {
    final bytes = utf8.encode('USB 输入设备\r\n');

    expect(
      UsbIpService.decodeProcessOutput(bytes, windows: true),
      'USB 输入设备\r\n',
    );
  });

  test('decodes mixed Windows command output line by line', () {
    final bytes = <int>[
      ...utf8.encode('USB 输入设备\r\n'),
      ...utf8.encode('legacy diagnostic'),
      0xff,
      ...utf8.encode('\r\n'),
    ];

    final output = UsbIpService.decodeProcessOutput(
      bytes,
      windows: true,
      // Latin-1 makes the test deterministic on Linux while simulating a
      // non-UTF-8 Windows fallback for the malformed second line.
      fallbackEncoding: latin1,
    );

    expect(output, 'USB 输入设备\r\nlegacy diagnosticÿ\r\n');
  });

  test('parses Linux BUSID output', () {
    final devices =
        service.parse(' - 1-2: Logitech Keyboard\n    2-1 (1-1): USB Camera');
    expect(devices.map((device) => device.id), ['1-2', '2-1']);
    expect(devices.first.name, 'Logitech Keyboard');
  });

  test('parses usbip busid output', () {
    final devices = service
        .parse('- busid 2-1 (0e0f:0003)\n  VMware, Inc. : Virtual Mouse');
    expect(devices.single.id, '2-1');
    expect(devices.single.name, contains('0e0f:0003'));
  });

  test('parses attached client ports', () {
    final devices =
        service.parse('Port 00: <Port in Use> at 192.168.1.20, busid 1-2');
    expect(devices.single.id, '00');
    expect(devices.single.detail, contains('busid 1-2'));
  });

  test('parses Windows sharing states', () {
    final devices = service.parse('''
BUSID  VID:PID    DEVICE                         STATE
1-2    046d:c52b  USB Input Device               Shared
2-1    1234:5678  USB Camera                     Not shared
3-1    1111:2222  USB Device                     Attached
4-3    1234:5678  USB Device                     Shared (forced)
5-1    1234:9999  USB Hub                        Incompatible hub
''', role: UsbIpRole.windowsServer);

    expect(devices.map((device) => device.id),
        ['1-2', '2-1', '3-1', '4-3', '5-1']);
    expect(devices[0].bound, isTrue);
    expect(devices[0].attached, isFalse);
    expect(devices[0].state, 'Shared');
    expect(devices[1].bound, isFalse);
    expect(devices[1].attached, isFalse);
    expect(devices[1].state, 'Not shared');
    expect(devices[2].bound, isTrue);
    expect(devices[2].attached, isTrue);
    expect(devices[2].state, 'Attached');
    expect(devices[3].bound, isTrue);
    expect(devices[3].attached, isFalse);
    expect(devices[3].state, 'Shared (forced)');
    expect(devices[4].bound, isFalse);
    expect(devices[4].attached, isFalse);
    expect(devices[4].state, 'Incompatible hub');
  });

  test('maps remote busids to local client ports', () {
    final ports = service.attachedPorts('''
Port 00: <Port in Use> at Full Speed(12Mbps)
       5-1 -> usbip://192.168.1.103:3240/1-1.4
Port 01: <Port Available>
''');

    expect(ports, {'1-1.4': '00'});
  });

  test('maps compact usbip URLs to remote client ports', () {
    final ports = service.attachedPorts('''
Port 02: <Port in Use> at High Speed(480Mbps)
       5-1 -> usbip://192.168.1.20:3240-2-3
''');

    expect(ports, {'2-3': '02'});
  });

  test('parses Linux attached port blocks into disconnectable devices', () {
    final devices = service.parseAttachedPorts('''
Imported USB devices
====================
Port 00: <Port in Use> at Full Speed(12Mbps)
       QinHeng Electronics : CH340 serial converter (1a86:7523)
       3-1 -> usbip://192.168.3.197:3240/4-6
           -> remote bus/dev 004/006
''');

    expect(devices, hasLength(1));
    expect(devices.single.id, '4-6');
    expect(devices.single.name, contains('CH340 serial converter'));
    expect(devices.single.attached, isTrue);
    expect(devices.single.attachedPort, '00');
    expect(devices.single.state, '已连接');
    expect(devices.single.detail, contains('usbip://192.168.3.197'));
  });

  test('parses Windows attached port blocks into disconnectable devices', () {
    final devices = service.parseAttachedPorts('''
Imported USB devices
====================
Port 01: device in use at Full Speed(12Mbps)
         QinHeng Electronics : CH340 serial converter (1a86:7523)
           -> usbip://192.168.3.193:3240/2-2.1
           -> remote bus/dev: 002/008
           -> serial:
           -> mode: zero-copy
''');

    expect(devices.single.id, '2-2.1');
    expect(devices.single.name, contains('CH340 serial converter'));
    expect(devices.single.attachedPort, '01');
    expect(devices.single.detail, contains('mode: zero-copy'));
  });

  test('keeps a connected device when remote list becomes empty', () {
    final devices = service.mergeClientDevices(const [], '''
Imported USB devices
====================
Port 01: device in use at Full Speed(12Mbps)
         VMware, Inc. : Virtual Mouse (0e0f:0003)
           -> usbip://192.168.3.193:3240/2-1
           -> remote bus/dev: 002/002
''', portsOk: true);

    expect(devices, hasLength(1));
    expect(devices.single.id, '2-1');
    expect(devices.single.attachedPort, '01');
    expect(devices.single.attached, isTrue);
  });

  test('uses a port fallback when attached output has no remote BUSID', () {
    final devices = service.parseAttachedPorts('''
Port 00: <Port in Use> at Full Speed(12Mbps)
       USB device with incomplete client metadata
''');

    expect(devices.single.id, 'port-00');
    expect(devices.single.attachedPort, '00');
    expect(devices.single.name, contains('incomplete client metadata'));
  });

  test('does not report disconnected when client port query fails', () {
    final devices = service.mergeClientDevices([
      const UsbDevice(id: '2-1', name: 'USB device'),
    ], '', portsOk: false);

    expect(devices.single.attached, isFalse);
    expect(devices.single.attachedPort, isNull);
    expect(devices.single.state, '连接状态未知');
    expect(devices.single.connectionStateKnown, isFalse);
  });

  test('legacy Linux role lists local devices when host is empty', () async {
    final result =
        await service.list(UsbIpRole.linux, '', customPath: '/missing/usbip');
    expect(result.command, '/missing/usbip list -l');
    expect(result.code, 127);
  });

  test('selects platform command defaults', () {
    expect(service.executable(UsbIpRole.linux, ''), 'usbip');
    expect(service.executable(UsbIpRole.windowsServer, ''), 'usbipd');
    expect(service.executable(UsbIpRole.windowsClient, ''), 'usbipw.exe');
  });

  test('recognizes all supported Windows client executable aliases', () {
    expect(UsbIpService.windowsClientExecutableNames,
        containsAll(['usbipw.exe', 'usbip.exe', 'usbip-win2.exe']));
  });

  test('keeps Windows server and client executable roles separate', () {
    expect(
      service.isExpectedWindowsExecutable(
        r'C:\Program Files\usbipd-win\usbipd.exe',
        UsbIpRole.windowsServer,
      ),
      isTrue,
    );
    expect(
      service.isExpectedWindowsExecutable(
        r'C:\Program Files\usbipd-win\usbipd.exe',
        UsbIpRole.windowsClient,
      ),
      isFalse,
    );
    expect(
      service.isExpectedWindowsExecutable(
        r'C:\Program Files\USBip\usbipw.exe',
        UsbIpRole.windowsClient,
      ),
      isTrue,
    );
    expect(
      service.isExpectedWindowsExecutable(
        r'C:\Downloads\USBip-0.9.7.7-x64.exe',
        UsbIpRole.windowsClient,
      ),
      isFalse,
    );
  });

  test('parses quoted Windows service executable path', () {
    final path = service.parseWindowsServiceExecutable('''
SERVICE_NAME: usbipd
        BINARY_PATH_NAME   : "C:\\Program Files\\usbipd-win\\usbipd.exe" --service
''');
    expect(path, r'C:\Program Files\usbipd-win\usbipd.exe');
  });

  test('parses unquoted Windows service executable path', () {
    final path = service.parseWindowsServiceExecutable('''
        BINARY_PATH_NAME   : C:\\Program Files\\usbipd-win\\usbipd.exe --service
''');
    expect(path, r'C:\Program Files\usbipd-win\usbipd.exe');
  });

  test('parses Windows uninstall entries and install locations', () {
    final entries = service.parseWindowsUninstallEntries(r'''
HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\USBip
    DisplayName    REG_SZ    USBip
    InstallLocation    REG_SZ    C:\Program Files\USBip
    DisplayIcon    REG_SZ    C:\Program Files\USBip\unins000.exe
    UninstallString    REG_SZ    "C:\Program Files\USBip\unins000.exe"
HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\usbipd-win
    DisplayName    REG_SZ    usbipd-win
    InstallLocation    REG_SZ    C:\Program Files\usbipd-win
''');

    expect(entries, hasLength(2));
    expect(entries[0].displayName, 'USBip');
    expect(entries[0].installLocation, r'C:\Program Files\USBip');
    expect(entries[0].displayIcon, r'C:\Program Files\USBip\unins000.exe');
    expect(
        entries[0].uninstallString, r'"C:\Program Files\USBip\unins000.exe"');
    expect(entries[1].displayName, 'usbipd-win');
    expect(entries[1].installLocation, r'C:\Program Files\usbipd-win');
  });

  test('parses Windows offline installer role paths independently', () {
    final paths = InstalledToolPaths.parse('''
Target architecture: x64
Server executable: C:\\Program Files\\usbipd-win\\usbipd.exe
Client executable: C:\\Program Files\\USBip\\usbipw.exe
''');

    expect(paths.server, r'C:\Program Files\usbipd-win\usbipd.exe');
    expect(paths.client, r'C:\Program Files\USBip\usbipw.exe');
  });

  test('parses an available Windows client driver probe', () {
    final result = WindowsClientDriverCheck.parseProbeOutput('''
SERVICE|usbip2_ude|Running|OK
SERVICE|usbip2_filter|Running|OK
DEVICE|ROOT\\USBIP_WIN2\\UDE|USB/IP Virtual Host Controller|OK
''');

    expect(result.status, 'available');
    expect(result.available, isTrue);
    expect(result.servicesDetected, isTrue);
    expect(result.virtualDeviceDetected, isTrue);
  });

  test('parses explicitly missing Windows client driver markers', () {
    final result = WindowsClientDriverCheck.parseProbeOutput('''
NO_USBIP_DRIVER
NO_USBIP_DEVICE
''');

    expect(result.status, 'missing');
    expect(result.missing, isTrue);
    expect(result.servicesDetected, isFalse);
    expect(result.virtualDeviceDetected, isFalse);
  });

  test(
      'reports a registered driver without a virtual device as pending restart',
      () {
    final result = WindowsClientDriverCheck.parseProbeOutput('''
SERVICE|usbip2_ude|Running|OK
SERVICE|usbip2_filter|Running|OK
NO_USBIP_DEVICE
''');

    expect(result.status, 'pending_restart');
    expect(result.pendingRestart, isTrue);
    expect(result.missing, isFalse);
    expect(result.available, isFalse);
    expect(result.servicesDetected, isTrue);
    expect(result.virtualDeviceDetected, isFalse);
    expect(result.output, contains('可能需要重启 Windows'));
  });

  test('does not treat a partial driver chain as pending restart', () {
    final result = WindowsClientDriverCheck.parseProbeOutput(
      'SERVICE|usbip2_ude|Stopped|OK',
    );

    expect(result.status, 'missing');
    expect(result.pendingRestart, isFalse);
    expect(result.missing, isTrue);
    expect(result.servicesDetected, isFalse);
  });

  test('does not treat one driver service plus a device as available', () {
    final result = WindowsClientDriverCheck.parseProbeOutput('''
SERVICE|usbip2_ude|Running|OK
DEVICE|ROOT\\USBIP_WIN2\\UDE|USB/IP Virtual Host Controller|OK
''');

    expect(result.status, 'missing');
    expect(result.available, isFalse);
    expect(result.servicesDetected, isFalse);
    expect(result.virtualDeviceDetected, isTrue);
  });

  test('keeps Windows client driver query errors unknown', () {
    final result = WindowsClientDriverCheck.parseProbeOutput('''
SERVICE_QUERY_ERROR|Access denied
DEVICE_QUERY_ERROR|CIM unavailable
''', exitCode: 1);

    expect(result.status, 'unknown');
    expect(result.missing, isFalse);
    expect(result.available, isFalse);
  });

  test('parses Windows offline install status markers', () {
    final result = WindowsOfflineInstallStatus.parse('''
TARGET_ARCHITECTURE|x64
SERVER_STATUS|installed
CLIENT_STATUS|installed
CLIENT_DRIVER_STATUS|available
CLIENT_DEVICE_STATUS|pending_restart
RESTART_REQUIRED|true
INSTALL_STATUS|partial
''');

    expect(result.hasStructuredStatus, isTrue);
    expect(result.partial, isTrue);
    expect(result.failed, isFalse);
    expect(result.restartRequired, isTrue);
    expect(result.serverStatus, 'installed');
    expect(result.clientStatus, 'installed');
    expect(result.clientDriverStatus, 'available');
    expect(result.clientDeviceStatus, 'pending_restart');
    expect(
      result.summary(serverRequested: true, clientRequested: true),
      contains('需要重启 Windows'),
    );
  });

  test('parses successful server-only install status markers', () {
    final result = WindowsOfflineInstallStatus.parse('''
SERVER_STATUS|installed
CLIENT_STATUS|not_requested
INSTALL_STATUS|success
RESTART_REQUIRED|false
''');

    expect(result.success, isTrue);
    expect(result.restartRequired, isFalse);
    expect(result.summary(serverRequested: true, clientRequested: false),
        '共享端=installed');
  });

  test('parses failed and partial install status markers', () {
    final failed = WindowsOfflineInstallStatus.parse(
      'INSTALL_STATUS|failed\nRESTART_REQUIRED|false',
    );
    final partial = WindowsOfflineInstallStatus.parse(
      'INSTALL_STATUS|partial\nRESTART_REQUIRED|true',
    );

    expect(failed.failed, isTrue);
    expect(partial.partial, isTrue);
    expect(partial.restartRequired, isTrue);
  });

  test('keeps missing Windows offline client path null', () {
    final paths = InstalledToolPaths.parse(
      r'Server executable: C:\Program Files\usbipd-win\usbipd.exe',
    );

    expect(paths.server, isNotNull);
    expect(paths.client, isNull);
  });

  test('combines independent Windows server and client install results', () {
    final result = OnlineInstaller().combineWindowsRoleResults(
      server: true,
      client: true,
      serverResult: const CommandResult(
        command: 'winget install usbipd-win',
        code: 0,
        output: 'server installed',
      ),
      clientResult: const CommandResult(
        command: 'install-windows-offline.ps1 -Client',
        code: 0,
        output: 'CLIENT_STATUS|installed\n'
            'CLIENT_DRIVER_STATUS|available\n'
            'CLIENT_DEVICE_STATUS|pending_restart\n'
            'INSTALL_STATUS|partial',
      ),
    );

    expect(result.ok, isFalse);
    expect(result.code, 1);
    expect(result.output, contains('[Windows 共享端]'));
    expect(result.output, contains('[Windows 客户端]'));
  });

  test('keeps a successful Windows client result successful', () {
    final result = OnlineInstaller().combineWindowsRoleResults(
      server: false,
      client: true,
      clientResult: const CommandResult(
        command: 'install-windows-offline.ps1 -Client',
        code: 0,
        output: 'CLIENT_STATUS|installed\n'
            'CLIENT_DRIVER_STATUS|available\n'
            'CLIENT_DEVICE_STATUS|available\n'
            'CLIENT_PATH|C:\\Program Files\\USBip\\usbipw.exe\n'
            'INSTALL_STATUS|success',
      ),
    );

    expect(result.ok, isTrue);
    expect(result.output, contains('CLIENT_PATH|'));
  });

  test('normalizes server status after combining winget and client output', () {
    final result = OnlineInstaller().combineWindowsRoleResults(
      server: true,
      client: true,
      serverResult: const CommandResult(
        command: 'winget install usbipd-win',
        code: 0,
        output: 'Windows 共享端安装来源：winget 在线安装成功。',
      ),
      clientResult: const CommandResult(
        command: 'install-windows-offline.ps1 -Client',
        code: 0,
        output: 'SERVER_STATUS|not_requested\n'
            'CLIENT_STATUS|installed\n'
            'CLIENT_DRIVER_STATUS|available\n'
            'CLIENT_DEVICE_STATUS|available\n'
            'INSTALL_STATUS|success',
      ),
    );

    final status = WindowsOfflineInstallStatus.parse(result.output);
    expect(status.summary(serverRequested: true, clientRequested: true),
        '共享端=installed，客户端=installed，驱动=available，虚拟设备=available');
    expect(result.ok, isTrue);
  });

  test('does not expose Windows diagnostics on non-Windows hosts', () async {
    final diagnostics =
        await service.windowsToolDiagnostics(UsbIpRole.windowsServer);
    if (!Platform.isWindows) {
      expect(diagnostics, isEmpty);
    }
  });

  test('rejects a missing custom executable path before starting a process',
      () async {
    final result = await service.run(
      UsbIpRole.windowsServer,
      ['list'],
      customPath: '/missing/usbipd',
    );
    expect(result.code, 127);
    expect(result.output, contains('工具路径不存在'));
  });

  test('environment probe accepts a custom executable path', () async {
    final directory = await Directory.systemTemp.createTemp('usbip-test-');
    try {
      final executable =
          File('${directory.path}${Platform.pathSeparator}usbipd.exe');
      await executable.writeAsString('placeholder');
      final found = await service.findExecutable(UsbIpRole.windowsServer,
          customPath: executable.path);
      expect(found, executable.path);
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('a stale custom path does not block automatic executable discovery',
      () async {
    final automatic = await service.findExecutable(UsbIpRole.linuxServer);
    final stale = await service.findExecutable(UsbIpRole.linuxServer,
        customPath: '/definitely/missing/usbip-from-an-old-install');
    expect(stale, automatic);
  });

  test('uses a non-forced Windows bind by default', () async {
    final result = await service.bind(
      UsbIpRole.windowsServer,
      '1-2',
      customPath: '/missing/usbipd',
    );
    expect(result.command, '/missing/usbipd bind --busid 1-2');
    expect(result.command, isNot(contains('--force')));
    expect(result.code, 127);
  });

  test('clears an attached port when requested', () {
    const device = UsbDevice(
        id: '1-2', name: 'USB device', attachedPort: '00', attached: true);
    final cleared = device.copyWith(attachedPort: null, attached: false);
    expect(cleared.attachedPort, isNull);
    expect(cleared.attached, isFalse);
  });

  test('uses the client detach command on Linux', () async {
    final result = await service.detach(
      UsbIpRole.linuxClient,
      '00',
      customPath: '/missing/usbip',
    );

    expect(result.command, '/missing/usbip detach -p 00');
    expect(result.code, 127);
  });

  test('uses the client detach command on Windows', () async {
    final result = await service.detach(
      UsbIpRole.windowsClient,
      '01',
      customPath: '/missing/usbip.exe',
    );

    expect(result.command, '/missing/usbip.exe detach -p 01');
    expect(result.code, 127);
  });

  test('rejects invalid remote ports before starting a client command',
      () async {
    final result = await service.attach(
      UsbIpRole.linuxClient,
      '192.168.1.20',
      '2-1',
      remotePort: 70000,
    );
    expect(result.ok, isFalse);
    expect(result.output, contains('1 到 65535'));
  });

  test('allows a custom remote port for Linux clients', () async {
    final result = await service.attach(
      UsbIpRole.linuxClient,
      '192.168.1.20',
      '2-1',
      remotePort: 4000,
      customPath: '/missing/usbip',
    );
    expect(result.command, contains('--tcp-port 4000'));
    expect(result.command, contains('attach -r 192.168.1.20 -b 2-1'));
    expect(result.code, 127);
  });

  test('rejects Windows client remote ports below 1024', () async {
    final result = await service.attach(
      UsbIpRole.windowsClient,
      '192.168.1.20',
      '2-1',
      remotePort: 1023,
    );
    expect(result.ok, isFalse);
    expect(result.output, contains('1024 到 65535'));
  });

  test('requires a remote host only for explicit client roles', () async {
    final result = await service.list(UsbIpRole.linuxClient, '');
    expect(result.ok, isFalse);
    expect(result.output, contains('客户端模式必须填写'));
  });

  test('rejects server/client role mismatches', () async {
    final attach = await service.attach(UsbIpRole.windowsServer, 'host', '1-2');
    final detach = await service.detach(UsbIpRole.windowsServer, '00');
    final bind = await service.bind(UsbIpRole.windowsClient, '1-2');
    final unbind = await service.unbind(UsbIpRole.windowsClient, '1-2');

    expect(attach.ok, isFalse);
    expect(detach.ok, isFalse);
    expect(bind.ok, isFalse);
    expect(unbind.ok, isFalse);
  });

  test('validates server ports and Windows fixed port', () async {
    final invalid =
        await service.share(UsbIpRole.linuxServer, '1-2', port: 70000);
    final windows =
        await service.share(UsbIpRole.windowsServer, '1-2', port: 4000);

    expect(invalid.ok, isFalse);
    expect(invalid.output, contains('1 到 65535'));
    expect(windows.ok, isFalse);
    expect(windows.output, contains('固定的 USB/IP TCP 端口 3240'));
  });

  test('server port lookup explains that clients own USB/IP ports', () async {
    final result = await service.listPorts(UsbIpRole.linuxServer);
    expect(result.ok, isFalse);
    expect(result.output, contains('共享端没有本地 USB/IP 客户端端口'));
  });
}
