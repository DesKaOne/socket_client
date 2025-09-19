import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http_client/http_client.dart';

import 'custom_socket.dart';

// NOTE: pastikan kamu punya StreamReader (dari package kamu sendiri / util)
class CustomSecureSocket implements SecureSocket {
  late SecureSocket _base;
  late StreamReader _reader;

  SecureSocket get raw => _base; // atau nama field publikmu
  StreamReader get reader => _reader; // atau nama field publikmu

  CustomSecureSocket._(SecureSocket socket, StreamReader reader) {
    _base = socket;
    _reader = reader;
  }

  /// TLS connect langsung ke [host]:[port]
  static Future<CustomSecureSocket> connect(
    dynamic host,
    int port, {
    SecurityContext? context,
    bool Function(X509Certificate certificate)? onBadCertificate,
    void Function(String line)? keyLog,
    List<String>? supportedProtocols,
    Duration? timeout,
  }) async {
    final secure = await SecureSocket.connect(
      host,
      port,
      context: context,
      onBadCertificate: onBadCertificate,
      keyLog: keyLog,
      supportedProtocols: supportedProtocols,
      timeout: timeout,
    );
    final reader = _initReaderFromSocket(secure);
    return CustomSecureSocket._(secure, reader);
  }

  /// Upgrade koneksi TCP yang sudah ada (CustomSocket) menjadi TLS.
  /// Wajib beri [host] untuk SNI & verifikasi sertifikat.
  static Future<CustomSecureSocket> secure(
    CustomSocket socket, {
    required String host,
    SecurityContext? context,
    bool Function(X509Certificate certificate)? onBadCertificate,
    void Function(String line)? keyLog,
    List<String>? supportedProtocols,
  }) async {
    // Ambil raw socket dari wrapper kamu
    final Socket raw = socket.raw;

    // Upgrade ke TLS di atas socket yang sudah terhubung/tunnel
    final SecureSocket tls = await SecureSocket.secure(
      raw,
      host: host, // penting untuk SNI & cert validation
      context: context,
      onBadCertificate: onBadCertificate,
      keyLog: keyLog,
      supportedProtocols: supportedProtocols,
    );

    final reader = _initReaderFromSocket(tls);
    return CustomSecureSocket._(tls, reader);
  }

  /// (Opsional) Overload: kalau kadang kamu punya Socket biasa (bukan CustomSocket)
  static Future<CustomSecureSocket> secureFromSocket(
    Socket raw, {
    required String host,
    SecurityContext? context,
    bool Function(X509Certificate certificate)? onBadCertificate,
    void Function(String line)? keyLog,
    List<String>? supportedProtocols,
  }) async {
    final SecureSocket tls = await SecureSocket.secure(
      raw,
      host: host,
      context: context,
      onBadCertificate: onBadCertificate,
      keyLog: keyLog,
      supportedProtocols: supportedProtocols,
    );
    final reader = _initReaderFromSocket(tls);
    return CustomSecureSocket._(tls, reader);
  }

  static StreamReader _initReaderFromSocket(Socket s) {
    return StreamReader.fromStream(
      s.asBroadcastStream(),
      bufferUntilListen: true,
      copyOnForward: false,
      closeOnSourceDone: true,
    );
  }

  // ============================== SecureSocket delegate ==============================

  @override
  X509Certificate? get peerCertificate => _base.peerCertificate;

  @override
  @Deprecated("Not implemented")
  void renegotiate({
    bool useSessionCache = true,
    bool requestClientCertificate = false,
    bool requireClientCertificate = false,
  }) {
    throw UnimplementedError();
  }

  @override
  String? get selectedProtocol => _base.selectedProtocol;

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

  /// Penting: gunakan reader broadcast agar listener-mu tetap stabil.
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
