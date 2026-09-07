import 'dart:convert';
import 'dart:typed_data';

/// A deterministic CBOR encoder and decoder covering exactly the subset the
/// certificate payload needs (RFC 8949 core deterministic encoding).
///
/// **Why hand-rolled rather than a package.** The same bytes must be produced
/// and verified by two independent implementations — this one and the
/// TypeScript `cert-core` used by the dashboard. A signature covers bytes, not
/// meaning, so any disagreement about map key ordering, integer width or string
/// handling between two general-purpose CBOR libraries silently breaks every
/// certificate. Owning ~200 lines of encoder is a far smaller risk than
/// reconciling two libraries' notions of "canonical", and it lets the byte
/// layout be pinned by shared test vectors.
///
/// Deterministic rules enforced here:
///
/// * Integers use the shortest form that fits.
/// * Only definite-length strings, arrays and maps.
/// * Map keys are sorted bytewise-lexicographically **by their encoded form**,
///   which is RFC 8949 section 4.2.1 ordering — not by numeric or lexical key
///   value. For small integer keys the two happen to coincide; for anything
///   else they do not.
/// * No floats, tags or indefinite lengths are emitted, and they are rejected
///   on decode rather than tolerated.
class CanonicalCbor {
  const CanonicalCbor._();

  // Major types, pre-shifted into the high three bits of the initial byte.
  static const int majorUnsigned = 0 << 5;
  static const int majorNegative = 1 << 5;
  static const int majorBytes = 2 << 5;
  static const int majorText = 3 << 5;
  static const int majorArray = 4 << 5;
  static const int majorMap = 5 << 5;
  static const int majorSimple = 7 << 5;

  static const int simpleFalse = 20;
  static const int simpleTrue = 21;
  static const int simpleNull = 22;

  /// Encodes [value] to canonical CBOR.
  ///
  /// Accepts `null`, `bool`, `int`, `String`, [CborBytes] for byte strings,
  /// `List` and `Map`.
  static Uint8List encode(Object? value) {
    final out = BytesBuilder(copy: false);
    _encodeValue(value, out);
    return out.takeBytes();
  }

  static void _encodeValue(Object? value, BytesBuilder out) {
    if (value == null) {
      out.addByte(majorSimple | simpleNull);
    } else if (value is bool) {
      out.addByte(majorSimple | (value ? simpleTrue : simpleFalse));
    } else if (value is int) {
      if (value >= 0) {
        _encodeHead(majorUnsigned, value, out);
      } else {
        // Negative integers encode as -1 - n, so -1 becomes argument 0.
        _encodeHead(majorNegative, -1 - value, out);
      }
    } else if (value is CborBytes) {
      _encodeHead(majorBytes, value.bytes.length, out);
      out.add(value.bytes);
    } else if (value is String) {
      final encoded = utf8.encode(value);
      _encodeHead(majorText, encoded.length, out);
      out.add(encoded);
    } else if (value is List) {
      _encodeHead(majorArray, value.length, out);
      for (final element in value) {
        _encodeValue(element, out);
      }
    } else if (value is Map) {
      _encodeMap(value, out);
    } else {
      throw CborError('Unsupported type for canonical CBOR: ${value.runtimeType}');
    }
  }

  static void _encodeMap(Map<Object?, Object?> map, BytesBuilder out) {
    // Encode every key first, then sort by the encoded bytes. Sorting by the
    // Dart key would order 9 before 10 numerically but 10 before 9 bytewise for
    // some encodings, and would diverge for multi-byte UTF-8 text keys. The
    // TypeScript side sorts the same way.
    final entries = <_EncodedEntry>[];
    for (final entry in map.entries) {
      entries.add(_EncodedEntry(encode(entry.key), entry.value));
    }
    entries.sort((a, b) => compareBytes(a.key, b.key));

    for (var i = 1; i < entries.length; i++) {
      if (compareBytes(entries[i - 1].key, entries[i].key) == 0) {
        throw CborError('Duplicate map key in canonical CBOR encoding');
      }
    }

    _encodeHead(majorMap, entries.length, out);
    for (final entry in entries) {
      out.add(entry.key);
      _encodeValue(entry.value, out);
    }
  }

  /// Writes a major type and argument using the shortest legal form.
  static void _encodeHead(int major, int argument, BytesBuilder out) {
    if (argument < 0) {
      throw CborError('Negative CBOR argument: $argument');
    }
    if (argument < 24) {
      out.addByte(major | argument);
    } else if (argument <= 0xFF) {
      out
        ..addByte(major | 24)
        ..addByte(argument);
    } else if (argument <= 0xFFFF) {
      out
        ..addByte(major | 25)
        ..addByte((argument >> 8) & 0xFF)
        ..addByte(argument & 0xFF);
    } else if (argument <= 0xFFFFFFFF) {
      out
        ..addByte(major | 26)
        ..addByte((argument >> 24) & 0xFF)
        ..addByte((argument >> 16) & 0xFF)
        ..addByte((argument >> 8) & 0xFF)
        ..addByte(argument & 0xFF);
    } else {
      out.addByte(major | 27);
      for (var shift = 56; shift >= 0; shift -= 8) {
        out.addByte((argument >> shift) & 0xFF);
      }
    }
  }

