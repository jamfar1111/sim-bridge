/// Byte-level helpers shared by the protocol layer.
///
/// Mirrors the `Bytes` object in Tether's Android core (`core/Records.kt`).
library;

import 'dart:convert' as convert;

/// Lower-case hex encoding, two characters per byte.
String hexEncode(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// Decodes a lower- or upper-case hex string. Throws [FormatException]
/// on odd length or non-hex characters.
List<int> hexDecode(String hex) {
  final clean = hex.trim();
  if (clean.length.isOdd) {
    throw const FormatException('hex string has odd length');
  }
  final out = <int>[];
  for (var i = 0; i < clean.length; i += 2) {
    out.add(int.parse(clean.substring(i, i + 2), radix: 16));
  }
  return out;
}

/// Concatenates byte lists into one new list.
List<int> concatBytes(List<List<int>> parts) =>
    parts.expand((part) => part).toList(growable: false);

/// Encodes a 64-bit unsigned integer as 8 big-endian bytes.
List<int> be64(int value) =>
    List<int>.generate(8, (i) => (value >> (56 - 8 * i)) & 0xff,
        growable: false);

/// Reads 8 big-endian bytes at [offset] as an unsigned 64-bit integer.
int readBe64(List<int> bytes, int offset) {
  var value = 0;
  for (var i = 0; i < 8; i++) {
    value = (value << 8) | (bytes[offset + i] & 0xff);
  }
  return value;
}

/// Base64url without padding (as used in QR pairing codes).
String b64url(List<int> bytes) =>
    convert.base64Url.encode(bytes).replaceAll('=', '');

/// Decodes base64url with or without padding. Throws [FormatException]
/// on invalid input.
List<int> unb64url(String value) {
  var s = value.trim();
  while (s.length % 4 != 0) {
    s += '=';
  }
  return convert.base64Url.decode(s);
}

/// Equality for short secrets (length check first, then all bytes).
bool bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}
