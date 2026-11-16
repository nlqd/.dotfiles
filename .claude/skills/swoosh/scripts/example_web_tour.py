# /// script
# requires-python = ">=3.11"
# dependencies = ["websockets"]
# ///
"""Example web tour: the Jenner Analytics homepage, hover only.

Run with `swoosh record example_web_tour.py OUT_DIR`. It never follows a link or
submits a form, so the take stays on one page.
"""

import sys
import time

from cdp import Page
from demo_driver import Session

URL = "https://jenneranalytics.com/"
PORT = 9333


def dismiss_cookie_banner(page, timeout=10):
    """The banner mounts a few seconds after load, so a one-shot click can miss it."""
    find = "[...document.querySelectorAll('button')].find(b => b.textContent.trim() === 'Reject Advertising')"
    deadline = time.monotonic() + timeout
    while not page.eval(f"!!{find}"):
        if time.monotonic() > deadline:
            raise RuntimeError("cookie banner never appeared; check the page before recording")
        time.sleep(0.25)
    page.eval(f"{find}.click()")
    while page.eval(f"!!{find}"):
        if time.monotonic() > deadline + 5:
            raise RuntimeError("cookie banner did not close after clicking Reject Advertising")
        time.sleep(0.25)


def main(out_dir):
    s = Session(out_dir)
    with s.chrome(f"--remote-debugging-port={PORT}", "--hide-scrollbars", "--kiosk", URL, settle=1.0):
        page = Page(PORT, URL)
        page.wait_ready()
        dismiss_cookie_banner(page)
        time.sleep(1.5)  # hero video and fade-in animations

        def hover(selector, dwell=1.2):
            box = page.box(selector)
            x, y = (box[0] + box[2]) / 2, (box[1] + box[3]) / 2
            s.focus(x, y, dwell, cursor=page.cursor_at(x, y), box=box)

        s.move_to(960, 700, duration=0.01)
        s.start_recording()
        s.pause(1.2)
        hover("text=Start Free Trial", 1.4)
        hover("text=View Documentation", 1.0)

        s.mark("scroll")
        page.scroll_to("text=Why Jenner?")
        s.pause(0.6)
        hover("text=Instantly Familiar")
        hover("text=Seamless Migration")
        hover("text=Low Transparent Cost")

        s.mark("scroll")
        page.scroll_to("#windows-linux")
        s.pause(0.6)
        hover("text=Linux pricing", 1.4)

        s.mark("scroll")
        page.scroll_to("#video")
        s.pause(0.6)
        hover("text=Try Workspace Free", 1.4)

        s.mark("scroll")
        page.scroll_to("#contact")
        s.pause(1.0)
        s.stop_recording()


if __name__ == "__main__":
    main(sys.argv[1])
