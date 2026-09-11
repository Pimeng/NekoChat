import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:logging/logging.dart';

import '../config/network_config.dart';
import '../models/models.dart';
import '../protocol/protocol.dart';

typedef TrustLookup = TrustedPeer? Function(String deviceId);
typedef NetworkInterfacesProvider = Future<List<NetworkInterface>> Function();

class _InterfaceSender {
  const _InterfaceSender({required this.address, required this.socket});
  final InternetAddress address;
  final RawDatagramSocket socket;
}

class DiscoveryService {
  DiscoveryService({
    required this.identity,
    required this.trustLookup,
    required this.onPeersChanged,
    NetworkInterfacesProvider? interfacesProvider,
    this.multicastLoopback = false,
  }) : _interfacesProvider =
           interfacesProvider ??
           (() => NetworkInterface.list(
             type: InternetAddressType.IPv4,
             includeLoopback: false,
             includeLinkLocal: false,
           ));

  final LocalIdentity identity;
  final TrustLookup trustLookup;
  final void Function(List<DiscoveredPeer> peers) onPeersChanged;
  final NetworkInterfacesProvider _interfacesProvider;
  final bool multicastLoopback;
  final _log = Logger('DiscoveryService');
  final Map<String, DiscoveredPeer> _peers = {};
  final List<_InterfaceSender> _senders = [];
  RawDatagramSocket? _receiver;
  StreamSubscription<RawSocketEvent>? _receiverSubscription;
  Timer? _announceTimer;
  Timer? _expiryTimer;

  List<DiscoveredPeer> get peers => _peers.values.toList(growable: false);

  Future<void> start() async {
    if (_receiver != null) return;
    final receiver = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      NetworkConfig.discoveryPort,
      reuseAddress: true,
    );
    _receiver = receiver;
    receiver.broadcastEnabled = true;
    receiver.multicastHops = 1;
    receiver.multicastLoopback = multicastLoopback;

    final interfaces = await _interfacesProvider();
    final multicastAddress = InternetAddress(NetworkConfig.multicastGroup);
    for (final interface in interfaces) {
      final addresses = interface.addresses
          .where((address) => address.type == InternetAddressType.IPv4)
          .toList();
      if (addresses.isEmpty) continue;
      try {
        receiver.joinMulticast(multicastAddress, interface);
        _log.info(
          '发现接收器已加入网卡 ${interface.name}(${addresses.map((value) => value.address).join(', ')})',
        );
      } on Object catch (error, stack) {
        _log.warning('网卡 ${interface.name} 加入组播失败，仍会尝试广播', error, stack);
      }

      for (final address in addresses) {
        try {
          final sender = await RawDatagramSocket.bind(address, 0);
          sender.broadcastEnabled = true;
          sender.multicastHops = 1;
          sender.multicastLoopback = multicastLoopback;
          _senders.add(_InterfaceSender(address: address, socket: sender));
          _log.info('发现公告将从 ${address.address} 发送');
        } on Object catch (error, stack) {
          _log.warning('无法为 ${address.address} 创建发现发送器', error, stack);
        }
      }
    }

    // Some restricted adapters are not returned by NetworkInterface.list.
    // Keeping this fallback is preferable to disabling discovery completely.
    if (_senders.isEmpty) {
      try {
        receiver.joinMulticast(multicastAddress);
      } on Object catch (error, stack) {
        _log.warning('默认网卡加入组播失败', error, stack);
      }
      _log.warning('未找到可用 IPv4 网卡，将使用系统默认路由发送发现公告');
    }

