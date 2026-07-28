import { readFileSync } from 'node:fs';
import { makeJws } from './mkjws.mjs';

const { verifyAppleJws } = await import('./apple_jws.ts');
const derB64 = (p) => readFileSync(p, 'utf8').replace(/-----[^-]+-----/g, '').replace(/\s+/g, '');
const TEST_ROOT = derB64('chain/root.crt');
const payload = { bundleId: 'com.okaymessaging', productId: 'com.okaymessaging.storage.gb50.monthly' };

let pass = 0, fail = 0;
const check = async (name, fn, expectOk) => {
  let ok = false, err = '';
  try { await fn(); ok = true; } catch (e) { err = e.message; }
  const good = ok === expectOk;
  console.log(`${good ? 'PASS' : 'FAIL'}  ${name}${ok ? '' : `  (${err})`}`);
  good ? pass++ : fail++;
};

// 1. Genuine chain, correct pin.
const good = makeJws(payload, { chain: ['chain/leaf.crt','chain/int.crt','chain/root.crt'], key: 'chain/leaf.key' });
await check('valid chain accepted', async () => {
  const p = await verifyAppleJws(good, { rootCertificate: TEST_ROOT });
  if (p.bundleId !== 'com.okaymessaging') throw new Error('payload mismatch');
}, true);

// 2. Wrong pin (Apple's real root) must reject.
await check('rejects chain not anchored to the pin', () => verifyAppleJws(good), false);

// 3. Tampered payload must reject.
const [h, , s] = good.split('.');
const evil = Buffer.from(JSON.stringify({ ...payload, productId: 'com.okaymessaging.storage.gb100.monthly' })).toString('base64url');
await check('rejects a tampered payload', () => verifyAppleJws(`${h}.${evil}.${s}`, { rootCertificate: TEST_ROOT }), false);

// 4. THE ATTACK: forged leaf, real root appended. Must reject.
const forged = makeJws(payload, { chain: ['chain/evil.crt','chain/evilint.crt','chain/root.crt'], key: 'chain/evil.key' });
await check('rejects a forged leaf with the real root appended', () => verifyAppleJws(forged, { rootCertificate: TEST_ROOT }), false);

// 5. Expired certificate must reject.
await check('rejects an expired certificate', () => verifyAppleJws(good, { rootCertificate: TEST_ROOT, now: new Date('2040-01-01') }), false);

// 6. Chain with the intermediate dropped must reject.
const short = makeJws(payload, { chain: ['chain/leaf.crt','chain/root.crt'], key: 'chain/leaf.key' });
await check('rejects a chain missing its intermediate', () => verifyAppleJws(short, { rootCertificate: TEST_ROOT }), false);

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
