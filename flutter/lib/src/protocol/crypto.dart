/// P-256 handshake, HKDF key schedule and AES-256-GCM sealed records
/// (protocol §3–§4).
///
/// Mirrors Tether's Android core (`core/Crypto.kt`). Primitives come from
/// the `pointycastle` package (pure Dart: ECDH P-256, HKDF-SHA256,
/// AES-256-GCM, SHA-256); everything wire-format related is implemented
/// here so the byte layout matches `protocol/vectors.json` exactly.
///
/// Note: the `cryptography` package was tried first, but its pure-Dart
/// ECDH throws `UnimplementedError` on the Dart VM (it only works in a
/// browser via WebCrypto), so it cannot reproduce the handshake vectors.
library;

import 'dart:convert' show utf8;
import 'dart:math' show Random;
import 'dart:typed_data' show Uint8List;

import 'package:pointycastle/export.dart';

import 'bytes.dart';
import 'records.dart';

class HandshakeException implements Exception {
  const HandshakeException(this.message, [this.reject]);

  final String message;

  /// REJECT reason to send, if the peer should be told (see [RejectReason]).
  final int? reject;

  @override
  String toString() => 'HandshakeException: $message';
}

class SessionException implements Exception {
  const SessionException(this.message);

  final String message;

  @override
  String toString() => 'SessionException: $message';
}

/// Protocol constants (protocol §2–§4).
abstract final class Proto {
  static const int version = 1;
  static const int modeResume = 0;
  static const int modePair = 1;
  static const int helloLength = 148;
  static const int helloAckLength = 82;

  /// Sealed-record plaintext channels.
  static const int channelControl = 0x00;
  static const int channelAudio = 0x01;
  static const int channelFinish = 0xff;

  static const String transcriptLabel = 'TETHER-HS-1';
  static const String hkdfInfo = 'tether/1 keys';

  /// A session never sends 2^32 records; it reconnects instead.
  static const int maxRecords = 1 << 32;
}

/// A P-256 key pair: a 32-byte private scalar and its 65-byte public
/// encoding (uncompressed X9.63 point, `0x04 ‖ X ‖ Y`).
class P256KeyPair {
  P256KeyPair(this.privateScalar, this.publicEncoded);

  /// 32-byte private scalar, big-endian.
  final List<int> privateScalar;

  /// 65-byte uncompressed public point.
  final List<int> publicEncoded;

  ECPrivateKey get _privateKey =>
      ECPrivateKey(P256._bytesToBigInt(privateScalar), P256._params);
}

/// P-256 helpers: X9.63 uncompressed encoding, ECDH, HKDF, SHA-256.
abstract final class P256 {
  static final ECDomainParameters _params =
      ECDomainParameters('prime256v1');

  /// Generates a fresh P-256 key pair.
  static P256KeyPair generate() {
    final random = Random.secure();
    final n = _params.n;
    BigInt d;
    do {
      final bytes = List<int>.generate(32, (_) => random.nextInt(256));
      d = _bytesToBigInt(bytes);
    } while (d <= BigInt.zero || d >= n);
    final q = _params.G * d;
    return P256KeyPair(
      _bigIntToBytes(d, 32),
      q!.getEncoded(false),
    );
  }

  /// Builds a key pair from a 32-byte private scalar and its 65-byte
  /// public encoding (used to reproduce the test vectors).
  static P256KeyPair keyPairFromScalar(
      List<int> privateScalar, List<int> publicEncoded) {
    if (privateScalar.length != 32) {
      throw const HandshakeException('bad private key length');
    }
    // Validates the format (and that the point is on the curve).
    decodePublic(publicEncoded);
    return P256KeyPair(
        List<int>.of(privateScalar), List<int>.of(publicEncoded));
  }

