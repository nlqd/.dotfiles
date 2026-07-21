# /// script
# requires-python = ">=3.11"
# dependencies = ["pillow>=10"]
# ///
"""
deck_ops.py - the imperative shell over slides_helpers.py's pure request builders.

slides_helpers.py answers "what JSON describes this element." deck_ops.py answers
the questions that need the live deck: what does it look like now, what changed since
I last looked, and is it safe to write. It shells out to `gws` (no new auth), keeps a
per-page snapshot on disk, and refuses to overwrite a page a collaborator has touched.

Two API facts shape everything here, both verified against Google's docs:
  - revisionId is document-wide; there is no per-page etag. Per-page change detection
    has to be built by hand by hashing each page's content. That is snapshot()/diff().
  - batchUpdate has no server dry-run for semantics (`gws --dry-run` checks JSON schema
    only). objectId rules, deleteText-on-empty, a missing target: all still 400 unless
    caught locally first. That is preflight().

The safety model: apply() guards with the LIVE revision (so writes to pages a
collaborator didn't touch still go through). The real protection is therefore the
per-page diff of the pages this batch writes, NOT the doc-wide revisionId, which only
covers the millisecond between the pre-write fetch and the write. So touched_pages()
must resolve every request to the page it writes, or a page escapes the guard.

CLI (run via `python3 deck_ops.py <cmd>`; `uv run` also works but cold-installs pillow):
  snapshot <pid>              record every page's state to .deckstate/
  diff <pid>                  per page, what changed since the last snapshot
  render <pid> [--changed]    stitch one contact-sheet PNG to look at
  preflight <requests.json>   run the local semantic checks
  apply <pid> <requests.json> guarded write: verify targets unchanged, preflight, submit, re-snapshot
"""
import hashlib
import json
import math
import os
import re
import subprocess
import sys
import urllib.request
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from slides_helpers import EMU_PER_PX, color, px  # type: ignore  # noqa: E402

STATE_DIR = ".deckstate"
GWS = ["gws", "slides", "presentations"]


# --- gws shell -------------------------------------------------------------

def _run(args, json_body=None):
    """The one place that shells out to gws. stdout is JSON; the 'Using keyring backend'
    banner goes to stderr and is dropped."""
    cmd = list(args)
    if json_body is not None:
        cmd += ["--json", json.dumps(json_body)]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(f"gws failed: {' '.join(cmd[:5])}...\n{proc.stderr}")
    return json.loads(proc.stdout)


def _params(d):
    return ["--params", json.dumps(d)]


def get_presentation(pid):
    # Full slide contents (no fields mask): auto-covers tables and grouped children,
    # and drops a long brittle mask string. One read, well under the 600/min quota.
    return _run(GWS + ["get"] + _params({"presentationId": pid, "fields": "slides,revisionId"}))


def batch_update(pid, requests, revision_id=None):
    body = {"requests": requests}
    if revision_id is not None:
        body["writeControl"] = {"requiredRevisionId": revision_id}
    return _run(GWS + ["batchUpdate"] + _params({"presentationId": pid}), json_body=body)


def dry_run_ok(pid, requests):
    """Ask gws to validate the request JSON schema locally (field names, nesting,
    types). Returns (ok, message). The free half of preflight."""
    cmd = GWS + ["batchUpdate"] + _params({"presentationId": pid}) + [
        "--json", json.dumps({"requests": requests}), "--dry-run"]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0 or not proc.stdout.strip():
        return False, proc.stderr.strip() or "gws dry-run failed"
    if '"error"' in proc.stdout:
        try:
            return False, json.loads(proc.stdout)["error"]["message"]
        except Exception:
            return False, proc.stdout
    return True, "schema ok"


def thumbnail(pid, page_id, size="MEDIUM"):
    """(contentUrl, width, height). Nested query params must be dotted: the API rejects
    a nested thumbnailProperties object on a GET."""
    r = _run(GWS + ["pages", "getThumbnail"] + _params({
        "presentationId": pid, "pageObjectId": page_id,
        "thumbnailProperties.thumbnailSize": size,
        "thumbnailProperties.mimeType": "PNG"}))
    return r["contentUrl"], r["width"], r["height"]


