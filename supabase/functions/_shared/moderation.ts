// Turning a classifier's category scores into a verdict.
//
// Pure and separate from the Edge Function so it can be executed by a test
// rather than read: this is the code that decides whether somebody gets to
// post, and "reads correct" is not the same as "is correct". See
// _shared/moderation_test.mjs.

/// Scores at or above this are treated as confident enough to stop a post.
/// Anything the classifier raises below it becomes a flag instead.
export const BLOCK_AT = 0.7;

/// The categories a post can be stopped outright for, and what the person who
/// wrote it is told.
///
/// DETERMINISTIC WORDING, on purpose. The classifier returns categories and
/// scores, not prose, so these are written once here rather than generated per
/// post. Somebody stopped twice for the same thing reads the same sentence
/// both times, it can be translated, and no model can invent a rule that does
/// not exist.
export const BLOCK_REASONS: Record<string, string> = {
  "sexual/minors": "That appears to involve a minor. It cannot be posted.",
  "harassment/threatening":
    "That reads as a threat aimed at someone. Take out the threat and it can go up.",
  "hate/threatening":
    "That reads as a threat against a group of people. It cannot be posted as written.",
  "illicit/violent":
    "That describes carrying out serious harm. It cannot be posted.",
  "violence":
    "That reads as a threat of violence. It cannot be posted as written.",
};

/// Everything else the classifier can raise. These never stop a post; they put
/// it in front of a moderator.
export const FLAG_CATEGORIES = [
  "harassment",
  "hate",
  "illicit",
  "self-harm",
  "self-harm/intent",
  "self-harm/instructions",
  "sexual",
  "violence/graphic",
];

export interface Verdict {
  verdict: "ok" | "flag" | "block";
  category: string;
  reason: string;
}

/// The verdict for one classifier result.
///
/// A block needs BOTH the raised category and a confident score, because a
/// block on a machine's say-so is the decision worth being careful about.
/// Everything raised without that confidence becomes a flag — a wrong block
/// silences somebody, a wrong flag costs a moderator a glance.
export function verdictFor(
  categories: Record<string, boolean>,
  scores: Record<string, number>,
): Verdict {
  for (const [category, reason] of Object.entries(BLOCK_REASONS)) {
    if (categories[category] !== true) continue;
    // Content involving minors is the one case where the threshold is the
    // classifier's own judgement; there is no version of this worth a second
    // opinion first.
    const confident = category === "sexual/minors" ||
      (scores[category] ?? 0) >= BLOCK_AT;
    if (confident) return { verdict: "block", category, reason };
  }

  // A severe category raised but not confidently is still worth a look — it
  // falls through to here rather than being forgotten.
  const flagged = FLAG_CATEGORIES.find((c) => categories[c] === true) ??
    Object.keys(BLOCK_REASONS).find((c) => categories[c] === true);
  if (flagged) return { verdict: "flag", category: flagged, reason: "" };

  return { verdict: "ok", category: "none", reason: "" };
}
