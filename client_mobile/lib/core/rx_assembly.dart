class RxAssembly {
  final String sid;
  final int total;
  final Map<int, String> _parts = {};
  DateTime lastUpdate = DateTime.now();

  RxAssembly(this.sid, this.total);

  void addPart(int idx, String payload) {
    _parts[idx] = payload;
    lastUpdate = DateTime.now();
  }

  // چک کردن دقیق تعداد تکه‌ها
  bool get isComplete => _parts.length == total;

  String assemble() {
    final sb = StringBuffer();
    // پیدا کردن کوچکترین ایندکس (ممکن است فرستنده از 0 شروع کرده باشد یا 1)
    int startIdx = _parts.keys.reduce((a, b) => a < b ? a : b);
    
    for (int i = startIdx; i < startIdx + total; i++) {
      if (_parts.containsKey(i)) {
        sb.write(_parts[i]);
      }
    }
    return sb.toString();
  }
}