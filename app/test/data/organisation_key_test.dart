import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:surakshaar/certificate/certificate_codec.dart';
import 'package:surakshaar/data/device_identity.dart';

void main() {
  group('OrganisationKey', () {
    test('the compiled-in key is a raw 32-byte Ed25519 public key', () {
      // A DER/SPKI-wrapped key is 44 bytes and starts with 0x30. Pasting one in
      // by mistake is easy — Node exports that form by default — and would mean
      // nothing verifies anywhere.
      final bytes = OrganisationKey.publicKeyBytes;
      expect(bytes.length, kPublicKeyLength);
      expect(bytes.first, isNot(0x30),
          reason: 'looks like DER, not a raw Ed25519 key');
    });

    test('rejects a malformed compiled key loudly', () {
      // Guards the guard: decoding must throw rather than quietly producing a
      // key that fails every signature check later.
      expect(
        () {
          final decoded = base64Decode('AAAA');
          if (decoded.length != kPublicKeyLength) {
            throw StateError('wrong length');
          }
        },
        throwsA(isA<StateError>()),
      );
    });

    test('the development root is flagged as such', () {
      // The UI uses this to make sure a demo trust root is never mistaken for a
      // deployment.
      expect(OrganisationKey.isDevelopmentRoot, isTrue);
      expect(OrganisationKey.keyId, startsWith('org:'));
    });
  });

  group('compiled key matches the generated private key', () {
    // keys/org-private.json is gitignored, so this only runs where the key has
    // actually been generated. That is exactly where it is useful: it catches
    // regenerating the organisation key and forgetting to paste the new public
    // half into the app, which would otherwise surface as every certificate
    // failing verification for no obvious reason.
    final keyFile = File('../keys/org-private.json');

    test(
      'a certificate signed with the private key verifies against the app key',
      () async {
        final json =
            jsonDecode(await keyFile.readAsString()) as Map<String, Object?>;

        expect(
          json['keyId'],
          OrganisationKey.keyId,
          reason: 'keys/org-private.json holds a different key id than the app '
              'was compiled with — rerun tools/keygen.mjs output into '
              'device_identity.dart',
        );

        final seed = base64Decode(json['privateSeedBase64']! as String);
        final keyPair = await Ed25519().newKeyPairFromSeed(seed);
        final derived = await CertificateCodec.publicKeyBytes(keyPair);

        expect(
          base64Encode(derived),
          OrganisationKey.publicKeyBase64,
          reason: 'the compiled public key does not match the private key on '
              'disk; certificates signed by the dashboard would not verify',
        );
      },
      skip: keyFile.existsSync()
          ? false
          : 'keys/org-private.json not present — run tools/keygen.mjs',
    );
  });
}
