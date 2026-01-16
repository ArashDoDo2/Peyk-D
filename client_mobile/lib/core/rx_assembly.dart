enum AddFrameResult { added, duplicate, reset, rejected }

class RxAssembly {
  final String sid;
  final int total;
  final Map<int, String> _parts = {};
  DateTime lastUpdate = DateTime.now();

  RxAssembly(this.sid, this.total);

  /// فریم کامل:
  /// idx-tot-sid-rid-payload
  AddFrameResult addFrame(String frame) {
    final parts = frame.split('-');
    if (parts.length < 5) return AddFrameResult.rejected;

    final idx = int.tryParse(parts[0]);
    final tot = int.tryParse(parts[1]);
    final frameSid = parts[2];
    // parts[3] = rid (receiver id)
    final data = parts.sublist(4).join('-');

    if (idx == null || tot == null) return AddFrameResult.rejected;
    if (tot != total) return AddFrameResult.rejected;
    if (frameSid != sid) return AddFrameResult.rejected;
    if (idx < 1 || idx > total) return AddFrameResult.rejected;
    if (data.isEmpty) return AddFrameResult.rejected;

    if (_parts.containsKey(idx)) {
      if (_parts[idx] == data) return AddFrameResult.duplicate;
      _parts.clear();
      _parts[idx] = data;
      lastUpdate = DateTime.now();
      return AddFrameResult.reset;
    }

    _parts[idx] = data;
    lastUpdate = DateTime.now();
    return AddFrameResult.added;
  }

  bool get isComplete => _parts.length == total;
  int get receivedCount => _parts.length;

  String assemble() {
    final sb = StringBuffer();
    for (int i = 1; i <= total; i++) {
      sb.write(_parts[i] ?? "");
    }
    return sb.toString();
  }
}
