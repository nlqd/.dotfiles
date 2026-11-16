"""Minimal Chrome DevTools client: read element rects, scroll smoothly.

Input never goes through CDP. The virtual pointer does that, so the
compositor draws a real cursor and the telemetry stays honest.
"""

import itertools
import json
import time
import urllib.request

from websockets.sync.client import connect


class Page:
    def __init__(self, port, url_prefix, timeout=20):
        deadline = time.monotonic() + timeout
        while True:
            try:
                targets = json.load(urllib.request.urlopen(f"http://127.0.0.1:{port}/json"))
                page = next(t for t in targets
                            if t["type"] == "page" and t["url"].startswith(url_prefix))
                break
            except Exception:
                if time.monotonic() > deadline:
                    raise RuntimeError(f"no Chrome page on debug port {port}")
                time.sleep(0.3)
        self.ws = connect(page["webSocketDebuggerUrl"], max_size=None)
        self.ids = itertools.count(1)

    def eval(self, expression):
        msg_id = next(self.ids)
        self.ws.send(json.dumps({"id": msg_id, "method": "Runtime.evaluate",
                                 "params": {"expression": expression, "returnByValue": True,
                                            "awaitPromise": True}}))
        while True:
            reply = json.loads(self.ws.recv())
            if reply.get("id") == msg_id:
                result = reply["result"]
                if "exceptionDetails" in result:
                    raise RuntimeError(f"page eval failed: {expression}: {result['exceptionDetails']}")
                return result["result"].get("value")

    def viewport_origin(self, session, probe=(960, 400)):
        """Screen position of the page's (0, 0), measured rather than guessed: the real
        pointer moves to a probe point and the page reports where it saw it. Needed
        whenever browser UI (address bar, DevTools) sits around the page; in --kiosk
        the origin is (0, 0). The probe must land on the page, not on DevTools."""
        # Keep the latest position and read it only once the pointer has settled:
        # events fired on the way to the probe report where the pointer was then.
        self.eval("window.__swooshSeen = null; addEventListener('mousemove', "
                  "e => window.__swooshSeen = [e.clientX, e.clientY])")
        session.move_to(probe[0] - 20, probe[1] - 20, duration=0.1)
        session.move_to(*probe, duration=0.2)
        time.sleep(0.3)
        seen = self.eval("window.__swooshSeen")
        if seen:
            return probe[0] - seen[0], probe[1] - seen[1]
        raise RuntimeError(f"the page never saw the pointer at {probe}; is the probe over DevTools?")

    def goto(self, url):
        """Navigate and wait for the new page. Open Chrome on about:blank and goto() once
        DevTools is up, or the first request never shows in the Network panel."""
        self.eval(f"location.href = {json.dumps(url)}")
        while self.eval("location.href") == "about:blank" or self.eval("document.readyState") != "complete":
            time.sleep(0.2)

    def wait_ready(self):
        while self.eval("document.readyState") != "complete":
            time.sleep(0.2)

    def box(self, selector):
        """Viewport bounding box [x0, y0, x1, y1] of the first element matching selector."""
        b = self.eval(f"""(() => {{
            const el = {self._find(selector)};
            if (!el) return null;
            const b = el.getBoundingClientRect();
            return [b.left, b.top, b.right, b.bottom];
        }})()""")
        if b is None:
            hint = (" (text= only matches links, buttons and headings; use CSS for anything else)"
                    if selector.startswith("text=") else "")
            raise RuntimeError(f"no element for {selector!r} on {self.eval('location.href')}{hint}; "
                               "check the live page, e.g. page.eval('document.body.innerText')")
        return b

    def cursor_at(self, x, y):
        """CSS cursor the page shows at viewport point (x, y), resolving 'auto' for links."""
        return self.eval(f"""(() => {{
            const el = document.elementFromPoint({x}, {y});
            if (!el) return 'default';
            const c = getComputedStyle(el).cursor;
            if (c !== 'auto') return c;
            return el.closest('a[href],button,[role=button]') ? 'pointer' : 'default';
        }})()""")

    def scroll_to(self, selector, top_margin=90):
        """Smooth-scroll so the element sits just under the fixed nav, wait until it settles."""
        self.eval(f"""(() => {{
            const el = {self._find(selector)};
            // Chrome's smooth scroll covers the distance in a few frames (130 px/frame
            // measured), so one dropped capture frame reads as a jolt. Animate it here
            // instead, eased over a duration that grows with the distance.
            const from = window.scrollY;
            const to = el.getBoundingClientRect().top + from - {top_margin};
            const ms = Math.min(1600, 600 + Math.abs(to - from) * 0.6);
            const start = performance.now();
            const ease = u => u < 0.5 ? 4 * u * u * u : 1 - Math.pow(-2 * u + 2, 3) / 2;
            const step = now => {{
                const u = Math.min(1, (now - start) / ms);
                window.scrollTo(0, from + (to - from) * ease(u));
                if (u < 1) requestAnimationFrame(step);
            }};
            requestAnimationFrame(step);
        }})()""")
        last, still = None, 0
        while still < 4:
            time.sleep(0.1)
            y = self.eval("window.scrollY")
            still = still + 1 if y == last else 0
            last = y

    @staticmethod
    def _find(selector):
        """'text=Foo' matches the first link, button or heading whose whitespace-collapsed
        text starts with Foo; anything else is a CSS selector."""
        if selector.startswith("text="):
            text = json.dumps(selector[5:])
            return (f"[...document.querySelectorAll('a,button,h1,h2,h3')]"
                    f".find(e => e.textContent.trim().replace(/\\s+/g,' ').startsWith({text}))")
        return f"document.querySelector({json.dumps(selector)})"
