"""
JSON request builders for the Google Slides API (v1 batchUpdate).
Coordinates are in px at 96dpi; px() converts to the EMU the API expects.
Feed the returned lists into {"requests": [...]} and POST via batchUpdate,
e.g. `gws slides presentations batchUpdate --params '{"presentationId": "..."}' --json "$(cat requests.json)"`.

Design tokens (SIZE_*/SPACE_*) are a starting scale, not a mandate, adjust to
the deck's own type/spacing rhythm, but pick ONE scale per deck and use it
everywhere rather than picking sizes ad hoc per slide.
"""
import math

EMU_PER_PX = 9525

# Typographic scale (points). Use these for every text element instead of
# picking a size per slide, that's what "consistent" means in practice.
SIZE_TITLE = 22.5    # slide title / H1
SIZE_H2 = 16         # section heading within a slide
SIZE_H3 = 13         # sub-heading (panel headers, grouped-content labels)
SIZE_H4 = 11         # small heading / standalone label
SIZE_BODY = 11       # body copy
SIZE_CAPTION = 9     # captions, footnotes, fine print
SIZE_LABEL = 8       # tags, tiny inline badges

# Spacing scale (px @ 96dpi), base unit 8. Use these for margins, gaps between
# elements, and padding instead of arbitrary numbers.
SPACE_XS = 8
SPACE_SM = 16
SPACE_MD = 24
SPACE_LG = 32
SPACE_XL = 40


def px(v):
    return round(v * EMU_PER_PX)


def rgb(hexstr):
    hexstr = hexstr.lstrip("#")
    return {
        "red": int(hexstr[0:2], 16) / 255,
        "green": int(hexstr[2:4], 16) / 255,
        "blue": int(hexstr[4:6], 16) / 255,
    }


def color(hexstr):
    """OptionalColor, for fields like TextStyle.foregroundColor."""
    return {"opaqueColor": {"rgbColor": rgb(hexstr)}}


def solid(hexstr):
    """Bare OpaqueColor, for SolidFill.color (outlineFill/shapeBackgroundFill/lineFill)."""
    return {"rgbColor": rgb(hexstr)}


def shape(id_, page, x, y, w, h, text=None, stroke=None, fill=None, weight=1.25, dash="SOLID",
          font="Arial", size=SIZE_BODY, col="16181d", bold=False, align=None, valign=None):
    """The one primitive for a rectangle that may have a border/fill, text, or both, as a
    SINGLE object. Prefer the semantic wrappers below (rect/box/textbox) at call sites;
    this exists so they all share one object-creation path."""
    reqs = [{"createShape": {"objectId": id_, "shapeType": "RECTANGLE", "elementProperties": {
        "pageObjectId": page,
        "size": {"width": {"magnitude": px(w), "unit": "EMU"}, "height": {"magnitude": px(h), "unit": "EMU"}},
        "transform": {"scaleX": 1, "scaleY": 1, "translateX": px(x), "translateY": px(y), "unit": "EMU"},
    }}}]
    if text:
        reqs.append({"insertText": {"objectId": id_, "text": text}})
        reqs.append({"updateTextStyle": {"objectId": id_, "style": {
            "fontSize": {"magnitude": size, "unit": "PT"}, "foregroundColor": color(col), "bold": bold, "fontFamily": font,
        }, "fields": "fontSize,foregroundColor,bold,fontFamily"}})
        if align:
            reqs.append({"updateParagraphStyle": {"objectId": id_, "style": {"alignment": align}, "fields": "alignment"}})
    shape_props = {
        "shapeBackgroundFill": {"solidFill": {"color": solid(fill)}} if fill else {"propertyState": "NOT_RENDERED"},
        "outline": ({
            "outlineFill": {"solidFill": {"color": solid(stroke)}},
            "weight": {"magnitude": weight, "unit": "PT"},
            "dashStyle": dash,
        } if stroke else {"propertyState": "NOT_RENDERED"}),
        "autofit": {"autofitType": "NONE"},
    }
    fields = "shapeBackgroundFill,outline,autofit.autofitType"
    if valign:
        shape_props["contentAlignment"] = valign  # "TOP" (default) or "MIDDLE"
        fields += ",contentAlignment"
    reqs.append({"updateShapeProperties": {"objectId": id_, "shapeProperties": shape_props, "fields": fields}})
    return reqs


