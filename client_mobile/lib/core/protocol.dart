class PeykProtocol {
  static const String baseDomain = "p99.online.ir";
  
  // این پسورد باید بین فرستنده و گیرنده یکی باشد
  static const String passphrase = "my-fixed-passphrase-change-me";
  
  // آی‌پی پیش‌فرض سرور (اگر در تنظیمات ست نشده باشد)
  static const String defaultServerIP = "188.209.155.2";

    // DNS QTYPEs
  static const int qtypeA = 1;
  static const int qtypeTXT = 16;

  // متد کمکی برای چک کردن فرمت آی‌دی (۵ کاراکتر a-z یا ۲-۷)
  static bool isValidID(String id) {
    return RegExp(r'^[a-z2-7]{5}$').hasMatch(id);
  }
}