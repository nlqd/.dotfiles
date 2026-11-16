# /// script
# requires-python = ">=3.11"
# dependencies = ["websockets"]
# ///
"""Example reviewer tour: address bar and DevTools Network panel stay in the video.

Run with `swoosh record example_review_tour.py OUT_DIR`. Serves demo-page.html from
localhost, fills the form, and clicks Save so its request shows in the Network panel.
Opening DevTools holds the camera still: zooming would crop the URL or the panel.
"""

import functools
import http.server
import sys
import threading

from cdp import Page
from demo_driver import SCRIPTS, Session

DEBUG_PORT = 9334


class DemoHandler(http.server.SimpleHTTPRequestHandler):
    """Serves the demo page, and answers its Save request so the panel shows a 200."""

    def do_GET(self):
        if self.path.startswith("/save"):
            body = b'{"ok": true}'
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            super().do_GET()

    def log_message(self, *args):
        pass


def main(out_dir):
    s = Session(out_dir)
    server = http.server.ThreadingHTTPServer(
        ("127.0.0.1", 0), functools.partial(DemoHandler, directory=str(SCRIPTS)))
    port = server.server_address[1]
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        with s.chrome(f"--remote-debugging-port={DEBUG_PORT}", "about:blank", settle=3.0, devtools={}):
            page = Page(DEBUG_PORT, "about:blank")
            page.goto(f"http://localhost:{port}/demo-page.html")
            ox, oy = page.viewport_origin(s)

            def at(selector):
                x0, y0, x1, y1 = page.box(selector)
                return ox + (x0 + x1) / 2, oy + (y0 + y1) / 2

            s.start_recording()
            s.pause(1.0)
            s.click(*at("#name"))
            s.type("Proof of work")
            s.click(*at("#toggle"))
            s.pause(0.4)
            s.click(*at("#save"))
            s.pause(2.0)
            s.stop_recording()
    finally:
        server.shutdown()


if __name__ == "__main__":
    main(sys.argv[1])
