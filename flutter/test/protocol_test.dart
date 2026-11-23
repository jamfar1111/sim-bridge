// Behavioural tests for the protocol core (no test vectors):
// framing, message envelopes, paging, audio frames, id ranges,
// number keys and handshake/session edge cases.
import 'package:flutter_test/flutter_test.dart';
import 'package:sim_bridge/src/protocol/protocol.dart';

void main() {
  group('framing', () {
    test('chunked stream reassembles 40 records', () {
      final records = List<Record>.generate(
          40, (i) => Record(i % 4 + 1, List<int>.filled(i * 53, 0x62)));
      final stream = records.expand((r) => r.encoded()).toList();
      final reader = RecordReader();
      final got = <Record>[];
      var i = 0;
      var step = 1;
      while (i < stream.length) {
        final n = step < stream.length - i ? step : stream.length - i;
        reader.append(stream, i, n);
        got.addAll(reader.drain());
        i += n;
        step = step % 89 + 2;
      }
      expect(got, records);
      expect(reader.pendingBytes, 0);
    });

    test('zero-length record throws', () {
      final reader = RecordReader()..append([0x00, 0x00]);
      expect(reader.next, throwsA(isA<FramingException>()));
    });

    test('incomplete record waits for more bytes', () {
      final record = Record(RecordKind.hello, [1, 2, 3]);
      final encoded = record.encoded();
      final reader = RecordReader()..append(encoded.sublist(0, 3));
      expect(reader.next(), isNull);
      reader.append(encoded.sublist(3));
      expect(reader.next(), record);
    });

    test('record body larger than 65534 bytes is rejected', () {
      expect(
        () => Record(0x01, List<int>.filled(65535, 0)).encoded(),
        throwsA(isA<FramingException>()),
      );
    });

    test('record round-trips through encoded bytes', () {
      const record = Record(RecordKind.sealed, [0x10, 0x20, 0x30]);
      final reader = RecordReader()..append(record.encoded());
      expect(reader.next(), record);
    });
  });

  group('hello parsing', () {
    test('bad version yields REJECT reason', () {
      final body = List<int>.filled(Proto.helloLength, 0);
      body[0] = 99;
      expect(
        () => Hello.parse(body),
        throwsA(isA<HandshakeException>()
            .having((e) => e.reject, 'reject', RejectReason.badVersion)),
      );
    });

    test('bad length and bad mode throw', () {
      expect(() => Hello.parse([1, 0]), throwsA(isA<HandshakeException>()));
      final body = List<int>.filled(Proto.helloLength, 0);
      body[0] = 1;
      body[1] = 7;
      expect(
          () => Hello.parse(body), throwsA(isA<HandshakeException>()));
    });

    test('hello encodes to 148 bytes', () {
      final hello = Hello(Proto.modePair, List<int>.filled(65, 1),
          List<int>.filled(16, 2), List<int>.filled(65, 3));
      expect(hello.encoded().length, Proto.helloLength);
      expect(Hello.parse(hello.encoded()).mode, Proto.modePair);
    });
  });

  group('messages', () {
    test('envelope round-trips, including Persian text', () {
      final message = Message(MessageType.smsSend,
          b: {'to': '123', 'body': 'سلام'}, id: 4);
      final back = Message.parse(message.toJsonBytes());
      expect(back.t, 'sms.send');
      expect(back.id, 4);
      expect(back.b['body'], 'سلام');
      expect(back.re, isNull);
    });

    test('reply envelope carries re', () {
      final reply = Message(MessageType.smsResult,
          b: {'ok': true, 'state': 'sent'}, re: 4);
      final back = Message.parse(reply.toJsonBytes());
      expect(back.re, 4);
      expect(back.b['state'], 'sent');
    });

    test('paginate splits by weight', () {
      final pages =
          paginate(List<int>.generate(100, (i) => i + 1), 1000, (_) => 90);
      expect(pages.length, 10);
      expect(pages.expand((p) => p).length, 100);
      expect(paginate(<int>[], 10, (_) => 1).length, 1);
    });

    test('sms/contact/call models round-trip through JSON', () {
      const sms = Sms(
          id: 5, thread: 2, addr: '+989121234567', body: 'hi', date: 7,
          box: 1, read: false, sub: 0);
      expect(Sms.fromJson(sms.toJson()), sms);
      const contact = Contact(
          id: 1,
          name: 'Test',
          phones: [Phone('0912', 'mobile')],
          emails: ['a@b.c'],
          starred: true);
      final contactBack = Contact.fromJson(contact.toJson());
      expect(contactBack.name, 'Test');
      expect(contactBack.phones.first.n, '0912');
      const entry = CallEntry(
          id: 9, num: '0912', date: 3, dur: 60, type: 1);
      expect(CallEntry.fromJson(entry.toJson()).dur, 60);
      const call = CallInfo(
          cid: 'c1', num: '0912', state: 'ringing', dir: 'in',
          hold: true);
      expect(CallInfo.fromJson(call.toJson()).state, 'ringing');
    });

    test('idRanges compresses consecutive ids', () {
      expect(idRanges([1, 2, 3, 5, 6, 9]), [
        [1, 3],
        [5, 6],
        [9, 9],
      ]);
      expect(idRanges([]), isEmpty);
      expect(idRanges([4, 4, 2]), [
        [2, 2],
        [4, 4],
      ]);
    });

    test('numberKey matches +98 and 0 notations', () {
      expect(numberKey('+989121234567'), '121234567');
      expect(numberKey('09121234567'), '121234567');
      expect(numberKey('+۹۸۹۱۲۱۲۳۴۵۶۷'), '121234567');
    });
  });

  group('audio frames', () {
    test('opus frame round-trips; bad codec rejected', () {
      final frame = AudioFrame(AudioFrame.opus, 65535, [1, 2]);
      final parsed = AudioFrame.parse(frame.encoded())!;
      expect(parsed.codec, AudioFrame.opus);
      expect(parsed.seq, 65535);
      expect(parsed.payload, [1, 2]);
      expect(AudioFrame.parse([9, 0, 1]), isNull);
      expect(AudioFrame.parse([1, 0]), isNull);
    });

    test('g711 silence and extremes', () {
      expect(G711.encodeSample(0), 0xff);
      expect(G711.decodeSample(0xff), 0);
      expect(G711.decodeSample(G711.encodeSample(32767)), 32124);
      expect(G711.decodeSample(G711.encodeSample(-32768)), -32124);
    });
  });

  group('session counters', () {
    test('counters start at 0 and increment per direction', () {
      final session = SecureSession(
          List<int>.filled(32, 1), List<int>.filled(32, 2));
      expect(session.sendCounter, 0);
      expect(session.recvCounter, 0);
      session.seal(Proto.channelControl, [1]);
      expect(session.sendCounter, 1);
      expect(session.recvCounter, 0);
    });

    test('opening a non-sealed record throws', () {
      final session = SecureSession(
          List<int>.filled(32, 1), List<int>.filled(32, 2));
      expect(
        () => session.open(const Record(RecordKind.hello, [1])),
        throwsA(isA<SessionException>()),
      );
    });

    test('opening a record with a skipped counter throws', () {
      final a = SecureSession(
          List<int>.filled(32, 1), List<int>.filled(32, 2));
      final b = SecureSession(
          List<int>.filled(32, 2), List<int>.filled(32, 1));
      final first = a.seal(0, [1]);
      a.seal(0, [2]); // counter 1 is never delivered to b
      b.open(first);
      // b now expects counter 1, but the next record it gets is counter 2.
      final third = a.seal(0, [3]);
      expect(
        () => b.open(third),
        throwsA(isA<SessionException>().having(
            (e) => e.message, 'message', contains('counter'))),
      );
    });
  });

  group('keys', () {
    test('generated key pair round-trips and ECDH agrees', () {
      final a = P256.generate();
      final b = P256.generate();
      final ab = P256.ecdh(a, b.publicEncoded);
      final ba = P256.ecdh(b, a.publicEncoded);
      expect(ab, ba);
      expect(ab.length, 32);
      // Rebuilding from scalar + public bytes gives the same keys.
      final rebuilt =
          P256.keyPairFromScalar(a.privateScalar, a.publicEncoded);
      expect(P256.ecdh(rebuilt, b.publicEncoded), ab);
    });

    test('bad public key is rejected', () {
      expect(() => P256.decodePublic([1, 2, 3]),
          throwsA(isA<HandshakeException>()));
      expect(
          () => P256.keyPairFromScalar(
              List<int>.filled(16, 1), List<int>.filled(65, 4)),
          throwsA(isA<HandshakeException>()));
    });
  });

  group('multi-client handshake', () {
    test('second paired central can resume', () {
      final sP = P256.generate();
      final c1 = P256.generate();
      final c2 = P256.generate();
      final centrals = [
        PairedCentral(c1.publicEncoded, name: 'iPhone'),
        PairedCentral(c2.publicEncoded, name: 'Mac', kind: 'mac'),
      ];

      // First central resumes.
      final first = CentralHandshake(c1, sP.publicEncoded);
      expect(
        PeripheralHandshake(sP)
            .receiveHello(first.hello(), pairedCentrals: centrals)
            .kind,
        RecordKind.helloAck,
      );

      // Second central resumes too — pairing it did not forget the first.
      final second = CentralHandshake(c2, sP.publicEncoded);
      expect(
        PeripheralHandshake(sP)
            .receiveHello(second.hello(), pairedCentrals: centrals)
            .kind,
        RecordKind.helloAck,
      );

      // An unknown third central is still rejected.
      final third = CentralHandshake(P256.generate(), sP.publicEncoded);
      expect(
        PeripheralHandshake(sP)
            .receiveHello(third.hello(), pairedCentrals: centrals),
        Record(RecordKind.reject, [RejectReason.unknownDevice]),
      );
    });

    test('per-key token lookup in pair mode', () {
      final sP = P256.generate();
      final tokenA = List<int>.filled(16, 0xA);
      final tokenB = List<int>.filled(16, 0xB);
      final cA = P256.generate();
      final cB = P256.generate();
      List<int>? tokenFor(List<int> key) {
        if (bytesEqual(key, cA.publicEncoded)) return tokenA;
        if (bytesEqual(key, cB.publicEncoded)) return tokenB;
        return null;
      }

      // Each central pairs with its own token and completes the handshake.
      void pairAndFinish(P256KeyPair centralKey, List<int> token) {
        final p = PeripheralHandshake(sP);
        final central =
            CentralHandshake(centralKey, sP.publicEncoded, token: token);
        final ack = p.receiveHello(central.hello(), tokenFor: tokenFor);
        expect(ack.kind, RecordKind.helloAck);
        final (session, fin) = central.receive(ack);
        final (ps, pfin) = p.receiveFinish(fin);
        central.verifyFinish(session, pfin);
        expect(ps, isNotNull);
      }

      pairAndFinish(cA, tokenA);
      pairAndFinish(cB, tokenB);

      // A central with no token for its key is rejected.
      final cC = P256.generate();
      final centralC = CentralHandshake(cC, sP.publicEncoded,
          token: List<int>.filled(16, 9));
      expect(
        PeripheralHandshake(sP)
            .receiveHello(centralC.hello(), tokenFor: tokenFor),
        Record(RecordKind.reject, [RejectReason.pairingClosed]),
      );
    });

    test('open token accepts any central in pair mode', () {
      final sP = P256.generate();
      final open = List<int>.filled(16, 3);
      final c1 =
          CentralHandshake(P256.generate(), sP.publicEncoded, token: open);
      final c2 =
          CentralHandshake(P256.generate(), sP.publicEncoded, token: open);
      expect(
        PeripheralHandshake(sP).receiveHello(c1.hello(), openToken: open).kind,
        RecordKind.helloAck,
      );
      expect(
        PeripheralHandshake(sP).receiveHello(c2.hello(), openToken: open).kind,
        RecordKind.helloAck,
      );
    });

    test('legacy single-client parameters still work', () {
      final sP = P256.generate();
      final sC = P256.generate();
      final resume = CentralHandshake(sC, sP.publicEncoded);
      expect(
        PeripheralHandshake(sP)
            .receiveHello(resume.hello(), pairedStaticKey: sC.publicEncoded)
            .kind,
        RecordKind.helloAck,
      );
    });
  });

  group('reject reasons', () {
    test('reason 4 (busy) round-trips as a REJECT record', () {
      expect(RejectReason.busy, 4);
      const reject = Record(RecordKind.reject, [RejectReason.busy]);
      final reader = RecordReader()..append(reject.encoded());
      final back = reader.next()!;
      expect(back.kind, RecordKind.reject);
      expect(back.body, [4]);
    });
  });

  group('framing', () {
    test('buffer cap throws FramingException, not RangeError', () {
      final reader = RecordReader();
      // Claim more than the 1 GiB cap without allocating it: append's
      // length parameter lets the cap check fire before any copy.
      expect(
        () => reader.append(
            [1, 2, 3], 0, RecordReader.maxBufferBytes + 1),
        throwsA(isA<FramingException>()),
      );
      expect(reader.pendingBytes, 0);
    });
  });
}
