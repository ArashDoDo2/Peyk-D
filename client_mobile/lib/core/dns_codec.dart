import 'dart:convert';
import 'dart:typed_data';
import 'dart:math';

class DnsCodec {
  /// ساخت کوئری DNS برای انواع تایپ‌ها (A=1, TXT=16, AAAA=28)
  static Uint8List buildQuery(
    String domain, {
    int qtype = 1,
  }) {
    final rnd = Random.secure();
    final fb = BytesBuilder();

    // Transaction ID (2 bytes)
    fb.addByte(rnd.nextInt(256));
    fb.addByte(rnd.nextInt(256));

    // Flags: Standard query, recursion desired (0x0100)
    fb.add([0x01, 0x00]);

    // Questions: 1, Answer RRs: 0, Authority RRs: 0, Additional RRs: 0
    fb.add([0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]);

    // QNAME
    for (final label in domain.split('.')) {
      if (label.isEmpty) continue;
      fb.addByte(label.length);
      fb.add(label.codeUnits);
    }
    fb.addByte(0x00);

    // QTYPE
    fb.addByte((qtype >> 8) & 0xff);
    fb.addByte(qtype & 0xff);

    // QCLASS: IN
    fb.add([0x00, 0x01]);

    return fb.toBytes();
  }

  /// Decode امن برای payload متنی (TXT یا بایت‌های A/AAAA)
  static String decodeBytesPayload(Uint8List raw) {
    final s = utf8.decode(raw, allowMalformed: true);
    // فقط null-byte های انتهایی حذف می‌شوند
    int end = s.length;
    while (end > 0 && s.codeUnitAt(end - 1) == 0) {
      end--;
    }
    return s.substring(0, end).trim();
  }

  /// استخراج payload از **اولین Answer** (خیلی مهم)
  static Uint8List extractAllBytes(Uint8List data) {
    try {
      if (data.length < 12) return Uint8List(0);

      // ANCOUNT
      final ancount = (data[6] << 8) | data[7];
      if (ancount == 0) return Uint8List(0);

      int i = 12;

      // Skip Question
      while (i < data.length && data[i] != 0) {
        if ((data[i] & 0xC0) == 0xC0) {
          i += 2;
          break;
        } else {
          i += data[i] + 1;
        }
      }
      if (i < data.length && data[i] == 0) i++;
      i += 4; // QTYPE + QCLASS

      final out = BytesBuilder();

      int skipName(int offset) {
        if (offset >= data.length) return data.length;
        if ((data[offset] & 0xC0) == 0xC0) {
          return offset + 2;
        }
        while (offset < data.length && data[offset] != 0) {
          offset += data[offset] + 1;
        }
        if (offset < data.length && data[offset] == 0) offset++;
        return offset;
      }

      // Parse all answers (payload may be split across multiple A/AAAA RRs)
      for (int a = 0; a < ancount; a++) {
        if (i + 10 > data.length) break;

        i = skipName(i);
        if (i + 10 > data.length) break;

        final type = (data[i] << 8) | data[i + 1];
        i += 8; // TYPE + CLASS + TTL

        final rdLen = (data[i] << 8) | data[i + 1];
        i += 2;

        if (i + rdLen > data.length) break;

        if (type == 1 || type == 28) {
          out.add(data.sublist(i, i + rdLen));
        } else if (type == 16) {
          int j = i;
          while (j < i + rdLen) {
            final len = data[j++];
            if (j + len <= i + rdLen) {
              out.add(data.sublist(j, j + len));
            }
            j += len;
          }
        }

        i += rdLen;
      }

      return out.toBytes();
    } catch (_) {
      // silent parse failure
    }

    return Uint8List(0);
  }
}
