// A minimal Google Cast sender: just enough CASTV2 to start the Felt Notes
// TV receiver on a Chromecast, hand it tonight's code, and let go. The TV
// then runs the table page by itself; nothing of this phone's screen (or
// its owner's cards) is sent, only the code.
//
// Launch, step by step (each line is one CastMessage, JSON payloads):
//   sender-0 → receiver-0  tp.connection  {"type":"CONNECT"}
//   sender-0 → receiver-0  receiver       {"type":"LAUNCH","appId":"2537B496","requestId":1}
//   receiver-0 → *         receiver       RECEIVER_STATUS … applications[{appId, transportId, namespaces}]
//   sender-0 → <transport> tp.connection  {"type":"CONNECT"}
//   sender-0 → <transport> feltnotes      {"code":"ABCD2345-WXYZ6789"}
//   (socket closed; the receiver keeps running: disableIdleTimeout)
// Heartbeat: answer PING with PONG, and PING every 5 s while connected.
// Stop: CONNECT, GET_STATUS, STOP {sessionId} for our app.

import 'dart:async';
import 'dart:io';

import 'cast_message.dart';

/// A byte pipe to a Cast device (TLS in the app, a fake in tests).
abstract class CastSocket {
  Stream<List<int>> get input;
  void add(List<int> bytes);
  Future<void> close();
}

typedef CastConnector = Future<CastSocket> Function(String host, int port);

/// Real devices: TLS on port 8009 with a self-signed certificate (the Cast
/// protocol authenticates devices differently; we only send a night code
/// that is already on the TV link).
Future<CastSocket> tlsCastConnector(String host, int port) async {
  final s = await SecureSocket.connect(host, port, onBadCertificate: (_) => true, timeout: const Duration(seconds: 8));
  return _TlsCastSocket(s);
}

class _TlsCastSocket implements CastSocket {
  final SecureSocket s;
  _TlsCastSocket(this.s);
  @override
  Stream<List<int>> get input => s;
  @override
  void add(List<int> bytes) => s.add(bytes);
  @override
  Future<void> close() async {
    try {
      await s.flush().timeout(const Duration(seconds: 2));
    } catch (_) {}
    s.destroy();
  }
}

class CastException implements Exception {
  final String message;
  const CastException(this.message);
  @override
  String toString() => message;
}

/// One open connection to a device's platform end (receiver-0): framing,
/// heartbeat, request ids, waiting for replies.
class CastChannel {
  final CastSocket socket;
  final String senderId;
  final _decoder = CastFrameDecoder();
  final _messages = StreamController<CastMessage>.broadcast();
  late final StreamSubscription<List<int>> _sub;
  Timer? _ping;
  int _requestId = 0;
  bool _closed = false;
  Object? _error;

  CastChannel(this.socket, {this.senderId = 'sender-0', Duration heartbeat = const Duration(seconds: 5)}) {
    _sub = socket.input
        .listen(_onBytes, onError: _fail, onDone: () => _fail(const CastException('The TV closed the connection.')));
    if (heartbeat > Duration.zero) {
      _ping = Timer.periodic(heartbeat, (_) => send(nsHeartbeat, castPlatformId, {'type': 'PING'}));
    }
  }

  Stream<CastMessage> get messages => _messages.stream;

  int nextRequestId() => ++_requestId;

  void _onBytes(List<int> chunk) {
    final List<CastMessage> got;
    try {
      got = _decoder.add(chunk);
    } on FormatException catch (e) {
      return _fail(CastException('Bad data from the TV: ${e.message}'));
    }
    for (final m in got) {
      if (m.namespace == nsHeartbeat && m.type == 'PING') {
        send(nsHeartbeat, m.sourceId, {'type': 'PONG'});
        continue;
      }
      _messages.add(m);
    }
  }

  void _fail(Object e) {
    if (_closed) return;
    _error ??= e;
    _messages.addError(e);
  }

  void send(String namespace, String dest, Map<String, Object?> body) {
    if (_closed) return;
    socket.add(CastMessage.json(senderId, dest, namespace, body).frame());
  }

  /// Opens the virtual connection to [dest] (receiver-0 or an app).
  void connectTo(String dest) => send(nsConnection, dest, {'type': 'CONNECT'});

  /// The first message for which [pick] returns non-null, within [timeout].
  /// Errors on the socket end the wait with that error.
  Future<T> waitFor<T>(T? Function(CastMessage m) pick, Duration timeout, String timeoutText) {
    if (_error != null) return Future.error(_error!);
    final done = Completer<T>();
    late final StreamSubscription<CastMessage> sub;
    final timer = Timer(timeout, () {
      if (!done.isCompleted) done.completeError(CastException(timeoutText));
    });
    sub = messages.listen((m) {
      if (done.isCompleted) return;
      try {
        final v = pick(m);
        if (v != null) done.complete(v);
      } catch (e) {
        done.completeError(e);
      }
    }, onError: (Object e) {
      if (!done.isCompleted) done.completeError(e);
    });
    return done.future.whenComplete(() {
      timer.cancel();
      sub.cancel();
    });
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _ping?.cancel();
    await _sub.cancel();
    await socket.close();
    await _messages.close();
  }
}

/// Our app in a RECEIVER_STATUS, if it is running.
class CastAppStatus {
  final String sessionId;
  final String? transportId;
  final Set<String> namespaces;
  const CastAppStatus(this.sessionId, this.transportId, this.namespaces);