# --- Box: relative placement so coordinates stop being hand-guessed ---------
# Public authoring API (like slides_helpers' builders): compute positions with these,
# then feed .as_xywh() into textbox()/box(). Everything is px @ 96dpi, matching
# slides_helpers. Methods return a NEW Box, so they chain.

class Box:

    __slots__ = ("x", "y", "w", "h")

    def __init__(self, x, y, w, h):
        self.x, self.y, self.w, self.h = float(x), float(y), float(w), float(h)

    @property
    def right(self):
        return self.x + self.w

    @property
    def bottom(self):
        return self.y + self.h

    @property
    def cx(self):
        return self.x + self.w / 2

    @property
    def cy(self):
        return self.y + self.h / 2

    def below(self, other, gap=24, h=None):
        return Box(other.x, other.bottom + gap, other.w, self.h if h is None else h)

    def right_of(self, other, gap=24, w=None):
        return Box(other.right + gap, other.y, self.w if w is None else w, other.h)

    def align_left(self, other):
        return Box(other.x, self.y, self.w, self.h)

    def inset(self, dx, dy=None):
        dy = dx if dy is None else dy
        return Box(self.x + dx, self.y + dy, self.w - 2 * dx, self.h - 2 * dy)

    def move_to(self, x=None, y=None):
        return Box(self.x if x is None else x, self.y if y is None else y, self.w, self.h)

    def with_size(self, w=None, h=None):
        return Box(self.x, self.y, self.w if w is None else w, self.h if h is None else h)

    def as_xywh(self):
        return (round(self.x), round(self.y), round(self.w), round(self.h))

    def __repr__(self):
        return f"Box(x={self.x:.0f}, y={self.y:.0f}, w={self.w:.0f}, h={self.h:.0f})"


def elem_box(el):
    """Rendered Box (px) of a fetched pageElement. size alone is not the on-screen size:
    it must be scaled by the transform. Use it to place a new element relative to one
    already on the slide."""
    t = el.get("transform", {})
    sz = el.get("size", {})
    w = sz.get("width", {}).get("magnitude", 0) * t.get("scaleX", 1)
    h = sz.get("height", {}).get("magnitude", 0) * t.get("scaleY", 1)
    return Box(t.get("translateX", 0) / EMU_PER_PX, t.get("translateY", 0) / EMU_PER_PX,
               w / EMU_PER_PX, h / EMU_PER_PX)


def find_overlaps(named_boxes, min_frac=0.15):
    """named_boxes: list of (id, Box). Returns (id1, id2, pct) for pairs whose overlap
    covers more than min_frac of the smaller box, the margin-note-into-the-title class
    of bug, caught before the write instead of after a squint at the render."""
    hits, items = [], list(named_boxes)
    for i in range(len(items)):
        for j in range(i + 1, len(items)):
            (id1, a), (id2, b) = items[i], items[j]
            ox = max(0, min(a.right, b.right) - max(a.x, b.x))
            oy = max(0, min(a.bottom, b.bottom) - max(a.y, b.y))
            area = ox * oy
            smaller = min(a.w * a.h, b.w * b.h) or 1
            if area / smaller >= min_frac:
                hits.append((id1, id2, round(100 * area / smaller)))
    return hits


# --- snapshot: per-page change detection (the collab-safety core) ----------

def _shape_text(el):
    if "shape" in el:
        runs = (el["shape"].get("text") or {}).get("textElements", [])
        return "".join(r.get("textRun", {}).get("content", "") for r in runs)
    if "table" in el:
        return "".join(r.get("textRun", {}).get("content", "")
                       for row in el["table"].get("tableRows", [])
                       for cell in row.get("tableCells", [])
                       for r in (cell.get("text") or {}).get("textElements", []))
    return ""


