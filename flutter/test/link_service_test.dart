// Tests for AndroidLinkService (finding 3): start/advertising,
// BLE connect + pair over the event stream, LE lifecycle calls,
// SMS/call event routing, and stop. The iPhone side is a real
// CentralConnection whose bytes are forwarded into the service's
// BLE event stream (and the service's writes back out to it).
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sim_bridge/src/link/link.dart';
import 'package:sim_bridge/src/protocol/protocol.dart';

import 'link_test.dart' show CollectingListener, waitFor;

/// Central-side transport whose writes go into the service's BLE
/// event stream, and whose reads come from the service's BLE writes.
class ForwardingTransport implements Transport {
  @override
  String label = 'test';

  @override
  String address = 'iphone';

  @override
  bool get dry => false;

  void Function(List<int> bytes)? onWrite;

  void Function(List<int>, int)? _onBytes;
  void Function()? _onClosed;

  @override
  void start(void Function(List<int>, int) onBytes, void Function() onClosed) {
    _onBytes = onBytes;
    _onClosed = onClosed;
  }

  @override
  void write(List<int> bytes) => onWrite?.call(bytes);

  @override
  void close() => _onClosed?.call();

  void deliver(List<int> bytes) => _onBytes?.call(bytes, bytes.length);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  final bleCalls = <MethodCall>[];
  final smsCalls = <MethodCall>[];
  final telecomCalls = <MethodCall>[];
  final audioCalls = <MethodCall>[];
  final bleEvents = StreamController<BleEvent>.broadcast();
  MockStreamHandlerEventSink? smsSink;
  MockStreamHandlerEventSink? telecomSink;

  late ForwardingTransport centralTransport;

  /// The transport the BLE `write` mock delivers to: the current
  /// central (updated when a second central connects).
  ForwardingTransport? currentCentralTransport;

  dynamic bleHandler(MethodCall call) {
    switch (call.method) {
      case 'startAdvertising':
        return true;
      case 'ensureAdvertising':
        return true;
      case 'write':
        final bytes = (call.arguments as Map)['bytes'];
        if (bytes is Uint8List) {
          currentCentralTransport?.deliver(bytes.toList());
        }
        return true;
    }
    return null;
  }

  dynamic smsHandler(MethodCall call) {
    switch (call.method) {
      case 'contactsVersion':
        return 'v1';
      case 'statusJson':
        return <String, dynamic>{'device': 'test'};
      case 'listsJson':
        return <String, dynamic>{
          'blocked': <String>[],
          'muted': <int>[],
          'system': false,
        };
      case 'smsSince':
      case 'callsSince':
      case 'contactsAll':
      case 'smsAllIds':
      case 'callAllIds':
      case 'unreadSmsIds':
        return <dynamic>[];
    }
    return null;
  }

  setUp(() {
    bleCalls.clear();
    smsCalls.clear();
    telecomCalls.clear();
    audioCalls.clear();
    smsSink = null;
    telecomSink = null;
    messenger.setMockMethodCallHandler(
        const MethodChannel('com.simbridge/ble'), (call) async {
      bleCalls.add(call);
      return bleHandler(call);
    });
    messenger.setMockMethodCallHandler(
        const MethodChannel('com.simbridge/sms'), (call) async {
      smsCalls.add(call);
      return smsHandler(call);
    });
    messenger.setMockMethodCallHandler(
        const MethodChannel('com.simbridge/telecom'), (call) async {
      telecomCalls.add(call);
      return null;
    });
    messenger.setMockMethodCallHandler(
        const MethodChannel('com.simbridge/audio'), (call) async {
      audioCalls.add(call);
      return null;
    });
    messenger.setMockStreamHandler(
        const EventChannel('com.simbridge/sms/events'),
        MockStreamHandler.inline(
            onListen: (args, events) => smsSink = events));
    messenger.setMockStreamHandler(
        const EventChannel('com.simbridge/telecom/events'),
        MockStreamHandler.inline(
            onListen: (args, events) => telecomSink = events));
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(
        const MethodChannel('com.simbridge/ble'), null);
    messenger.setMockMethodCallHandler(
        const MethodChannel('com.simbridge/sms'), null);
    messenger.setMockMethodCallHandler(
        const MethodChannel('com.simbridge/telecom'), null);
    messenger.setMockMethodCallHandler(
        const MethodChannel('com.simbridge/audio'), null);
    messenger.setMockStreamHandler(
        const EventChannel('com.simbridge/sms/events'), null);
    messenger.setMockStreamHandler(
        const EventChannel('com.simbridge/telecom/events'), null);
  });

  Future<(AndroidLinkService, KeyStore)> startService() async {
    final keyStore = KeyStore(backend: MemoryKeyStoreBackend());
    final service = AndroidLinkService(
      ble: BleLink(),
      sms: SmsBridge(),
      telecom: TelecomBridge(),
      audio: CallAudioBridge(),
      keyStore: keyStore,
      bleEvents: bleEvents.stream,
    );
    await service.start();
    return (service, keyStore);
  }

  /// Connects a central over the BLE event stream and pairs it.
  /// Returns the central, its listener, and its key pair (so a
  /// later test can reconnect with the same — paired — keys).
  Future<(CentralConnection, CollectingListener, P256KeyPair)>
      connectCentral(AndroidLinkService service, KeyStore keyStore) async {
    final code = await service.openPairing();
    final centralKeys = P256.generate();
    centralTransport = ForwardingTransport();
    currentCentralTransport = centralTransport;
    centralTransport.onWrite = (bytes) {
      bleEvents.add(BleEvent.parse(Uint8List.fromList(bytes)));
    };
    final listener = CollectingListener();
    final central = CentralConnection(
      centralTransport,
      listener,
      CentralKeys(
        staticKey: centralKeys,
        peerStatic: keyStore.ownKey.publicEncoded,
        token: code.token,
      ),
    );
    bleEvents.add(BleEvent.parse({
      't': 'connected',
      'address': 'AA:BB:CC:DD:EE:FF',
    }));
    // The service creates the transport synchronously on the event.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    central.start();
    await waitFor(() => central.isUp && service.hub.conns.isNotEmpty);
    return (central, listener, centralKeys);
  }