def rect(id_, page, x, y, w, h, stroke=None, weight=1.25, fill=None, dash="SOLID"):
    """A box with no text. For a box WITH text inside it, use box(), not rect()+textbox()."""
    return shape(id_, page, x, y, w, h, stroke=stroke, weight=weight, fill=fill, dash=dash)


def textbox(id_, page, x, y, w, h, text, size, col, font="Arial", bold=False, align=None, valign=None):
    """Text with no border/fill (captions, free-floating labels). For text INSIDE a
    bordered/filled box, use box() instead of pairing this with rect()."""
    return shape(id_, page, x, y, w, h, text=text, font=font, size=size, col=col, bold=bold, align=align, valign=valign)


def box(id_, page, x, y, w, h, text, stroke=None, fill=None, weight=1.25,
        font="Arial", size=SIZE_BODY, col="16181d", bold=False, align="CENTER", valign="MIDDLE"):
    """A bordered/filled box with its label INSIDE the same object, this is the correct
    primitive for anything that reads as "a labeled box" (a session/state box, a tag, a
    code panel). Do not build this as a separate rect() + textbox() pair at matching
    coordinates: two independent objects drift, different default autofit/insets between
    shape instances mean the text can visibly misalign with its own border even when x/y/w/h
    are identical on paper. One object, always."""
    return shape(id_, page, x, y, w, h, text=text, stroke=stroke, fill=fill, weight=weight,
                 font=font, size=size, col=col, bold=bold, align=align, valign=valign)


def heading(id_, page, x, y, w, h, text, level=1, col="16181d", font="IBM Plex Mono", align=None):
    """level 1 = slide title (SIZE_TITLE, bold), 2 = SIZE_H2 bold, 3 = SIZE_H3 bold,
    4 = SIZE_H4 bold. Use this instead of picking a one-off font size per slide."""
    sizes = {1: SIZE_TITLE, 2: SIZE_H2, 3: SIZE_H3, 4: SIZE_H4}
    return textbox(id_, page, x, y, w, h, text, sizes[level], col, font=font, bold=True, align=align)


def body_text(id_, page, x, y, w, h, text, col="545d6b", font="Arial", align=None):
    return textbox(id_, page, x, y, w, h, text, SIZE_BODY, col, font=font, align=align)


def caption(id_, page, x, y, w, h, text, col="545d6b", font="Arial", align=None):
    return textbox(id_, page, x, y, w, h, text, SIZE_CAPTION, col, font=font, align=align)


def bullet_list(id_, page, x, y, w, h, items, size=SIZE_BODY, col="16181d", font="Arial",
                 bullet_preset="BULLET_ARROW_DIAMOND_DISC"):
    """A REAL bulleted list (createParagraphBullets), not manually-typed prefix characters.
    items is a list of strings, one per bullet; use a leading tab character in an item to
    nest it one level deeper, per the API's own convention."""
    reqs = textbox(id_, page, x, y, w, h, "\n".join(items), size, col, font=font)
    reqs.append({"createParagraphBullets": {"objectId": id_, "textRange": {"type": "ALL"}, "bulletPreset": bullet_preset}})
    return reqs


def image(id_, page, url, x, y, w, h):
    """url is fetched once at insertion time and embedded, same as a page background
    fill (see SKILL.md), no ongoing dependency on the URL afterward. Must be public,
    PNG/JPEG/GIF, under 50MB/25MP."""
    return [{"createImage": {"objectId": id_, "url": url, "elementProperties": {
        "pageObjectId": page,
        "size": {"width": {"magnitude": px(w), "unit": "EMU"}, "height": {"magnitude": px(h), "unit": "EMU"}},
        "transform": {"scaleX": 1, "scaleY": 1, "translateX": px(x), "translateY": px(y), "unit": "EMU"},
    }}}]


