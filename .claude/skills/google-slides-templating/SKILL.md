---
name: google-slides-templating
description: Use when building or extending a Google Slides deck programmatically (Slides API or a Workspace CLI like gws), when new slides must automatically inherit a consistent background/font/layout, when a diagonal line/connector/arrowhead renders wrong, when building flowcharts or other diagrams via the API, when asked about Morph or slide/object animation via the API, when you need a custom slide layout/master and the Slides API alone can't create one, when a replaceAllText edit seems to vanish or hit zero occurrences unexpectedly, or when auditing an existing deck for leftover unstyled or inconsistent elements
---

# Google Slides Templating

## Overview

The Slides API can edit slides but cannot author masters or layouts: `presentations.create` ignores any `masters`/`layouts` in its request body, `duplicateObject` explicitly refuses layout pages, and there is no `createLayout`/`createMaster` request in the whole `Request` union. Two levels of "template" are available depending on how native the result needs to be.

## When to Use

- Building a multi-slide deck via the Slides API/gws where every slide should share chrome (background, corner marks, title style, etc.)
- "+ New slide" or "Apply layout" in the Slides UI produces something unstyled, because the design lives on hand-drawn shapes rather than a real layout
- A diagonal line or shape renders as a stray angle/chevron instead of a clean diagonal
- Need a genuinely native, selectable custom layout (Slidesgo-style) built without touching the Slides UI by hand

## Design Language First (Optional)

If the visual design itself is still undecided (colors, type, motif, layout), iterate on it in `superpowers:brainstorming`'s visual companion, a browser tab the assistant offers mid-brainstorm for showing HTML mockups, before writing any Slides JSON. Comparing 2-3 directions as HTML/CSS is much faster than comparing them as batchUpdate calls. There's no literal trigger phrase for it: it's opt-in, offered by the assistant the first time a design question is genuinely clearer shown than described, not summoned by a magic word. Once a direction is picked, carry its concrete values (hex colors, font names, positions) into the techniques below.

## Three Levels of Template

| Level | Mechanism | Shows in UI "+ New slide"? | Setup |
|---|---|---|---|
| Duplicate-based | Build slide 1 fully, `duplicateObject` per new slide, `replaceAllText` the content | No, only via duplicate | Zero manual steps |
| Master-styled predefined layouts | Style the deck's master once (background, fonts, decoration), use Google's built-in `TITLE`/`TITLE_AND_BODY`/etc. layouts | Yes, all 11 built-ins, natively | Zero manual steps |
| Fully custom native layout | Author a bespoke layout via pptx import, reference with `slideLayoutReference` | Yes, but only that one custom layout | One manual "Import slides" step |

Start with the master-styled option, it's simpler and needs no pptx pipeline at all. Reach for pptx import only when the predefined layout shapes (title+body, two columns, etc.) genuinely can't express what you need.

### Duplicate-based (pure API)

1. Build one slide with every chrome element (background, corner marks, title/subtitle as plain text boxes) via `batchUpdate`.
2. Per new slide: `duplicateObject` with an explicit `objectIds` remap for the page id (`{"<sourceId>": "<newId>"}`), then `replaceAllText` scoped to `pageObjectIds: ["<newId>"]` to swap old text for new.
3. `duplicateObject` inserts each copy immediately after the source, so looping N duplicates yields REVERSE order. Fix with one `updateSlidesPosition` request per slide afterward.

### Master-styled predefined layouts (start here)

Every deck already ships with 11 built-in layouts (`TITLE`, `TITLE_AND_BODY`, `TITLE_AND_TWO_COLUMNS`, `TITLE_ONLY`, `SECTION_HEADER`, `SECTION_TITLE_AND_DESCRIPTION`, `ONE_COLUMN_TEXT`, `MAIN_POINT`, `BIG_NUMBER`, `CAPTION_ONLY`, `BLANK`), all inheriting from one master. Styling the master cascades through every layout to every slide, confirmed empirically: applying background/corner-decoration/font changes to the master updated an already-existing slide that predated the change, with zero per-slide or per-layout work.

1. `presentations.get` with `fields: "masters"` to find the master's `objectId` and its placeholder object ids (it has its own TITLE/BODY/etc. placeholders, same as any layout).
2. `updatePageProperties` on the master for the background (`pageBackgroundFill.stretchedPictureFill.contentUrl`, see the image note under Gotchas), plus any decoration shapes (corner marks, etc.) added directly to the master's page.
3. `updateTextStyle` on the master's placeholder object ids for fonts/colors.
4. `createSlide` with `slideLayoutReference: {"predefinedLayout": "TITLE_AND_TWO_COLUMNS"}` (etc.) from then on, every predefined layout carries the styling, and so does "+ New slide" in the UI since these are the deck's real default layouts, not an import.