  group('AndroidLinkService', () {
    test('start advertises and loads the key store', () async {
      final (service, keyStore) = await startService();
      expect(service.isRunning, isTrue);
      expect(keyStore.ownKey.publicEncoded.length, 65);
      expect(
          bleCalls.any((c) =>
              c.method == 'startAdvertising' &&
              (c.arguments as Map)['serviceUuid'] ==
                  '5ABF5C3C-2BF1-4B1C-9E8E-5D153F835BD5'),
          isTrue);
      expect(service.data.contactsVersion(), 'v1');
      await service.stop();
      expect(service.isRunning, isFalse);
      expect(bleCalls.any((c) => c.method == 'stopAdvertising'), isTrue);
    });

    test('BLE connect + pair: LE held, central persisted', () async {
      final (service, keyStore) = await startService();
      final (central, _, _) = await connectCentral(service, keyStore);
      // The session holds the LE link.
      expect(
          bleCalls.any((c) =>
              c.method == 'setLinked' &&
              (c.arguments as Map)['on'] == true),
          isTrue);
      expect(
          bleCalls.any((c) =>
              c.method == 'holdLe' &&
              (c.arguments as Map)['address'] == 'AA:BB:CC:DD:EE:FF'),
          isTrue);
      // The paired central was persisted.
      expect(keyStore.pairedCentrals.length, 1);
      expect(keyStore.isPaired, isTrue);
      // Pairing closed itself after the pairing completed.
      expect(keyStore.currentToken, isNull);
      central.close();
      await service.stop();
    });

    test('session down releases the LE link', () async {
      final (service, keyStore) = await startService();
      final (central, _, _) = await connectCentral(service, keyStore);
      central.close();
      // In reality the native BLE layer reports the disconnect; the
      // test feeds that event so the transport closes.
      bleEvents.add(BleEvent.parse({
        't': 'disconnected',
        'address': 'AA:BB:CC:DD:EE:FF',
      }));
      await waitFor(() => bleCalls.any((c) =>
          c.method == 'releaseLe' &&
          (c.arguments as Map)['address'] == 'AA:BB:CC:DD:EE:FF'));
      expect(
          bleCalls.any((c) =>
              c.method == 'setLinked' &&
              (c.arguments as Map)['on'] == false),
          isTrue);
      await service.stop();
    });

    test('incoming SMS and call events reach the iPhone', () async {
      final (service, keyStore) = await startService();
      final (_, listener, _) = await connectCentral(service, keyStore);
      // The Hub needs the sync before it sends anything; the client
      // already synced on establish (LinkClient is not used here, so
      // send a sync from the test central).
      // Incoming SMS via the native event channel.
      smsSink?.success({
        't': 'sms.new',
        'item': {
          'id': 7,
          'thread': 5,
          'addr': '+989121234567',
          'body': 'سلام',
          'date': 2000,
          'box': 1,
          'read': false,
        },
      });
      await waitFor(() => listener.messages
          .any((e) => e.$2.t == MessageType.smsNew));
      // Live call via the telecom event channel.
      telecomSink?.success({
        'cid': 'c1',
        'num': '+989121234567',
        'state': 'ringing',
        'dir': 'in',
        'hold': true,
      });
      await waitFor(() => listener.messages
          .any((e) => e.$2.t == MessageType.callState));
      final callState = listener.messages
          .firstWhere((e) => e.$2.t == MessageType.callState)
          .$2;
      expect(callState.b['cid'], 'c1');
      expect(callState.b['state'], 'ringing');
      // Read-state change.
      smsSink?.success({
        't': 'sms.readChanged',
        'ids': [7],
      });
      await waitFor(() => listener.messages
          .any((e) => e.$2.t == MessageType.smsUnread));
      await service.stop();
    });

    test('peer restart on the same pipe replays the HELLO', () async {
      final (service, keyStore) = await startService();
      final (central, _, centralKeys) =
          await connectCentral(service, keyStore);
      // The same iPhone restarts its app and sends a fresh HELLO
      // into the same BLE event stream while the old session is up
      // (resume mode: already paired, no token). The old connection
      // sees the HELLO, closes, and the service replays it on a
      // fresh transport so the new handshake runs; the Hub replaces
      // the old session with the new one.
      final transport2 = ForwardingTransport();
      currentCentralTransport = transport2;
      transport2.onWrite = (bytes) {
        bleEvents.add(BleEvent.parse(Uint8List.fromList(bytes)));
      };
      final listener2 = CollectingListener();
      final central2 = CentralConnection(
        transport2,
        listener2,
        CentralKeys(
          staticKey: centralKeys,
          peerStatic: keyStore.ownKey.publicEncoded,
        ),
      );
      central2.start();
      await waitFor(() => central2.isUp);
      // The Hub replaced the old session with the new one (the old
      // central object is the pre-restart app; it never learns — the
      // peripheral side is what closed).
      expect(service.hub.conns.length, 1);
      expect(service.hub.conns.first.isUp, isTrue);
      central.close();
      central2.close();
      await service.stop();
    });
  });
}
