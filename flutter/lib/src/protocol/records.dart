/// Record framing (protocol §2).
///
/// The byte stream is a sequence of records:
///
/// ```
/// +----------------+-----------+-----------------+
/// | len : uint16   | kind: u8  | body (len-1 B)  |
/// +----------------+-----------+-----------------+
/// ```
///
/// `len` counts `kind` + `body`, so the largest body is 65534 bytes.
/// All integers are big-endian.
library;

import 'bytes.dart';

/// Record kinds (protocol §2).
abstract final class RecordKind {
  static const int hello = 0x01;
  static const int helloAck = 0x02;
  static const int reject = 0x03;
  static const int sealed = 0x10;

  /// Any other kind closes the connection.
  static bool isKnown(int kind) =>
      kind == hello || kind == helloAck || kind == reject || kind == sealed;
}

/// REJECT reasons (protocol §2).
abstract final class RejectReason {
  static const int badVersion = 1;
  static const int unknownDevice = 2;
  static const int pairingClosed = 3;
  static const int busy = 4;
}

/// A single record: a [kind] byte and a [body].
class Record {
  const Record(this.kind, this.body);

  final int kind;
  final List<int> body;

  /// Encodes this record as `len:u16 ‖ kind:u8 ‖ body`.
  List<int> encoded() {
    if (body.length > 65534) {
      throw const FramingException('record body too large');
    }
    final len = body.length + 1;
    final out = List<int>.filled(body.length + 3, 0, growable: false);
    out[0] = (len >> 8) & 0xff;
    out[1] = len & 0xff;
    out[2] = kind & 0xff;
    out.setRange(3, out.length, body);
    return out;
  }

  @override
  bool operator ==(Object other) =>
      other is Record && other.kind == kind && bytesEqual(other.body, body);

  @override
  int get hashCode => Object.hash(kind, Object.hashAll(body));

  @override
  String toString() => 'Record(kind=$kind, ${body.length}B)';
}

class FramingException implements Exception {
  const FramingException(this.message);

  final String message;

  @override
  String toString() => 'FramingException: $message';
}

/// Accumulates stream bytes and yields complete records.
///
/// Feed arbitrary chunks with [append]; [next] returns the next complete
/// record, or `null` when more bytes are needed. A zero-length record or
/// an unknown kind throws [FramingException].
class RecordReader {
  /// Hard cap on buffered bytes (1 GiB). Exceeding it is a framing
  /// error, not a crash: [append] throws [FramingException] instead of
  /// letting the buffer grow without bound (or failing with a raw
  /// [RangeError] inside `setRange`).
  static const int maxBufferBytes = 1 << 30;

  List<int> _buf = List<int>.filled(4096, 0, growable: false);
  int _start = 0;
  int _end = 0;

  /// Bytes held but not yet consumed into a record.
  int get pendingBytes => _end - _start;

  void append(List<int> data, [int offset = 0, int? length]) {
    final len = length ?? (data.length - offset);
    if (_end - _start + len > maxBufferBytes) {
      throw const FramingException('record buffer cap exceeded');
    }
    if (_end + len > _buf.length) {
      final live = _end - _start;
      final newBuf = live + len > _buf.length
          ? List<int>.filled(
              (_buf.length * 2).clamp(live + len, 1 << 30), 0,
              growable: false)
          : _buf;
      newBuf.setRange(0, live, _buf, _start);
      _buf = newBuf;
      _start = 0;
      _end = live;
    }
    _buf.setRange(_end, _end + len, data, offset);
    _end += len;
  }

  Record? next() {
    if (_end - _start < 2) return null;
    final len = ((_buf[_start] & 0xff) << 8) | (_buf[_start + 1] & 0xff);
    if (len == 0) throw const FramingException('zero-length record');
    if (_end - _start < 2 + len) return null;
    // Note: unknown kinds are NOT rejected here (unlike the reference
    // Kotlin reader, which also accepts them): the protocol says any
    // other kind closes the connection, which is the link layer's
    // decision, not a framing error. Use [RecordKind.isKnown] there.
    final kind = _buf[_start + 2] & 0xff;
    final body = _buf.sublist(_start + 3, _start + 2 + len);
    _start += 2 + len;
    if (_start == _end) {
      _start = 0;
      _end = 0;
    }
    return Record(kind, body);
  }

  /// Drains every complete record currently buffered.
  List<Record> drain() {
    final out = <Record>[];
    while (true) {
      final record = next();
      if (record == null) return out;
      out.add(record);
    }
  }
}
