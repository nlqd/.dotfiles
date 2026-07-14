---
name: academic-writing
description: Use when drafting or revising any part of a research manuscript (abstract, introduction, method, experiments, related work, conclusion, rebuttal), framing contributions or calibrating claims, building results tables or figures, writing equations and notation, positioning against prior work, or preparing an author response, especially for ML/CV venues (WACV, CVPR, ICCV, ECCV, NeurIPS). Also use when a draft section reads weak, overclaims, or you want a reviewer-style critique.
---

# Academic writing

Rules for writing and editing a research paper. Two layers: a general scientific-writing core, then ML/CV conference conventions on top. Built for this manuscript but reusable across papers.

Core principle, in one line: write for value to the reader, build the whole paper around one reusable idea, and remember the paper is the advertisement for the work. Work that is unpublished or unclear may as well not have been done.

This skill governs structure, claims, evidence, math, and figures. For sentence-level AI-tell cleanup (em dashes, rule-of-three, inflated significance, promotional tone), it does not repeat the rules, it defers: run the `humanizer` skill and follow the prose rules in the project CLAUDE.md (comma/colon over em dash, minimal bold, prose over bullets, LaTeX symbols over unicode).

## Quick reference

Read this much if nothing else.

- Can a tired reader state your one idea after one pass? If not, the paper has no spine yet.
- Does the intro answer: what problem, why it matters, what is missing in prior work, what is your key insight, what do you contribute?
- Is every contribution a scoped, refutable claim the experiments actually deliver?
- Does each headline claim point to a specific figure, table, or number?
- Does an ablation isolate the cause, toggling one component at a time?
- Are baselines tuned with the same backbone, data, and budget as your method?
- Are results reported over multiple seeds with error bars, not a single best run?
- Is every symbol defined at first use, and every displayed equation numbered and punctuated?
- Self-cite in third person, no "in our previous work", and strip identifying content (blind review).
- Could a hostile reviewer point to one easy reason to reject? Remove it.

## 1. The one idea and the reader

- Commit the paper to exactly one reusable idea. If you have several, write several papers (Peyton Jones).
- State the idea explicitly: "The main idea of this paper is...". Many papers hide a good idea and never distil it.
- Write for the reader's gain, not to show effort or what you learned. "Interesting and unpublished" equals non-existent (McEnerney, Whitesides).
- Treat readers as busy expert skeptics who skim and bail. Front-load worth: the paper is read in a funnel (title, abstract, details), so value must surface where the eye lands.
- Beat the curse of knowledge: assume the reader lacks the context obvious to you. Define jargon and notation before using it (Pinker).

## 2. Structure and the introduction

- Order content by importance, not chronology. Lead with the main result; do not recount your path of discovery.
- Tell it as a story, as at a whiteboard: here is a problem, it is interesting, it is unsolved, here is my idea, it works, here is how it compares.
- Open with a concrete problem or tension the reader already cares about, not a grand survey. One example beats six citations (molehills not mountains).
- Use the five-question intro: what is the problem, what have others done, what is the gap, what did you do, what do you contribute (Jia-Bin Huang).
- Write the contributions list first and let it drive the paper. Make each an enumerated, refutable claim with a forward reference to where it is delivered (Peyton Jones).
- Keep the intro near one page. Convey intuition before formalism, examples before the general case.
- Put related work at the end, where it does not stand between the reader and your idea.

## 3. Claims and contributions

- Match claim strength to evidence: an existence claim needs one solid example, a universal claim needs breadth (Steinhardt).
- Narrow every "general" claim to the exact datasets, metrics, and conditions tested. Never let the abstract promise more than the experiments deliver.
- "Do the authors deliver what they promise?" is the first reason an AC reaches for to reject. Cut any claim the experiments do not support (Freeman).
- Frame novelty as what was done first, not how hard it was. Difficulty is not innovation; a simple idea with a big effect is genuine novelty (Black).
- Do not sell on the SOTA table alone. Reviewers are told that failing to beat SOTA is not by itself grounds for rejection; sell on insight and significance.
- Avoid mathiness: use math and terms of art only where they clarify, never to look sophisticated (Lipton and Steinhardt).

