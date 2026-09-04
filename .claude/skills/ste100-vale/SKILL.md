---
name: ste100-vale
description: |
  Lint or write technical documentation against ASD-STE100 Simplified
  Technical English. Use when the target style is STE100 rather than
  natural prose: procedures, runbooks, setup guides, maintenance
  instructions, error messages, incident reports, release notes, and
  instructions written for other agents. Runs the deterministic Vale style
  in this repo, then does the judgment pass the linter cannot. Not for
  general "sound less like AI" edits, that's the humanizer skill instead.
---

# ste100-vale

Deterministic linter for ASD-STE100 Simplified Technical English, see
[`README.md`](README.md) for what it checks and why it exists, and
[`docs/RULE-COVERAGE.md`](docs/RULE-COVERAGE.md) for exactly which of the
53 rules are implemented, heuristic, or out of scope.

The linter covers the mechanical half of STE. The judgment pass below covers
the half that needs reading comprehension. Neither one alone is enough, and
together they still do not certify compliance.

## Pick a level first

Full STE needs the approved dictionary, which is copyrighted and not in this
repo. So say which level you are working at:

Structural is the default. Every rule that does not depend on the dictionary:
sentence length, verb forms, active voice, noun clusters, punctuation,
condition order. Domain words stay as they are. This is what a clean lint run
means.

Dictionary level adds one-word-one-meaning discipline and needs your
filled-in `dictionary/ste100-words.csv`. Say so explicitly when you report at
this level, and say that final approval needs the official standard.

## Workflow

1. Classify the text as procedure (instructions) or description
   (explanation). Every other rule depends on this, and STE does not let you
   mix the two in one passage. A "Getting started" section is a procedure. An
   "Architecture" section is a description. A note inside a procedure is a
   description and takes the 25-word limit, not the 20-word one.
2. Choose your terms before you draft, not after. If the document needs a
   word for the check/verify/confirm concept, pick one now and use nothing
   else for it. Same for config, settings, and options. Retrofitting this
   costs far more than deciding it up front.
3. Run the linter:

   ```sh
   cd ~/dev/ste100-vale
   export PATH="$PWD/bin:$PATH"
   vale --config=.vale.ini <path-to-file>
   ```

   Sentence-length and passive-voice rules differ between procedures and
   descriptions, so scope the run with an inline `.vale.ini` the way
   `fixtures/` and `examples/` do, or add a glob section to your own
   project's config. See the README's Install section.
4. Fix every flagged line, then re-run until clean. Each message names the
   violated rule and, where confirmed, its real ASD-STE100 rule number.
5. Do the judgment pass below. A clean lint run is not the finish line.
6. If a rule looks wrong or overly aggressive on real text, that's worth
   reporting, not silently ignoring, `docs/RULE-COVERAGE.md` tracks known
   false-positive classes (e.g. POS-tagger mistakes on sentence-initial
   imperatives, ALL-CAPS runs).

## The judgment pass

These are the rules the linter does not check, listed in
`docs/RULE-COVERAGE.md` as not automatable. Read the draft once for each.

Classification. Is every passage cleanly one type? Procedures use the
imperative and never narrate. Descriptions explain and never command.

One instruction per sentence. A procedure sentence that joins two actions
with "and" is two steps, unless the actions really do happen at the same
time.

Condition placement. The linter flags a trailing "if" or "when" but cannot
tell a condition from a noun clause. "Determine if the file exists" is fine.
"Read the log if the build fails" is not, and becomes "If the build fails,
read the log."

Notes and warnings. A note gives information and never instructs. A warning
or a caution opens with the command or the condition and gives the risk
second. Never bury the instruction behind the explanation.

Passive voice in descriptions. The linter flags every instance at suggestion
level because it cannot judge intent. Passive is legal only where the agent
is genuinely unknown. Everywhere else, name who acts.

Completeness. STE is short sentences with complete grammar, not telegraph
style. "Ensure file exists before running" is not STE. "Make sure that the
file exists before you run the command" is. Keep the articles and keep
"that".

One new fact per sentence. Descriptive text gives information gradually. A
sentence carrying three facts is three sentences.

Terminology drift. The consistency check only knows the synonym pairs you
told it about. Re-read for the ones you did not list.

Facts. Rewrite the style, not the content. Where the source gives no number,
no cause, or no exact term, keep the general statement. Do not invent
specifics to look concrete.

## Untouchables

Leave these exact, even where they break a vocabulary rule. They are
technical names, and the word-count rules already treat each as one word.

Code blocks, inline code, identifiers, commands, flags, and file paths.
Quoted error messages and log lines. Product names, endpoint names, and
config keys. Numbers with their units.

## Reporting

When asked to check text rather than write it, give each violation as the
rule number, the offending text, and a compliant rewrite. Cite only rule
numbers that `docs/RULE-COVERAGE.md` records, and prefer the section name
where that document flags a sub-number as unverified. Models invent STE rule
numbers freely and the real numbering is not intuitive.

End a compliance report with the limit: no tool certifies ASD-STE100
compliance, final approval rests with the writer, and the standard is a free
download at asd-ste100.org.

## What this can't do

STE100 has 53 rules; a real fraction of them need reading comprehension,
not pattern matching (is the topic sentence first, is this list "too
complex," did text omit a necessary article). This linter does not attempt
those and says so in `RULE-COVERAGE.md`. The judgment pass above is a
careful reading, not a check, so it does not close the gap either. Don't
claim STE100 compliance from a clean lint run alone.

STE is for technical facts and instructions. It deletes persuasion by
design, so keep it away from marketing copy, launch posts, and brand voice.
For making ordinary prose read less like a machine wrote it, use the
humanizer skill instead.

See [`docs/USE-CASES.md`](docs/USE-CASES.md) for how the same rules apply to
error messages, runbooks, incident reports, release notes, and instructions
written for other agents.
