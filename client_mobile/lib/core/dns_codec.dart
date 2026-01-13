import 'dart:convert';
import 'dart:typed_data';
import 'dart:math';

class DnsCodec {
  static Uint8List buildQuery(
    String domain, {
    int qtype = 1, // default = A
  }) {
    final rnd = Random.secure();
    final fb = BytesBuilder();

    // TXID
    fb.addByte(rnd.nextInt(256));
    fb.addByte(rnd.nextInt(256));

    // Flags: standard query
    fb.add([0x01, 0x00]);

    // QDCOUNT = 1
    fb.add([0x00, 0x01]);

    // ANCOUNT, NSCOUNT, ARCOUNT
    fb.add([0x00, 0x00, 0x00, 0x00, 0x00, 0x00]);

    // QNAME
    for (final label in domain.split('.')) {
      if (label.isEmpty) continue;
      fb.addByte(label.length);
      fb.add(label.codeUnits);
    }
    fb.addByte(0x00);

    // QTYPE (🔴 این خیلی مهمه)
    fb.addByte((qtype >> 8) & 0xff);
    fb.addByte(qtype & 0xff);

    // QCLASS = IN
    fb.add([0x00, 0x01]);

    return fb.toBytes();
  }

  static String? extractTxt(Uint8List data) {
    try {
      // Logic for skipping Header & Question
      int i = 12; 
      while (i < data.length && data[i] != 0) { i += data[i] + 1; }
      i += 5; // Question end

      while (i + 10 < data.length) {
        if ((data[i] & 0xC0) == 0xC0) i += 2; else { 
          while (i < data.length && data[i] != 0) { i += data[i] + 1; } i++;
        }
        final type = (data[i] << 8) | data[i + 1];
        i += 8; // skip Type, Class, TTL
        final rdLen = (data[i] << 8) | data[i + 1];
        i += 2;
        if (type == 16) { // TXT Record
          final out = BytesBuilder();
          int j = i;
          while (j < i + rdLen) {
            int l = data[j++];
            out.add(data.sublist(j, j + l));
            j += l;
          }
          return utf8.decode(out.toBytes()).trim();
        }
        i += rdLen;
      }
    } catch (_) {}
    return null;
  }
}









