# ste100-vale

A [Vale](https://vale.sh) style package implementing the mechanically
checkable rules of [ASD-STE100](https://www.asd-ste100.org) Simplified
Technical English (Issue 9, January 2025).

This is not an official STEMG tool, and it does not claim to certify STE
compliance. STE has 53 writing rules; a meaningful fraction of them require
understanding what a sentence means, not just its shape, and no deterministic
linter can check those. See [`docs/RULE-COVERAGE.md`](docs/RULE-COVERAGE.md)
for exactly which rules this package checks, which it approximates with
heuristics, and which it can't check at all, and why.

## Why this exists

The only pre-existing open-source STE linter, [`stilist/text_linter`](https://github.com/stilist/text_linter),
is abandoned (last commit 2020) and has real bugs: one of its rules is a
tautology that never fires, another counts sentences across the whole
document instead of per paragraph, and a third is implemented but never
wired into its default rule set. No Vale style for STE100 existed before this
one.

## Install

Clone this repo somewhere Vale can find it and point your own `.vale.ini` at
it:

```ini
StylesPath = /path/to/ste100-vale/styles

[formats]
tex = md

[*.{md,tex}]
BasedOnStyles = STE100

[procedures/*.{md,tex}]
BasedOnStyles = STE100, STE100Procedure

[descriptions/*.{md,tex}]
BasedOnStyles = STE100, STE100Description
```

`STE100` holds the rules that apply regardless of text type (vocabulary,
noun-cluster limits, punctuation). `STE100Procedure` and `STE100Description`
add the rules that differ between instructions and explanations (sentence
length, passive voice). STE requires classifying text as one or the other
before applying these, so pick the style variant per file glob rather than
relying on the tool to guess.

A fourth package, `STE100Unverified`, is opt-in and off by default. It holds
rulings taken from a third-party summary of the standard rather than from the
standard itself: the modal ladder, a set of verb swaps, and `and/or`. Every
rule in it is pinned to `suggestion`. Add it to `BasedOnStyles` when you want
those flags for human review, and read
[`docs/RULE-COVERAGE.md`](docs/RULE-COVERAGE.md) first for why they are kept
separate.

Vale has no native LaTeX format, `tex = md` is a crude extension-level
substitution it documents itself: `.tex` files get linted as if they were
Markdown. Structural rules (sentence length, noun clusters, passive voice)
held up fine in testing against real LaTeX prose, commands like
`\section{...}` weren't mistaken for prose violations. Inline math isn't
stripped, though, a token like `x$` next to a `$...$` boundary can get
tokenized oddly. Worth a skeptical read on math-heavy documents.

## Dictionary (bring your own)

The ~900-word approved dictionary is copyrighted by STEMG and won't be
redistributed here. Request your free copy of the standard at
[asd-ste100.org](https://www.asd-ste100.org), fill in
`dictionary/ste100-words.csv` yourself following the schema in
`dictionary/ste100-words.example.csv`, then run:

```sh
ruby scripts/build-dictionary
```

This generates the dictionary-dependent rules from whichever CSV exists
(your real one, or the example placeholder if you haven't filled one in
yet): `ApprovedWords` (a Hunspell dictionary of just your approved words,
wired into Vale's `spelling` check), and `WordPartOfSpeechNoun`/
`WordPartOfSpeechVerb` (flags a noun-only word used as a verb, or a
verb-only word used as a noun). See
[`docs/RULE-COVERAGE.md`](docs/RULE-COVERAGE.md) for exact scope and known
limitations.

Every other rule works today without a dictionary.

## Development

```sh
bundle install
ruby scripts/build-dictionary   # generates the dictionary-dependent rules
bundle exec cucumber            # run the rule test suite
```

Every rule is test-first: a Gherkin scenario in `features/rules.feature`
plus a fixture in `fixtures/<RuleName>/test.md`, written and confirmed
failing before the rule (`styles/**/*.yml`) that makes it pass.

## License

[MIT](LICENSE). ASD-STE100 is a registered trademark of ASD; this project is
not affiliated with or endorsed by ASD or STEMG.
