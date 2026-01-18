import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import './dns_codec.dart';

class DnsTransport {
  final String? serverIP;
  final int port;
  final bool useTcp;

  DnsTransport({this.serverIP, this.port = 53, this.useTcp = false});

  bool get _useDirect => serverIP != null && serverIP!.isNotEmpty;
  bool get _useTcp => _useDirect && useTcp;

  Future<void> sendOnly(String domain, {int qtype = 1}) async {
    if (!_useDirect) {
      await _lookup(domain, qtype: qtype);
      return;
    }

    if (_useTcp) {
      final query = DnsCodec.buildQuery(domain, qtype: qtype);
      await _sendAndReceiveRawTcp(query, timeoutMs: 2500);
      return;
    }

    RawDatagramSocket? socket;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      final query = DnsCodec.buildQuery(domain, qtype: qtype);
      socket.send(query, InternetAddress(serverIP!), port);
      await Future.delayed(const Duration(milliseconds: 20));
    } catch (_) {
      // Best-effort send.
    } finally {
      socket?.close();
    }
  }

  Future<Uint8List?> sendAndReceive(String domain, {int qtype = 28, int timeoutMs = 2500}) async {
    if (!_useDirect) {
      final ips = await _lookup(domain, qtype: qtype, timeoutMs: timeoutMs);
      if (ips == null || ips.isEmpty) return null;
      return _extractPayloadFromIPs(ips);
    }

    final query = DnsCodec.buildQuery(domain, qtype: qtype);
    if (_useTcp) {
      final raw = await _sendAndReceiveRawTcp(query, timeoutMs: timeoutMs);
      if (raw == null) return null;
      return DnsCodec.extractAllBytes(raw);
    }
    final raw = await _sendAndReceiveRaw(query, timeoutMs: timeoutMs);
    if (raw == null) return null;
    return DnsCodec.extractAllBytes(raw);
  }

  Future<bool> pingServer() async {
    if (!_useDirect) return false;
    final ping = Uint8List.fromList([
      0x12, 0x34, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00,
      0x00, 0x00, 0x00, 0x00, 0x01, 0x76, 0x00, 0x00, 0x01, 0x00, 0x01
    ]);
    final res = _useTcp
        ? await _sendAndReceiveRawTcp(ping, timeoutMs: 1500)
        : await _sendAndReceiveRaw(ping, timeoutMs: 1500);
    return res != null;
  }

  Future<Uint8List?> _sendAndReceiveRaw(Uint8List query, {int timeoutMs = 2500}) async {
    if (query.length < 2) return null;

    final txid = (query[0] << 8) | query[1];
    final completer = Completer<Uint8List?>();
    RawDatagramSocket? socket;
    Timer? timeoutTimer;

    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.send(query, InternetAddress(serverIP!), port);

      socket.listen(
        (RawSocketEvent event) {
          if (event == RawSocketEvent.read) {
            final datagram = socket?.receive();
            if (datagram != null && datagram.data.length >= 2) {
              final responseId = (datagram.data[0] << 8) | datagram.data[1];
              if (responseId == txid && !completer.isCompleted) {
                timeoutTimer?.cancel();
                completer.complete(datagram.data);
                socket?.close();
              }
            }
          }
        },
        onError: (_) => _safeComplete(completer, null),
        onDone: () => _safeComplete(completer, null),
      );

      timeoutTimer = Timer(Duration(milliseconds: timeoutMs), () {
        _safeComplete(completer, null);
        socket?.close();
      });

      return await completer.future;
    } catch (_) {
      socket?.close();
      return null;
    }
  }

  Future<Uint8List?> _sendAndReceiveRawTcp(Uint8List query, {int timeoutMs = 2500}) async {
    if (query.length < 2) return null;
    Socket? socket;
    StreamSubscription<List<int>>? sub;
    Timer? timeoutTimer;
    final completer = Completer<Uint8List?>();
    final buffer = BytesBuilder();
    int? expectedLen;

    void finish(Uint8List? data) {
      if (completer.isCompleted) return;
      timeoutTimer?.cancel();
      sub?.cancel();
      socket?.destroy();
      completer.complete(data);
    }

    try {
      socket = await Socket.connect(
        serverIP!,
        port,
        timeout: Duration(milliseconds: timeoutMs),
      );
    } catch (_) {
      return null;
    }

    timeoutTimer = Timer(Duration(milliseconds: timeoutMs), () => finish(null));
    sub = socket.listen(
      (data) {
        buffer.add(data);
        final bytes = buffer.toBytes();
        if (expectedLen == null && bytes.length >= 2) {
          expectedLen = (bytes[0] << 8) | bytes[1];
        }
        if (expectedLen != null && bytes.length >= expectedLen! + 2) {
          finish(Uint8List.fromList(bytes.sublist(2, 2 + expectedLen!)));
        }
      },
      onError: (_) => finish(null),
      onDone: () => finish(null),
    );

    final lenBuf = Uint8List(2);
    lenBuf[0] = (query.length >> 8) & 0xff;
    lenBuf[1] = query.length & 0xff;
    socket.add(lenBuf);
    socket.add(query);
    await socket.flush();

    return completer.future;
  }

  void _safeComplete(Completer c, dynamic value) {
    if (!c.isCompleted) c.complete(value);
  }

  Future<List<InternetAddress>?> _lookup(String domain, {int qtype = 1, int timeoutMs = 2500}) async {
    try {
      final type = qtype == 28 ? InternetAddressType.IPv6 : InternetAddressType.IPv4;
      return await InternetAddress.lookup(domain, type: type).timeout(Duration(milliseconds: timeoutMs));
    } catch (_) {
      return null;
    }
  }

  Uint8List _extractPayloadFromIPs(List<InternetAddress> ips) {
    final legacy = BytesBuilder();
    final Map<int, Uint8List> indexedParts = {};
    bool hasIndex0 = false;

    for (final ip in ips) {
      final raw = ip.rawAddress;
      legacy.add(raw);
      if (raw.length >= 2 && raw[0] > 0) {
        final idx = raw[0] - 1;
        if (!indexedParts.containsKey(idx)) {
          indexedParts[idx] = Uint8List.fromList(raw.sublist(1));
          if (idx == 0) hasIndex0 = true;
        }
      }
    }

    Uint8List bytes;
    if (indexedParts.isNotEmpty && hasIndex0) {
      final ordered = indexedParts.keys.toList()..sort();
      final rebuilt = BytesBuilder();
      for (final idx in ordered) {
        rebuilt.add(indexedParts[idx]!);
      }
      bytes = rebuilt.toBytes();
    } else {
      bytes = legacy.toBytes();
    }

    int end = bytes.length;
    while (end > 0 && bytes[end - 1] == 0) {
      end--;
    }
    return Uint8List.fromList(bytes.sublist(0, end));
  }
}