  /// Validates a 65-byte uncompressed X9.63 point and returns it as an
  /// [ECPublicKey]. Throws [HandshakeException] on bad format or a point
  /// off the curve.
  static ECPublicKey decodePublic(List<int> encoded) {
    if (encoded.length != 65 || encoded[0] != 0x04) {
      throw const HandshakeException('bad public key');
    }
    try {
      return ECPublicKey(
          _params.curve.decodePoint(encoded), _params);
    } catch (e) {
      throw HandshakeException('bad public key: $e');
    }
  }

  /// ECDH; returns the 32-byte X coordinate.
  static List<int> ecdh(P256KeyPair private, List<int> peerPublicEncoded) {
    final agreement = ECDHBasicAgreement()..init(private._privateKey);
    BigInt shared;
    try {
      shared = agreement.calculateAgreement(decodePublic(peerPublicEncoded));
    } catch (e) {
      throw HandshakeException('ECDH failed: $e');
    }
    return _bigIntToBytes(shared, 32);
  }

  static List<int> sha256(List<List<int>> parts) {
    final digest = SHA256Digest();
    final data = Uint8List.fromList(concatBytes(parts));
    return digest.process(data);
  }

  /// HKDF-SHA256. `salt` is the HKDF salt (never empty in this protocol).
  static List<int> hkdf(
      List<int> salt, List<int> ikm, List<int> info, int length) {
    final derivator = HKDFKeyDerivator(SHA256Digest())
      ..init(HkdfParameters(
        Uint8List.fromList(ikm),
        length,
        Uint8List.fromList(salt),
        Uint8List.fromList(info),
      ));
    final out = Uint8List(length);
    derivator.deriveKey(null, 0, out, 0);
    return out;
  }

  /// 16 cryptographically random bytes.
  static List<int> randomNonce([int length = 16]) {
    final random = Random.secure();
    return List<int>.generate(length, (_) => random.nextInt(256),
        growable: false);
  }

  static BigInt _bytesToBigInt(List<int> bytes) {
    var value = BigInt.zero;
    for (final byte in bytes) {
      value = (value << 8) | BigInt.from(byte & 0xff);
    }
    return value;
  }

  static List<int> _bigIntToBytes(BigInt value, int length) {
    final out = List<int>.filled(length, 0, growable: false);
    var v = value;
    for (var i = length - 1; i >= 0; i--) {
      out[i] = (v & BigInt.from(0xff)).toInt();
      v >>= 8;
    }
    if (v != BigInt.zero) {
      throw ArgumentError('BigInt does not fit in $length bytes');
    }
    return out;
  }
}

/// Session keys derived by the handshake (protocol §3).
class SessionKeys {
  const SessionKeys(this.th, this.c2p, this.p2c);

  /// Transcript hash: `SHA-256("TETHER-HS-1" ‖ HELLO ‖ HELLO_ACK)`.
  final List<int> th;

  /// Central → peripheral key.
  final List<int> c2p;

  /// Peripheral → central key.
  final List<int> p2c;
}

abstract final class KeySchedule {
  static List<int> transcript(List<int> helloBody, List<int> ackBody) =>
      P256.sha256([
        utf8.encode(Proto.transcriptLabel),
        helloBody,
        ackBody,
      ]);

  static SessionKeys derive(List<int> dh1, List<int> dh2, List<int> dh3,
      List<int> psk, List<int> th) {
    final okm = P256.hkdf(
      th,
      concatBytes([dh1, dh2, dh3, psk]),
      utf8.encode(Proto.hkdfInfo),
      64,
    );
    return SessionKeys(th, okm.sublist(0, 32), okm.sublist(32, 64));
  }
}

/// HELLO body (C → P), 148 bytes:
/// `ver: u8 = 1 | mode: u8 | E_C: 65 | n_C: 16 | S_C: 65`.
class Hello {
  const Hello(this.mode, this.ephemeral, this.nonce, this.staticKey);

  final int mode;
  final List<int> ephemeral;
  final List<int> nonce;
  final List<int> staticKey;

  List<int> encoded() => concatBytes([
        [Proto.version, mode],
        ephemeral,
        nonce,
        staticKey,
      ]);