def _flatten(elements):
    """Yield every element, recursing into groups so a grouped child's text/geometry is
    tracked and is addressable by move()/set_text_safe()."""
    for el in elements:
        if "objectId" in el:
            yield el
        kids = el.get("elementGroup", {}).get("children")
        if kids:
            yield from _flatten(kids)


def _canon(el):
    """Hashable view of one element: identity, text, rounded geometry. Deliberately
    content-scoped: a color/font-only change is not tracked (a human 'spacing tweak'
    moves or edits things). raw_tf is kept unrounded for move()'s delta math."""
    t, sz = el.get("transform", {}), el.get("size", {})
    return {
        "id": el["objectId"],
        "type": el.get("shape", {}).get("shapeType") or ("TABLE" if "table" in el else "OTHER"),
        "text": _shape_text(el),
        "tf": [round(t.get(k, d), 4) for k, d in (("scaleX", 1), ("scaleY", 1), ("translateX", 0), ("translateY", 0))],
        "sz": [round(sz.get("width", {}).get("magnitude", 0)), round(sz.get("height", {}).get("magnitude", 0))],
        "raw_tf": t,
    }


def _page_hash(canon_elements):
    # Sorted so a pure z-order reorder (same content, different list order) does not
    # produce a phantom change that diff() then reports as +0 -0 ~0.
    rows = sorted([c["id"], c["type"], c["text"], c["tf"], c["sz"]] for c in canon_elements)
    return hashlib.sha256(json.dumps(rows, sort_keys=True).encode()).hexdigest()[:16]


def build_snapshot(pid):
    pres = get_presentation(pid)
    pages, index = {}, {}
    for slide in pres.get("slides", []):
        sid = slide["objectId"]
        cs = [_canon(el) for el in _flatten(slide.get("pageElements", []))]
        pages[sid] = {"hash": _page_hash(cs), "elements": {c["id"]: c for c in cs}}
        index.update({c["id"]: sid for c in cs})
    return {"presentationId": pid, "revisionId": pres.get("revisionId"),
            "pageOrder": [s["objectId"] for s in pres.get("slides", [])],
            "pages": pages, "index": index}


def _state_path(pid):
    return os.path.join(STATE_DIR, f"{pid}.json")


def save_snapshot(snap):
    os.makedirs(STATE_DIR, exist_ok=True)
    with open(_state_path(snap["presentationId"]), "w") as f:
        json.dump(snap, f, indent=2)


def load_snapshot(pid):
    p = _state_path(pid)
    return json.load(open(p)) if os.path.exists(p) else None


def _element(snap, oid):
    """Canonical element for an objectId anywhere in the snapshot, or None."""
    pid = snap["index"].get(oid) if snap else None
    return snap["pages"][pid]["elements"].get(oid) if pid else None


def diff(pid, live=None, base=None):
    """Compare live state to the recorded snapshot. Returns {pageId: {added, removed,
    changed}} for pages that moved; empty means nothing changed since the snapshot."""
    base = base or load_snapshot(pid)
    if base is None:
        raise RuntimeError("no snapshot on disk; run `snapshot` first")
    live = live or build_snapshot(pid)
    out = {}
    for sid in set(base["pages"]) | set(live["pages"]):
        b = base["pages"].get(sid, {"hash": None, "elements": {}})
        l = live["pages"].get(sid, {"hash": None, "elements": {}})
        if b["hash"] == l["hash"]:
            continue
        be, le = b["elements"], l["elements"]
        changed = []
        for k in le:
            if k not in be:
                continue
            o, n = be[k], le[k]
            what = []
            if o["text"] != n["text"]:
                what.append(f"text {o['text'][:30]!r}->{n['text'][:30]!r}")
            if o["tf"] != n["tf"] or o["sz"] != n["sz"]:
                what.append("moved/resized")
            if what:
                changed.append((k, "; ".join(what)))
        out[sid] = {"added": [k for k in le if k not in be],
                    "removed": [k for k in be if k not in le], "changed": changed}
    return out


