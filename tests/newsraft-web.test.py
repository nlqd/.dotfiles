#!/usr/bin/env python3
# Run: python3 tests/newsraft-web.test.py
import importlib.machinery
import importlib.util
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / ".local/scripts/newsraft-web"
loader = importlib.machinery.SourceFileLoader("newsraft_web", str(SCRIPT))
spec = importlib.util.spec_from_loader("newsraft_web", loader)
assert spec is not None
nw = importlib.util.module_from_spec(spec)
loader.exec_module(nw)

D = "\x1f"
SCHEMA = (
    "CREATE TABLE feeds(feed_url TEXT NOT NULL UNIQUE,title TEXT,link TEXT,content TEXT,attachments TEXT,persons TEXT,"
    "extras TEXT,download_date INTEGER NOT NULL DEFAULT 0,update_date INTEGER NOT NULL DEFAULT 0,time_to_live INTEGER NOT NULL DEFAULT 0,"
    "http_header_etag TEXT,http_header_last_modified INTEGER NOT NULL DEFAULT 0,http_header_expires INTEGER NOT NULL DEFAULT 0,user_data TEXT);"
    "CREATE TABLE items(feed_url TEXT NOT NULL,guid TEXT NOT NULL,title TEXT,link TEXT,content TEXT,attachments TEXT,persons TEXT,"
    "extras TEXT,download_date INTEGER NOT NULL DEFAULT 0,publication_date INTEGER NOT NULL DEFAULT 0,update_date INTEGER NOT NULL DEFAULT 0,"
    "unread INTEGER NOT NULL DEFAULT 0,important INTEGER NOT NULL DEFAULT 0,user_data TEXT);"
)


def make_db(folder: str) -> Path:
    db = Path(folder, "newsraft.sqlite3")
    con = sqlite3.connect(db)
    con.executescript(SCHEMA)
    con.executemany("INSERT INTO feeds(feed_url, title) VALUES (?, ?)", [("https://a.example/feed", "Feed <A>"), ("https://b.example/feed", None)])
    con.executemany(
        "INSERT INTO items(feed_url, guid, title, link, content, publication_date, unread) VALUES (?,?,?,?,?,?,?)",
        [
            ("https://a.example/feed", "1", "Tom & <Jerry>", "https://a.example/1", f"{D}^{D}type=text/html{D}text=<p>Hello <script>x()</script></p>", 1790000000, 1),
            ("https://a.example/feed", "2", "Second", "https://a.example/2", f"{D}^{D}text=line one\n\nline two", 1790000100, 1),
            ("https://b.example/feed", "3", "Old", "https://b.example/3", "", 1700000000, 0),
        ],
    )
    con.commit()
    con.close()
    return db


class Core(unittest.TestCase):
    def test_largest_text_piece_wins_with_its_type(self) -> None:
        data = f"{D}^{D}type=text/plain{D}text=short{D}^{D}type=text/html{D}text=<p>much longer</p>"
        self.assertEqual(nw.largest_text(data), ("<p>much longer</p>", "text/html"))

    def test_text_without_type_is_plain(self) -> None:
        self.assertEqual(nw.largest_text(f"{D}^{D}text=a=b"), ("a=b", "text/plain"))

    def test_empty_content(self) -> None:
        self.assertEqual(nw.largest_text(None), ("", "text/plain"))

    def test_feeds_file_lists_feeds_with_optional_names(self) -> None:
        text = '# mine\n@ Papers\nhttps://a.example/feed\n\n$(curl -sL \'http://x/q?a="b"\' | filter) "Continual Learning"\nhttps://b.example/rss "B Blog"\n'
        self.assertEqual(
            nw.parse_feeds(text),
            {"https://a.example/feed": "", "$(curl -sL 'http://x/q?a=\"b\"' | filter)": "Continual Learning", "https://b.example/rss": "B Blog"},
        )

    def test_long_feed_titles_are_shortened(self) -> None:
        name = nw.feed_name("arXiv Query: " + "x" * 200, "https://a.example/feed")
        self.assertTrue(len(name) <= 60 and name.endswith("…"))

    def test_serves_only_on_the_named_tailnet(self) -> None:
        status = {"BackendState": "Running", "CurrentTailnet": {"Name": "hs.example.com"}, "Self": {"TailscaleIPs": ["100.64.0.99", "fd7a::3"]}}
        self.assertEqual(nw.tailnet_address(status, "hs.example.com"), "100.64.0.99")

    def test_other_tailnets_are_refused(self) -> None:
        status = {"BackendState": "Running", "CurrentTailnet": {"Name": "work.example"}, "Self": {"TailscaleIPs": ["100.113.0.1"]}}
        self.assertIsNone(nw.tailnet_address(status, "hs.example.com"))

    def test_logged_out_is_refused(self) -> None:
        self.assertIsNone(nw.tailnet_address({"BackendState": "NeedsLogin", "Self": {}}, "hs.example.com"))


