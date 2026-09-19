#!/usr/bin/env node
// Swift to Node: opens what the iOS crypto package produced
// (ABCMailboxKit/.build/interop/swift-fixture.json, written by SwiftToNodeFixtureTests)
// with libsodium.js. Exit code 0 means a browser client can read the iPhone's output.
//
// libsodium.js is borrowed from the Android tools directory (run `npm install` there once),
// so the three clients are checked against one copy of the reference library.
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const _sodium = createRequire(resolve(here, '../../Android/tools/package.json'))('libsodium-wrappers-sumo');
await _sodium.ready;
const s = _sodium;
const from = (t) => s.from_base64(t, s.base64_variants.ORIGINAL);
const b64 = (bytes) => s.to_base64(bytes, s.base64_variants.ORIGINAL);
const f = JSON.parse(readFileSync(resolve(here, '../ABCMailboxKit/.build/interop/swift-fixture.json'), 'utf8'));
let failures = 0;
const check = (name, ok) => { console.log((ok ? 'ok   ' : 'FAIL ') + name); if (!ok) failures++; };

const unwrap = (w, secret) => {
  const { ciphertext, nonce } = JSON.parse(w.wrapped);
  const key = s.crypto_pwhash(32, secret.normalize('NFKC'), from(w.salt), w.params.opslimit, w.params.memlimit, w.params.alg);
  return s.crypto_aead_xchacha20poly1305_ietf_decrypt(null, from(ciphertext), null, from(nonce), key);
};

// Key order is not part of the contract, so compare the fields rather than the text.
const p = f.passwordWrapped.params;
check('kdfParams is the agreed schema', Object.keys(p).length === 4 && p.kdf === 'argon2id' && p.alg === 2 && p.opslimit === 2 && p.memlimit === 67108864);
check('password-wrapped private key opens', b64(unwrap(f.passwordWrapped, f.password)) === f.privateKey);
check('recovery-wrapped private key opens with the normalised code', b64(unwrap(f.recoveryWrapped, f.recoveryCode)) === f.privateKey);

const mine = f.letter.envelopes.find((e) => e.readerType === 'user');
const key = s.crypto_box_seal_open(from(mine.wrappedKey), from(f.publicKey), from(f.privateKey));
check('writer envelope opens', b64(key) === f.letter.contentKey);
const groupEnv = f.letter.envelopes.find((e) => e.readerType === 'chapter');
check('group envelope opens and names its key version', groupEnv.keyVersion === 3 && b64(s.crypto_box_seal_open(from(groupEnv.wrappedKey), from(f.groupPublicKey), from(f.groupPrivateKey))) === f.letter.contentKey);
const dec = (c, n) => s.to_string(s.crypto_aead_xchacha20poly1305_ietf_decrypt(null, from(c), null, from(n), key));
check('body decrypts', dec(f.letter.ciphertext, f.letter.nonce) === f.letter.body);
check('relay note decrypts', dec(f.letter.relayNote.ciphertext, f.letter.relayNote.nonce) === f.letter.note);
check('file decrypts', b64(s.crypto_aead_xchacha20poly1305_ietf_decrypt(null, from(f.file.ciphertext), null, from(f.file.nonce), key)) === f.file.plain);
check('token hash matches', s.to_hex(s.crypto_hash_sha256(s.from_string(f.tokenHash.token))) === f.tokenHash.sha256);

process.exit(failures === 0 ? 0 : 1);
