import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:http_client/http_client.dart';

// Ganti import berikut sesuai lokasi util/handler milikmu:

class CustomSocket implements Socket {
  late Socket _base;
  late StreamReader _reader;

  Socket get raw => _base; // atau nama field publikmu
  StreamReader get reader => _reader; // atau nama field publikmu

  CustomSocket._(Socket socket, StreamReader reader) {
    _base = socket;
    _reader = reader;
  }

  /// Koneksi socket dengan dukungan proxy:
  /// - NONE   : pakai proxy pertama (jika ada), else direct
  /// - ROTATOR: acak salah satu proxy lalu tunnel ke target
  /// - CHAIN  : tunnel berlapis: p1->p2->...->target
  static Future<CustomSocket> connect(
    dynamic host,
    int port, {
    ProxyMode proxyMode = ProxyMode.NONE,
    List<ProxyConfig> proxies = const [],
    dynamic sourceAddress,
    int sourcePort = 0,
    Duration? timeout,
  }) async {
    final Duration effTimeout = timeout ?? const Duration(seconds: 30);

    // Tanpa proxy sama sekali → direct
    if (proxies.isEmpty) {
      return await _connectDirect(
        host,
        port,
        sourceAddress: sourceAddress,
        sourcePort: sourcePort,
        timeout: effTimeout,
      );
    }

    switch (proxyMode) {
      case ProxyMode.CHAIN:
        // Minimal 2 proxy agar "CHAIN" bermakna; kalau 1, jatuhkan ke FIRST.
        if (proxies.length > 1) {
          return await _connectProxyChain(
            proxies: proxies,
            host: host,
            port: port,
            timeout: effTimeout,
            sourceAddress: sourceAddress,
            sourcePort: sourcePort,
          );
        } else {
          return await _connectProxyFirstOrRandom(
            proxies: proxies,
            host: host,
            port: port,
            timeout: effTimeout,
            sourceAddress: sourceAddress,
            sourcePort: sourcePort,
            randomPick: false,
          );
        }

      case ProxyMode.ROTATOR:
        return await _connectProxyRotator(
          proxies: proxies,
          host: host,
          port: port,
          timeout: effTimeout,
          sourceAddress: sourceAddress,
          sourcePort: sourcePort,
        );

      case ProxyMode.NONE:
        // Pakai proxy pertama agar deterministik
        return await _connectProxyFirstOrRandom(
          proxies: proxies,
          host: host,
          port: port,
          timeout: effTimeout,
          sourceAddress: sourceAddress,
          sourcePort: sourcePort,
          randomPick: false,
        );
    }
  }

  /// Tunneling berlapis: connect ke proxies.first,
  /// lalu chain CONNECT/handshake ke proxy berikutnya, dst, terakhir ke target.
  static Future<CustomSocket> _connectProxyChain({
    required List<ProxyConfig> proxies,
    required dynamic host,
    required int port,
    required Duration timeout,
    required dynamic sourceAddress,
    required int sourcePort,
  }) async {
    // 1) Koneksi awal ke proxy pertama
    Socket socket = await Socket.connect(
      proxies.first.host,
      proxies.first.port,
      timeout: timeout,
      sourceAddress: sourceAddress,
      sourcePort: sourcePort,
    );
    final reader = _initReaderFromSocket(socket);

    try {
      // 2) Chain antar proxy
      for (var i = 0; i < proxies.length - 1; i++) {
        final from = proxies[i];
        final to = proxies[i + 1];
        final tuple = await _tunnelThroughProxy(
          socket,
          reader,
          from,
          to.host,
          to.port,
          timeout,
        );
        socket = tuple.$1;
        // reader tetap sama (stream broadcast), jadi abaikan tuple.$2
      }

      // 3) Hop terakhir ke target
      await _tunnelThroughProxy(
        socket,
        reader,
        proxies.last,
        host is String ? host : host.toString(),
        port,
        timeout,
      );

      return CustomSocket._(socket, reader);
    } catch (e) {
      try {
        socket.destroy();
      } catch (_) {}
      rethrow;
    }
  }

  /// Pilih proxy: acak (rotator) atau pertama (default),
  /// lalu tunnel dari proxy terpilih ke target.
  static Future<CustomSocket> _connectProxyFirstOrRandom({
    required List<ProxyConfig> proxies,
    required dynamic host,
    required int port,
    required Duration timeout,
    required dynamic sourceAddress,
    required int sourcePort,
    required bool randomPick,
  }) async {
    final ProxyConfig chosen = randomPick
        ? proxies[Random().nextInt(proxies.length)]
        : proxies.first;

    // 1) connect ke proxy terpilih
    Socket socket = await Socket.connect(
      chosen.host,
      chosen.port,
      timeout: timeout,
      sourceAddress: sourceAddress,
      sourcePort: sourcePort,
    );
    final reader = _initReaderFromSocket(socket);

    try {
      // 2) tunnel ke target
      await _tunnelThroughProxy(
        socket,
        reader,
        chosen,
        host is String ? host : host.toString(),
        port,
        timeout,
      );

      return CustomSocket._(socket, reader);
    } catch (e) {
      try {
        socket.destroy();
      } catch (_) {}
      rethrow;
    }
  }

