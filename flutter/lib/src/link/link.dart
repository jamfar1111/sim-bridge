/// Link layer: transports, handshake + sealed records, hub routing,
/// and the platform-channel contracts for the native bridges.
///
/// The transport only moves [Record] bytes; everything above it lives
/// here and in `../protocol/`.
library;

export 'audio_session.dart';
export 'ble_transport.dart';
export 'callkit.dart';
export 'channels.dart';
export 'client.dart';
export 'connection.dart';
export 'hub.dart';
export 'hub_data.dart';
export 'ios_audio.dart';
export 'key_store.dart';
export 'link_service.dart';
export 'transport.dart';
export 'webrtc_settings.dart';
export 'webrtc_transport.dart';
