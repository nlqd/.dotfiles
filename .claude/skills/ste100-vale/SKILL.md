---
name: ste100-vale
description: |
  Lint or write technical documentation against ASD-STE100 Simplified
  Technical English. Use when the target style is STE100 rather than
  natural prose: procedures, runbooks, setup guides, maintenance
  instructions. Runs the deterministic Vale style in this repo and fixes
  what it flags. Not for general "sound less like AI" edits, that's the
  humanizer skill instead.
---

# ste100-vale

Deterministic linter for ASD-STE100 Simplified Technical English, see
[`README.md`](README.md) for what it checks and why it exists, and
[`docs/RULE-COVERAGE.md`](docs/RULE-COVERAGE.md) for exactly which of the
53 rules are implemented, heuristic, or out of scope.

## Workflow

1. Classify the text as procedure (instructions) or description
   (explanation) first. Never mix the two in one passage, STE100 requires
   picking one.
2. Run the linter:

   ```sh
   cd ~/dev/ste100-vale
   export PATH="$PWD/bin:$PATH"
   vale --config=.vale.ini <path-to-file>
   ```

   For a procedure or description specifically (sentence-length and
   passive-voice rules differ between the two), scope it with an inline
   `.vale.ini` the way `fixtures/` and `examples/` do, or add a glob
   section to your own project's config, see the README's Install section.
3. Fix every flagged line, then re-run until clean. Each message names the
   violated rule and, where confirmed, its real ASD-STE100 rule number.
4. If a rule looks wrong or overly aggressive on real text, that's
   worth reporting, not silently ignoring, `docs/RULE-COVERAGE.md` tracks
   known false-positive classes (e.g. POS-tagger mistakes on
   sentence-initial imperatives, ALL-CAPS runs).

## What this can't do

STE100 has 53 rules; a real fraction of them need reading comprehension,
not pattern matching (is the topic sentence first, is this list "too
complex," did text omit a necessary article). This linter does not attempt
those and says so in `RULE-COVERAGE.md`. Don't claim STE100 compliance
from a clean lint run alone.
