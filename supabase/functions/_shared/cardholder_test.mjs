const { nameMatches, judgeCard, normalizeName } = await import('./cardholder.ts');
let pass = 0, fail = 0;
const eq = (n, got, want) => {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${n}${ok ? '' : `  got ${JSON.stringify(got)}`}`);
  ok ? pass++ : fail++;
};

// --- names that are the same person ---
eq('exact', nameMatches('Robert Smith', 'Robert Smith'), true);
eq('case + punctuation', nameMatches("ROBERT O'BRIEN", "robert obrien"), true);
eq('accents', nameMatches('Jose Garcia', 'José García'), true);
eq('card order SURNAME/GIVEN', nameMatches('SMITH ROBERT J', 'Robert Smith'), true);
eq('nickname prefix', nameMatches('Rob Smith', 'Robert Smith'), true);
eq('extra middle name on ID', nameMatches('Robert Smith', 'Robert John Smith'), true);

// --- different people ---
eq('different surname', nameMatches('Robert Jones', 'Robert Smith'), false);
eq('different given name', nameMatches('Alice Smith', 'Robert Smith'), false);
eq('empty card name', nameMatches('', 'Robert Smith'), false);
eq('empty id name', nameMatches('Robert Smith', ''), false);
eq('initials only', nameMatches('R S', 'Robert Smith'), false);
eq('hyphenated surname', nameMatches('Robert Smith Jones', 'Robert Smith-Jones'), true);
eq('apostrophe on ID only', nameMatches('ROBERT OBRIEN', "Robert O'Brien"), true);

// --- the full verdict ---
eq('prepaid blocked', judgeCard({funding:'prepaid'}, 'Robert Smith', 'Robert Smith'), {ok:false, reason:'prepaid'});
eq('credit ok', judgeCard({funding:'credit'}, 'Robert Smith', 'Robert Smith'), {ok:true});
eq('debit ok', judgeCard({funding:'debit'}, 'Rob Smith', 'Robert Smith'), {ok:true});
eq('someone else card', judgeCard({funding:'credit'}, 'Alice Jones', 'Robert Smith'), {ok:false, reason:'name_mismatch'});
eq('no verified name fails closed', judgeCard({funding:'credit'}, 'Robert Smith', null), {ok:false, reason:'name_mismatch'});
eq('no billing name fails closed', judgeCard({funding:'credit'}, null, 'Robert Smith'), {ok:false, reason:'name_mismatch'});
eq('no card at all', judgeCard(null, 'Robert Smith', 'Robert Smith'), {ok:false, reason:'unknown_card'});
eq('prepaid beats a matching name', judgeCard({funding:'prepaid'}, 'Robert Smith', 'Robert Smith'), {ok:false, reason:'prepaid'});
eq('unknown funding is allowed if the name matches', judgeCard({funding:'unknown'}, 'Robert Smith', 'Robert Smith'), {ok:true});

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
