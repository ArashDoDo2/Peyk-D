import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

class DnsTransport {
  final String serverIP;
  final int port;

  DnsTransport(this.serverIP, {this.port = 53});

  /// ارسال پکت بدون انتظار برای پاسخ (Fire-and-Forget)
  /// مناسب برای ارسال chunk و ACK2
  Future<void> sendOnly(Uint8List query) async {
    RawDatagramSocket? socket;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.send(query, InternetAddress(serverIP), port);
      await Future.delayed(const Duration(milliseconds: 10));
    } catch (e) {
      print("❌ UDP Send Error: $e");
    } finally {
      socket?.close();
    }
  }

  /// ارسال پکت و انتظار برای پاسخ سرور (Polling / TXT / ACK2)
  Future<Uint8List?> sendAndWait(
    Uint8List query, {
    int timeoutMs = 2000,
  }) async {
    final completer = Completer<Uint8List?>();
    RawDatagramSocket? socket;

    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.send(query, InternetAddress(serverIP), port);

      socket.listen(
        (RawSocketEvent event) {
          if (event == RawSocketEvent.read) {
            final datagram = socket?.receive();
            if (datagram != null && !completer.isCompleted) {
              completer.complete(datagram.data);
              socket?.close(); // بستن بعد از اولین پاسخ
            }
          }
        },
        onError: (_) {
          if (!completer.isCompleted) completer.complete(null);
        },
        onDone: () {
          if (!completer.isCompleted) completer.complete(null);
        },
      );

      return await completer.future.timeout(
        Duration(milliseconds: timeoutMs),
        onTimeout: () => null,
      );
    } catch (e) {
      print("❌ Transport Error: $e");
      return null;
    } finally {
      socket?.close();
    }
  }

  /// Alias برای سازگاری با chat_screen.dart
  /// (کدت از این متد استفاده می‌کند)
  Future<Uint8List?> sendAndReceive(
    Uint8List query, {
    int timeoutMs = 2000,
  }) {
    return sendAndWait(query, timeoutMs: timeoutMs);
  }

  /// تست ساده اتصال به سرور DNS
  Future<bool> pingServer() async {
    final pingQuery = Uint8List.fromList([
      0xAA, 0xBB, // TX ID
      0x01, 0x00, // Flags
      0x00, 0x01, // QDCount
      0x00, 0x00, // AN
      0x00, 0x00, // NS
      0x00, 0x00, // AR
      0x04, 0x70, 0x69, 0x6e, 0x67, // "ping"
      0x00,
      0x00, 0x01, // QTYPE A
      0x00, 0x01, // QCLASS IN
    ]);

    final response = await sendAndWait(pingQuery, timeoutMs: 1500);
    return response != null;
  }
}
