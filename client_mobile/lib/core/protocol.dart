class PeykProtocol {
  static const String baseDomain = String.fromEnvironment('PEYK_DOMAIN', defaultValue: '');
  
  // این پسورد باید بین فرستنده و گیرنده یکی باشد
  static const String passphrase = String.fromEnvironment('PEYK_PASSPHRASE', defaultValue: '');
  
  // آی‌پی پیش‌فرض سرور (اگر در تنظیمات ست نشده باشد)
  static const String defaultServerIP = String.fromEnvironment('PEYK_DIRECT_SERVER_IP', defaultValue: '');

    // DNS QTYPEs
  static const int qtypeA = 1;
  static const int qtypeTXT = 16;
  static const int qtypeAAAA = 28;

  // متد کمکی برای چک کردن فرمت آی‌دی (۵ کاراکتر a-z یا ۲-۷)
  static bool isValidID(String id) {
    return RegExp(r'^[a-z2-7]{5}$').hasMatch(id);
  }
}