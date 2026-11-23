/// Tether link protocol v1 — transport-independent core.
///
/// Implemented from `protocol/PROTOCOL.md` and tested against
/// `protocol/vectors.json`. The transport (BLE L2CAP/GATT, TCP/WebRTC)
/// only has to move [Record] bytes; everything above it lives here.
library;

export 'audio.dart';
export 'bytes.dart';
export 'crypto.dart';
export 'messages.dart';
export 'otp.dart';
export 'records.dart';
