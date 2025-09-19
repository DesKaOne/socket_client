import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';
import 'package:socket_client/socket_client.dart';

Future<void> main() async {
  final ws = await CustomWebsocket.connect(
    Uri.parse('wss://echo.websocket.org'),
    proxies: [
      ProxyConfig(host: '127.0.0.1', port: 1080, type: ProxyType.SOCKS5),
    ],
    proxyMode: ProxyMode.NONE, // pakai proxy pertama
    protocols: ['chat', 'superchat'],
    compress: true,
  );

  // kirim & terima
  ws.add('hello via proxy socks!');
  final sub = ws.listen((data) => print('recv: $data'));
  await Future.delayed(Duration(seconds: 2));
  await ws.close(1000, 'bye');
  await sub.cancel();

  print('');

  final host = 'httpbin.org';
  final raw = await CustomSocket.connect(
    host,
    443,
    proxies: [
      ProxyConfig(host: '127.0.0.1', port: 1080, type: ProxyType.SOCKS5),
    ],
  );
  late CustomSecureSocket secure;
  try {
    // Matikan Nagle (opsional, gak semua platform support)
    try {
      raw.setOption(SocketOption.tcpNoDelay, true);
    } catch (_) {}

    secure = await CustomSecureSocket.secure(raw, host: host);

    // Kirim request
    final req = StringBuffer()
      ..writeln('GET /ip HTTP/1.1')
      ..writeln('Host: $host')
      ..writeln('Accept: */*')
      ..writeln('Accept-Encoding: gzip') // minta gzip
      ..writeln('Connection: close') // biar gampang demo parsing
      ..writeln();
    secure.write(req.toString());
    await secure.flush(); // eksplisit flush

    // Ambil seluruh response (blocking sederhana untuk demo)
    final bytes = await _readHttpResponse(
      secure,
    ).timeout(const Duration(seconds: 15));

    // Tampilkan hasil
    print(bytes.$1); // status line
    print(bytes.$2.entries.map((e) => '${e.key}: ${e.value}').join('\n'));
    print('');
    print(utf8.decode(bytes.$3, allowMalformed: true));
  } finally {
    try {
      await raw.close();
      await secure.close();
    } catch (_) {}
  }
}

/// Return (statusLine, headers, bodyBytes)
Future<(String, Map<String, String>, Uint8List)> _readHttpResponse(
  SecureSocket sock,
) async {
  // 1) Baca header sampai \r\n\r\n
  final headerBytes = BytesBuilder();
  final crlfcrlf = ascii.encode('\r\n\r\n');
  final buf = <int>[];
  await for (final chunk in sock) {
    headerBytes.add(chunk);
    final hb = headerBytes.toBytes();
    final idx = _indexOf(hb, crlfcrlf);
    if (idx >= 0) {
      // header complete
      final hdrPart = hb.sublist(0, idx + 4);
      final bodyRemainder = hb.sublist(idx + 4);
      buf.addAll(bodyRemainder);
      // parse headers
      final headerText = ascii.decode(hdrPart);
      final lines = headerText.split('\r\n');
      final statusLine = lines.first;
      final headers = <String, String>{};
      for (var i = 1; i < lines.length; i++) {
        final line = lines[i];
        if (line.isEmpty) continue;
        final sep = line.indexOf(':');
        if (sep > 0) {
          final name = line.substring(0, sep).trim();
          final value = line.substring(sep + 1).trim();
          headers[name.toLowerCase()] = value;
        }
      }

      // 2) Baca body
      Uint8List body;
      final te = headers['transfer-encoding']?.toLowerCase();
      if (te == 'chunked') {
        body = await _readChunked(
          sock,
          initialRemainder: Uint8List.fromList(buf),
        );
      } else {
        final clenStr = headers['content-length'];
        if (clenStr != null) {
          final clen = int.tryParse(clenStr) ?? 0;
          body = await _readExact(sock, clen, initial: Uint8List.fromList(buf));
        } else {
          // fallback: baca sampai socket ditutup (Connection: close)
          final bb = BytesBuilder()..add(buf);
          await for (final more in sock) {
            bb.add(more);
          }
          body = bb.toBytes();
        }
      }

      // 3) decompress kalau gzip
      final ce = headers['content-encoding']?.toLowerCase();
      if (ce == 'gzip') {
        body = Uint8List.fromList(gzip.decode(body));
      }

      return (statusLine, headers, body);
    }
  }
  throw const FormatException('EOF sebelum header lengkap');
}

