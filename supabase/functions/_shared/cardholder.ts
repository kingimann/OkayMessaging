// Deciding whether a card may be used to send money.
//
// Two rules, both of which have to hold before a charge is captured:
//
//   1. The card is not prepaid. A prepaid card is bought with cash and tied
//      to nobody, which is the whole appeal for someone moving money they
//      shouldn't be.
//   2. The cardholder name matches the name Stripe read off the sender's
//      government ID. Someone else's card is not yours to send from.
//
// Both are checked against the *authorised* payment method, before capture,
// so a card that fails is never actually charged.

/// Strips case, accents and punctuation so "O'BRIEN-Smith" and "obrien smith"
/// compare equal.
///
/// Apostrophes are deleted rather than turned into spaces: they never
/// separate one name from another, and splitting "O'Brien" into "o" and
/// "brien" would stop it matching a card printed "OBRIEN". Hyphens do
/// separate, so they become spaces.
export function normalizeName(name: string): string {
  return name
    .normalize("NFD")
    .replace(/[̀-ͯ]/g, "")
    .toLowerCase()
    .replace(/['’ʼ]/g, "")
    .replace(/[^a-z\s]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

/// Whether [cardName] plausibly belongs to the person whose ID says
/// [verifiedName].
///
/// Deliberately lenient in one direction and strict in the other. Cards carry
/// abbreviated and reordered names — "SMITH/ROBERT J", "Rob Smith", "Robert
/// John Smith" — and rejecting a legitimate sender is a worse failure here
/// than accepting a nickname. So: every surname-ish token of the ID name must
/// appear, and the first name must match or be a prefix of it. A different
/// person's name shares neither.
export function nameMatches(cardName: string, verifiedName: string): boolean {
  const card = normalizeName(cardName);
  const id = normalizeName(verifiedName);
  if (card.length === 0 || id.length === 0) return false;
  if (card === id) return true;

  const cardParts = card.split(" ").filter((p) => p.length > 1);
  const idParts = id.split(" ").filter((p) => p.length > 1);
  if (cardParts.length === 0 || idParts.length === 0) return false;

  // The last token of the ID name is the one that must be present outright.
  const surname = idParts[idParts.length - 1];
  if (!cardParts.includes(surname)) return false;

  // And something on the card has to correspond to the given name, allowing
  // "Rob" for "Robert" but not "Alice" for "Robert".
  const given = idParts[0];
  return cardParts.some((p) =>
    p === given || given.startsWith(p) || p.startsWith(given)
  );
}

/// The `reason?: undefined` on the passing arm is deliberate. Without it,
/// reading `verdict.reason` requires TypeScript to have narrowed the union
/// first, and the Supabase dashboard editor's type worker does not narrow
/// across the try/catch these verdicts are produced in — it reports
/// "Property 'reason' does not exist on type '{ ok: true }'" over code that
/// both `deno check` and strict `tsc` accept. Declaring the property as
/// always-present-but-undefined makes the access legal unnarrowed while
/// still refusing `{ ok: true, reason: … }`, so nothing is given up.
export type CardVerdict =
  | { ok: true; reason?: undefined }
  | { ok: false; reason: "prepaid" | "name_mismatch" | "unknown_card" };

/// The full decision for one authorised card.
export function judgeCard(
  card: { funding?: string | null } | null | undefined,
  billingName: string | null | undefined,
  verifiedName: string | null | undefined,
): CardVerdict {
  if (!card) return { ok: false, reason: "unknown_card" };
  if (card.funding === "prepaid") return { ok: false, reason: "prepaid" };
  // No verified name means the sender never passed the ID check, or Stripe
  // gave us no name to compare. Either way there is nothing to match against,
  // and "nothing to match" must fail closed.
  if (!verifiedName || !billingName) {
    return { ok: false, reason: "name_mismatch" };
  }
  return nameMatches(billingName, verifiedName)
    ? { ok: true }
    : { ok: false, reason: "name_mismatch" };
}