def touched_pages(requests, snap):
    """Every page a batch writes. Creates carry the page in elementProperties; page-level
    verbs (deleteObject/updatePageProperties on a slide, reorder, group, global replace)
    carry a page id or child ids; edits carry an element objectId resolved via the index.
    A target that resolves to no page just isn't guarded here, preflight() errors on it."""
    pages = set()
    for r in requests:
        for verb, body in r.items():
            if not isinstance(body, dict):
                continue
            ep = body.get("elementProperties") or {}
            if "pageObjectId" in ep:
                pages.add(ep["pageObjectId"])
            elif "pageObjectIds" in body:
                pages.update(body["pageObjectIds"])
            elif "slideObjectIds" in body:
                pages.update(body["slideObjectIds"])
            elif "childrenObjectIds" in body:
                pages.update(p for c in body["childrenObjectIds"] if (p := snap["index"].get(c)))
            elif verb == "replaceAllText":
                pages.update(snap["pages"])
            elif body.get("objectId"):
                oid = body["objectId"]
                if p := (snap["index"].get(oid) or (oid if oid in snap["pages"] else None)):
                    pages.add(p)
    return pages


# --- robust in-place text edit (snapshot removes the empty-box branch) ------

def set_text_safe(oid, text, size, col, snap, font="Arial", bold=False, align="START"):
    """settext without the empty-box footgun. The snapshot already knows whether the box
    has text, so this picks delete+insert vs insert-only (deleteText on an empty range
    400s)."""
    el = _element(snap, oid)
    reqs = []
    if el and el["text"].strip():
        reqs.append({"deleteText": {"objectId": oid, "textRange": {"type": "ALL"}}})
    reqs.append({"insertText": {"objectId": oid, "text": text}})
    reqs.append({"updateTextStyle": {"objectId": oid, "style": {
        "fontSize": {"magnitude": size, "unit": "PT"}, "foregroundColor": color(col),
        "bold": bold, "fontFamily": font}, "fields": "fontSize,foregroundColor,bold,fontFamily"}})
    if align is not None:
        reqs.append({"updateParagraphStyle": {"objectId": oid, "style": {"alignment": align}, "fields": "alignment"}})
    return reqs


# --- safe move: RELATIVE nudge preserves scale AND size --------------------

def move(oid, to_x, to_y, snap):
    """Move an element to absolute (to_x, to_y) px WITHOUT the size reset an ABSOLUTE
    transform inflicts on a text box. RELATIVE multiplies onto the current matrix, so
    scale 1 / shear 0 plus a translate delta shifts position and leaves scale and size
    untouched. Needs the snapshot for the current translate."""
    el = _element(snap, oid)
    if el is None:
        raise RuntimeError(f"{oid} not in snapshot; can't compute move delta")
    cur = el["raw_tf"]
    assert cur.get("unit", "EMU") == "EMU", f"unexpected transform unit {cur.get('unit')}"
    return [{"updatePageElementTransform": {"objectId": oid, "applyMode": "RELATIVE", "transform": {
        "scaleX": 1, "scaleY": 1,
        "translateX": px(to_x) - cur.get("translateX", 0),
        "translateY": px(to_y) - cur.get("translateY", 0), "unit": "EMU"}}}]


# --- preflight: the semantic checks gws --dry-run does NOT do ---------------

_OBJ_ID_RE = re.compile(r"[A-Za-z0-9_][A-Za-z0-9_:-]{4,49}\Z")


def _valid_objectid(s):
    return bool(_OBJ_ID_RE.match(s))


