A real before/after test, not synthetic fixtures.

- `original-server-mode-setup.md`: unmodified copy of a real setup doc from
  a personal dotfiles repo, ordinary prose, not written in STE.
- `server-mode-setup-procedure.md` / `server-mode-setup-description.md`:
  the same content, hand-rewritten into STE100 style and split into a
  procedure and a description (STE requires not mixing the two).

`ApprovedWords`/`WordPartOfSpeech` are turned off here since this repo's
dictionary is placeholder-only (see the top-level README); without a real
~900-word approved list those two rules would flag nearly every word,
which would swamp the signal from the rules that actually matter for this
comparison.

Run it:

    cd examples
    vale --config=.vale.ini .

The original flags real violations (semicolons, a modal verb, a
26-word sentence, three passive-voice constructions). The rewrite passes
clean.
