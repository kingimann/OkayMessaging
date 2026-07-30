// The verdict logic, executed. This is the code that decides whether somebody
// gets to post; reading it is not the same as running it.
//
//     deno run --allow-read supabase/functions/_shared/moderation_test.mjs

const { verdictFor, BLOCK_AT } = await import('./moderation.ts');

let pass = 0, fail = 0;
const eq = (n, got, want) => {
  const ok = got === want;
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${n}${ok ? '' : `  got ${JSON.stringify(got)} want ${JSON.stringify(want)}`}`);
  ok ? pass++ : fail++;
};

const v = (cats, scores = {}) => verdictFor(cats, scores).verdict;

// --- nothing raised ---
eq('clean post', v({}), 'ok');
eq('all categories false', v({ harassment: false, violence: false }), 'ok');

// --- a block needs the category AND a confident score ---
eq('threat, confident', v({ 'harassment/threatening': true }, { 'harassment/threatening': 0.95 }), 'block');
eq('threat, unsure', v({ 'harassment/threatening': true }, { 'harassment/threatening': 0.3 }), 'flag');
eq('threat, exactly at the line', v({ violence: true }, { violence: BLOCK_AT }), 'block');
eq('threat, just under the line', v({ violence: true }, { violence: BLOCK_AT - 0.01 }), 'flag');
eq('score with no category raised', v({}, { violence: 0.99 }), 'ok');
eq('missing score is not confident', v({ violence: true }), 'flag');

// --- the one category that does not wait for a second opinion ---
eq('minors, any score', v({ 'sexual/minors': true }, { 'sexual/minors': 0.1 }), 'block');
eq('minors, no score at all', v({ 'sexual/minors': true }), 'block');

// --- flags never stop a post ---
eq('rudeness', v({ harassment: true }, { harassment: 0.99 }), 'flag');
eq('spam', v({ illicit: true }, { illicit: 0.99 }), 'flag');
eq('self-harm', v({ 'self-harm': true }, { 'self-harm': 0.99 }), 'flag');
eq('gore', v({ 'violence/graphic': true }, { 'violence/graphic': 0.99 }), 'flag');

// --- a block always carries words the poster can read ---
for (const c of ['sexual/minors', 'harassment/threatening', 'hate/threatening', 'illicit/violent', 'violence']) {
  const out = verdictFor({ [c]: true }, { [c]: 0.99 });
  eq(`${c} explains itself`, out.reason.length > 10 && out.verdict === 'block', true);
}
// ...and a flag says nothing, because the poster is never told.
eq('a flag is silent', verdictFor({ harassment: true }, { harassment: 0.9 }).reason, '');

// --- the severe-but-unsure case is not silently dropped ---
eq('unsure severe still reaches a human',
   verdictFor({ 'illicit/violent': true }, { 'illicit/violent': 0.2 }).category, 'illicit/violent');

console.log(`\n${pass} passed, ${fail} failed`);
if (fail) Deno.exit(1);