class CleanHtml(unittest.TestCase):
    def test_feed_classes_cannot_restyle_links_into_buttons(self) -> None:
        self.assertEqual(
            nw.clean_html('<p class="button-wrapper" data-attrs="{}"><a class="button primary" id="x" style="color:red" href="https://a.example/s">Subscribe</a></p>'),
            '<p><a href="https://a.example/s">Subscribe</a></p>',
        )

    def test_only_web_links_survive(self) -> None:
        self.assertEqual(nw.clean_html('<a href="javascript:alert(1)">x</a>'), "<a>x</a>")
        self.assertEqual(nw.clean_html('<a href="https://a.example/">x</a>'), '<a href="https://a.example/">x</a>')

    def test_widgets_that_need_scripts_are_dropped_with_their_content(self) -> None:
        for tag in ("button", "select", "textarea", "script", "style", "iframe"):
            with self.subTest(tag=tag):
                self.assertEqual(nw.clean_html(f"<p>a</p><{tag}>inner</{tag}><p>b</p>"), "<p>a</p><p>b</p>")

    def test_forms_unwrap_and_inputs_vanish(self) -> None:
        self.assertEqual(nw.clean_html('<form action="/x"><p>hi</p><input type="range"></form>'), "<p>hi</p>")

    def test_images_keep_source_and_alt_but_scale_by_stylesheet(self) -> None:
        self.assertEqual(
            nw.clean_html('<img width="900" height="600" class="wide" srcset="a 2x" src="https://a.example/i.jpg" alt="a cat"/>'),
            '<img src="https://a.example/i.jpg" alt="a cat">',
        )

    def test_images_without_a_web_source_are_dropped(self) -> None:
        self.assertEqual(nw.clean_html('<p><img src="data:image/png;base64,AAAA"></p>'), "<p></p>")

    def test_tables_keep_their_spans(self) -> None:
        self.assertEqual(
            nw.clean_html('<table class="t"><tr><td colspan="2" style="x">a</td></tr></table>'),
            '<table><tr><td colspan="2">a</td></tr></table>',
        )

    def test_unknown_tags_unwrap(self) -> None:
        self.assertEqual(nw.clean_html("<custom-el>hi <b>there</b></custom-el>"), "hi <b>there</b>")

    def test_text_is_escaped(self) -> None:
        self.assertEqual(nw.clean_html("<p>1 &lt; 2 &amp; 3</p>"), "<p>1 &lt; 2 &amp; 3</p>")

    def test_unclosed_tags_are_closed(self) -> None:
        self.assertEqual(nw.clean_html("<p>a<b>bold"), "<p>a<b>bold</b></p>")


