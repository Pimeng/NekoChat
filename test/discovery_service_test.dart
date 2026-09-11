import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neko_chat/core/models/models.dart';
import 'package:neko_chat/core/networking/discovery_service.dart';

void main() {
  test('每个 IPv4 网卡可生成对应的 /24 定向广播地址', () {
    expect(
      classCBroadcastAddress(InternetAddress('192.168.10.23')).address,
      '192.168.10.255',
    );
    expect(
      classCBroadcastAddress(InternetAddress('10.20.30.40')).address,
      '10.20.30.255',
    );
  });

  test('定向广播地址拒绝 IPv6', () {
    expect(
      () => classCBroadcastAddress(InternetAddress('::1')),
      throwsArgumentError,
    );
  });

  test('两个发现服务可通过指定网卡互相发现', () async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: true,
      includeLinkLocal: true,
    );
    final loopback = interfaces.where(
      (interface) => interface.addresses.any((address) => address.isLoopback),
    );
    if (loopback.isEmpty) return;
    final interface = loopback.first;
    final now = DateTime.now();
    final foundA = <DiscoveredPeer>[];
    final foundB = <DiscoveredPeer>[];
    final a = DiscoveryService(
      identity: LocalIdentity(
        deviceId: 'discovery-a',
        displayName: 'A',
        createdAt: now,
        lastLoginAt: now,
      ),
      trustLookup: (_) => null,
      onPeersChanged: foundA.addAll,
      interfacesProvider: () async => [interface],
      multicastLoopback: true,
    );
    final b = DiscoveryService(
      identity: LocalIdentity(
        deviceId: 'discovery-b',
        displayName: 'B',
        createdAt: now,
        lastLoginAt: now,
      ),
      trustLookup: (_) => null,
      onPeersChanged: foundB.addAll,
      interfacesProvider: () async => [interface],
      multicastLoopback: true,
    );
    addTearDown(a.stop);
    addTearDown(b.stop);

    await a.start();
    await b.start();
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while ((foundA.isEmpty || foundB.isEmpty) &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }

    expect(foundA.any((peer) => peer.deviceId == 'discovery-b'), isTrue);
    expect(foundB.any((peer) => peer.deviceId == 'discovery-a'), isTrue);
  });
}