def line(id_, page, x1, y1, x2, y2, col, weight=1.25, dash="SOLID", alpha=1.0, start_arrow=None, end_arrow=None):
    """Horizontal/vertical only, a free-floating line not attached to any shape. For a true
    diagonal use diag() (decoration) or connector() (shape-to-shape) instead, see SKILL.md.
    Arrow values: NONE, STEALTH_ARROW, FILL_ARROW, FILL_CIRCLE, FILL_SQUARE, FILL_DIAMOND,
    OPEN_ARROW, OPEN_CIRCLE, OPEN_SQUARE, OPEN_DIAMOND."""
    w, h = abs(x2 - x1), abs(y2 - y1)
    sx, sy = (1 if x2 >= x1 else -1), (1 if y2 >= y1 else -1)
    tx, ty = min(x1, x2), min(y1, y2)
    props = {
        "lineFill": {"solidFill": {"color": solid(col), "alpha": alpha}},
        "weight": {"magnitude": weight, "unit": "PT"},
        "dashStyle": dash,
    }
    fields = "lineFill,weight,dashStyle"
    if start_arrow:
        props["startArrow"] = start_arrow
        fields += ",startArrow"
    if end_arrow:
        props["endArrow"] = end_arrow
        fields += ",endArrow"
    return [
        {"createLine": {"objectId": id_, "lineCategory": "STRAIGHT", "elementProperties": {
            "pageObjectId": page,
            "size": {"width": {"magnitude": max(px(w), 1), "unit": "EMU"}, "height": {"magnitude": max(px(h), 1), "unit": "EMU"}},
            "transform": {"scaleX": sx, "scaleY": sy, "translateX": px(tx), "translateY": px(ty), "unit": "EMU"},
        }}},
        {"updateLineProperties": {"objectId": id_, "lineProperties": props, "fields": fields}},
    ]


def connector(id_, page, from_id, from_site, to_id, to_site, col, weight=1.25, dash="SOLID",
              category="STRAIGHT", end_arrow="NONE", start_arrow="NONE"):
    """A line ATTACHED to two shapes (LineConnection), not positioned by hand. Unlike line()/
    diag(), this reliably renders true diagonals (confirmed empirically, createLine's own
    width/height/scale approach does not, see the Gotchas section), auto-routes, and moves
    with the shapes if they're repositioned later. Prefer this over diag() whenever the
    diagonal is genuinely "connecting" two shapes rather than pure decoration (an X mark,
    a strike-through). For a plain RECTANGLE, connectionSiteIndex 0=top, 1=LEFT, 2=bottom,
    3=RIGHT (confirmed empirically with a 4-color test rig, this is NOT the clockwise-from-
    top order you'd guess from ECMA-376 docs, 1 and 3 are swapped from that assumption).
    Getting this backwards doesn't error, it silently draws the connector from the wrong
    side of the shape, straight through its interior, to reach the target. For a normal
    left-to-right connection (A leads to B, B to the right of A), use from_site=3 (A's
    right side) and to_site=1 (B's left side). category: STRAIGHT | BENT | CURVED."""
    return [
        {"createLine": {"objectId": id_, "category": category, "elementProperties": {
            "pageObjectId": page,
            "size": {"width": {"magnitude": px(1), "unit": "EMU"}, "height": {"magnitude": px(1), "unit": "EMU"}},
            "transform": {"scaleX": 1, "scaleY": 1, "translateX": 0, "translateY": 0, "unit": "EMU"},
        }}},
        {"updateLineProperties": {"objectId": id_, "lineProperties": {
            "startConnection": {"connectedObjectId": from_id, "connectionSiteIndex": from_site},
            "endConnection": {"connectedObjectId": to_id, "connectionSiteIndex": to_site},
            "lineFill": {"solidFill": {"color": solid(col)}},
            "weight": {"magnitude": weight, "unit": "PT"},
            "dashStyle": dash,
            "startArrow": start_arrow,
            "endArrow": end_arrow,
        }, "fields": "startConnection,endConnection,lineFill,weight,dashStyle,startArrow,endArrow"}},
    ]


