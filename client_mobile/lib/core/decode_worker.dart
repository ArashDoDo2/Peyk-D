import 'dart:typed_data';
import 'package:base32/base32.dart';
import './crypto.dart';

Future<Map<String, Object>> decodeAndDecrypt(Map<String, Object> args) async {
  final raw = (args["raw"] as String?) ?? "";
  final debug = args["debug"] == true;

  String normalized = raw.toUpperCase().replaceAll(RegExp(r'[^A-Z2-7]'), '');
  while (normalized.length % 8 != 0) {
    normalized += '=';
  }

  final Uint8List decoded = Uint8List.fromList(base32.decode(normalized));
  final decrypted = await PeykCrypto.decrypt(decoded);

  final result = <String, Object>{
    "decrypted": decrypted,
    "decodedLen": decoded.length,
  };
  if (debug) {
    result["normalized"] = normalized;
  }
  return result;
}