  /// (Deprecated path) — tidak dipakai lagi, tapi disediakan kalau suatu saat
  /// kamu ingin strategi rotasi yang berbeda dari method di atas.
  static Future<CustomSocket> _connectProxyRotator({
    required List<ProxyConfig> proxies,
    required dynamic host,
    required int port,
    required Duration timeout,
    required dynamic sourceAddress,
    required int sourcePort,
  }) async {
    // fallback ke versi acak
    return _connectProxyFirstOrRandom(
      proxies: proxies,
      host: host,
      port: port,
      timeout: timeout,
      sourceAddress: sourceAddress,
      sourcePort: sourcePort,
      randomPick: true,
    );
  }

  static Future<CustomSocket> _connectDirect(
    dynamic host,
    int port, {
    dynamic sourceAddress,
    int sourcePort = 0,
    Duration? timeout,
  }) async {
    final Duration effTimeout = timeout ?? const Duration(seconds: 30);
    final IOOverrides? overrides = IOOverrides.current;

    if (overrides == null) {
      final socket = await Socket.connect(
        host,
        port,
        sourceAddress: sourceAddress,
        sourcePort: sourcePort,
        timeout: effTimeout,
      );
      final reader = _initReaderFromSocket(socket);
      return CustomSocket._(socket, reader);
    }
    final socket = await overrides.socketConnect(
      host,
      port,
      sourceAddress: sourceAddress,
      sourcePort: sourcePort,
      timeout: effTimeout,
    );
    final reader = _initReaderFromSocket(socket);
    return CustomSocket._(socket, reader);
  }

  static StreamReader _initReaderFromSocket(Socket s) {
    return StreamReader.fromStream(
      s.asBroadcastStream(),
      bufferUntilListen: true,
      copyOnForward: false,
      closeOnSourceDone: true,
    );
  }

  /// Lakukan handshake/tunnel sesuai tipe proxy.
  /// Setelah selesai, [socket] sudah menjadi tunnel ke (dstHost:dstPort).
  static Future<(Socket, StreamReader)> _tunnelThroughProxy(
    Socket socket,
    StreamReader reader,
    ProxyConfig proxy,
    String dstHost,
    int dstPort,
    Duration? timeout,
  ) async {
    final Duration effTimeout = timeout ?? const Duration(seconds: 30);

    switch (proxy.type) {
      case ProxyType.HTTP:
        // Pastikan HttpHandler milikmu implement CONNECT (untuk HTTPS).
        final http = HttpHandler(
          rawSocket: socket,
          reader: reader,
          username: proxy.username,
          password: proxy.password,
        );
        await http.connect(dstHost, dstPort, timeout: effTimeout);
        break;

      case ProxyType.SOCKS5:
        final s5 = Socks5Handler(
          useLookup: false, // biarkan proxy resolve DNS (ATYP=DOMAIN)
          rawSocket: socket,
          reader: reader,
          proxy: proxy,
        );
        await s5.handshake(
          greetingTimeout: effTimeout,
          authTimeout: effTimeout,
        );
        await s5.connect(dstHost, dstPort, timeout: effTimeout);
        break;

      default:
        throw UnsupportedError('Proxy type ${proxy.type} belum didukung.');
    }

    return (socket, reader);
  }

  // ============================== Socket delegate ==============================

  @override
  set encoding(Encoding value) {
    _base.encoding = value;
  }

  @override
  Encoding get encoding => _base.encoding;

  @override
  void add(List<int> data) => _base.add(data);

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _base.addError(error, stackTrace);

  @override
  Future addStream(Stream<List<int>> stream) => _base.addStream(stream);

  @override
  InternetAddress get address => _base.address;

  @override
  Future<bool> any(bool Function(Uint8List element) test) => _base.any(test);

  @override
  Stream<Uint8List> asBroadcastStream({
    void Function(StreamSubscription<Uint8List> subscription)? onListen,
    void Function(StreamSubscription<Uint8List> subscription)? onCancel,
  }) => _base.asBroadcastStream(onListen: onListen, onCancel: onCancel);

  @override
  Stream<E> asyncExpand<E>(Stream<E>? Function(Uint8List event) convert) {
    return _base.asyncExpand<E>(convert);
  }

  @override
  Stream<E> asyncMap<E>(FutureOr<E> Function(Uint8List event) convert) =>
      _base.asyncMap<E>(convert);