def diag(id_, page, x1, y1, x2, y2, col, thickness=2.0):
    """A true diagonal, as a thin rotated rectangle (createLine can't do this, see SKILL.md)."""
    length = math.hypot(x2 - x1, y2 - y1)
    angle = math.atan2(y2 - y1, x2 - x1)
    cos_a, sin_a = math.cos(angle), math.sin(angle)
    return [
        {"createShape": {"objectId": id_, "shapeType": "RECTANGLE", "elementProperties": {
            "pageObjectId": page,
            "size": {"width": {"magnitude": px(length), "unit": "EMU"}, "height": {"magnitude": px(thickness), "unit": "EMU"}},
            "transform": {"scaleX": cos_a, "shearY": sin_a, "shearX": -sin_a, "scaleY": cos_a, "translateX": px(x1), "translateY": px(y1), "unit": "EMU"},
        }}},
        {"updateShapeProperties": {"objectId": id_, "shapeProperties": {
            "shapeBackgroundFill": {"solidFill": {"color": solid(col)}},
            "outline": {"propertyState": "NOT_RENDERED"},
        }, "fields": "shapeBackgroundFill,outline"}},
    ]


def replace_text(page, old, new):
    """Calling this more than once in the same batch: order matters if one `old` is a
    substring of another (e.g. "cast/2" inside "handle_cast/2"). Replacing the shorter
    pattern first mangles the longer one before its own call can match, and that second
    call then silently replaces zero occurrences, see SKILL.md Gotchas. Order calls
    longest-pattern-first, and verify the actual text afterward."""
    return [{"replaceAllText": {"containsText": {"text": old, "matchCase": True}, "replaceText": new, "pageObjectIds": [page]}}]


def duplicate(src_page, new_page_id):
    """new_page_id must be 5-50 chars. Duplicates insert right after the source, so
    looping this for N pages yields REVERSE order, fix with updateSlidesPosition after."""
    return [{"duplicateObject": {"objectId": src_page, "objectIds": {src_page: new_page_id}}}]


def reorder(page_ids_in_order):
    """One updateSlidesPosition per page, in the order you want them, starting at index 1
    (index 0 is presumed to be an already-correctly-placed first slide)."""
    return [{"updateSlidesPosition": {"slideObjectIds": [pid], "insertionIndex": i}} for i, pid in enumerate(page_ids_in_order, start=1)]


def group(group_id, child_ids):
    """Group 2+ existing page elements (all on the same page) into one unit you can then
    duplicate/reposition as a whole with updatePageElementTransform, useful for a reusable
    "node" component (a box + its label + a small mark) you build once and stamp out
    repeatedly. Tables, videos, and placeholders can't be grouped."""
    return [{"groupObjects": {"groupObjectId": group_id, "childrenObjectIds": child_ids}}]


def find_split_pairs(presentation, tol=3):
    """Diagnostic, not a request builder: takes the dict from `presentations.get` (not a
    request list) and flags leftover rect()+textbox() pairs, the anti-pattern box()
    replaces (see SKILL.md, "Never Split a Labeled Box"). Two shapes on the same slide
    with near-identical RENDERED bounding boxes are almost always an old split pair that
    never got migrated, plain coordinate comparison misses this if you forget that
    size.width/height must be scaled by transform.scaleX/scaleY first (see Gotchas).

    Returns a list of (slideId, id1, id2, x_px, y_px, w_px, h_px) tuples, one per
    suspected pair; empty means clean. Run after any box()-migration fix against a fresh
    presentations.get to confirm it reached every slide, not just the one that prompted
    the fix, confirmed necessary in practice: a fix for one reported slide left six more
    split pairs untouched elsewhere in the same deck until a full scan caught them."""
    hits = []
    for slide in presentation.get("slides", []):
        boxes = []
        for el in slide.get("pageElements", []):
            sh = el.get("shape")
            if not sh:
                continue
            t = el.get("transform", {})
            sx, sy = t.get("scaleX", 1), t.get("scaleY", 1)
            w = el.get("size", {}).get("width", {}).get("magnitude", 0) * sx / EMU_PER_PX
            h = el.get("size", {}).get("height", {}).get("magnitude", 0) * sy / EMU_PER_PX
            x, y = t.get("translateX", 0) / EMU_PER_PX, t.get("translateY", 0) / EMU_PER_PX
            boxes.append((el["objectId"], x, y, w, h))
        for i in range(len(boxes)):
            for j in range(i + 1, len(boxes)):
                id1, x1, y1, w1, h1 = boxes[i]
                id2, x2, y2, w2, h2 = boxes[j]
                if abs(x1 - x2) < tol and abs(y1 - y2) < tol and abs(w1 - w2) < tol and abs(h1 - h2) < tol:
                    hits.append((slide["objectId"], id1, id2, round(x1), round(y1), round(w1), round(h1)))
    return hits


