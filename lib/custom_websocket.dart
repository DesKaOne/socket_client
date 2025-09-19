import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http_client/http_client.dart';

import 'custom_secure_socket.dart';
import 'custom_socket.dart';

class CustomWebsocket extends WebSocket {
  late final WebSocket _ws;

  CustomWebsocket._(this._ws);

  /// Koneksikan WebSocket lewat proxy (HTTP/SOCKS5), termasuk chain/rotator.
  /// - [uri] ws:// atau wss://
  /// - [proxies]/[proxyMode] mengikuti engine CustomSocket
  /// - [headers]/[protocols] opsional
  /// - [compress] minta permessage-deflate (akan dinego)
  static Future<CustomWebsocket> connect(
    Uri uri, {
    List<ProxyConfig> proxies = const [],
    ProxyMode proxyMode = ProxyMode.NONE,
    Map<String, dynamic /*String|List<String>*/>? headers,
    List<String>? protocols,
    bool compress = true,
    Duration timeout = const Duration(seconds: 30),

    // TLS opts (untuk wss)
    SecurityContext? context,
    bool Function(X509Certificate cert)? onBadCertificate,
    void Function(String line)? keyLog,
    List<String>? supportedProtocols,
  }) async {
    // 1) Siapkan HttpClient dengan dukungan proxy via connectionFactory
    final httpClient = HttpClient(context: context)
      ..idleTimeout = timeout
      ..connectionTimeout = timeout;

    if (proxies.isEmpty) {
      final ws = await WebSocket.connect(
        uri.toString(),
        protocols: protocols,
        headers: headers,
        compression: compress
            ? CompressionOptions.compressionDefault
            : CompressionOptions.compressionOff,
        customClient: httpClient,
      );
      return CustomWebsocket._(ws);
    }

    if (!(uri.scheme == 'ws' || uri.scheme == 'wss')) {
      throw ArgumentError('URI scheme harus ws:// atau wss://');
    }

    // HTTP proxy native akan ditangani HttpClient.findProxy,
    // tapi karena kamu dukung SOCKS5/CHAIN, kita override connectionFactory
    // supaya semua koneksi dibuat lewat engine proxy kamu:
    httpClient.findProxy = (_) => "DIRECT";
    httpClient.badCertificateCallback = (cert, host, port) =>
        onBadCertificate?.call(cert) ?? false;

    httpClient.connectionFactory = (Uri destUri, String? _ph, int? _pp) {
      final int targetPort = destUri.hasPort
          ? destUri.port
          : (destUri.scheme == 'https' ? 443 : 80);

      final Future<Socket> futSocket = () async {
        // 1) tunnel mentah (direct/HTTP/SOCKS5/ROTATOR/CHAIN)
        final raw = await CustomSocket.connect(
          destUri.host,
          targetPort,
          proxyMode: proxyMode,
          proxies: proxies,
          timeout: timeout,
        );

        // 2) TLS hanya kalau https
        if (destUri.scheme == 'https') {
          final tls = await CustomSecureSocket.secure(raw, host: destUri.host);
          return tls; // sudah SecureSocket
        }
        return raw; // http: tetap raw
      }();

      return Future.value(
        ConnectionTask.fromSocket(futSocket, () async {
          try {
            (await futSocket).destroy();
          } catch (_) {}
        }),
      );
    };

    // 2) Terjemahkan ws:// → http://, wss:// → https:// untuk HttpClient
    final httpUri = uri.replace(
      scheme: uri.scheme == 'wss' ? 'https' : 'http',
      userInfo: '',
    );

    // 3) Build request upgrade
    final req = await httpClient.openUrl('GET', httpUri);

    // Header wajib upgrade
    final keyBytes = List<int>.generate(
      16,
      (_) => Random.secure().nextInt(256),
    );
    final secKey = base64.encode(keyBytes);
    req.headers.set(HttpHeaders.connectionHeader, 'Upgrade');
    req.headers.set(HttpHeaders.upgradeHeader, 'websocket');
    req.headers.set('Sec-WebSocket-Version', '13');
    req.headers.set('Sec-WebSocket-Key', secKey);

    // Per-message deflate (opsional)
    if (compress) {
      req.headers.add(
        'Sec-WebSocket-Extensions',
        'permessage-deflate; client_max_window_bits',
      );
    }

    // Subprotocols (opsional)
    if (protocols != null && protocols.isNotEmpty) {
      req.headers.add('Sec-WebSocket-Protocol', protocols.join(', '));
    }

    // Extra headers dari caller
    headers?.forEach((k, v) {
      if (v == null) return;
      if (v is String) {
        req.headers.add(k, v);
      } else if (v is List<String>) {
        for (final s in v) {
          req.headers.add(k, s);
        }
      } else {
        req.headers.add(k, v.toString());
      }
    });

    // 4) Kirim dan dapatkan response
    final resp = await req.close().timeout(timeout);

    // Validasi status 101
    if (resp.statusCode != 101) {
      final body = await resp.transform(utf8.decoder).join();
      throw WebSocketException(
        'Upgrade gagal: status ${resp.statusCode}\n$body',
      );
    }

    // Validasi headers
    final upgrade = resp.headers
        .value(HttpHeaders.upgradeHeader)
        ?.toLowerCase();
    final connection = resp.headers
        .value(HttpHeaders.connectionHeader)
        ?.toLowerCase();
    if (upgrade != 'websocket' || !(connection?.contains('upgrade') ?? false)) {
      throw WebSocketException('Header Upgrade/Connection tidak valid');
    }

    final accept = resp.headers.value('Sec-WebSocket-Accept');
    final expected = _computeWebSocketAccept(secKey);
    if (accept == null || accept.trim() != expected) {
      throw WebSocketException('Sec-WebSocket-Accept tidak cocok');
    }

    // Negotiated protocol (opsional)
    String? selectedProtocol;
    final serverProto = resp.headers.value('Sec-WebSocket-Protocol');
    if (serverProto != null && protocols != null && protocols.isNotEmpty) {
      final picked = serverProto
          .split(',')
          .map((s) => s.trim())
          .firstWhere((p) => protocols.contains(p), orElse: () => '');
      if (picked.isNotEmpty) selectedProtocol = picked;
    }

    final compressionAccepted =
        (resp.headers.value('Sec-WebSocket-Extensions')?.toLowerCase() ?? '')
            .contains('permessage-deflate');

    // 5) Lepaskan socket "bersih" dari HttpClient
    final upgradedSocket = await resp.detachSocket();

    // 6) Serahkan ke WebSocket.fromUpgradedSocket (ini listen pertama → aman)
    final ws = WebSocket.fromUpgradedSocket(
      upgradedSocket,
      protocol: selectedProtocol,
      serverSide: false,
      compression: compressionAccepted
          ? CompressionOptions.compressionDefault
          : CompressionOptions.compressionOff,
    );

    return CustomWebsocket._(ws);
  }

