#!/usr/bin/env node
/**
 * Generates the SurakshaAR organisation signing key pair.
 *
 * The organisation key is the trust root for *verified* certificates. Its
 * public half is compiled into the Android app, which is what lets a DGMS
 * inspector with a fresh install, no account and no network verify a
 * certificate presented at a pit head. Its private half signs the
 * counter-signature applied when a worker's handset syncs, and must never leave
 * the dashboard host.
 *
 * Usage:
 *   node tools/keygen.mjs                 # generate into ./keys
 *   node tools/keygen.mjs --out ./keys    # explicit output directory
 *   node tools/keygen.mjs --id org:jh-2026a
 *
 * Ed25519 raw key sizes are fixed: 32-byte public, 32-byte private seed. Node
 * exports SPKI/PKCS8 DER by default, so this pulls the raw values out of the
 * JWK form instead — the app and the TypeScript verifier both work with raw
 * bytes, and hand-slicing DER is exactly the sort of thing that works until it
 * silently does not.
 */

import { generateKeyPairSync, createHash } from 'node:crypto';
import { writeFileSync, mkdirSync, existsSync } from 'node:fs';
import { join, resolve } from 'node:path';

function parseArgs(argv) {
  const args = { out: 'keys', id: null, force: false };
  for (let i = 2; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === '--out') args.out = argv[++i];
    else if (arg === '--id') args.id = argv[++i];
    else if (arg === '--force') args.force = true;
    else if (arg === '--help' || arg === '-h') args.help = true;
  }
  return args;
}

function base64UrlToBuffer(value) {
  return Buffer.from(value.replace(/-/g, '+').replace(/_/g, '/'), 'base64');
}

function main() {
  const args = parseArgs(process.argv);

  if (args.help) {
    console.log(
      'Usage: node tools/keygen.mjs [--out DIR] [--id org:NAME] [--force]',
    );
    process.exit(0);
  }

  const outDir = resolve(args.out);
  const privatePath = join(outDir, 'org-private.json');
  const publicPath = join(outDir, 'org-public.json');

  if (existsSync(privatePath) && !args.force) {
    console.error(
      `Refusing to overwrite an existing key at ${privatePath}.\n` +
        'Overwriting the organisation key invalidates every certificate signed\n' +
        'with it. Pass --force only if you genuinely intend that.',
    );
    process.exit(1);
  }

  const { publicKey, privateKey } = generateKeyPairSync('ed25519');

  const publicJwk = publicKey.export({ format: 'jwk' });
  const privateJwk = privateKey.export({ format: 'jwk' });

  const publicRaw = base64UrlToBuffer(publicJwk.x);
  const privateSeed = base64UrlToBuffer(privateJwk.d);

  if (publicRaw.length !== 32 || privateSeed.length !== 32) {
    console.error(
      `Unexpected Ed25519 key sizes: public ${publicRaw.length}, ` +
        `private ${privateSeed.length}. Expected 32 each.`,
    );
    process.exit(1);
  }

  // Key id derived from the public key: stable, collision-resistant, and it
  // leaks nothing about the machine that generated it.
  const fingerprint = createHash('sha256')
    .update(publicRaw)
    .digest('hex')
    .slice(0, 16);
  const keyId = args.id ?? `org:${fingerprint.slice(0, 8)}`;

  mkdirSync(outDir, { recursive: true });

  writeFileSync(
    privatePath,
    JSON.stringify(
      {
        keyId,
        algorithm: 'Ed25519',
        privateSeedBase64: privateSeed.toString('base64'),
        publicKeyBase64: publicRaw.toString('base64'),
        createdAt: new Date().toISOString(),
        warning:
          'SECRET. Never commit. Never copy onto a worker handset. This key ' +
          'signs every verified certificate the organisation issues.',
      },
      null,
      2,
    ) + '\n',
    { mode: 0o600 },
  );

  writeFileSync(
    publicPath,
    JSON.stringify(
      {
        keyId,
        algorithm: 'Ed25519',
        publicKeyBase64: publicRaw.toString('base64'),
        fingerprint,
        createdAt: new Date().toISOString(),
      },
      null,
      2,
    ) + '\n',
  );

  console.log('Organisation key pair generated.\n');
  console.log(`  key id      ${keyId}`);
  console.log(`  public key  ${publicRaw.toString('base64')}`);
  console.log(`  private     ${privatePath}  (mode 0600, gitignored)`);
  console.log(`  public      ${publicPath}\n`);
  console.log('Compile the public half into the app by setting, in');
  console.log('app/lib/data/device_identity.dart:\n');
  console.log(`    static const String keyId = '${keyId}';`);
  console.log(
    `    static const String publicKeyBase64 =\n        '${publicRaw.toString('base64')}';\n`,
  );
  console.log(
    'Keep org-private.json on the dashboard host only. For a real deployment,\n' +
      'hold it in an HSM under the issuing authority\'s control — see\n' +
      'docs/threat-model.md.',
  );
}

main();
