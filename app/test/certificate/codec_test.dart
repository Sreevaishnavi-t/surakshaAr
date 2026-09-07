import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:surakshaar/certificate/base45.dart';
import 'package:surakshaar/certificate/canonical_cbor.dart';

String hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  group('Base45 (RFC 9285)', () {
    // The vectors published in the RFC itself. Passing these means the
    // TypeScript verifier can use any conformant base45 library and agree.
    const vectors = {
      'AB': 'BB8',
      'Hello!!': '%69 VD92EX0',
      'base-45': 'UJCLQE7W581',
      'ietf!': 'QED8WEX0',
    };

    test('encodes the published vectors', () {
      vectors.forEach((plain, encoded) {
        expect(Base45.encode(utf8.encode(plain)), encoded, reason: plain);
      });
    });

    test('decodes the published vectors', () {
      vectors.forEach((plain, encoded) {
        expect(utf8.decode(Base45.decode(encoded)), plain, reason: encoded);
      });
    });

    test('round-trips arbitrary binary including zero and 0xFF bytes', () {
      final payloads = [
        <int>[],
        [0],
        [255],
        [0, 0, 0],
        [255, 255, 255, 255],
        List<int>.generate(256, (i) => i),
        List<int>.generate(257, (i) => (i * 7) % 256),
      ];

      for (final payload in payloads) {
        final round = Base45.decode(Base45.encode(payload));
        expect(hex(round), hex(payload), reason: '${payload.length} bytes');
      }
    });

    test('an odd-length payload uses a two-character final group', () {
      // Three bytes is one full pair plus a remainder: 3 + 2 characters.
      expect(Base45.encode([1, 2, 3]).length, 5);
      // Four bytes is two full pairs.
      expect(Base45.encode([1, 2, 3, 4]).length, 6);
    });

    test('rejects characters outside the alphabet', () {
      // Lowercase is deliberately not in the QR alphanumeric set.
      expect(() => Base45.decode('ab8'), throwsA(isA<Base45Error>()));
      expect(() => Base45.decode('BB!'), throwsA(isA<Base45Error>()));
    });

    test('rejects an impossible length', () {
      expect(() => Base45.decode('B'), throwsA(isA<Base45Error>()));
      expect(() => Base45.decode('BB8B'), throwsA(isA<Base45Error>()));
    });

    test('rejects a group that overflows two bytes', () {
      // 'GGW' decodes to 45*45*32 + ... which exceeds 0xFFFF.
      expect(() => Base45.decode('::::::'), throwsA(isA<Base45Error>()));
    });
  });

  group('CanonicalCbor', () {
    test('encodes small integers in one byte', () {
      expect(hex(CanonicalCbor.encode(0)), '00');
      expect(hex(CanonicalCbor.encode(1)), '01');
      expect(hex(CanonicalCbor.encode(23)), '17');
    });

    test('uses the shortest integer form at every boundary', () {
      expect(hex(CanonicalCbor.encode(24)), '1818');
      expect(hex(CanonicalCbor.encode(255)), '18ff');
      expect(hex(CanonicalCbor.encode(256)), '190100');
      expect(hex(CanonicalCbor.encode(65535)), '19ffff');
      expect(hex(CanonicalCbor.encode(65536)), '1a00010000');
      expect(hex(CanonicalCbor.encode(4294967295)), '1affffffff');
      expect(hex(CanonicalCbor.encode(4294967296)), '1b0000000100000000');
    });

    test('encodes negative integers as -1 - n', () {
      expect(hex(CanonicalCbor.encode(-1)), '20');
      expect(hex(CanonicalCbor.encode(-24)), '37');
      expect(hex(CanonicalCbor.encode(-25)), '3818');
    });

    test('encodes simple values and text', () {
      expect(hex(CanonicalCbor.encode(false)), 'f4');
      expect(hex(CanonicalCbor.encode(true)), 'f5');
      expect(hex(CanonicalCbor.encode(null)), 'f6');
      expect(hex(CanonicalCbor.encode('')), '60');
      expect(hex(CanonicalCbor.encode('a')), '6161');
    });

    test('encodes text as UTF-8 by byte length, not character count', () {
      // Devanagari and Ol Chiki are multi-byte; a length in characters would
      // desynchronise the decoder and corrupt every Hindi or Santali name.
      final devanagari = CanonicalCbor.encode('राम');
      // 3 characters, 9 UTF-8 bytes.
      expect(devanagari[0], CanonicalCbor.majorText | 9);
      expect(CanonicalCbor.decode(devanagari), 'राम');

      final olChiki = 'ᱥᱟᱱᱛᱟᱲᱤ';
      expect(CanonicalCbor.decode(CanonicalCbor.encode(olChiki)), olChiki);
    });

    test('sorts map keys bytewise by encoded form, not numerically', () {
      // Encoded, 9 is 0x09 and 10 is 0x180a. Bytewise that puts 9 first, which
      // here agrees with numeric order — the case that matters is that both
      // implementations use the *same* rule.
      final encoded = CanonicalCbor.encode({10: 'b', 9: 'a', 1: 'c'});
      final decoded = CanonicalCbor.decode(encoded) as Map;

      expect(decoded.keys.toList(), [1, 9, 10]);
      // Insertion order must not leak into the bytes.
      expect(
        hex(CanonicalCbor.encode({1: 'c', 9: 'a', 10: 'b'})),
        hex(encoded),
      );
    });

    test('produces identical bytes regardless of map insertion order', () {
      final a = CanonicalCbor.encode({
        'z': 1,
        'a': 2,
        'm': {'y': 3, 'b': 4},
      });
      final b = CanonicalCbor.encode({
        'a': 2,
        'm': {'b': 4, 'y': 3},
        'z': 1,
      });

      expect(hex(a), hex(b));
    });

    test('round-trips a nested structure with byte strings', () {
      final original = {
        1: 'Sunita Murmu',
        2: CborBytes(List<int>.generate(32, (i) => i * 3 % 256)),
        3: [
          {1: 1, 2: 87},
          {1: 2, 2: 91},
        ],
        4: true,
        5: null,
        6: -17,
      };

      final decoded = CanonicalCbor.decode(CanonicalCbor.encode(original)) as Map;

      expect(decoded[1], 'Sunita Murmu');
      expect(decoded[2], original[2]);
      expect((decoded[3] as List).length, 2);
      expect(((decoded[3] as List)[1] as Map)[2], 91);
      expect(decoded[4], true);
      expect(decoded[5], isNull);
      expect(decoded[6], -17);
    });

    test('rejects duplicate keys in incoming bytes', () {
      // The reachable case: a crafted QR carrying the same key twice. A
      // last-wins parser and a first-wins parser would read different values
      // out of one validly signed payload, so the payload must be refused.
      // Bytes below are {1: 'a', 1: 'b'} — a two-entry map with a repeated key.
      final crafted = Uint8List.fromList([
        CanonicalCbor.majorMap | 2,
        0x01, CanonicalCbor.majorText | 1, 0x61, // 1: "a"
        0x01, CanonicalCbor.majorText | 1, 0x62, // 1: "b"
      ]);

      expect(() => CanonicalCbor.decode(crafted), throwsA(isA<CborError>()));
    });

    test('a Dart map cannot express duplicate keys on the encode side', () {
      // Documents why the encoder's duplicate guard is defensive only: Dart
      // map keys are already unique under ==, and 1 == 1.0.
      final collapsed = <Object?, Object?>{1: 'a', 1.0: 'b'};
      expect(collapsed.length, 1);
      expect(hex(CanonicalCbor.encode(collapsed)), 'a1016162');
    });

    test('rejects trailing bytes', () {
      final valid = CanonicalCbor.encode(42);
      final withJunk = Uint8List.fromList([...valid, 0x00]);
      expect(() => CanonicalCbor.decode(withJunk), throwsA(isA<CborError>()));
    });

    test('rejects indefinite-length encoding', () {
      // 0x5F is an indefinite-length byte string, legal CBOR but not canonical.
      expect(
        () => CanonicalCbor.decode(Uint8List.fromList([0x5F, 0xFF])),
        throwsA(isA<CborError>()),
      );
    });

    test('rejects floats and tags outright', () {
      // 0xFB is a float64, 0xC0 is a tag. Neither belongs in a certificate.
      expect(
        () => CanonicalCbor.decode(
          Uint8List.fromList([0xFB, 0, 0, 0, 0, 0, 0, 0, 0]),
        ),
        throwsA(isA<CborError>()),
      );
      expect(
        () => CanonicalCbor.decode(Uint8List.fromList([0xC0, 0x01])),
        throwsA(isA<CborError>()),
      );
      expect(
        () => CanonicalCbor.encode(1.5),
        throwsA(isA<CborError>()),
      );
    });

    test('rejects truncated input rather than returning partial data', () {
      // Declares a 10-byte string but supplies three.
      expect(
        () => CanonicalCbor.decode(Uint8List.fromList([0x4A, 1, 2, 3])),
        throwsA(isA<CborError>()),
      );
    });
  });

  group('CBOR and base45 together', () {
    test('a realistic certificate payload stays inside QR alphanumeric limits', () {
      final payload = {
        1: 1, // schema version
        2: CborBytes(List<int>.generate(16, (i) => i)), // certificate uuid
        3: 'Sunita Murmu',
        4: 'JH-DHN-0042', // employer code
        5: [
          {1: 1, 2: 87, 3: 1757203200},
          {1: 2, 2: 91, 3: 1757203200},
        ],
        6: 1757203200, // issued
        7: 1820275200, // expires
        8: 'org-2026a', // key id
      };

      final cbor = CanonicalCbor.encode(payload);
      // Signature is 64 bytes of Ed25519 on top of the payload.
      final signed = Uint8List.fromList([...cbor, ...List.filled(64, 0xAB)]);
      final encoded = 'SJH1:${Base45.encode(signed)}';

      // QR alphanumeric mode holds 1,852 characters even at the highest error
      // correction level, so there is a very wide margin here.
      expect(encoded.length, lessThan(500));

      // And it survives the round trip intact.
      final body = Base45.decode(encoded.substring(5));
      expect(hex(body.sublist(0, cbor.length)), hex(cbor));
      expect(
        CanonicalCbor.decode(Uint8List.fromList(body.sublist(0, cbor.length))),
        isA<Map>(),
      );
    });
  });
}
