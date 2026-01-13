import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'protocol.dart'; // این خط برای حل اروری که فرستادی حیاتی است

class PeykCrypto {
  static final algorithm = AesGcm.with256bits();

  static Future<Uint8List> encrypt(String text) async {
    final hash = await Sha256().hash(utf8.encode(PeykProtocol.passphrase));
    final secretKey = SecretKey(hash.bytes);
    
    final secretBox = await algorithm.encrypt(
      utf8.encode(text),
      secretKey: secretKey,
    );
    // خروجی شامل: Nonce (12) + CipherText + Mac (16)
    return Uint8List.fromList(secretBox.concatenation());
  }

  static Future<String> decrypt(Uint8List encryptedBytes) async {
    final hash = await Sha256().hash(utf8.encode(PeykProtocol.passphrase));
    final secretKey = SecretKey(hash.bytes);

    // ۱. جدا کردن ۱۲ بایت اول به عنوان Nonce
    final nonce = encryptedBytes.sublist(0, 12);
    
    // ۲. جدا کردن ۱۶ بایت آخر به عنوان MAC (تگ)
    // این دقیقاً جایی است که با سمیلاتور Go هماهنگ می‌شود
    final macBytes = encryptedBytes.sublist(encryptedBytes.length - 16);
    
    // ۳. هر آنچه بین این دو مانده، متن رمز شده (CipherText) است
    final ciphertext = encryptedBytes.sublist(12, encryptedBytes.length - 16);

    final secretBox = SecretBox(
      ciphertext,
      nonce: nonce,
      mac: Mac(macBytes),
    );

    final clearText = await algorithm.decrypt(
      secretBox,
      secretKey: secretKey,
    );
    
    return utf8.decode(clearText);
  }
}