  static Hello parse(List<int> body) {
    if (body.length != Proto.helloLength) {
      throw const HandshakeException('bad hello length');
    }
    if (body[0] != Proto.version) {
      throw HandshakeException('bad version', RejectReason.badVersion);
    }
    final mode = body[1];
    if (mode != Proto.modePair && mode != Proto.modeResume) {
      throw const HandshakeException('bad mode');
    }
    return Hello(
      mode,
      body.sublist(2, 67),
      body.sublist(67, 83),
      body.sublist(83, 148),
    );
  }
}

/// AES-256-GCM record layer with strict per-direction counters
/// (protocol §4).
///
/// ```
/// nonce = 0x00000000 ‖ ctr (u64)        12 bytes
/// aad   = 0x10 ‖ ctr (u64)              9 bytes
/// ```
///
/// Each direction counts from 0 and adds 1 per record. The receiver
/// requires `ctr` to equal the next expected value exactly; anything else
/// (replay, gap, reorder, bad tag) throws [SessionException].
class SecureSession {
  SecureSession(List<int> sendKey, List<int> recvKey)
      : _sendKey = Uint8List.fromList(sendKey),
        _recvKey = Uint8List.fromList(recvKey);

  final Uint8List _sendKey;
  final Uint8List _recvKey;

  int sendCounter = 0;
  int recvCounter = 0;

  static List<int> nonce(int ctr) => concatBytes([
        [0, 0, 0, 0],
        be64(ctr),
      ]);

  static List<int> aad(int ctr) => concatBytes([
        [RecordKind.sealed],
        be64(ctr),
      ]);

  /// Seals `channel ‖ payload` as a SEALED record.
  Record seal(int channel, List<int> payload) {
    if (sendCounter >= Proto.maxRecords) {
      throw const SessionException('session exhausted');
    }
    final ctr = sendCounter++;
    final plain = Uint8List.fromList(concatBytes([
      [channel],
      payload,
    ]));
    final cipher = GCMBlockCipher(AESEngine())
      ..init(
        true,
        AEADParameters(
          KeyParameter(_sendKey),
          128,
          Uint8List.fromList(nonce(ctr)),
          Uint8List.fromList(aad(ctr)),
        ),
      );
    // GCM output is ciphertext ‖ 16-byte tag.
    final out = Uint8List(plain.length + 16);
    var len = cipher.processBytes(plain, 0, plain.length, out, 0);
    len += cipher.doFinal(out, len);
    return Record(
      RecordKind.sealed,
      concatBytes([be64(ctr), out.sublist(0, len)]),
    );
  }

  /// Opens a SEALED record. Returns `(channel, payload)`.
  /// Throws [SessionException] on any counter mismatch or auth failure.
  (int, List<int>) open(Record record) {
    if (record.kind != RecordKind.sealed) {
      throw const SessionException('not sealed');
    }
    final body = record.body;
    if (body.length < 8 + 16 + 1) {
      throw const SessionException('too short');
    }
    final ctr = readBe64(body, 0);
    if (ctr != recvCounter) {
      throw SessionException(
          'counter mismatch: expected $recvCounter got $ctr');
    }
    final cipherTextWithTag =
        Uint8List.fromList(body.sublist(8));
    final cipher = GCMBlockCipher(AESEngine())
      ..init(
        false,
        AEADParameters(
          KeyParameter(_recvKey),
          128,
          Uint8List.fromList(nonce(ctr)),
          Uint8List.fromList(aad(ctr)),
        ),
      );
    final out = Uint8List(cipherTextWithTag.length);
    List<int> plain;
    try {
      var len = cipher.processBytes(
          cipherTextWithTag, 0, cipherTextWithTag.length, out, 0);
      len += cipher.doFinal(out, len);
      plain = out.sublist(0, len);
    } on InvalidCipherTextException {
      throw const SessionException('auth failed');
    }
    recvCounter++;
    return (plain[0] & 0xff, plain.sublist(1));
  }
}