  static CastAppStatus? from(CastMessage m, String appId) {
    if (m.namespace != nsReceiver) return null;
    final j = m.json;
    if (j == null || j['type'] != 'RECEIVER_STATUS') return null;
    final status = j['status'];
    final apps = status is Map ? status['applications'] : null;
    if (apps is! List) return null;
    for (final a in apps) {
      if (a is! Map || a['appId'] != appId) continue;
      final ns = <String>{
        for (final n in (a['namespaces'] is List ? a['namespaces'] as List : const []))
          if (n is Map && n['name'] is String) n['name'] as String
      };
      return CastAppStatus('${a['sessionId'] ?? ''}', a['transportId'] as String?, ns);
    }
    return null;
  }
}

enum CastPhase { connecting, launching, sending, done }

/// Starts Felt Notes TV on the device at [host]:[port] and shows [code].
/// Returns the receiver's session id. Throws [CastException].
///
/// [namespaceGrace]: once the app is up but has not yet listed our
/// namespace (its page is still loading), how long to wait for it before
/// sending anyway.
Future<String> castShowCode({
  required String host,
  required int port,
  required String code,
  String appId = feltNotesCastAppId,
  CastConnector connector = tlsCastConnector,
  void Function(CastPhase phase)? onPhase,
  Duration launchTimeout = const Duration(seconds: 30),
  Duration namespaceGrace = const Duration(seconds: 8),
  Duration heartbeat = const Duration(seconds: 5),
  Duration settle = const Duration(milliseconds: 400),
}) async {
  onPhase?.call(CastPhase.connecting);
  final CastSocket socket;
  try {
    socket = await connector(host, port);
  } catch (e) {
    throw CastException('Could not reach the TV ($e).');
  }
  final ch = CastChannel(socket, heartbeat: heartbeat);
  Timer? grace;
  try {
    ch.connectTo(castPlatformId);
    onPhase?.call(CastPhase.launching);
    final launchId = ch.nextRequestId();
    ch.send(nsReceiver, castPlatformId, {'type': 'LAUNCH', 'appId': appId, 'requestId': launchId});

    // Wait for our app with a transport id, ideally with our namespace
    // registered (the receiver page has started); after [namespaceGrace]
    // a transport id alone will do.
    CastAppStatus? seen;
    final graceUp = Completer<void>();
    final app = await ch.waitFor<CastAppStatus>((m) {
      final j = m.json;
      if (m.namespace == nsReceiver && (j?['type'] == 'LAUNCH_ERROR' || j?['type'] == 'INVALID_REQUEST')) {
        final reason = j?['reason'] ?? j?['type'];
        throw CastException(reason == 'NOT_FOUND' || reason == 'NOT_ALLOWED'
            ? 'The TV would not start Felt Notes ($reason). An unpublished receiver only runs on '
                'Chromecasts registered in the Cast console.'
            : 'The TV would not start Felt Notes ($reason).');
      }
      if (graceUp.isCompleted && seen != null) return seen;
      final a = CastAppStatus.from(m, appId);
      if (a == null || a.transportId == null) return null;
      if (a.namespaces.contains(nsFeltNotes)) return a;
      seen = a;
      grace ??= Timer(namespaceGrace, () {
        graceUp.complete();
        // Nudge the wait with a status request so it re-checks.
        ch.send(nsReceiver, castPlatformId, {'type': 'GET_STATUS', 'requestId': ch.nextRequestId()});
      });
      return null;
    }, launchTimeout, 'The TV did not start Felt Notes in time.');
    onPhase?.call(CastPhase.sending);
    final transport = app.transportId!;
    ch.connectTo(transport);
    ch.send(nsFeltNotes, transport, {'code': code});
    // Let the bytes leave before the socket closes.
    await Future<void>.delayed(settle);
    onPhase?.call(CastPhase.done);
    return app.sessionId;
  } finally {
    grace?.cancel();
    await ch.close();
  }
}

/// Stops Felt Notes TV on the device (the TV goes back to its backdrop).
/// True when it was running and is now stopped; false when it was not
/// running. Throws [CastException] when the TV cannot be reached.
Future<bool> castStop({
  required String host,
  required int port,
  String appId = feltNotesCastAppId,
  CastConnector connector = tlsCastConnector,
  Duration timeout = const Duration(seconds: 10),
  Duration heartbeat = const Duration(seconds: 5),
}) async {
  final CastSocket socket;
  try {
    socket = await connector(host, port);
  } catch (e) {
    throw CastException('Could not reach the TV ($e).');
  }
  final ch = CastChannel(socket, heartbeat: heartbeat);
  try {
    ch.connectTo(castPlatformId);
    final statusId = ch.nextRequestId();
    final statusReply = ch.waitFor<CastMessage>(
        (m) => m.namespace == nsReceiver && m.type == 'RECEIVER_STATUS' ? m : null, timeout, 'The TV did not answer.');
    ch.send(nsReceiver, castPlatformId, {'type': 'GET_STATUS', 'requestId': statusId});
    final app = CastAppStatus.from(await statusReply, appId);
    if (app == null) return false;
    final stopped = ch.waitFor<bool>(
        (m) => m.namespace == nsReceiver && m.type == 'RECEIVER_STATUS' && CastAppStatus.from(m, appId) == null
            ? true
            : null,
        timeout,
        'The TV did not stop Felt Notes.');
    ch.send(nsReceiver, castPlatformId, {'type': 'STOP', 'sessionId': app.sessionId, 'requestId': ch.nextRequestId()});
    return await stopped;
  } finally {
    await ch.close();
  }
}