    _receiverSubscription = receiver.listen(
      _onSocketEvent,
      onError: (Object error, StackTrace stack) {
        _log.warning('发现 Socket 异常', error, stack);
      },
    );
    _announceTimer = Timer.periodic(
      NetworkConfig.announceInterval,
      (_) => _announce(),
    );
    _expiryTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _expirePeers(),
    );
    _announce();
  }

  void _announce() {
    final receiver = _receiver;
    if (receiver == null) return;
    final bytes = utf8.encode(
      ProtocolCodec.encode(
        ProtocolEnvelope(
          type: MessageType.announce,
          payload: {
            'deviceId': identity.deviceId,
            'displayName': identity.displayName,
            'port': NetworkConfig.chatPort,
          },
        ),
      ),
    );

    if (_senders.isEmpty) {
      _sendFromSocket(receiver, bytes, sourceAddress: null);
      return;
    }
    for (final sender in _senders) {
      _sendFromSocket(sender.socket, bytes, sourceAddress: sender.address);
    }
  }

  void _sendFromSocket(
    RawDatagramSocket socket,
    List<int> bytes, {
    required InternetAddress? sourceAddress,
  }) {
    final destinations = <InternetAddress>{
      InternetAddress(NetworkConfig.multicastGroup),
      InternetAddress('255.255.255.255'),
      if (sourceAddress != null) classCBroadcastAddress(sourceAddress),
    };
    for (final destination in destinations) {
      try {
        socket.send(bytes, destination, NetworkConfig.discoveryPort);
      } on Object catch (error, stack) {
        _log.fine(
          '从 ${sourceAddress?.address ?? '默认网卡'} 向 ${destination.address} 发送发现公告失败',
          error,
          stack,
        );
      }
    }
  }

  void _onSocketEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    Datagram? datagram;
    while ((datagram = _receiver?.receive()) != null) {
      try {
        final envelope = ProtocolCodec.decode(utf8.decode(datagram!.data));
        if (envelope?.type != MessageType.announce) continue;
        final payload = envelope!.payload;
        final deviceId = payload['deviceId'];
        final displayName = payload['displayName'];
        final port = payload['port'];
        if (deviceId is! String ||
            deviceId.isEmpty ||
            displayName is! String ||
            displayName.isEmpty ||
            port is! int ||
            port < 1 ||
            port > 65535) {
          continue;
        }
        if (deviceId == identity.deviceId) continue;
        final observedIp = datagram.address.address;
        final trusted = trustLookup(deviceId);
        final existing = _peers[deviceId];
        final duplicateIdentity =
            existing != null &&
            existing.online &&
            existing.ip != observedIp &&
            DateTime.now().difference(existing.lastSeen) <=
                NetworkConfig.offlineTimeout;
        if (duplicateIdentity) {
          _log.warning(
            '同一 deviceId=$deviceId 同时从 ${existing.ip} 和 $observedIp 出现',
          );
        }
        final peer = DiscoveredPeer(
          deviceId: deviceId,
          displayName: displayName,
          ip: observedIp,
          port: port,
          lastSeen: DateTime.now(),
          trusted: trusted != null && !trusted.blocked,
          online: true,
          locationChanged:
              duplicateIdentity ||
              (trusted != null && trusted.lastKnownIp != observedIp),
        );
        _peers[deviceId] = peer;
        if (existing == null ||
            existing.ip != peer.ip ||
            existing.displayName != peer.displayName ||
            !existing.online) {
          _log.info('发现设备 ${peer.deviceId} @ $observedIp:${peer.port}');
        }
        _notify();
      } on Object catch (error, stack) {
        _log.fine('忽略无效发现包', error, stack);
      }
    }
  }

  void _expirePeers() {
    final now = DateTime.now();
    var changed = false;
    for (final entry in _peers.entries.toList()) {
      if (entry.value.online &&
          now.difference(entry.value.lastSeen) > NetworkConfig.offlineTimeout) {
        _peers[entry.key] = entry.value.copyWith(online: false);
        changed = true;
        _log.info('设备离线 ${entry.key}');
      }
    }
    if (changed) _notify();
  }

  void refreshTrust() {
    for (final entry in _peers.entries.toList()) {
      final trusted = trustLookup(entry.key);
      _peers[entry.key] = entry.value.copyWith(
        trusted: trusted != null && !trusted.blocked,
      );
    }
    _notify();
  }

  void _notify() {
    final sorted = peers
      ..sort((a, b) {
        if (a.online != b.online) return a.online ? -1 : 1;
        return a.displayName.compareTo(b.displayName);
      });
    onPeersChanged(sorted);
  }

  Future<void> stop() async {
    _announceTimer?.cancel();
    _expiryTimer?.cancel();
    _announceTimer = null;
    _expiryTimer = null;
    await _receiverSubscription?.cancel();
    _receiverSubscription = null;
    _receiver?.close();
    _receiver = null;
    for (final sender in _senders) {
      sender.socket.close();
    }
    _senders.clear();
    _peers.clear();
  }
}

/// Directed /24 broadcast is a compatibility fallback for common classroom
/// networks. Multicast remains the primary discovery mechanism.
InternetAddress classCBroadcastAddress(InternetAddress address) {
  if (address.type != InternetAddressType.IPv4 ||
      address.rawAddress.length != 4) {
    throw ArgumentError.value(address, 'address', '必须是 IPv4 地址');
  }
  final bytes = Uint8List.fromList(address.rawAddress)..[3] = 255;
  return InternetAddress.fromRawAddress(bytes);
}