/// A central (iPhone/Mac) that completed pairing with this peripheral.
/// Mirrors Tether's `Keys.Central` (link/Keys.kt): pairing a second
/// device never forgets the first.
class PairedCentral {
  const PairedCentral(this.staticKey,
      {this.name = 'iPhone', this.kind = 'iphone'});

  /// The central's long-term static public key (65 bytes).
  final List<int> staticKey;

  final String name;
  final String kind;

  bool matches(List<int> key) => bytesEqual(staticKey, key);
}

/// Peripheral (Android) side of the handshake.
class PeripheralHandshake {
  PeripheralHandshake(
    this.staticKey, {
    P256KeyPair? ephemeral,
    List<int>? nonce,
  })  : _ephemeral = ephemeral ?? P256.generate(),
        _nonce = nonce ?? P256.randomNonce();

  final P256KeyPair staticKey;
  final P256KeyPair _ephemeral;
  final List<int> _nonce;

  Hello? hello;
  SessionKeys? keys;
  SecureSession? _session;

  /// Handles a HELLO record.
  ///
  /// Mirrors Kotlin `Crypto.kt`'s primary overload
  /// `receiveHello(r, isKnown, tokenFor)`:
  /// - resume mode accepts any key in [pairedCentrals] (or the legacy
  ///   single [pairedStaticKey]);
  /// - pair mode takes the token from [tokenFor] for that central's key
  ///   (or the legacy single [openToken], which accepts any key).
  /// A caller that wants the Kotlin `Keys.tokenFor` behaviour passes a
  /// lookup returning the open pairing token, or — for a short window
  /// after a pairing completed — that pairing's token for the same
  /// central only.
  /// Returns HELLO_ACK, or REJECT (unknown device / pairing closed /
  /// bad version).
  Record receiveHello(
    Record record, {
    List<PairedCentral> pairedCentrals = const [],
    List<int>? Function(List<int> centralKey)? tokenFor,
    List<int>? pairedStaticKey,
    List<int>? openToken,
  }) {
    if (record.kind != RecordKind.hello) {
      throw const HandshakeException('expected HELLO');
    }
    final Hello parsed;
    try {
      parsed = Hello.parse(record.body);
    } on HandshakeException catch (e) {
      return Record(
          RecordKind.reject, [e.reject ?? RejectReason.badVersion]);
    }
    hello = parsed;
    bool isKnown(List<int> key) =>
        pairedCentrals.any((c) => c.matches(key)) ||
        (pairedStaticKey != null && bytesEqual(pairedStaticKey, key));
    final List<int> psk;
    if (parsed.mode == Proto.modeResume) {
      if (!isKnown(parsed.staticKey)) {
        return Record(RecordKind.reject, [RejectReason.unknownDevice]);
      }
      psk = const [];
    } else {
      final token =
          tokenFor != null ? tokenFor(parsed.staticKey) : openToken;
      if (token == null) {
        return Record(RecordKind.reject, [RejectReason.pairingClosed]);
      }
      psk = token;
    }
    final ack = concatBytes([
      [Proto.version],
      _ephemeral.publicEncoded,
      _nonce,
    ]);
    final dh1 = P256.ecdh(_ephemeral, parsed.ephemeral);
    final dh2 = P256.ecdh(staticKey, parsed.ephemeral);
    final dh3 = P256.ecdh(_ephemeral, parsed.staticKey);
    final th = KeySchedule.transcript(record.body, ack);
    final derived = KeySchedule.derive(dh1, dh2, dh3, psk, th);
    keys = derived;
    _session = SecureSession(derived.p2c, derived.c2p);
    return Record(RecordKind.helloAck, ack);
  }