Future<Uint8List> _readExact(
  Stream<List<int>> stream,
  int n, {
  Uint8List? initial,
}) async {
  final out = BytesBuilder();
  var have = 0;

  if (initial != null && initial.isNotEmpty) {
    final take = initial.length > n ? n : initial.length;
    out.add(initial.sublist(0, take));
    have += take;
    if (initial.length > take) {
      // sisanya taruh buffer untuk berikutnya
      // Tapi di desain simpel ini kita asumsikan initial <= n
    }
    if (have >= n) return out.toBytes();
  }

  await for (final chunk in stream) {
    final remain = n - have;
    if (chunk.length >= remain) {
      out.add(chunk.sublist(0, remain));
      have += remain;
      // sisanya akan “terbaca” oleh caller berikutnya — untuk demo kita stop di sini
      break;
    } else {
      out.add(chunk);
      have += chunk.length;
    }
    if (have >= n) break;
  }
  if (have != n) throw const FormatException('EOF saat readExact');
  return out.toBytes();
}

Future<Uint8List> _readChunked(
  Stream<List<int>> stream, {
  required Uint8List initialRemainder,
}) async {
  final bb = BytesBuilder();
  var buf = initialRemainder;

  // helper baca satu baris CRLF
  Future<String> readLine() async {
    // cari CRLF di buf; kalau belum ada, baca dari stream
    while (true) {
      final idx = _indexOf(buf, ascii.encode('\r\n'));
      if (idx >= 0) {
        final line = ascii.decode(buf.sublist(0, idx));
        buf = buf.sublist(idx + 2);
        return line;
      }
      final next = await stream.first; // blocking-ish: cukup buat demo
      buf = Uint8List.fromList([...buf, ...next]);
    }
  }

  // baca chunk sampe 0
  while (true) {
    final sizeLine = (await readLine()).trim();
    final semicolon = sizeLine.indexOf(';'); // ignore extensions
    final sizeHex = semicolon >= 0
        ? sizeLine.substring(0, semicolon)
        : sizeLine;
    final size = int.parse(sizeHex, radix: 16);
    if (size == 0) {
      // baca trailing headers sampai CRLF kosong
      // (opsional, untuk demo kita sikat dua CRLF jika ada)
      // konsumsi CRLF setelah size=0 (sudah dikonsumsi di readLine berikutnya)
      // Baca CRLF final:
      // Ada kemungkinan masih ada header trailing; sederhananya:
      // buang sampai ketemu CRLFCRLF atau end.
      // Untuk demo ringkas: coba baca satu baris kosong
      final trailing = await readLine();
      if (trailing.isNotEmpty) {
        // ada trailing header lain -> konsumsi sampai kosong
        while (true) {
          final l = await readLine();
          if (l.isEmpty) break;
        }
      }
      break;
    }

    // pastikan buf punya minimal `size` byte, kalau kurang baca stream
    while (buf.length < size) {
      final next = await stream.first;
      buf = Uint8List.fromList([...buf, ...next]);
    }
    bb.add(buf.sublist(0, size));
    buf = buf.sublist(size);

    // konsumsi CRLF setelah payload chunk
    if (buf.length < 2) {
      final next = await stream.first;
      buf = Uint8List.fromList([...buf, ...next]);
    }
    if (!(buf[0] == 13 && buf[1] == 10)) {
      throw const FormatException('Format chunked invalid (CRLF missing)');
    }
    buf = buf.sublist(2);
  }

  return bb.toBytes();
}

int _indexOf(Uint8List data, List<int> pattern) {
  // naive search (cukup untuk header kecil)
  for (int i = 0; i <= data.length - pattern.length; i++) {
    var ok = true;
    for (int j = 0; j < pattern.length; j++) {
      if (data[i + j] != pattern[j]) {
        ok = false;
        break;
      }
    }
    if (ok) return i;
  }
  return -1;
}