Caveat: this restyles the layout/master for the WHOLE deck. Fine when one visual identity should apply everywhere (the common case), not what you want if different slides need genuinely different masters.

### Fully custom native layout (pptx import, only when predefined shapes don't fit)

Converting an uploaded `.pptx` into a native Slides file preserves masters/layouts, because PowerPoint round-tripping has to work that way. This is the way to get a bespoke, "+ New slide"-selectable custom layout (not just a restyled predefined one) without hand-editing Slides' Theme builder.

1. Build the layout with `python-pptx` (see `pptx_layout.py`, run standalone via `uv run pptx_layout.py`, its inline PEP 723 header pins `python-pptx` so there's no ambient-environment dependency to manage): start from the bundled default template, pick a base layout with the placeholder types you need (Title/Body/etc.), reposition/restyle its placeholders, add a background picture and decoration shapes.
2. Upload via the Drive API targeting the Slides mimetype so it auto-converts:
   `gws drive files create --upload deck.pptx --upload-content-type application/vnd.openxmlformats-officedocument.presentationml.presentation --json '{"name": "...", "mimeType": "application/vnd.google-apps.presentation"}'`
3. Fix fonts right after conversion. Custom font names set via python-pptx often silently fall back to a generic font during conversion. Find the layout's placeholder object ids (`presentations.get`, under `layouts[]`) and re-apply the font with a plain `updateTextStyle` call. Confirmed empirically: this sticks, and a brand new slide created from the layout afterward, with no per-slide font override at all, renders in the corrected font.
4. To bring the layout into an ALREADY-EXISTING presentation: no API for this exists. Manually do File → Import slides → the pptx-derived file → select the slide using the new layout → check "Keep original theme" → Import.

**Evaluated `officecli` (iOfficeAI/OfficeCLI) as an alternative, kept python-pptx.** It can build the same layouts (background via the layout's own `background=image:...` property, decoration shapes directly on `/slideMaster[N]`/`/slideLayout[N]`, all confirmed working end to end through a Drive round trip), and its `view screenshot`/`watch` loop gives a cheaper local visual check than the `getThumbnail`-after-conversion approach here. But rebuilding a real multi-slide deck with it surfaced three non-obvious gotchas in one session (pictures refused on layouts, entirely unrelated to the `background` property that replaces them; shape-to-shape connectors auto-attaching center-to-center instead of edge-to-edge; and, most notably, theme-level font settings (`theme.font.major.latin`) silently failing to survive the pptx-to-Slides conversion even though the local XML is correct, only a font set *directly* on a run/placeholder survives). That's more undocumented surface area than python-pptx's one known limitation (below), so python-pptx stays the default here.
5. To bring the layout into an ALREADY-EXISTING presentation: no API for this exists. Manually do File → Import slides → the pptx-derived file → select the slide using the new layout → check "Keep original theme" → Import.

## Design System, Not Ad Hoc Styling

Pick one typographic scale and one spacing scale for the whole deck and use them everywhere, `slides_helpers.py` provides `SIZE_TITLE/H2/H3/H4/BODY/CAPTION/LABEL` and `SPACE_XS/SM/MD/LG/XL` as a starting scale, and `heading()`/`body_text()`/`caption()` wrappers that use them, rather than picking a font size per slide by eye.

For bullet lists, use `bullet_list()` (a real `createParagraphBullets` request) instead of hand-typing "→ " or "- " prefixes into the text, real bullets get proper glyphs, indentation, and nesting; manually-typed prefix characters are just text that happens to look like a list.

For images, `image()` wraps `createImage`, same embed-once-not-linked behavior as a page background (see Gotchas).

## Never Split a Labeled Box Into Two Objects

A box with text inside it (a session/state box, a tag, a code panel) is ONE shape with both fill/outline properties AND text content, use `box()`. Do not build it as a separate `rect()` for the border and a `textbox()` for the label at matching coordinates, even with identical x/y/w/h, the two objects can visibly drift apart, confirmed in practice: a rect+textbox pair rendered with the text box's selection outline offset from its own border, because the two shape types don't share identical default autofit/inset behavior. One object always stays aligned with itself.

When retrofitting this fix into an existing deck, scan every slide, not just the slide a screenshot happened to show. Confirmed necessary in practice: a first pass fixed the one reported slide, but four tag-pill pairs on one slide and two on another kept the old split pattern, unnoticed until a full-deck scan caught them, nothing about the old pattern errors or looks obviously broken in a quick skim. `find_split_pairs()` in `slides_helpers.py` flags any two same-slide shapes with matching rendered bounding boxes; run it against a fresh `presentations.get` after any box()-migration to confirm it actually reached every slide.

## Diagramming Beyond Boxes and Lines

The API has more diagram vocabulary than "rectangle + line," most of it unused above:

- **Arrowheads.** `LineProperties.startArrow`/`endArrow` (`FILL_ARROW`, `STEALTH_ARROW`, `FILL_CIRCLE`, `FILL_DIAMOND`, `OPEN_ARROW`, etc.), set in the same `updateLineProperties` call as color/weight. `line()` and `connector()` both take `start_arrow`/`end_arrow`.
- **Real connectors.** `connector()` attaches a line to two shapes by `connectionSiteIndex` (ECMA-376 sites, roughly 0=top/1=right/2=bottom/3=left on a plain rectangle) instead of hand-placed coordinates. It auto-routes, renders true diagonals correctly (see Gotchas), and moves with the shapes if they're repositioned later, hand-placed `line()` calls do none of that.
- **Line category.** `STRAIGHT` (default), `BENT` (elbow connectors), `CURVED`, not just straight segments.
- **~28 flow-chart preset shapes** available via `createShape`'s `shapeType`: `FLOW_CHART_DECISION`, `FLOW_CHART_PROCESS`, `FLOW_CHART_TERMINATOR`, `FLOW_CHART_DOCUMENT`, etc., plus block arrows, `DIAMOND`, `HEXAGON`, `PARALLELOGRAM`, `CHEVRON`, `CLOUD`, callouts, `STAR_n`. Real flowchart node shapes instead of hand-approximating with rectangles.
- **`group()`** (`groupObjects`) bundles 2+ elements into one unit you can `duplicateObject` and reposition as a whole with `updatePageElementTransform`, good for a "node" component (box + label + mark) built once and stamped out repeatedly. Tables, videos, and placeholders can't be grouped.
- **Tables** (`createTable` + the insert/merge/border row-column family) for matrix/grid-shaped content. Can't be grouped or used as a connector endpoint.
- **The UI's Insert → Diagram feature** (Hierarchy/Timeline/Process/Relationship/Cycle, sometimes called SmartArt-equivalent) has no API creation path, confirmed no such request exists in the `Request` union. Unlike custom layouts, though, what it produces is ordinary shapes/connectors you CAN read and edit via the API afterward, it's just not creatable from scratch that way.

**When native shapes aren't worth it:** for genuinely complex diagrams, most real-world usage (including Google's own `md2googleslides`) authors elsewhere, Graphviz/Mermaid/D2/PlantUML with an auto-layout engine (dagre, elkjs, Graphviz's own layout, D2's TALA) to compute positions, exports SVG/PNG, and inserts the result as a single `image()`. Full visual capability, but the result isn't editable in Slides (text isn't selectable, doesn't match the deck's theme). Reach for this when a diagram has enough nodes/edges that hand-computing positions stops being worth it; use native shapes when the diagram needs to stay editable inside the deck.