  /// Bytewise-lexicographic comparison, shorter-is-smaller on a common prefix.
  static int compareBytes(List<int> a, List<int> b) {
    final shorter = a.length < b.length ? a.length : b.length;
    for (var i = 0; i < shorter; i++) {
      if (a[i] != b[i]) return a[i] - b[i];
    }
    return a.length - b.length;
  }

  /// Decodes canonical CBOR.
  ///
  /// Throws [CborError] on trailing bytes or on any construct outside the
  /// supported subset. Strictness is deliberate: a certificate that decodes
  /// only under a lenient parser is a certificate two implementations will
  /// disagree about.
  static Object? decode(Uint8List bytes) {
    final reader = _CborReader(bytes);
    final value = reader.readValue();
    if (!reader.atEnd) {
      throw CborError('Trailing bytes after CBOR value');
    }
    return value;
  }
}

/// Marks a byte string, so it is not confused with an array of small integers.
class CborBytes {
  CborBytes(this.bytes);

  final List<int> bytes;

  @override
  bool operator ==(Object other) =>
      other is CborBytes && CanonicalCbor.compareBytes(bytes, other.bytes) == 0;

  @override
  int get hashCode => Object.hashAll(bytes);

  @override
  String toString() => 'CborBytes(${bytes.length} bytes)';
}

class CborError implements Exception {
  CborError(this.message);

  final String message;

  @override
  String toString() => 'CborError: $message';
}

class _EncodedEntry {
  _EncodedEntry(this.key, this.value);

  final Uint8List key;
  final Object? value;
}

class _CborReader {
  _CborReader(this.bytes);

  final Uint8List bytes;
  int offset = 0;

  bool get atEnd => offset >= bytes.length;

  int _readByte() {
    if (offset >= bytes.length) throw CborError('Unexpected end of CBOR input');
    return bytes[offset++];
  }

  Object? readValue() {
    final initial = _readByte();
    final major = initial & 0xE0;
    final additional = initial & 0x1F;

    switch (major) {
      case CanonicalCbor.majorUnsigned:
        return _readArgument(additional);
      case CanonicalCbor.majorNegative:
        return -1 - _readArgument(additional);
      case CanonicalCbor.majorBytes:
        return CborBytes(_readSlice(_readArgument(additional)));
      case CanonicalCbor.majorText:
        final raw = _readSlice(_readArgument(additional));
        try {
          // Strict decoding: malformed sequences must be rejected, not silently
          // replaced with U+FFFD. A replacement character would change the
          // worker's name while still producing a "successful" parse.
          return utf8.decode(raw, allowMalformed: false);
        } on FormatException catch (e) {
          // Never let a dart:convert exception escape the decoder. Certificate
          // bytes are attacker-controlled — a corrupted or forged QR must
          // surface as a clean CborError the scanner can report, not as an
          // unhandled crash on the verification screen.
          throw CborError('Text string is not valid UTF-8: ${e.message}');
        }
      case CanonicalCbor.majorArray:
        final length = _readArgument(additional);
        return List<Object?>.generate(length, (_) => readValue(), growable: false);
      case CanonicalCbor.majorMap:
        final length = _readArgument(additional);
        final map = <Object?, Object?>{};
        for (var i = 0; i < length; i++) {
          final key = readValue();
          // Duplicate keys are a genuine attack surface, not a formality. A
          // crafted QR could carry the same key twice with different values;
          // a last-wins parser and a first-wins parser would then read
          // different scores or a different expiry out of one validly signed
          // payload. Refuse the whole thing.
          if (map.containsKey(key)) {
            throw CborError('Duplicate key in CBOR map: $key');
          }
          map[key] = readValue();
        }
        return map;
      case CanonicalCbor.majorSimple:
        switch (additional) {
          case CanonicalCbor.simpleFalse:
            return false;
          case CanonicalCbor.simpleTrue:
            return true;
          case CanonicalCbor.simpleNull:
            return null;
          default:
            throw CborError('Unsupported CBOR simple value: $additional');
        }
      default:
        throw CborError('Unsupported CBOR major type: ${major >> 5}');
    }
  }

  int _readArgument(int additional) {
    if (additional < 24) return additional;
    switch (additional) {
      case 24:
        return _readByte();
      case 25:
        return (_readByte() << 8) | _readByte();
      case 26:
        return (_readByte() << 24) |
            (_readByte() << 16) |
            (_readByte() << 8) |
            _readByte();
      case 27:
        var value = 0;
        for (var i = 0; i < 8; i++) {
          value = (value << 8) | _readByte();
        }
        return value;
      default:
        // 28-30 are reserved and 31 signals indefinite length, which is not
        // canonical and must never appear in a certificate.
        throw CborError('Non-canonical CBOR length encoding: $additional');
    }
  }

  Uint8List _readSlice(int length) {
    if (offset + length > bytes.length) {
      throw CborError('CBOR string runs past end of input');
    }
    final slice = Uint8List.fromList(
      bytes.sublist(offset, offset + length),
    );
    offset += length;
    return slice;
  }
}