  // ======== Handshake Client RFC6455 ========

  static String _computeWebSocketAccept(String secKey) {
    // RFC6455: accept = base64( SHA1( key + magicGUID ) )
    const magic = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';
    final sha1 = Hash.sha1.convert(utf8.encode(secKey + magic));
    return base64.encode(sha1);
  }

  // ================== Delegasi ke _ws ==================

  @override
  void add(data) => _ws.add(data);

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _ws.addError(error, stackTrace);

  @override
  Future addStream(Stream stream) => _ws.addStream(stream);

  @override
  void addUtf8Text(List<int> bytes) => _ws.addUtf8Text(bytes);

  @override
  Future<bool> any(bool Function(dynamic element) test) => _ws.any(test);

  @override
  Stream asBroadcastStream({
    void Function(StreamSubscription subscription)? onListen,
    void Function(StreamSubscription subscription)? onCancel,
  }) => _ws.asBroadcastStream(onListen: onListen, onCancel: onCancel);

  @override
  Stream<E> asyncExpand<E>(Stream<E>? Function(dynamic event) convert) =>
      _ws.asyncExpand<E>(convert);

  @override
  Stream<E> asyncMap<E>(FutureOr<E> Function(dynamic event) convert) =>
      _ws.asyncMap<E>(convert);

  @override
  Stream<R> cast<R>() => _ws.cast<R>();

  @override
  Future close([int? code, String? reason]) => _ws.close(code, reason);

  @override
  int? get closeCode => _ws.closeCode;