## 4. Experiments and evidence

- Include an ablation that toggles each claimed component on and off, one variable at a time. Without it, reviewers cannot attribute the gain to your idea versus tuning.
- Tune baselines with the same backbone, data, protocol, and compute as your method; reimplement freshly when feasible. Under-tuned baselines manufacture false superiority and get caught.
- Report over multiple seeds with error bars or standard deviation, stating the number of runs and what the bar captures. Single best runs read as cherry-picking.
- In comparison tables, mark which numbers you reproduced versus copied, and cite the source paper for every baseline.
- Make every headline claim traceable to a specific figure, table, or number in the text.
- Specify all training and eval details (splits, hyperparameters and how chosen) and compute used; keep the test set for the final model only.
- Be scrupulously honest: report what did not work. Trust, once earned, carries the whole paper (Freeman).

## 5. Related work and positioning

- Cite the key prior work and state plainly why existing solutions are unsatisfactory and how you differ. Missing references signal you are not on top of the field.
- Position so the work reads as neither too incremental nor unbelievable, and pre-empt the "obvious in hindsight" dismissal.
- Discuss competitors graciously, from security not rivalry; acknowledge trade-offs instead of claiming dominance on every axis.
- Self-cite in the third person: "Smith et al. [1] show", never "in our previous work [1]". First-person self-reference breaks double-blind review.

## 6. Math and notation

Mermin's three rules ("What's Wrong With These Equations?", 1989):
- Fisher's Rule: number all displayed equations, even ones you never reference. You cannot predict which a later reader will need to cite.
- Good Samaritan Rule: refer to an equation by a descriptive phrase, not a bare number. "As the balance condition (6) shows" spares a backward page-flip.
- Math Is Prose Rule: a displayed equation is part of a sentence, so end it with the right punctuation (comma or period).

- Never start a sentence with a symbol; recast as "The polynomial $x^n - a$ has..." (Knuth et al.).
- Make the prose flow when every formula is mentally replaced by "blah". Many readers skim formulas on the first pass.
- Define every symbol at or near first use. Never use one notation for two things, or two notations for one thing.
- Design the whole notation before writing, with consistent typographic conventions (lowercase elements, uppercase sets, bold vectors). Minimize subscript and superscript pileups (Halmos, Knuth et al.).

## 7. Figures and tables

- Put a teaser figure on page 1 showing the main idea or best result. It answers "what did you do?" before the reader reads a word.
- Write self-contained captions that state the takeaway and tell the reader what to notice, not merely what is shown. Figure plus caption must stand alone.
- Size figure fonts near body-text size; export plots as vector PDF with adequate line widths. Reference every figure by number in the text.
- Use a color-blind-safe palette (Okabe-Ito, viridis, ColorBrewer), never jet/rainbow, and never encode meaning by color alone; add a redundant channel (marker, line style, label).
- Tables: use booktabs (`\toprule`, `\midrule`, `\bottomrule`), no vertical rules. Bold the best result per column, underline the second-best.
- Keep decimal precision consistent within a column and align on the decimal point. Define metrics, units, and arrows ($\uparrow$/$\downarrow$) in the caption, placed above the table.

## 8. Prose and clarity

Science-specific items only. For everything else (AI tells, em dashes, tone), run `humanizer` and follow CLAUDE.md.

