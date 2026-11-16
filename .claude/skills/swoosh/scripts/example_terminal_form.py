"""Example desktop tour: a terminal and a browser form side by side, with clicks and typing.

Run with `swoosh record example_terminal_form.py OUT_DIR`. Positions come from the
sway tree plus the fixed layout of demo-page.html.
"""

import json
import subprocess
import sys

from demo_driver import SCRIPTS, Session


def window_origin(predicate):
    tree = json.loads(subprocess.run(["swaymsg", "-t", "get_tree", "--raw"],
                                     check=True, capture_output=True, text=True).stdout)
    stack = [tree]
    while stack:
        node = stack.pop()
        if node.get("pid") and predicate(node):
            return node["rect"]["x"], node["rect"]["y"]
        stack.extend(node.get("nodes", []) + node.get("floating_nodes", []))
    raise RuntimeError("window not found in sway tree")


def main(out_dir):
    s = Session(out_dir)
    s.spawn(["foot", "--app-id", "demo-term", "--working-directory", str(SCRIPTS)], settle=1.5)
    with s.chrome(f"--app=file://{SCRIPTS / 'demo-page.html'}", settle=4.0):
        cx, cy = window_origin(lambda n: n.get("app_id") != "demo-term")
        tx, ty = window_origin(lambda n: n.get("app_id") == "demo-term")

        s.start_recording()
        s.pause(1.0)
        s.click(cx + 210, cy + 140)
        s.type("Proof of work")
        s.pause(0.4)
        s.click(cx + 70, cy + 216)
        s.pause(0.5)
        s.click(cx + 110, cy + 292)
        s.pause(1.5)
        s.click(tx + 300, ty + 200)
        s.type("ls --color=always && python3 -c 'print(sum(range(10)))'")
        s.key("Return")
        s.pause(2.0)
        s.stop_recording()


if __name__ == "__main__":
    main(sys.argv[1])
