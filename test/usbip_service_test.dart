import 'package:flutter_test/flutter_test.dart';
import 'package:usbip_unified/services/usbip_service.dart';

void main() {
  final service = UsbIpService();

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
