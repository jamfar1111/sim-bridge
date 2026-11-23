/// Audio channel frames (protocol §4) and G.711 µ-law (bit-exact with the
/// iOS implementation).
///
/// Audio is drop-late: frames more than 60 ms old are discarded before
/// sealing, so counters stay contiguous. `seq` keeps counting for the
/// whole call.
library;

/// Audio channel frame: `codec: u8 ‖ seq: u16 ‖ frame bytes`. 20 ms per
/// frame.
class AudioFrame {
  const AudioFrame(this.codec, this.seq, this.payload);

  static const int opus = 1;
  static const int pcmu = 2;

  final int codec;
  final int seq;
  final List<int> payload;

  List<int> encoded() => [
        codec & 0xff,
        (seq >> 8) & 0xff,
        seq & 0xff,
        ...payload,
      ];

  /// Parses a frame; returns `null` on a short buffer or unknown codec.
  static AudioFrame? parse(List<int> bytes) {
    if (bytes.length < 3) return null;
    final codec = bytes[0] & 0xff;
    if (codec != opus && codec != pcmu) return null;
    final seq = ((bytes[1] & 0xff) << 8) | (bytes[2] & 0xff);
    return AudioFrame(codec, seq, bytes.sublist(3));
  }
}

/// G.711 µ-law, bit-exact with the iOS implementation (see
/// `protocol/vectors.json` → `g711`).
abstract final class G711 {
  /// Encodes one 16-bit PCM sample to one µ-law byte (0–255).
  static int encodeSample(int sample) {
    var s = sample;
    final sign = s < 0 ? 0x80 : 0;
    if (s < 0) s = -s;
    if (s > 32635) s = 32635;
    s += 0x84;
    var exp = 7;
    var mask = 0x4000;
    while (exp > 0 && (s & mask) == 0) {
      exp--;
      mask >>= 1;
    }
    final mantissa = (s >> (exp + 3)) & 0x0f;
    return (~(sign | (exp << 4) | mantissa)) & 0xff;
  }

  /// Decodes one µ-law byte (0–255) to a 16-bit PCM sample.
  static int decodeSample(int byte) {
    final u = (~byte) & 0xff;
    final sign = u & 0x80;
    final exp = (u >> 4) & 7;
    final mantissa = u & 0x0f;
    final s = (((mantissa << 3) + 0x84) << exp) - 0x84;
    return sign != 0 ? -s : s;
  }

  static List<int> encode(List<int> pcm) =>
      pcm.map(encodeSample).toList(growable: false);

  static List<int> decode(List<int> ulaw) =>
      ulaw.map(decodeSample).toList(growable: false);
}
