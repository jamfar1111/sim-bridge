/// A [Transport] over the native BLE link ([BleLink]).
///
/// Android (peripheral): one transport per incoming L2CAP channel
/// (or GATT fallback). iOS (central): one transport per connection
/// to the peripheral. Either way the byte stream is the same record
/// stream as any other transport.
///
/// The native side owns the BLE channel itself: closing the
/// transport only stops listening to the event stream (and, for the
/// central side, drops the connection — see [disconnectOnClose]).
/// The channel is closed by the native side when the central
/// disconnects (a `closed` event), or by the service through
/// [BleLink.releaseLe] / [BleLink.closeLeConnection].
library;

import 'dart:async';

import 'channels.dart';
import 'transport.dart';

/// The BLE service the peripheral advertises (protocol §1).
const String bleServiceUuid = '5ABF5C3C-2BF1-4B1C-9E8E-5D153F835BD5';

class BleTransport implements Transport {
  BleTransport(
    this.link, {
    Stream<BleEvent>? events,
    this.disconnectOnClose = false,
    this.label = 'ble',
    this._address = '',
    this.replayFirst,
  }) : _events = events ?? link.events;

  final BleLink link;

  /// When true, [close] also drops the BLE connection
  /// ([BleLink.disconnect]). Central side (iOS): yes. Peripheral
  /// side (Android): no — the channel outlives one session (a peer
  /// restart reuses the same pipe), and the service releases it
  /// explicitly.
  final bool disconnectOnClose;

  @override
  final String label;

  final Stream<BleEvent> _events;

  /// One buffered record (a HELLO from a peer restart) to deliver
  /// before the live bytes. Cleared after it is replayed.
  List<int>? replayFirst;

  String _address;

  @override
  String get address => _address;

  @override
  bool get dry => false;

  /// Called when the peer starts a new session on a *new* channel
  /// while one is up (native `peerRestart` event): the address and
  /// the first record of the new session. The service hands them to
  /// a fresh transport (replayed), so the old session is replaced.
  /// (A HELLO on the *same* pipe is caught by the link layer
  /// instead — [LinkConnection.onPeerRestart].)
  void Function(String address, List<int> firstRecord)? onPeerRestart;

  void Function(List<int>, int)? _onBytes;
  void Function()? _onClosed;
  StreamSubscription<BleEvent>? _sub;
  bool _closed = false;

  @override
  void start(void Function(List<int> bytes, int length) onBytes,
      void Function() onClosed) {
    _onBytes = onBytes;
    _onClosed = onClosed;
    // A replayed HELLO (peer restart) goes to the new connection
    // first, before any live bytes.
    final first = replayFirst;
    replayFirst = null;
    if (first != null) {
      onBytes(first, first.length);
    }
    _sub = _events.listen((e) {
      switch (e.kind) {
        case 'bytes':
          if (e.bytes != null) _onBytes?.call(e.bytes!, e.bytes!.length);
        case 'connected':
          if (e.address != null) _address = e.address!;
        case 'closed':
        case 'disconnected':
          close();
        case 'peerRestart':
          if (e.bytes != null) onPeerRestart?.call(_address, e.bytes!);
        case 'mtuChanged':
          break;
      }
    }, onError: (_) => close());
  }

  @override
  void write(List<int> bytes) {
    // Dropped when closed: the writer loop closes the connection on
    // a failed write, and the native side may already have dropped
    // the channel.
    if (_closed) return;
    unawaited(link.write(bytes).catchError((_) {}));
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    unawaited(_sub?.cancel());
    _sub = null;
    if (disconnectOnClose) {
      unawaited(link.disconnect().catchError((_) {}));
    }
    _onClosed?.call();
  }
}
