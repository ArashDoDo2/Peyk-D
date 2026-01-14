import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

class DnsTransport {
  final String serverIP;
  final int port;

  DnsTransport(this.serverIP, {this.port = 53});

  Future<void> sendOnly(Uint8List query) async {
    RawDatagramSocket? socket;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.send(query, InternetAddress(serverIP), port);
      // یک وقفه بسیار کوتاه برای اطمینان از خروج پکت از بافر سیستم‌عامل
      await Future.delayed(const Duration(milliseconds: 20));
    } catch (e) {
      // در حالت Debug چاپ شود
    } finally {
      socket?.close();
    }
  }

  Future<Uint8List?> sendAndReceive(Uint8List query, {int timeoutMs = 2500}) async {
    if (query.length < 2) return null;
    
    // استخراج TXID برای تایید اصالت پاسخ
    final txid = (query[0] << 8) | query[1];
    final completer = Completer<Uint8List?>();
    RawDatagramSocket? socket;
    Timer? timeoutTimer;

    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.send(query, InternetAddress(serverIP), port);

      socket.listen(
        (RawSocketEvent event) {
          if (event == RawSocketEvent.read) {
            final datagram = socket?.receive();
            if (datagram != null && datagram.data.length >= 2) {
              final responseId = (datagram.data[0] << 8) | datagram.data[1];
              
              // تایید اینکه این پاسخ مربوط به همین درخواست است
              if (responseId == txid && !completer.isCompleted) {
                timeoutTimer?.cancel();
                completer.complete(datagram.data);
                socket?.close();
              }
            }
          }
        },
        onError: (e) => _safeComplete(completer, null),
        onDone: () => _safeComplete(completer, null),
      );

      // مدیریت تایم‌اوت به صورت دستی برای کنترل دقیق‌تر
      timeoutTimer = Timer(Duration(milliseconds: timeoutMs), () {
        _safeComplete(completer, null);
        socket?.close();
      });

      return await completer.future;
    } catch (e) {
      socket?.close();
      return null;
    }
  }

  void _safeComplete(Completer c, dynamic value) {
    if (!c.isCompleted) c.complete(value);
  }

  // متد کمکی برای تست سلامت مسیر UDP
  Future<bool> pingServer() async {
    // ایجاد یک کوئری ساده A برای دامین اصلی
    final ping = Uint8List.fromList([
      0x12, 0x34, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 
      0x00, 0x00, 0x00, 0x00, 0x01, 0x76, 0x00, 0x00, 0x01, 0x00, 0x01
    ]);
    final res = await sendAndReceive(ping, timeoutMs: 1500);
    return res != null;
  }
}