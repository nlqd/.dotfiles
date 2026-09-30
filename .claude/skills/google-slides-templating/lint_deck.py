# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""lint_deck.py - find the consistency gaps in a deck WITHOUT being told the design system.

Every check here infers the deck's own norm and reports what breaks it, because a deck that was
hand-built, inherited, or restyled by a script has no token file to check against. What it looks
for is drift: the one card in a near-identical grey, the four runs left in the old font, the title
that sits 6pt lower than the other thirty-eight, the footer that went missing on one slide.

    python3 lint_deck.py <presentationId> [--json]

Pairs with a visual pass (deck_ops.py render): this finds what the eye slides over (a 1-unit
colour difference, a stray font), the eye finds what this cannot (crowding, imbalance, a photo
that clashes). Neither alone is a review.
"""
import json
import re
import statistics
import sys
from collections import Counter, defaultdict

sys.path.insert(0, __file__.rsplit("/", 1)[0])
import deck_ops  # noqa: E402

EMU_PER_PT = 12700
PAGE_W, PAGE_H = 960, 540
CHAR_W = 0.50  # mean advance width as a fraction of font size, calibrated on Inter/Plex/Grotesk


def _hex(color):
    if not color:
        return None
    if "themeColor" in color:
        return "theme:" + color["themeColor"]
    rgb = color.get("rgbColor", {})
    return "#%02x%02x%02x" % tuple(round(rgb.get(k, 0) * 255) for k in ("red", "green", "blue"))


def _near(a, b, tol=6):
    """Two hex colours so close that only a script can tell them apart: the signature of
    drift (a value retyped, or half-converted by an earlier sweep), not of a design decision."""
    if not (a and b) or a.startswith("theme:") or b.startswith("theme:"):
        return False
    return all(abs(int(a[i:i + 2], 16) - int(b[i:i + 2], 16)) <= tol for i in (1, 3, 5))


def _box(el):
    t, s = el.get("transform", {}), el.get("size", {})
    return (t.get("translateX", 0) / EMU_PER_PT, t.get("translateY", 0) / EMU_PER_PT,
            s.get("width", {}).get("magnitude", 0) * t.get("scaleX", 1) / EMU_PER_PT,
            s.get("height", {}).get("magnitude", 0) * t.get("scaleY", 1) / EMU_PER_PT)


def _flatten(els):
    for el in els:
        yield el
        yield from _flatten(el.get("elementGroup", {}).get("children", []))


def _runs(el):
    for te in el.get("shape", {}).get("text", {}).get("textElements", []):
        if "textRun" in te and te["textRun"]["content"].strip():
            yield te["textRun"]


def _contains(a, b):
    return (a[0] <= b[0] + 1 and a[1] <= b[1] + 1
            and a[0] + a[2] >= b[0] + b[2] - 1 and a[1] + a[3] >= b[1] + b[3] - 1)


def collect(pres):
    """One pass: every styled thing, tagged with where it came from."""
    facts = []
    for i, s in enumerate(pres["slides"], 1):
        sid = s["objectId"]
        skipped = s["slideProperties"].get("isSkipped", False)
        for el in _flatten(s.get("pageElements", [])):
            oid, box = el["objectId"], _box(el)
            if "shape" in el:
                sp = el["shape"].get("shapeProperties", {})
                for kind, node in (("fill", sp.get("shapeBackgroundFill", {})),
                                   ("outline", sp.get("outline", {}))):
                    if node.get("propertyState", "RENDERED") != "RENDERED":
                        continue
                    fill = node.get("solidFill") or node.get("outlineFill", {}).get("solidFill")
                    if fill:
                        facts.append(dict(slide=i, sid=sid, skipped=skipped, oid=oid, box=box,
                                          kind=kind, value=_hex(fill.get("color"))))
                for r in _runs(el):
                    st = r.get("style", {})
                    fam = (st.get("weightedFontFamily") or {}).get("fontFamily") or st.get("fontFamily")
                    facts.append(dict(slide=i, sid=sid, skipped=skipped, oid=oid, box=box, kind="font",
                                      value=fam, size=(st.get("fontSize") or {}).get("magnitude"),
                                      text=r["content"],
                                      colour=_hex((st.get("foregroundColor") or {}).get("opaqueColor"))))
    return facts


def lint(pres):
    facts = collect(pres)
    issues = []
    n_slides = len(pres["slides"])

    # 1. colour drift: a value that is nearly, but not exactly, a value used far more often
    counts = Counter(f["value"] for f in facts if f["kind"] in ("fill", "outline") and f["value"])
    counts.update(f["colour"] for f in facts if f["kind"] == "font" and f["colour"])
    for colour, n in counts.items():
        for other, m in counts.items():
            if colour != other and m >= max(6, 4 * n) and _near(colour, other):
                where = {f"{f['slide']}/{f['oid']}" for f in facts
                         if colour in (f.get("value"), f.get("colour"))}
                issues.append(("colour-drift", f"{colour} (x{n}) is a near-duplicate of {other} (x{m}): "
                                               f"{', '.join(sorted(where)[:4])}"))
                break

    # 2. rare fonts: the leftovers of a half-finished restyle
    fonts = Counter(f["value"] for f in facts if f["kind"] == "font" and f["value"])
    total = sum(fonts.values()) or 1
    for fam, n in fonts.items():
        if n / total < 0.05:
            where = {f"{f['slide']}/{f['oid']}" for f in facts if f["kind"] == "font" and f["value"] == fam}
            issues.append(("rare-font", f"{fam!r} on only {n} of {total} runs: {', '.join(sorted(where)[:4])}"))

    # 3. title drift: compare each slide's topmost sizeable text against the deck's median
    heads = {}
    for f in facts:
        if f["kind"] != "font" or not f.get("size") or f["size"] < 18:
            continue
        cur = heads.get(f["slide"])
        if cur is None or f["box"][1] < cur["box"][1]:
            heads[f["slide"]] = f
    ys = [h["box"][1] for h in heads.values()]
    if len(ys) > 4:
        my, mx = statistics.median(ys), statistics.median(h["box"][0] for h in heads.values())
        msize = statistics.median(h["size"] for h in heads.values())
        for slide, h in sorted(heads.items()):
            dy, dx, ds = h["box"][1] - my, h["box"][0] - mx, h["size"] - msize
            # a cover or divider sits in its own band and is meant to differ; only compare
            # headings that are trying to be the same heading, where a gap is an accident
            if abs(dy) < 40 and (abs(dy) > 1 or abs(dx) > 1 or abs(ds) > 0.1):
                issues.append(("title-drift", f"slide {slide} {h['oid']}: heading at "
                                              f"({h['box'][0]:.0f},{h['box'][1]:.0f}) {h['size']}pt vs "
                                              f"deck norm ({mx:.0f},{my:.0f}) {msize}pt"))

    # 4. missing furniture: an element most slides carry, absent from one
    slots = defaultdict(set)
    for f in facts:
        slots[(round(f["box"][0] / 8), round(f["box"][1] / 8), f["kind"])].add(f["slide"])
    for slot, slides in slots.items():
        if len(slides) >= 0.6 * n_slides:
            missing = [i for i in range(1, n_slides + 1) if i not in slides]
            if 0 < len(missing) <= max(2, n_slides // 8):
                issues.append(("missing-furniture", f"the {slot[2]} at about ({slot[0] * 8},{slot[1] * 8}) "
                                                    f"is on {len(slides)} slides but not {missing}"))

    # 5. overflow and off-slide, run-aware so a title run does not mis-size the body
    per_el = defaultdict(list)
    for f in facts:
        if f["kind"] == "font":
            per_el[(f["slide"], f["oid"])].append(f)
    for (slide, oid), runs in per_el.items():
        box = runs[0]["box"]
        if box[2] < 4 or box[3] < 24:
            continue
        # Join the runs first: a heading is often several runs ("The Mac App " + "- June
        # Scorecard"), and counting each run as its own line invents overflow that is not there.
        # Sizing every line by the element's largest run keeps the estimate conservative.
        size = max((r.get("size") or 12) for r in runs)
        width, text = max(box[2] - 8, 10), "".join(r["text"] for r in runs).rstrip("\n")
        per = max(1, int(width / (size * CHAR_W)))
        lines = sum(max(1, -(-len(line) // per)) for line in text.split("\n"))
        est = lines * size * 1.25
        if est > box[3] + 8:
            issues.append(("overflow", f"slide {slide} {oid}: about {lines} lines needs ~{est:.0f}pt "
                                       f"in a {box[3]:.0f}pt box"))
    for f in facts:
        x, y, w, h = f["box"]
        if f["kind"] == "font" and (x < -2 or y < -2 or x + w > PAGE_W + 2 or y + h > PAGE_H + 2):
            issues.append(("off-slide", f"slide {f['slide']} {f['oid']}: extends past the slide edge"))

    # 6. partial overlaps, ignoring a container and its own label
    by_slide = defaultdict(dict)
    for f in facts:
        by_slide[f["slide"]].setdefault(f["oid"], f["box"])
    for slide, boxes in by_slide.items():
        items = list(boxes.items())
        for i in range(len(items)):
            for j in range(i + 1, len(items)):
                (id1, a), (id2, b) = items[i], items[j]
                ox = max(0, min(a[0] + a[2], b[0] + b[2]) - max(a[0], b[0]))
                oy = max(0, min(a[1] + a[3], b[1] + b[3]) - max(a[1], b[1]))
                small = min(a[2] * a[3], b[2] * b[3]) or 1
                if small > 900 and not _contains(a, b) and not _contains(b, a) and ox * oy / small > 0.5:
                    issues.append(("overlap", f"slide {slide}: {id1} and {id2} overlap "
                                              f"{100 * ox * oy / small:.0f}% without containing each other"))

    # 7. copy tells: em/en dashes and straight-quote drift within one deck
    dashes = [f for f in facts if f["kind"] == "font" and re.search(r"[—–]", f.get("text", ""))]
    if dashes and len(dashes) < 0.2 * sum(1 for f in facts if f["kind"] == "font"):
        issues.append(("copy", f"em/en dash in {len(dashes)} runs, e.g. slide {dashes[0]['slide']} "
                               f"{dashes[0]['oid']}: {dashes[0]['text'].strip()[:40]!r}"))
    return issues


def main(argv):
    if not argv:
        print(__doc__)
        return 2
    pid = argv[0]
    pres = deck_ops.get_presentation(pid)
    issues = lint(pres)
    if "--json" in argv:
        print(json.dumps([{"kind": k, "detail": d} for k, d in issues], indent=1))
        return 0
    by_kind = defaultdict(list)
    for kind, detail in issues:
        by_kind[kind].append(detail)
    for kind in sorted(by_kind):
        print(f"\n== {kind} ({len(by_kind[kind])})")
        for d in by_kind[kind][:12]:
            print("  " + d)
        if len(by_kind[kind]) > 12:
            print(f"  ... {len(by_kind[kind]) - 12} more")
    print(f"\n{len(issues)} findings over {len(pres['slides'])} slides")
    print("Expect false positives on: autofitting display numerals, tables (the API reports a "
          "default size), and intentionally distinct cover/divider layouts.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