## No Morph, No API Path for Animation

Google Slides has no Morph transition, confirmed by grepping the actual API schema (zero hits for transition/animation/morph across all 136 schemas) plus Google's own docs, that feature is PowerPoint-only and does not exist in Slides at all, not even in the UI. Slides does have whole-slide transitions (Fade, Dissolve, Cube, etc.) and per-object build animations (fly in, zoom, spin, "by paragraph"), but both are entirely UI-only: no REST field, and no Apps Script `SlidesApp` class either (unlike the layout-import case, Apps Script is not an escape hatch here). If true Morph-style interpolation is required, the only path is authoring in PowerPoint itself; round-tripping a Morph-using pptx back into Slides is expected to degrade it.

## Collaborating on a Shared Deck

Putting a deck on Google Slides means people (or their own agents) can open it and edit it directly, confirmed in practice: a stray manual edit showed up mid-session on a deck that was link-shared for viewing. Don't just fire off a `batchUpdate` against a shared file assuming it still looks like your last read.

Checking the Drive file's `modifiedTime` isn't enough, a check-then-write race can still land between your check and your write. The Slides API has an actual server-enforced mechanism for this: `writeControl.requiredRevisionId` on `batchUpdate`.

1. Before editing, get the current revision: `presentations.get` with `--params '{"fields": "revisionId"}'` (cheap, skips fetching the whole document).
2. Include it in your batchUpdate body: `{"requests": [...], "writeControl": {"requiredRevisionId": "<that id>"}}`.
3. If someone edited the file since your read, the whole batch is rejected atomically with a 400: `"The required revision ID '...' does not match the latest revision."` Nothing partially applies. Re-fetch, re-check your assumptions still hold, then retry with the new revision, don't just retry blindly with `--force`-style resubmission.
4. Every successful response's `writeControl.requiredRevisionId` is the new revision after your change, carry it forward as the basis for your next edit in the same session instead of re-fetching every time.

Omitting `writeControl` entirely (as in most examples above) skips this check, fine for a throwaway file only you touch, not for a deck other people are actively looking at.