# --- editing EXISTING content in place (content-surgical, preserves the element's transform) ---

def settext(id_, text, size, col, font="Arial", bold=False, align="START"):
    """Replace ALL text in an existing text box IN PLACE and re-style it, keeping the box's
    position/size. Use this to change copy on a live deck instead of deleteObject + recreate,
    which resets the transform and wipes any spacing a collaborator hand-tuned. `align`
    defaults to START on purpose: a fresh box's paragraph alignment is inherited and, depending
    on the master, often renders CENTER (see SKILL.md Gotchas); pass align=None to leave it
    untouched. WARNING: the deleteText here fails on an EMPTY box ("startIndex 0 must be less
    than endIndex 0"); for a maybe-empty target use insert_text() or fetch its length first."""
    reqs = [
        {"deleteText": {"objectId": id_, "textRange": {"type": "ALL"}}},
        {"insertText": {"objectId": id_, "text": text}},
        {"updateTextStyle": {"objectId": id_, "style": {
            "fontSize": {"magnitude": size, "unit": "PT"}, "foregroundColor": color(col),
            "bold": bold, "fontFamily": font}, "fields": "fontSize,foregroundColor,bold,fontFamily"}},
    ]
    if align is not None:
        reqs.append({"updateParagraphStyle": {"objectId": id_, "style": {"alignment": align}, "fields": "alignment"}})
    return reqs


def insert_text(id_, text):
    """insertText ONLY, for a box or notes placeholder that is currently EMPTY (deleteText
    errors on an empty range). Follow with updateTextStyle if the run needs styling."""
    return [{"insertText": {"objectId": id_, "text": text}}]


def hyperlink(id_, url, text_range=None):
    """Make an existing run clickable (updateTextStyle link). Renders underlined; works in the
    editable/Drive deck, not in a flattened screenshare. Defaults to the whole element; pass a
    textRange dict to link a sub-span. Good for turning a citation footnote into a source link."""
    return [{"updateTextStyle": {"objectId": id_, "style": {"link": {"url": url}},
             "textRange": text_range or {"type": "ALL"}, "fields": "link"}}]


# --- page backgrounds ---

def picture_bg(page, url):
    """Set a slide/master background to a stretched picture (embedded once at set time, like
    image()). Each slide can override the master's background, so to change a whole deck's
    texture you often must set this on EVERY slide, not just the master."""
    return [{"updatePageProperties": {"objectId": page, "pageProperties": {
        "pageBackgroundFill": {"stretchedPictureFill": {"contentUrl": url}}},
        "fields": "pageBackgroundFill"}}]


def solid_bg(page, hexstr):
    return [{"updatePageProperties": {"objectId": page, "pageProperties": {
        "pageBackgroundFill": {"solidFill": {"color": solid(hexstr)}}}, "fields": "pageBackgroundFill"}}]


# --- batch plumbing ---

def guarded(requests, revision_id):
    """Wrap a request list into a batchUpdate body with optimistic-concurrency control. If the
    deck changed since revision_id the whole batch is rejected 400 (see SKILL.md 'Collaborating
    on a Shared Deck'); re-fetch and retry rather than blind-resubmit."""
    return {"requests": requests, "writeControl": {"requiredRevisionId": revision_id}}


def assert_no_emdash(requests):
    """Fail fast if any insertText/replaceAllText copy carries an em/en dash (a reliable
    AI-writing tell). Call right before submitting a batch that writes human-facing text."""
    hits = []
    for r in requests:
        t = r.get("insertText", {}).get("text", "")
        rt = r.get("replaceAllText", {}).get("replaceText", "")
        for s in (t, rt):
            if "—" in s or "–" in s:
                hits.append(s[:60])
    assert not hits, f"em/en dash in batch text: {hits}"
    return requests
