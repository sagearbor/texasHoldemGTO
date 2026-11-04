// The Cast v2 wire format (CASTV2), by hand: a frame is a 4-byte
// big-endian length followed by a protobuf `CastMessage`
// (cast_channel.proto). Only the fields a sender needs are written; the
// decoder skips anything else. No protobuf package, no generated code.
//
//   message CastMessage {
//     required ProtocolVersion protocol_version = 1;  // CASTV2_1_0 = 0
//     required string source_id = 2;
//     required string destination_id = 3;
//     required string namespace = 4;
//     required PayloadType payload_type = 5;          // STRING = 0, BINARY = 1
//     optional string payload_utf8 = 6;
//     optional bytes payload_binary = 7;
//   }

import 'dart:convert';
import 'dart:typed_data';

const nsConnection = 'urn:x-cast:com.google.cast.tp.connection';
const nsHeartbeat = 'urn:x-cast:com.google.cast.tp.heartbeat';
const nsReceiver = 'urn:x-cast:com.google.cast.receiver';

/// Felt Notes TV's own channel: `{"code": "<night code>"}`.
const nsFeltNotes = 'urn:x-cast:com.sagearbor.feltnotes';

/// The Felt Notes TV custom receiver (Cast developer console).
const feltNotesCastAppId = '2537B496';

/// The platform end of every Cast device.
const castPlatformId = 'receiver-0';

class CastMessage {
  final String sourceId;
  final String destinationId;
  final String namespace;

  /// The JSON text (payload_type STRING); null for a binary payload.
  final String? payloadUtf8;
  final List<int>? payloadBinary;

  const CastMessage({
    required this.sourceId,
    required this.destinationId,
    required this.namespace,
    this.payloadUtf8,
    this.payloadBinary,
  });

  factory CastMessage.json(String source, String dest, String namespace, Map<String, Object?> body) =>
      CastMessage(sourceId: source, destinationId: dest, namespace: namespace, payloadUtf8: jsonEncode(body));

  /// The payload as a JSON object, or null when it is not one.
  Map<String, Object?>? get json {
    final p = payloadUtf8;
    if (p == null) return null;
    try {
      final v = jsonDecode(p);
      return v is Map<String, Object?> ? v : null;
    } on FormatException {
      return null;
    }
  }

  String? get type => json?['type'] as String?;

  /// The protobuf bytes (no length prefix).
  Uint8List encode() {
    final b = BytesBuilder();
    b.add(const [0x08, 0x00]); // protocol_version = CASTV2_1_0
    _string(b, 2, sourceId);
    _string(b, 3, destinationId);
    _string(b, 4, namespace);
    final bin = payloadBinary;
    b.add([0x28, bin == null ? 0 : 1]); // payload_type
    if (bin == null) {
      _string(b, 6, payloadUtf8 ?? '');
    } else {
      _bytes(b, 7, bin);
    }
    return b.toBytes();
  }

  /// One frame: length prefix + protobuf.
  Uint8List frame() {
    final body = encode();
    final out = Uint8List(4 + body.length);
    ByteData.sublistView(out).setUint32(0, body.length);
    out.setRange(4, out.length, body);
    return out;
  }

  /// Parses protobuf bytes (no length prefix). Throws [FormatException].
  static CastMessage decode(List<int> data) {
    var source = '', dest = '', ns = '';
    String? utf8Payload;
    List<int>? bin;
    var i = 0;
    int varint() {
      var v = 0, shift = 0;
      while (true) {
        if (i >= data.length) throw const FormatException('cast: truncated varint');
        final byte = data[i++];
        v |= (byte & 0x7F) << shift;
        if (byte & 0x80 == 0) return v;
        shift += 7;
        if (shift > 63) throw const FormatException('cast: bad varint');
      }
    }

    while (i < data.length) {
      final key = varint();
      final field = key >> 3, wire = key & 7;
      switch (wire) {
        case 0:
          varint();
        case 1:
          i += 8;
        case 5:
          i += 4;
        case 2:
          final len = varint();
          if (len < 0 || i + len > data.length) throw const FormatException('cast: truncated field');
          final bytes = data.sublist(i, i + len);
          i += len;
          switch (field) {
            case 2:
              source = utf8.decode(bytes, allowMalformed: true);
            case 3:
              dest = utf8.decode(bytes, allowMalformed: true);
            case 4:
              ns = utf8.decode(bytes, allowMalformed: true);
            case 6:
              utf8Payload = utf8.decode(bytes, allowMalformed: true);
            case 7:
              bin = bytes;
          }
        default:
          throw FormatException('cast: wire type $wire');
      }
    }
    if (i > data.length) throw const FormatException('cast: truncated message');
    return CastMessage(
        sourceId: source, destinationId: dest, namespace: ns, payloadUtf8: utf8Payload, payloadBinary: bin);
  }

  @override
  String toString() => 'CastMessage($sourceId → $destinationId, $namespace, ${payloadUtf8 ?? '<binary>'})';

  static void _varint(BytesBuilder b, int v) {
    while (v >= 0x80) {
      b.addByte((v & 0x7F) | 0x80);
      v >>= 7;
    }
    b.addByte(v);
  }

  static void _bytes(BytesBuilder b, int field, List<int> bytes) {
    _varint(b, (field << 3) | 2);
    _varint(b, bytes.length);
    b.add(bytes);
  }

  static void _string(BytesBuilder b, int field, String s) => _bytes(b, field, utf8.encode(s));
}

/// Splits a TCP byte stream into [CastMessage]s (frames can arrive split
/// or several at once).
class CastFrameDecoder {
  /// Cast devices cap a message at 64 KB; anything larger is a broken stream.
  static const maxFrame = 64 * 1024;
  final _buf = BytesBuilder(copy: true);

  /// Feeds bytes; returns the complete messages they finish.
  List<CastMessage> add(List<int> chunk) {
    _buf.add(chunk);
    final out = <CastMessage>[];
    var data = _buf.takeBytes();
    var at = 0;
    while (data.length - at >= 4) {
      final len = ByteData.sublistView(data, at, at + 4).getUint32(0);
      if (len > maxFrame) throw FormatException('cast: frame of $len bytes');
      if (data.length - at - 4 < len) break;
      out.add(CastMessage.decode(Uint8List.sublistView(data, at + 4, at + 4 + len)));
      at += 4 + len;
    }
    if (at < data.length) _buf.add(Uint8List.sublistView(data, at));
    return out;
  }
}
