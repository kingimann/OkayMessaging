// Builds a compact JWS signed by leaf.key with the given x5c chain.
import { readFileSync } from 'node:fs';
import { createSign, createPrivateKey } from 'node:crypto';

const b64u = (b) => Buffer.from(b).toString('base64url');
const derB64 = (p) => {
  const pem = readFileSync(p, 'utf8');
  return pem.replace(/-----[^-]+-----/g, '').replace(/\s+/g, '');
};

export function makeJws(payload, { chain, key, alg = 'ES256' }) {
  const header = { alg, x5c: chain.map(derB64) };
  const signingInput = `${b64u(JSON.stringify(header))}.${b64u(JSON.stringify(payload))}`;
  const signer = createSign('SHA256');
  signer.update(signingInput);
  const sig = signer.sign({ key: createPrivateKey(readFileSync(key)), dsaEncoding: 'ieee-p1363' });
  return `${signingInput}.${b64u(sig)}`;
}
