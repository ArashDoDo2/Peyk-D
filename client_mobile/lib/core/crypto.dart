import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';

// ایمپورت فایل پروتکل با آدرس نسبی
import './protocol.dart'; 

class PeykCrypto {
  static final _algorithm = AesGcm.with256bits();

  /// رمزنگاری پیام قبل از ارسال
  static Future<Uint8List> encrypt(String text) async {
    // دسترسی به پسورد از طریق کلاس PeykProtocol
    final keyBytes = (await Sha256().hash(utf8.encode(PeykProtocol.passphrase))).bytes;
    final secretKey = await _algorithm.newSecretKeyFromBytes(keyBytes);
    
    final clearText = utf8.encode(text);
    final secretBox = await _algorithm.encrypt(
      clearText,
      secretKey: secretKey,
    );
    
    final combined = BytesBuilder();
    combined.add(secretBox.nonce);
    combined.add(secretBox.cipherText);
    combined.add(secretBox.mac.bytes);
    
    return combined.toBytes();
  }

  /// رمزگشایی پیام‌های دریافتی
  static Future<String> decrypt(Uint8List encryptedData) async {
    try {
      if (encryptedData.length < 28) {
        return "Error: Payload too short (${encryptedData.length} bytes)";
      }

      // استفاده از SHA256 برای تبدیل پسورد به کلید ۳۲ بایتی
      final hash = await Sha256().hash(utf8.encode(PeykProtocol.passphrase));
      final secretKey = await _algorithm.newSecretKeyFromBytes(hash.bytes);

      // جدا سازی: ۱۲ بایت اول Nonce، ۱۶ بایت آخر MAC
      final nonce = encryptedData.sublist(0, 12);
      final mac = Mac(encryptedData.sublist(encryptedData.length - 16));
      final ciphertext = encryptedData.sublist(12, encryptedData.length - 16);

      final secretBox = SecretBox(ciphertext, nonce: nonce, mac: mac);

      final clearTextBytes = await _algorithm.decrypt(
        secretBox,
        secretKey: secretKey,
      );

      return utf8.decode(clearTextBytes);
    } catch (e) {
      // اگر خطا مربوط به احراز هویت بود، احتمالاً پسورد اشتباه است
      if (e.toString().contains("SecretBoxAuthenticationError")) {
        return "Decryption error: Invalid Passphrase or Corrupted Data";
      }
      return "Decryption error: $e";
    }
  }/// 
}