def preflight(requests, snap=None):
    """Returns (errors, warnings). errors would 400 or corrupt; warnings would just
    render wrong. Covers the whole discover-by-400 class: bad/duplicate new objectId,
    deleteText on an empty box, an edit target that doesn't exist, em/en dashes, and the
    center-align default on a new box."""
    errors, warnings = [], []
    existing = (set(snap["index"]) | set(snap["pages"])) if snap else None
    created, inserted, aligned = set(), set(), set()

    def new_id(oid):
        if not _valid_objectid(oid):
            errors.append(f"objectId {oid!r} breaks the 5-50 char / [A-Za-z0-9_:-] rule")
        if oid in created or (existing and oid in existing):
            errors.append(f"objectId {oid!r} already exists (must be unique)")
        created.add(oid)

    for r in requests:
        for verb, body in r.items():
            if not isinstance(body, dict):
                continue
            oid = body.get("objectId")
            if verb.startswith("create") and oid:
                new_id(oid)
            elif verb == "duplicateObject":
                for v in (body.get("objectIds") or {}).values():
                    new_id(v)
            elif verb == "groupObjects" and body.get("groupObjectId"):
                new_id(body["groupObjectId"])
            if verb == "deleteText" and oid:
                el = _element(snap, oid)
                if el is not None and not el["text"].strip():
                    errors.append(f"deleteText on {oid!r}: box is empty, this 400s (use insert-only)")
            if verb == "insertText" and oid:
                inserted.add(oid)
            if verb == "updateParagraphStyle" and oid and "alignment" in (body.get("style") or {}):
                aligned.add(oid)
            for key in ("text", "replaceText"):
                s = body.get(key, "")
                if isinstance(s, str) and ("—" in s or "–" in s):
                    errors.append(f"{verb} on {oid!r}: em/en dash in text (AI-writing tell)")

    if existing is not None:  # an edit target must pre-exist or be created in this batch
        for r in requests:
            for verb, body in r.items():
                if not isinstance(body, dict) or verb.startswith("create"):
                    continue
                oid = body.get("objectId")
                if oid and oid not in existing and oid not in created:
                    errors.append(f"{verb} targets {oid!r}, not in the snapshot (deleted or typo'd?)")

    for oid in inserted:
        if oid in created and oid not in aligned:
            warnings.append(f"{oid!r}: new box gets text but no alignment set, may render CENTER (pass align=START)")
    return errors, warnings


# --- guarded apply: verify -> preflight -> submit -> re-snapshot ------------

def apply(pid, requests, force=False, schema_check=True):
    """The code-driven write. Refuses to touch a page a collaborator changed since the
    snapshot, so a concurrent edit is a clean refusal with a diff, not a clobber. Steps:
    load snapshot; rebuild live; refuse if any target page changed; preflight (+ gws
    schema dry-run); batchUpdate guarded by the live revision; re-snapshot. force=True
    overrides the collision refusal."""
    snap = load_snapshot(pid)
    if snap is None:
        raise RuntimeError("no snapshot; run `snapshot` first so there's a baseline to protect")

    live = build_snapshot(pid)
    changes = diff(pid, live=live, base=snap)
    collisions = {sid: c for sid, c in changes.items() if sid in touched_pages(requests, snap)}
    if collisions and not force:
        print("REFUSED: these target pages changed since the snapshot:")
        for sid, c in collisions.items():
            print(f"  {sid}: +{len(c['added'])} -{len(c['removed'])} ~{len(c['changed'])}")
            for k, what in c["changed"][:4]:
                print(f"      {k}: {what}")
        print("Re-snapshot to accept their edits, or pass --force to write anyway.")
        return None

    errors, warnings = preflight(requests, snap)
    for w in warnings:
        print(f"  warn: {w}")
    if errors:
        print("REFUSED: preflight errors:")
        for e in errors:
            print(f"  err:  {e}")
        return None
    if schema_check:
        ok, msg = dry_run_ok(pid, requests)
        if not ok:
            print(f"REFUSED: schema dry-run failed: {msg}")
            return None

    resp = batch_update(pid, requests, revision_id=live["revisionId"])
    save_snapshot(build_snapshot(pid))
    print(f"applied {len(requests)} request(s); re-snapshotted.")
    return resp


