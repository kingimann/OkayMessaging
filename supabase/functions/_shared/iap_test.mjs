const { statusForNotification, gbForProduct, entitlementFor } = await import('./iap.ts');
let pass = 0, fail = 0;
const eq = (name, got, want) => {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${ok ? '' : `  got ${JSON.stringify(got)} want ${JSON.stringify(want)}`}`);
  ok ? pass++ : fail++;
};

eq('renewal keeps access', statusForNotification('DID_RENEW', ''), 'active');
eq('first subscribe', statusForNotification('SUBSCRIBED', 'INITIAL_BUY'), 'active');
eq('turning off auto-renew does NOT cut access now',
   statusForNotification('DID_CHANGE_RENEWAL_STATUS', 'AUTO_RENEW_DISABLED'), 'canceled');
eq('re-enabling auto-renew', statusForNotification('DID_CHANGE_RENEWAL_STATUS', 'AUTO_RENEW_ENABLED'), 'active');
eq('billing retry with grace stays usable', statusForNotification('DID_FAIL_TO_RENEW', 'GRACE_PERIOD'), 'grace');
eq('billing failure without grace expires', statusForNotification('DID_FAIL_TO_RENEW', ''), 'expired');
eq('expiry', statusForNotification('EXPIRED', 'VOLUNTARY'), 'expired');
eq('refund', statusForNotification('REFUND', ''), 'refunded');
eq('unknown type never revokes', statusForNotification('SOME_FUTURE_THING', ''), null);

eq('gb parsed from product', gbForProduct('com.okaymessaging.storage.gb50.monthly'), 50);
eq('100 gb', gbForProduct('com.okaymessaging.storage.gb100.monthly'), 100);
eq('tips grant nothing', gbForProduct('com.okaymessaging.tip.lunch'), 0);
eq('garbage grants nothing', gbForProduct('com.evil.storage.gb999'), 0);

// entitlementFor picks the largest live plan and ignores dead ones.
const future = new Date(Date.now() + 86400e3).toISOString();
const past = new Date(Date.now() - 86400e3).toISOString();
const fakeDb = (rows) => ({ from: () => ({ select: () => ({ eq: async () => ({ data: rows }) }) }) });

eq('no rows -> free', await entitlementFor(fakeDb([]), '1'), { active: false, gb: 0, expiresAt: null, productId: null });
eq('expired row -> free',
   (await entitlementFor(fakeDb([{ product_id: 'p', gb: 50, expires_at: past, status: 'active' }]), '1')).active, false);
eq('refunded row -> free',
   (await entitlementFor(fakeDb([{ product_id: 'p', gb: 50, expires_at: future, status: 'refunded' }]), '1')).active, false);
eq('canceled but paid-up still works',
   (await entitlementFor(fakeDb([{ product_id: 'p', gb: 30, expires_at: future, status: 'canceled' }]), '1')).gb, 30);
eq('grace still works',
   (await entitlementFor(fakeDb([{ product_id: 'p', gb: 30, expires_at: future, status: 'grace' }]), '1')).gb, 30);
eq('largest live plan wins',
   (await entitlementFor(fakeDb([
     { product_id: 'a', gb: 10, expires_at: future, status: 'active' },
     { product_id: 'b', gb: 80, expires_at: future, status: 'active' },
     { product_id: 'c', gb: 100, expires_at: past, status: 'active' },
   ]), '1')).gb, 80);

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