  @override
  Stream<R> cast<R>() => _base.cast<R>();

  @override
  Future close() => _base.close();

  @override
  Future<bool> contains(Object? needle) => _base.contains(needle);

  @override
  void destroy() => _base.destroy();

  @override
  Stream<Uint8List> distinct([
    bool Function(Uint8List previous, Uint8List next)? equals,
  ]) => _base.distinct(equals);

  @override
  Future get done => _base.done;

  @override
  Future<E> drain<E>([E? futureValue]) => _base.drain<E>(futureValue);

  @override
  Future<Uint8List> elementAt(int index) => _base.elementAt(index);

  @override
  Future<bool> every(bool Function(Uint8List element) test) =>
      _base.every(test);

  @override
  Stream<S> expand<S>(Iterable<S> Function(Uint8List element) convert) =>
      _base.expand<S>(convert);

  @override
  Future<Uint8List> get first => _base.first;

  @override
  Future<Uint8List> firstWhere(
    bool Function(Uint8List element) test, {
    Uint8List Function()? orElse,
  }) => _base.firstWhere(test, orElse: orElse);

  @override
  Future flush() => _base.flush();

  @override
  Future<S> fold<S>(
    S initialValue,
    S Function(S previous, Uint8List element) combine,
  ) => _base.fold<S>(initialValue, combine);

  @override
  Future<void> forEach(void Function(Uint8List element) action) =>
      _base.forEach(action);

  @override
  Uint8List getRawOption(RawSocketOption option) => _base.getRawOption(option);

  @override
  Stream<Uint8List> handleError(
    Function onError, {
    bool Function(dynamic)? test,
  }) => _base.handleError(onError, test: test);

  @override
  bool get isBroadcast => _base.isBroadcast;

  @override
  Future<bool> get isEmpty => _base.isEmpty;

  @override
  Future<String> join([String separator = ""]) => _base.join(separator);

  @override
  Future<Uint8List> get last => _base.last;

  @override
  Future<Uint8List> lastWhere(
    bool Function(Uint8List element) test, {
    Uint8List Function()? orElse,
  }) => _base.lastWhere(test, orElse: orElse);

  @override
  Future<int> get length => _base.length;

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _reader.listen(
    onData,
    onDone: onDone,
    onError: onError,
    cancelOnError: cancelOnError,
  );

  @override
  Stream<S> map<S>(S Function(Uint8List event) convert) =>
      _base.map<S>(convert);

  @override
  Future pipe(StreamConsumer<Uint8List> streamConsumer) =>
      _base.pipe(streamConsumer);

  @override
  int get port => _base.port;

  @override
  Future<Uint8List> reduce(
    Uint8List Function(Uint8List previous, Uint8List element) combine,
  ) => _base.reduce(combine);

  @override
  InternetAddress get remoteAddress => _base.remoteAddress;

  @override
  int get remotePort => _base.remotePort;

  @override
  bool setOption(SocketOption option, bool enabled) =>
      _base.setOption(option, enabled);

  @override
  void setRawOption(RawSocketOption option) => _base.setRawOption(option);

  @override
  Future<Uint8List> get single => _base.single;

  @override
  Future<Uint8List> singleWhere(
    bool Function(Uint8List element) test, {
    Uint8List Function()? orElse,
  }) => _base.singleWhere(test, orElse: orElse);

  @override
  Stream<Uint8List> skip(int count) => _base.skip(count);

  @override
  Stream<Uint8List> skipWhile(bool Function(Uint8List element) test) =>
      _base.skipWhile(test);

  @override
  Stream<Uint8List> take(int count) => _base.take(count);

  @override
  Stream<Uint8List> takeWhile(bool Function(Uint8List element) test) =>
      _base.takeWhile(test);

  @override
  Stream<Uint8List> timeout(
    Duration timeLimit, {
    void Function(EventSink<Uint8List> sink)? onTimeout,
  }) => _base.timeout(timeLimit, onTimeout: onTimeout);

  @override
  Future<List<Uint8List>> toList() => _base.toList();

  @override
  Future<Set<Uint8List>> toSet() => _base.toSet();

  @override
  Stream<S> transform<S>(StreamTransformer<Uint8List, S> streamTransformer) =>
      _base.transform<S>(streamTransformer);

  @override
  Stream<Uint8List> where(bool Function(Uint8List event) test) =>
      _base.where(test);

  @override
  void write(Object? object) => _base.write(object);

  @override
  void writeAll(Iterable objects, [String separator = ""]) =>
      _base.writeAll(objects, separator);

  @override
  void writeCharCode(int charCode) => _base.writeCharCode(charCode);

  @override
  void writeln([Object? object = ""]) => _base.writeln(object);
}