# --- render: one contact sheet to actually look at -------------------------

def render(pid, slides=None, changed=False, cols=3, out=None, size="MEDIUM"):
    """Download page thumbnails and stitch them into one labelled PNG. `changed` renders
    only pages that differ from the snapshot. The whole point: turn 'write blind, hope'
    into 'write, glance at one image.'"""
    from PIL import Image, ImageDraw

    if changed:
        slides = list(diff(pid).keys())
        if not slides:
            print("nothing changed since snapshot; rendering nothing.")
            return None
    if slides is None:
        slides = (load_snapshot(pid) or build_snapshot(pid))["pageOrder"]

    os.makedirs(os.path.join(STATE_DIR, "thumbs"), exist_ok=True)

    def _tile(sid):
        # Each thumbnail() is a gws subprocess round-trip; sequential, a 16-slide deck
        # blows a 30s budget. Fetch concurrently, well under the 60/min thumbnail quota.
        url, _, _ = thumbnail(pid, sid, size=size)
        p = os.path.join(STATE_DIR, "thumbs", f"{sid}.png")
        with open(p, "wb") as f:
            f.write(urllib.request.urlopen(url).read())
        return sid, Image.open(p).convert("RGB")

    with ThreadPoolExecutor(max_workers=8) as ex:
        tiles = list(ex.map(_tile, slides))  # map preserves slide order

    tw, th = tiles[0][1].size
    pad, label_h = 12, 20
    rows = math.ceil(len(tiles) / cols)
    sheet = Image.new("RGB", (cols * tw + (cols + 1) * pad, rows * (th + label_h) + (rows + 1) * pad), "white")
    draw = ImageDraw.Draw(sheet)
    for i, (sid, img) in enumerate(tiles):
        r, c = divmod(i, cols)
        x, y = pad + c * (tw + pad), pad + r * (th + label_h) + label_h
        sheet.paste(img, (x, y))
        draw.text((x, y - label_h + 4), f"{i}: {sid}", fill="black")

    out = out or os.path.join(STATE_DIR, "contact_sheet.png")
    sheet.save(out)
    print(f"wrote {out} ({len(tiles)} slides, {cols} cols)")
    return out


# --- CLI -------------------------------------------------------------------

def _load_requests(path):
    doc = json.load(open(path))
    return doc["requests"] if isinstance(doc, dict) and "requests" in doc else doc


def main(argv):
    if not argv:
        print(__doc__)
        return
    cmd, rest = argv[0], argv[1:]

    if cmd == "snapshot":
        snap = build_snapshot(rest[0])
        save_snapshot(snap)
        print(f"snapshot: {len(snap['pages'])} pages, revision {snap['revisionId']}")

    elif cmd == "diff":
        d = diff(rest[0])
        if not d:
            print("no changes since snapshot.")
        for sid, c in d.items():
            print(f"{sid}: +{len(c['added'])} -{len(c['removed'])} ~{len(c['changed'])}")
            for k, what in c["changed"]:
                print(f"    {k}: {what}")

    elif cmd == "render":
        sel = rest[rest.index("--slides") + 1].split(",") if "--slides" in rest else None
        render(rest[0], slides=sel, changed=("--changed" in rest),
               cols=int(rest[rest.index("--cols") + 1]) if "--cols" in rest else 3)

    elif cmd == "preflight":
        errors, warnings = preflight(_load_requests(rest[0]), load_snapshot(rest[1]) if len(rest) > 1 else None)
        for w in warnings:
            print(f"warn: {w}")
        for e in errors:
            print(f"err:  {e}")
        print("clean." if not errors and not warnings else f"{len(errors)} error(s), {len(warnings)} warning(s)")

    elif cmd == "apply":
        apply(rest[0], _load_requests(rest[1]), force=("--force" in rest))

    else:
        print(f"unknown command {cmd!r}")
        print(__doc__)


if __name__ == "__main__":
    main(sys.argv[1:])