  /// Verifies the central's FIN; returns the session and our FIN record.
  (SecureSession, Record) receiveFinish(Record record) {
    final session = _session;
    final derived = keys;
    if (session == null || derived == null) {
      throw const HandshakeException('no hello');
    }
    final (channel, payload) = session.open(record);
    if (channel != Proto.channelFinish ||
        !bytesEqual(payload, derived.th)) {
      throw const HandshakeException('finish mismatch');
    }
    return (session, session.seal(Proto.channelFinish, derived.th));
  }
}

/// Central (iPhone) side of the handshake.
class CentralHandshake {
  CentralHandshake(
    this.staticKey,
    this.peerStatic, {
    this.token,
    P256KeyPair? ephemeral,
    List<int>? nonce,
  })  : _ephemeral = ephemeral ?? P256.generate(),
        _nonce = nonce ?? P256.randomNonce();

  final P256KeyPair staticKey;

  /// The peripheral's long-term static public key (65 bytes).
  final List<int> peerStatic;

  /// Pairing token, or `null` for resume mode.
  final List<int>? token;

  final P256KeyPair _ephemeral;
  final List<int> _nonce;

  List<int>? helloBody;
  SessionKeys? keys;

  /// Builds the HELLO record.
  Record hello() {
    final mode = token == null ? Proto.modeResume : Proto.modePair;
    helloBody = Hello(mode, _ephemeral.publicEncoded, _nonce,
            staticKey.publicEncoded)
        .encoded();
    return Record(RecordKind.hello, helloBody!);
  }

  /// Handles HELLO_ACK (or REJECT). Returns the session and our FIN.
  (SecureSession, Record) receive(Record record) {
    if (record.kind == RecordKind.reject) {
      throw HandshakeException('rejected',
          record.body.isNotEmpty ? record.body[0] & 0xff : null);
    }
    if (record.kind != RecordKind.helloAck ||
        record.body.length != Proto.helloAckLength) {
      throw const HandshakeException('bad ack');
    }
    final hello = helloBody;
    if (hello == null) throw const HandshakeException('no hello sent');
    final eP = record.body.sublist(1, 66);
    final dh1 = P256.ecdh(_ephemeral, eP);
    final dh2 = P256.ecdh(_ephemeral, peerStatic);
    final dh3 = P256.ecdh(staticKey, eP);
    final th = KeySchedule.transcript(hello, record.body);
    final derived =
        KeySchedule.derive(dh1, dh2, dh3, token ?? const [], th);
    keys = derived;
    final session = SecureSession(derived.c2p, derived.p2c);
    return (session, session.seal(Proto.channelFinish, th));
  }

  /// Verifies the peripheral's FIN record.
  void verifyFinish(SecureSession session, Record record) {
    final derived = keys;
    if (derived == null) throw const HandshakeException('no keys');
    final (channel, payload) = session.open(record);
    if (channel != Proto.channelFinish ||
        !bytesEqual(payload, derived.th)) {
      throw const HandshakeException('finish mismatch');
    }
  }
}

/// QR payload `tether1:<S_P>.<token>.<name>` (protocol §3).
class PairingCode {
  const PairingCode(this.peripheralKey, this.token, this.deviceName);

  static const String prefix = 'tether1:';

  /// The peripheral's long-term static public key (65 bytes).
  final List<int> peripheralKey;

  /// 16 random bytes.
  final List<int> token;

  final String deviceName;

  String encode() =>
      '$prefix${b64url(peripheralKey)}.${b64url(token)}.${b64url(utf8.encode(deviceName))}';

  /// Parses a QR string; returns `null` on any malformed input.
  static PairingCode? parse(String value) {
    final text = value.trim();
    if (!text.startsWith(prefix)) return null;
    final parts = text.substring(prefix.length).split('.');
    if (parts.length != 3) return null;
    try {
      final key = unb64url(parts[0]);
      final token = unb64url(parts[1]);
      if (key.length != 65 || key[0] != 0x04 || token.length != 16) {
        return null;
      }
      return PairingCode(key, token, utf8.decode(unb64url(parts[2])));
    } on FormatException {
      return null;
    }
  }
}
