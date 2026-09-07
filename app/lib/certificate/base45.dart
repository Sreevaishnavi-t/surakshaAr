import 'dart:typed_data';

/// Base45 encoding, per RFC 9285.
///
/// **Why base45 and not base64.** A QR code has a dedicated alphanumeric mode
/// covering exactly 45 characters, and it packs two of them into 11 bits — about
/// 5.5 bits per character. Byte mode costs a full 8 bits per character. Feeding
/// a QR encoder base64 forces it into byte mode and inflates the symbol by
/// roughly 40%, which on a printed certificate is the difference between a code
/// a cracked phone camera can read in a dim gallery and one it cannot.
///
/// This is the same reasoning behind the EU Digital COVID Certificate and
/// India's own DIVOC/CoWIN QR payloads, so the choice is well-trodden rather
/// than clever.
///
/// The alphabet is fixed by the RFC and is a subset of the QR alphanumeric set.
class Base45 {
  const Base45._();

  static const String alphabet =
      '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ \$%*+-./:';

  /// Reverse lookup, built once. Index is the code unit, value is the digit or
  /// -1 for characters outside the alphabet.
  static final List<int> _decodeTable = _buildDecodeTable();

  static List<int> _buildDecodeTable() {
    final table = List<int>.filled(128, -1);
    for (var i = 0; i < alphabet.length; i++) {
      table[alphabet.codeUnitAt(i)] = i;
    }
    return table;
  }

  /// Encodes [bytes].
  ///
  /// Byte pairs become three characters (a 16-bit value in base 45 needs three
  /// digits, since 45^2 = 2025 < 65536 <= 45^3 = 91125). A trailing odd byte
  /// becomes two characters. Digits are emitted least-significant first, which
  /// is what the RFC specifies and is easy to get backwards.
  static String encode(List<int> bytes) {
    final buffer = StringBuffer();

    var i = 0;
    while (i + 1 < bytes.length) {
      final value = (bytes[i] << 8) + bytes[i + 1];
      final c = value % 45;
      final d = (value ~/ 45) % 45;
      final e = value ~/ (45 * 45);
      buffer
        ..writeCharCode(alphabet.codeUnitAt(c))
        ..writeCharCode(alphabet.codeUnitAt(d))
        ..writeCharCode(alphabet.codeUnitAt(e));
      i += 2;
    }

    if (i < bytes.length) {
      final value = bytes[i];
      final c = value % 45;
      final d = value ~/ 45;
      buffer
        ..writeCharCode(alphabet.codeUnitAt(c))
        ..writeCharCode(alphabet.codeUnitAt(d));
    }

    return buffer.toString();
  }

  /// Decodes [input], throwing [Base45Error] on anything malformed.
  ///
  /// Rejects out-of-range groups rather than truncating them. A certificate
  /// scanner must never accept a payload it had to repair — the signature check
  /// downstream would fail anyway, but a clear error here is far easier to act
  /// on than "invalid signature".
  static Uint8List decode(String input) {
    if (input.isEmpty) return Uint8List(0);

    final remainder = input.length % 3;
    if (remainder == 1) {
      throw Base45Error('Base45 length ${input.length} is not valid: '
          'complete groups are 3 characters and a final partial group is 2');
    }

    final digits = List<int>.filled(input.length, 0);
    for (var i = 0; i < input.length; i++) {
      final unit = input.codeUnitAt(i);
      final digit = unit < 128 ? _decodeTable[unit] : -1;
      if (digit < 0) {
        throw Base45Error(
          'Character "${input[i]}" at position $i is not in the base45 alphabet',
        );
      }
      digits[i] = digit;
    }

    final out = BytesBuilder(copy: false);

    var i = 0;
    while (i + 2 < digits.length) {
      final value = digits[i] + digits[i + 1] * 45 + digits[i + 2] * 45 * 45;
      if (value > 0xFFFF) {
        throw Base45Error('Base45 group at position $i decodes to $value, '
            'which does not fit in two bytes');
      }
      out
        ..addByte((value >> 8) & 0xFF)
        ..addByte(value & 0xFF);
      i += 3;
    }

    if (remainder == 2) {
      final value = digits[i] + digits[i + 1] * 45;
      if (value > 0xFF) {
        throw Base45Error('Final base45 group decodes to $value, '
            'which does not fit in one byte');
      }
      out.addByte(value);
    }

    return out.takeBytes();
  }
}

class Base45Error implements Exception {
  Base45Error(this.message);

  final String message;

  @override
  String toString() => 'Base45Error: $message';
}
