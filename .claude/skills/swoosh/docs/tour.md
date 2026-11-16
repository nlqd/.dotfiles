# Writing a tour

A tour is a Python script that takes one argument, `OUT_DIR`, and drives the demo through `Session` from `demo_driver`. `swoosh record` runs it inside the headless display with the right environment, so never run a tour directly. Start by copying an example:

- `scripts/example_web_tour.py`: a web page in Chrome, hover only, scrolls between sections.
- `scripts/example_terminal_form.py`: foot plus a browser form, with clicks and typing.
- `scripts/example_review_tour.py`: reviewer mode, with the address bar and DevTools Network panel in the video.

`swoosh record` puts `scripts/` on `PYTHONPATH`, so a tour anywhere can `from demo_driver import Session` and `from cdp import Page`. A tour that imports packages declares them in a PEP 723 header (`# /// script`), as the web example does for `websockets`.

## Session

The renderer only knows what the tour logs, so make every move through `Session`.

- `s = Session(out_dir)`
- `with s.chrome(*flags, url):` runs Chrome with the flags this display needs and a throwaway profile, and closes it afterwards. Add `--kiosk` for a full-screen page, `--remote-debugging-port=N` to read the page with `cdp.Page`, or `--app=URL` for a window without browser chrome. `s.spawn(argv, settle)` starts anything else (foot, an Electron app).
- `s.start_recording()` and `s.stop_recording()` bracket the part worth showing. Do setup (page load, dismissing banners) before starting.
- `s.focus(x, y, dwell, cursor=..., box=...)` moves to a target and hovers it; the camera zooms on it. For a link or button, pass its CSS cursor and its box (`page.cursor_at(x, y)`, `page.box(selector)`) so the drawn cursor is a hand exactly while it's over the element. `cursor` without `box` raises.
- `s.click(x, y)`, `s.type(text)`, `s.key("Return")` interact. Clicks get a ripple and typing gets the keystroke pill.
- `s.mark("scroll")` right before a page scroll, so the camera is zoomed out while the page moves.
- `s.move_to(x, y)` and `s.pause(seconds)` for anything else.

Coordinates are logical pixels of a 1920x1080 desktop.

## Reading a page with cdp.Page

`page = Page(port, url_prefix)` attaches to the Chrome tab whose URL starts with `url_prefix`. It only reads; input always goes through the real pointer.

- `page.wait_ready()` waits for the document to load.
- `page.box(selector)` returns `[x0, y0, x1, y1]`; the target is its center.
- `page.cursor_at(x, y)` returns the CSS cursor there (`pointer` on links).
- `page.scroll_to(selector)` eases a scroll so the element sits under a fixed header; use it instead of the mouse wheel or Chrome's smooth scroll, which is too fast to capture cleanly.
- `page.eval(js)` runs JavaScript and returns the value.
- A selector is CSS, or `text=Foo` for the first link, button or heading whose text starts with Foo.

## Before you finish

- Open `DIR/sheet.png` (from `swoosh sheet DIR`) and look at it: every target in frame, the right cursor shape, no cookie banner or dialog. Fix the tour and record again; `record` simply overwrites the take in DIR.
- Never publish the video anywhere (a PR, an upload, a chat) without asking the user first. With their yes, `gh pr edit N --attach out/demo.mp4` (gh 2.104+) uploads it into the PR description, where it plays inline.

## Reviewer mode

For code reviewers who want to see the real URL and the requests, like a dev doing QA, open Chrome without `--kiosk` and pass `devtools`:

```python
with s.chrome(f"--remote-debugging-port={PORT}", "about:blank", devtools={}):
    page = Page(PORT, "about:blank")
    page.goto(url)                    # navigate after DevTools is up, or the first request is missed
    ox, oy = page.viewport_origin(s)  # page (0, 0) on screen; add it to page.box() coordinates
```

- DevTools opens docked at the bottom on the Network tab with Keep log on. Options: `devtools={"text_filter": "domain:localhost", "types": ("Doc", "Fetch"), "height": 380, "preserve_log": True}` (those are the defaults; `types` also takes JS, CSS, Img, Media, Font, WS).
- The camera holds still for the whole take, since any zoom would crop the address bar or the panel. Cursor, ripples and the keystroke pill stay; the pill moves above the panel.
- Use a single Chrome window: sway tiles a second one into a split screen.
- For a redirect or page-load story, pass `types=("Doc",)`: Fetch adds framework prefetch rows (Next.js RSC, for one) that crowd the panel. Keep Fetch for flows that post to an API.

## Things that bite

- Cookie banners mount late. Poll for the button, click it, poll until it's gone, and fail loudly on timeout; see `dismiss_cookie_banner` in the web example.
- Keep the demo short, 15 to 30 s, and let each target dwell 1 to 1.5 s. Shorter dwells give the camera no time to settle.
- A web tour should stay on one page unless the demo is about navigation. Hover links rather than clicking them.
- Pick targets from the live page, not from memory of it: sites change. When a selector fails, print the page's text or links with `page.eval` and choose again.
- Never put secrets on screen: the video ends up in a pull request.