class Server(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.db = make_db(self.tmp.name)
        self.reader = nw.Reader(self.db, reload_commands=[[sys.executable, "-c", "import time; time.sleep(0.3)"]], lists={"feeds": {"https://b.example/feed": "Named B", "https://a.example/feed": ""}, "feeds-vn": {"https://c.example/feed": "C feed"}})
        self.server = nw.serve(self.reader, "127.0.0.1", 0)
        self.base = f"http://127.0.0.1:{self.server.server_address[1]}"
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def tearDown(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.tmp.cleanup()

    def get(self, path: str) -> tuple[int, str, dict[str, str]]:
        with urllib.request.urlopen(self.base + path) as r:
            return r.status, r.read().decode(), dict(r.headers)

    def post(self, path: str, data: bytes = b"", origin: str | None = "self") -> int:
        req = urllib.request.Request(self.base + path, data=data, method="POST")
        if origin:
            req.add_header("Origin", self.base if origin == "self" else origin)
        try:
            with urllib.request.urlopen(req) as r:
                return r.status
        except urllib.error.HTTPError as e:
            return e.code

    def unread(self, guid: str) -> int:
        con = sqlite3.connect(self.db)
        try:
            return con.execute("SELECT unread FROM items WHERE guid = ?", (guid,)).fetchone()[0]
        finally:
            con.close()

    def rowid(self, guid: str) -> int:
        con = sqlite3.connect(self.db)
        try:
            return con.execute("SELECT rowid FROM items WHERE guid = ?", (guid,)).fetchone()[0]
        finally:
            con.close()

    def test_main_page_lists_every_feed_in_the_feeds_file_in_order(self) -> None:
        _, body, _ = self.get("/")
        self.assertLess(body.index("Named B"), body.index("Feed &lt;A&gt;"))

    def test_all_unread_lists_items_with_titles_escaped(self) -> None:
        _, body, _ = self.get("/unread")
        self.assertIn("Tom &amp; &lt;Jerry&gt;", body)
        self.assertNotIn("Old", body)

    def test_other_feeds_files_have_their_own_list(self) -> None:
        _, main, _ = self.get("/")
        _, other, _ = self.get("/list/feeds-vn")
        self.assertIn('href="/list/feeds-vn"', main)
        self.assertIn("C feed", other)

    def test_feeds_show_unread_counts(self) -> None:
        _, body, _ = self.get("/")
        self.assertIn("Feed &lt;A&gt;", body)
        self.assertIn("2", body)

    def test_names_from_the_feeds_file_win(self) -> None:
        _, body, _ = self.get("/")
        self.assertIn("Named B", body)

    def test_feeds_missing_from_the_feeds_files_stay_hidden_like_in_newsraft(self) -> None:
        self.reader.fixed_lists = {"feeds": {"https://b.example/feed": "Named B"}}
        _, body, _ = self.get("/unread")
        self.assertNotIn("Tom &amp; &lt;Jerry&gt;", body)

    def test_opening_an_item_marks_it_read(self) -> None:
        self.get(f"/item/{self.rowid('1')}")
        self.assertEqual(self.unread("1"), 0)

    def test_pages_forbid_scripts(self) -> None:
        _, _, headers = self.get(f"/item/{self.rowid('1')}")
        csp = headers["Content-Security-Policy"]
        self.assertIn("default-src 'none'", csp)
        self.assertNotIn("script-src", csp)

    def test_html_items_are_cleaned_before_they_are_shown(self) -> None:
        con = sqlite3.connect(self.db)
        con.execute("UPDATE items SET content = ? WHERE guid = '1'", (f'{D}^{D}type=text/html{D}text=<a class="button primary" href="https://a.example/s">Subscribe</a>',))
        con.commit()
        con.close()
        _, body, _ = self.get(f"/item/{self.rowid('1')}")
        self.assertIn('<a href="https://a.example/s">Subscribe</a>', body)
        self.assertNotIn("button primary", body)

    def test_reader_stylesheet_keeps_wide_content_inside_the_screen(self) -> None:
        _, page, _ = self.get(f"/item/{self.rowid('1')}")
        self.assertIn('href="/reader.css"', page)
        _, css, headers = self.get("/reader.css")
        self.assertTrue(headers["Content-Type"].startswith("text/css"))
        for rule in ("max-width: 100%", "overflow-x: auto"):
            self.assertIn(rule, css)

    def test_plain_text_items_become_paragraphs(self) -> None:
        _, body, _ = self.get(f"/item/{self.rowid('2')}")
        self.assertIn("<p>line one</p>", body)

    def test_keep_unread(self) -> None:
        self.get(f"/item/{self.rowid('1')}")
        self.assertEqual(self.post(f"/item/{self.rowid('1')}/unread"), 200)
        self.assertEqual(self.unread("1"), 1)

    def test_posts_from_other_sites_are_refused(self) -> None:
        self.assertEqual(self.post("/feed/read", b"url=https%3A%2F%2Fa.example%2Ffeed", origin="https://evil.example"), 403)
        self.assertEqual(self.post("/feed/read", b"url=https%3A%2F%2Fa.example%2Ffeed", origin=None), 403)
        self.assertEqual(self.unread("1"), 1)

    def test_mark_feed_read(self) -> None:
        self.post("/feed/read", b"url=https%3A%2F%2Fa.example%2Ffeed")
        self.assertEqual((self.unread("1"), self.unread("2")), (0, 0))

    def test_stylesheet_is_served(self) -> None:
        _, body, headers = self.get("/simple.css")
        self.assertTrue(headers["Content-Type"].startswith("text/css"))
        self.assertIn("--accent", body)

    def test_fetch_runs_the_reload_and_the_page_waits_for_it(self) -> None:
        self.post("/fetch")
        _, busy, _ = self.get("/")
        self.assertIn('http-equiv="refresh"', busy)
        time.sleep(0.8)
        _, done, _ = self.get("/")
        self.assertNotIn('http-equiv="refresh"', done)

    def test_locked_database_offers_switch_and_switch_frees_it(self) -> None:
        holder = subprocess.Popen(
            ["newsraft", "-c", "import sqlite3, sys, time\n"
             "c = sqlite3.connect(sys.argv[1]); c.execute('PRAGMA locking_mode = EXCLUSIVE'); c.execute('BEGIN EXCLUSIVE')\n"
             "print('locked', flush=True); time.sleep(60)", str(self.db)],
            executable=sys.executable, stdout=subprocess.PIPE, text=True,
        )
        try:
            assert holder.stdout is not None
            holder.stdout.readline()
            _, body, _ = self.get("/")
            self.assertIn("Switch to phone", body)
            self.post("/switch")
            holder.wait(timeout=10)
            _, after, _ = self.get("/")
            self.assertIn("Feed &lt;A&gt;", after)
        finally:
            holder.kill()
            holder.wait()
            if holder.stdout:
                holder.stdout.close()


if __name__ == "__main__":
    unittest.main()