- Fix one canonical term per concept and repeat it; do not cycle synonyms. Use "gain" throughout, never gain/boost/swing/lift for the same quantity. Repeating the exact term of art is clarity in technical prose, not monotony.
- Prize precision over formality. Prefer plain, concrete words, and reach for a longer or rarer word only when it is more exact, never to sound academic. Watch colloquial metaphors looser than the plain term (a "swing" in accuracy is just a change).
- Give one idea per paragraph, led by a topic sentence. Chain sentences old-information-first, new-information-last.
- Prefer active voice and name the agent: "we run 34 tests", not "34 tests were run".
- Make "this" point to an explicit noun: "this regularizer", not a bare "this".
- Complete every comparison: "higher with bromine than with chlorine", not "higher with bromine".
- Never use a citation as a noun. The sentence must stay grammatical with all brackets removed: "as shown by Smith et al. [1]", not "[1] shows".

## 9. Reviewer psychology and rebuttals

- Write for a hurried reviewer asking "how can I reject this?". Remove every easy-to-point-to flaw; one small defect sinks a good paper.
- Make the paper look like a good paper: clear teaser, clean tables, full pages, no large blank space. Reviewers form a gestalt before reading closely.
- Red-team your own narrative and state limitations honestly. Competent reviewers detect hidden weaknesses and lose confidence; visible integrity earns respect.
- In a rebuttal, quote each concern and answer it directly, biggest first, with concrete new results (a small table), not camera-ready promises.
- Keep the rebuttal self-contained (re-expand acronyms, cite exact line, table, and figure numbers) and non-combative. The AC may read only the reviews and rebuttal.
- Do not add contributions reviewers did not request, or make claims contradicting the submission.

## 10. WACV compliance (verify against the live CFP)

Hard constraints that risk desk rejection. Confirm specifics against the current WACV author kit, since they shift year to year.

- Main paper within the page limit including all figures and tables; references on extra pages; official template unedited.
- Strip all author-identifying content: acknowledgments, grant IDs, identity-revealing links, named leaderboard entries, code or data headers.
- Keep core results in the main paper. Supplementary is for videos, proofs, and deeper analysis, not new results or retuned methods; reviewers need not read it.
- Include a dedicated limitations section (assumptions, robustness, scope).

## Common mistakes

| Mistake | Fix |
| --- | --- |
| Intro surveys the field before naming the problem | Open on one concrete problem the reader cares about |
| Contributions vague or implied | Enumerate scoped, refutable claims with forward references |
| Abstract promises more than experiments show | Narrow claims to what is tested |
| Gain not attributable | Add a one-variable-at-a-time ablation |
| Single best-run numbers | Report mean and std over seeds |
| "in our previous work [1]" | Third-person self-citation |
| Unnumbered or unpunctuated equations | Number all; punctuate as sentence parts |
| Caption says only what is shown | Caption states the takeaway, stands alone |
| Ends on a "future work" section | Close on a conclusion or where the work leads |
| Synonym-cycling a key quantity (gain, boost, swing) | Fix one canonical term and repeat it |
| Reaching for a fancier word to sound academic | Prefer the plain, more precise word |

## Sources

General craft: Peyton Jones, "How to Write a Great Research Paper"; Whitesides, "Writing a Paper" (Adv. Mater. 2004); McEnerney, "The Craft of Writing Effectively" (UChicago); Pinker, "The Sense of Style"; Strunk and White; Zinsser. ML/CV: Jia-Bin Huang ("Research 101", the five-question intro); Freeman, "How to Write a Good CVPR Submission"; Steinhardt, "Highly Opinionated Advice on How to Write ML Papers"; Black, "Novelty in Science"; Lipton and Steinhardt, "Troubling Trends in ML Scholarship"; Parikh, Batra, and Lee, "How We Write Rebuttals"; CVPR/WACV/NeurIPS author and reviewer guidelines. Math and figures: Mermin, "What's Wrong With These Equations?" (1989); Knuth, Larrabee, and Roberts, "Mathematical Writing" (Stanford); Halmos, "How to Write Mathematics"; Wong, "Color Blindness" (Nature Methods 2011); Wilke, "Fundamentals of Data Visualization".