## Gotchas

- **Free-floating diagonal lines don't work.** `createLine` (STRAIGHT category) with hand-set width/height/scale ignores true diagonal slope: both "diagonal" attempts collapse toward one shared point instead of crossing. Two fixes depending on the case: if the diagonal connects two actual shapes, use `connector()` (a real `LineConnection`, confirmed empirically to render a correct diagonal with a working arrowhead and auto-routing, this is the better fix when it applies). If it's pure decoration not attached to anything (an X mark, a strike-through), use `diag()`, a thin rotated `RECTANGLE`: length = `hypot(dx,dy)`, angle = `atan2(dy,dx)`, transform = `{scaleX: cos, shearY: sin, shearX: -sin, scaleY: cos, translateX: x1, translateY: y1}`.
- **`connector()` site indices aren't clockwise-from-top.** For a plain `RECTANGLE`, 0=top, 1=LEFT, 2=bottom, 3=RIGHT, confirmed with a 4-color test rig, not the 0=top/1=right/2=bottom/3=left order the ECMA-376 naming suggests. Getting it backwards doesn't error, the connector silently draws from the wrong side of the shape, straight through its interior. For A leading to B (B to the right of A): `from_site=3, to_site=1`.
- **Two different color shapes.** `SolidFill.color` (used in `outlineFill`, `shapeBackgroundFill`, `lineFill`) wants a bare `OpaqueColor` (`{"rgbColor": {...}}`). `TextStyle.foregroundColor` wants an `OptionalColor` (`{"opaqueColor": {"rgbColor": {...}}}`). Mixing them up fails schema validation with "Unknown property: opaqueColor".
- **Object ids must be 5-50 chars.** Short ids like `"s2"` are rejected: "The object ID length should not be less than 5."
- **`duplicateObject` refuses layouts.** Literal error: `"Duplicating a layout (p2) is not allowed."` Layouts/masters are API read-only, full stop, confirmed live against the API, not just the docs.
- **python-pptx's `LayoutShapes` has essentially no `add_*` methods at all.** Not just `add_picture`/`add_connector`, confirmed empirically: its only public method is `clone_placeholder`, `add_shape` and `add_textbox` aren't there either. Build every new element (picture, autoshape, textbox) on a scratch slide first, where the full `SlideShapes` API works, then move its XML element into the layout's shape tree and delete the scratch slide. If it's a picture, also re-register the image relationship on the target part (`target_part.relate_to(image_part, RT.IMAGE)`, then rewrite the blip's `r:embed`), otherwise it renders as a broken-image glyph instead of the picture. `pptx_layout.py`'s `add_layout_picture`/`add_layout_shape` do this uniformly.
- **Verify visually, not just via the API response.** `presentations.pages.getThumbnail` returns a `contentUrl` you can download and actually look at. A 200 response doesn't mean it rendered as intended, broken image relationships, wrong diagonal lines, and font fallbacks all returned success while rendering wrong.
- **Chained `replaceAllText` calls can corrupt each other if one pattern is a substring of another.** Replacing `"cast/2"` before `"handle_cast/2"` in the same batch turns `"handle_cast/2"` into `"handle_send"` first, so the second replacement then matches zero occurrences of a string that no longer exists, and silently does nothing. `occurrencesChanged` in the response won't catch this, it's honestly reporting 0 for a pattern that's genuinely gone. Order `replace_text()` calls longest-pattern-first, and read the actual text back after any multi-replacement batch rather than trusting the response alone.
- **`size` alone is not the rendered dimensions.** `pageElements[].size.width/height` is the shape's unscaled base size, actual rendered width/height is `size * transform.scaleX/scaleY`. `shape()` always bakes the target size directly into `size` with `scaleX/scaleY: 1`, but plenty of Slides-authored or pptx-converted content uses the base-size-plus-scale form instead, reading `size.width.magnitude` alone when writing diagnostic code over `presentations.get` output silently gives the wrong number. `find_split_pairs()` applies the correction.

## Reference

- `slides_helpers.py`: JSON request builders for the Slides API. Primitives: `rect`/`textbox`/`box`/`line`/`diag`/`connector`/`group`/`image`. Design-system wrappers built on them: `heading`/`body_text`/`caption`/`bullet_list`, plus the `SIZE_*`/`SPACE_*` tokens. Also `replace_text`/`duplicate`/`reorder`, and one diagnostic (reads a fetched presentation instead of building requests): `find_split_pairs`.
- `pptx_layout.py`: python-pptx layout builder, run via `uv run pptx_layout.py` (PEP 723 header pins `python-pptx`, no separate install step). `add_layout_picture`/`add_layout_shape` do the scratch-slide-then-reparent workaround `LayoutShapes` needs for every element type; `set_placeholder_position` repositions an existing one.
