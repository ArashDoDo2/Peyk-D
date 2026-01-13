import 'dart:math';

class IdUtils {
  static String generateRandomID() {
    const chars = 'abcdefghijklmnopqrstuvwxyz234567';
    final rnd = Random.secure();
    return List.generate(5, (_) => chars[rnd.nextInt(chars.length)]).join();
  }

  static bool isValid(String id) {
    return RegExp(r'^[a-z2-7]{5}$').hasMatch(id);
  }
}