  @override
  String? get closeReason => _ws.closeReason;

  @override
  Future<bool> contains(Object? needle) => _ws.contains(needle);

  @override
  Stream distinct([bool Function(dynamic previous, dynamic next)? equals]) =>
      _ws.distinct(equals);

  @override
  Future get done => _ws.done;

  @override
  Future<E> drain<E>([E? futureValue]) => _ws.drain<E>(futureValue);

  @override
  Future elementAt(int index) => _ws.elementAt(index);

  @override
  Future<bool> every(bool Function(dynamic element) test) => _ws.every(test);

  @override
  Stream<S> expand<S>(Iterable<S> Function(dynamic element) convert) =>
      _ws.expand<S>(convert);

  @override
  String get extensions => _ws.extensions;

  @override
  Future get first => _ws.first;

  @override
  Future firstWhere(
    bool Function(dynamic element) test, {
    Function()? orElse,
  }) => _ws.firstWhere(test, orElse: orElse);

  @override
  Future<S> fold<S>(
    S initialValue,
    S Function(S previous, dynamic element) combine,
  ) => _ws.fold<S>(initialValue, combine);

  @override
  Future<void> forEach(void Function(dynamic element) action) =>
      _ws.forEach(action);

  @override
  Stream handleError(Function onError, {bool Function(dynamic error)? test}) =>
      _ws.handleError(onError, test: test);

  @override
  bool get isBroadcast => _ws.isBroadcast;

  @override
  Future<bool> get isEmpty => _ws.isEmpty;

  @override
  Future<String> join([String separator = ""]) => _ws.join(separator);

  @override
  Future get last => _ws.last;

  @override
  Future lastWhere(bool Function(dynamic element) test, {Function()? orElse}) =>
      _ws.lastWhere(test, orElse: orElse);

  @override
  Future<int> get length => _ws.length;

  @override
  StreamSubscription listen(
    void Function(dynamic event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _ws.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  Stream<S> map<S>(S Function(dynamic event) convert) => _ws.map<S>(convert);

  @override
  Future pipe(StreamConsumer streamConsumer) => _ws.pipe(streamConsumer);

  @override
  String? get protocol => _ws.protocol;

  @override
  int get readyState => _ws.readyState;

  @override
  Future reduce(Function(dynamic previous, dynamic element) combine) =>
      _ws.reduce(combine);

  @override
  Future get single => _ws.single;

  @override
  Future singleWhere(
    bool Function(dynamic element) test, {
    Function()? orElse,
  }) => _ws.singleWhere(test, orElse: orElse);

  @override
  Stream skip(int count) => _ws.skip(count);

  @override
  Stream skipWhile(bool Function(dynamic element) test) => _ws.skipWhile(test);

  @override
  Stream take(int count) => _ws.take(count);

  @override
  Stream takeWhile(bool Function(dynamic element) test) => _ws.takeWhile(test);

  @override
  Stream timeout(
    Duration timeLimit, {
    void Function(EventSink sink)? onTimeout,
  }) => _ws.timeout(timeLimit, onTimeout: onTimeout);

  @override
  Future<List> toList() => _ws.toList();

  @override
  Future<Set> toSet() => _ws.toSet();

  @override
  Stream<S> transform<S>(StreamTransformer<dynamic, S> streamTransformer) =>
      _ws.transform<S>(streamTransformer);

  @override
  Stream where(bool Function(dynamic event) test) => _ws.where(test);
}

// === Helper untuk digest SHA1 (tanpa import crypto eksternal) ===
// Kamu bisa ganti dengan package:crypto kalau mau.
class Hash {
  static _Sha1 get sha1 => _Sha1();
}

class _Sha1 {
  List<int> convert(List<int> data) {
    final d = DigestSink();
    final h = sha1.convert(data);
    d.value = h.bytes;
    return d.value!;
  }
}

/// Implementasi SHA-1 kecil (cukup untuk Sec-WebSocket-Accept).
/// (Kalau sudah pakai package:crypto, hapus kelas-kelas ini dan pakai sha1.convert)
class DigestSink extends ByteConversionSinkBase {
  List<int>? value;
  @override
  void add(List<int> chunk) {}
  @override
  void close() {}
}
