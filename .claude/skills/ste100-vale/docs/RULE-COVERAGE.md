# Rule coverage

ASD-STE100 Issue 9 defines 53 writing rules across 9 sections:
1. Words (14 rules), 2. Multi-word nouns (2), 3. Verbs (7), 4. Sentences (5),
5. Procedural writing (5), 6. Descriptive writing (6), 7. Safety instructions
(3), 8. Punctuation and word count (7), 9. Writing practices (4). That adds
up to 53, confirming this structure against the official Issue 9 table of
contents.

A note on how these citations were checked: the PDF is copy-protected (its
own permission flags disable extraction) and its free-to-request copy grants
reproduction/publication rights to 8 specific organizational categories,
which doesn't include an individual open-source project. So this document
cites rule numbers and describes rules in our own words, the same way any
style guide cites an external standard, but does not reproduce rule text,
examples, or dictionary entries from the spec.

Rows below marked with a specific rule ID (STE-x.y) have been checked
against the real Issue 9 table of contents and rule titles. Rows without a
specific ID are described by concept only, we either haven't located the
exact rule yet or the concept spans parts of several rules. Two IDs in this
document, STE-6.7 and STE-8.11, were inherited from `stilist/text_linter`,
which targets an older edition (Issue 6). Rule numbers move between issues
(confirmed directly: Issue 9's own changelog notes "Rule 2.3 removed from
section 2, moved to section 4 to become rule 4.5"), so those two are flagged
below as unverified against Issue 9 specifically, not confirmed like the
others.

**A real correction already made from this cross-check**: this project
initially shipped a rule banning the words "can, could, may, might, should,
would" outright, sourced from a third-party summary. That summary was wrong.
The real Rule 3.4 uses "You can adjust the volume control" as an example of
*correct* STE text, and the dictionary lists `CAN (v)` as approved. The
actual violation is combining an auxiliary with a past participle ("can be
adjusted," "has adjusted"), not using a modal on its own. That rule has been
removed and replaced with `NoPerfectTense` (have/has/had + past participle),
which matches Rule 3.4's own examples.

Automatable column key:

- **Yes**: a Vale check reliably detects every real violation of this rule.
- **Heuristic**: a Vale check catches common cases but has real false
  positive/negative risk; useful as a first-pass flag, not a compliance proof.
- **No**: detecting this requires understanding meaning, not pattern
  matching. Out of scope for any deterministic linter, including this one.

## Section 1: Words (14 rules)

| Rule | Automatable | Mechanism | Status |
|---|---|---|---|
| Use only approved dictionary words, technical nouns, technical verbs (STE-1.1) | Yes | `spelling` check backed by a generated Hunspell dictionary of just your approved words (bring-your-own, see README); `scripts/build-dictionary` compiles it | **Implemented** |
| Each approved word has one meaning and one part of speech (STE-1.2) | Heuristic | `sequence` checks: words approved as noun-only flagged when tagged as any verb form, and vice versa. Only the noun/verb confusion is covered, other mixups (adjective/adverb, and so on) aren't generated. Sentence-initial imperative verb usage is under-detected in testing, a tagger accuracy limit, not a rule bug | **Implemented** |
| Use technical nouns approved in your company/industry/subject field (STE-1.8) | No | Requires knowing what counts as an authoritative domain glossary | Not automatable |
| New technical nouns should be short, 3 words or less (STE-1.9) | No | Only relevant when coining new terminology, a judgment call about what's "easy to understand" | Not automatable |
| Do not use regional, slang, or jargon words as technical nouns (STE-1.10) | No | Requires knowing what's regionally obscure vs. universally understood | Not automatable |
| Do not use different technical nouns for the same item (STE-1.11) | Heuristic | `ConsistentTerminology`, Vale's `consistency` check, but only for synonym pairs you tell it about; it can't discover unknown synonyms on its own. Ships with one placeholder pair, replace it with your own domain's terms | **Implemented** |
| Technical verbs must fit an approved category (STE-1.12), not used as nouns (STE-1.13) | No | Requires an external technical-verb glossary and category judgment, same shape as STE-1.8 | Not automatable |
| American English spelling (STE-1.14) | Yes | `substitution` list, British → American spellings. Not exhaustive, covers common cases | **Implemented** |

## Section 2: Multi-word nouns (2 rules)

| Rule | Automatable | Mechanism | Status |
|---|---|---|---|
| Write multi-word nouns of no more than 3 words (STE-2.1) | Heuristic | `NounClusterLimit`, `sequence` check counting consecutive noun-tagged tokens | **Implemented** |
| When a technical noun needs more than 3 words, shorten it or hyphenate it as one unit (STE-2.2) | No | Detecting the long cluster is automatable (above); picking a shorter form or knowing which hyphenation is officially approved is a generative/domain-knowledge task, not a lint | Not automatable |

Dogfooded against real prose (this project's own `humanizer` skill docs, not written
in STE), `NounClusterLimit` caught one real bug: non-word tokens (an arrow character, "→")
that the tagger mistagged as a noun could join a cluster; fixed by requiring every
token in the sequence to match `\w+`, not just the anchor. Two failure modes remain
that no regex fix resolves, only real, disclosed tagger limitations: POS-ambiguous
words used in an unfamiliar role get mistagged as nouns (e.g. "substitute" and
"multiple" used as a verb/adjective respectively), and runs of ALL-CAPS emphasis
text get over-tagged as proper nouns. Expect occasional false positives of both
kinds on non-technical prose; STE100-style declarative sentences (the actual target
domain) triggered none in testing.

## Section 3: Verbs (7 rules)

| Rule | Automatable | Mechanism | Status |
|---|---|---|---|
| Use only the verb forms given in the dictionary (STE-3.1) | No | Requires per-word dictionary lookup of which forms are approved for that specific word; broader than a fixed tag list | Not automatable without full dictionary data |
| Use only infinitive, imperative, simple present/past/future, or past participle as adjective (STE-3.2) | Heuristic | Partially covered by `NoProgressiveTense` and `NoPerfectTense` below, which each catch one disallowed construction | Partial |
| Use the past participle form as an adjective (STE-3.3) | No | Distinguishing correct adjectival use from other uses needs sentence-level grammatical judgment beyond tag-matching | Not automatable |
| Do not use auxiliary verbs to make complex verb constructions (STE-3.4) | Heuristic | `NoPerfectTense`, `sequence`: have/has/had + past participle, matches the rule's own explicit example ("has adjusted" flagged). The modal+passive example in the same rule ("can be adjusted") is already caught by `PassiveVoice` below, since the modal is incidental to that pattern | **Implemented** |
| Use the "-ing" form of a verb only as a technical noun or modifier, never as a verb (STE-3.5) | Heuristic | Depends entirely on the tagger distinguishing VBG-as-verb from VBG/NN-as-noun in context; real false-positive risk | Planned, low confidence |
| Use active voice; passive only in descriptions when the agent is unknown (STE-3.6) | Heuristic | `sequence`: be-form + past participle. Detecting passive voice is reliable; judging whether "the agent is genuinely unknown" is not, see the Procedure/Description split below | **Implemented** |
| Use an approved verb to describe an action, not a noun or other part of speech (STE-3.7) | Heuristic | Overlaps with STE-1.2's noun/verb confusion check above | Covered by STE-1.2 |

**Correction note**: this project previously shipped `NoModalVerbs`, banning
can/could/may/might/should/would outright. That was wrong, sourced from a
third-party summary rather than the spec. Removed; see the note at the top
of this document.

## Section 4: Sentences (5 rules)

| Rule | Automatable | Mechanism | Status |
|---|---|---|---|
| Short sentences (word limits are set per Section 5/6 below) | Yes | See Sections 5 and 6 | **Implemented** |
| Do not omit the subject, verb, or articles | No | Requires grammatical completeness judgment | Not automatable |
| Use vertical lists for complex sequences | No | "Complex" is a judgment call, not a text property | Not automatable |
| State conditions before commands ("If X, do Y") | Heuristic | Depends on reliably detecting the sentence-initial imperative verb in "do Y"; blocked, see Section 5 | Blocked on tagger accuracy |
| Articles and demonstrative adjectives (moved here from old rule 2.3 in Issue 9) | No | Haven't located the exact current rule text; likely requires grammatical judgment similar to omitted articles above | Not yet reviewed |

## Section 5: Procedural writing (5 rules)

| Rule | Automatable | Mechanism | Status |
|---|---|---|---|
| Give commands using the imperative form | Heuristic | Blocked: tested empirically and Vale's tagger mistags sentence-initial imperative verbs (for example "Install" opening a sentence gets tagged `DT`, not `VB`), so there's no reliable tag to anchor on. Same tagger gap noted for `WordPartOfSpeech`, but here it blocks the rule entirely rather than just causing occasional misses | Blocked on tagger accuracy |
| One instruction per sentence; never combine instructions | Heuristic | Same blocker: flagging "coordinating conjunctions joining two imperative clauses" needs the first clause's sentence-initial verb reliably tagged, which the tagger doesn't do | Blocked on tagger accuracy |
| Max 20 words per sentence | Yes | `STE100Procedure.SentenceLength`, `occurrence`, `scope: sentence` | **Implemented** |
| No passive voice, no narrative | Heuristic | `STE100Procedure.PassiveVoice`, `sequence`: be-form + VBN, always an error since procedures never allow passive voice | **Implemented** |
| Content structure / paragraph rules for procedures | No | Haven't located the exact current rule text | Not yet reviewed |

## Section 6: Descriptive writing (6 rules)

| Rule | Automatable | Mechanism | Status |
|---|---|---|---|
| Active voice preferred; passive only when the agent is unknown | Heuristic | `STE100Description.PassiveVoice`, `sequence`: be-form + VBN. Can't judge "agent is genuinely unknown" mechanically, so this flags at `suggestion` level for human review rather than erroring | **Implemented** |
| Max 25 words per sentence | Yes | `STE100Description.SentenceLength`, same mechanism as Section 5 | **Implemented** |
| One topic per paragraph, topic sentence at the start | No | Requires understanding paragraph content | Not automatable |
| Max sentences per paragraph | Yes | `ParagraphSentenceLimit`, `occurrence`, `scope: paragraph`, counting sentence-ending punctuation. Cited as STE-6.7 by `text_linter` (Issue 6); not yet confirmed against Issue 9's renumbered Section 6, and `text_linter`'s own implementation of this rule is broken regardless (counts the whole document, not per paragraph), ours is correctly scoped | **Implemented**, citation unverified |
| Remaining descriptive-writing structure rules | No | Haven't located the exact current rule text | Not yet reviewed |

## Section 7: Safety instructions (3 rules)

| Rule | Automatable | Mechanism | Status |
|---|---|---|---|
| WARNING/CAUTION/NOTE must open with a clear command or condition | Heuristic | Structural check on the block's first sentence | Planned |
| Three levels with defined formatting | Yes | `existence`/format check that the label is present and styled correctly | Planned |
| Safety text may need legal review | No | Organizational process, not a text property | Not automatable |

## Section 8: Punctuation and word count (7 rules)

| Rule | Automatable | Mechanism | Status |
|---|---|---|---|
| No semicolons | Yes | `NoSemicolons`, `existence`. Cited as STE-8.11 by `text_linter` (Issue 6); Issue 9's Section 8 only has 7 rules per its table of contents, so 8.11 is very likely stale, not yet re-confirmed against the real Issue 9 number | **Implemented**, citation unverified |
| Other punctuation restrictions (colons, dashes, parentheses, list punctuation) | Partial | Each specific restriction can be its own `existence` check once we confirm the exact rule; not yet reviewed against Issue 9 text | Needs review |
| Word-count limits | Yes | Covered under Sections 5/6 above | **Implemented** |

## Section 9: Writing practices (4 rules)

| Rule | Automatable | Mechanism | Status |
|---|---|---|---|
| The conjunction "that" (general recommendation, not a numbered rule) | No | Stylistic preference, not a detectable violation | Not automatable |
| When you select terminology or wording, use a consistent style (STE-9.4) | Heuristic | Related to `ConsistentTerminology` (STE-1.11) above; STE-9.4 is broader (wording/phrasing patterns for repeated instructions, not just object naming) and isn't separately implemented | Partially covered by STE-1.11 |
| Simple, parallel sentence constructions | No | Structural elegance is a judgment call | Not automatable |
| Avoid recurring error patterns | Partial | Specific known patterns can become `existence` checks; the general instruction is not automatable | Case-by-case |

## Summary

Of the concepts tracked above, 9 are implemented and confirmed against real
Issue 9 rule numbers, 2 more are implemented but carry a citation inherited
from `text_linter`'s older edition that still needs re-checking (STE-6.7,
STE-8.11), and a handful are implemented against a correctly-identified rule
but without a specific sub-number yet. 3 are blocked on a concrete, tested
tagger limitation (Vale mistags sentence-initial imperative verbs, confirmed
empirically: "Install" opening a sentence gets tagged `DT`, not `VB`), and
several sections still have rules we haven't located in the real text yet
("Not yet reviewed"). The remainder require actual reading comprehension and
are out of scope for any mechanical linter, including a hypothetical
"AI-powered" one that isn't willing to say so.
