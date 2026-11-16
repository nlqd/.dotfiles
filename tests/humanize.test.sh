#!/usr/bin/env bash
# Tests for humanize. Run: bash tests/humanize.test.sh
# Talks to a stub model server, so no model or GPU is needed. The stub rewrites "important" to
# "key" and prefixes "So,", and misbehaves on cue: DROPNUM loses its numbers on the first try,
# ALWAYSBAD loses them every time, SAMEPARA is returned unchanged.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
HZ="$HERE/../.local/scripts/humanize"

W=$(mktemp --directory)
trap 'kill $STUB_PID 2>/dev/null; wait $STUB_PID 2>/dev/null; rm --recursive --force "$W"' EXIT

cat >"$W/stub.py" <<'EOF'
import http.server, json, re, sys
counts = {}
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        self.send_response(200); self.end_headers(); self.wfile.write(b'{"status":"ok"}')
    def do_POST(self):
        text = json.loads(self.rfile.read(int(self.headers["Content-Length"])))["messages"][-1]["content"]
        counts[text] = counts.get(text, 0) + 1
        out = text.replace("important", "key")
        out = "So, " + out[0].lower() + out[1:]
        if "SAMEPARA" in text:
            out = text
        if "BOLDSTRIP" in text:
            out = out.replace("**", "")
        if "CURLYQ" in text:
            out = out.replace("'", "\u2019")
        if "QUOTEWRAP" in text:
            out = "\u201c" + out + "\u201d"
        if "ALWAYSBAD" in text or ("DROPNUM" in text and counts[text] == 1):
            out = re.sub(r"\d", "", out)
        body = json.dumps({"choices": [{"message": {"content": out}}]}).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers()
        self.wfile.write(body)
srv = http.server.HTTPServer(("127.0.0.1", 0), H)
open(sys.argv[1], "w").write(str(srv.server_port))
srv.serve_forever()
EOF
python3 "$W/stub.py" "$W/port" &
STUB_PID=$!
for _ in $(seq 50); do [[ -s "$W/port" ]] && break; sleep 0.1; done
URL="http://127.0.0.1:$(cat "$W/port")"

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

hz() { "$HZ" --server "$URL" "$@"; }

PROSE="It is important to note that this paragraph has plenty of words in it so that it counts as prose."

printf '%s\n' "$PROSE" >"$W/prose.md"
out=$(hz -q "$W/prose.md")
check "a prose paragraph is rewritten" contains "$out" "So, it is key to note"
check "the rewrite replaces the original wording" lacks "$out" "important"

cat >"$W/structure.md" <<EOF
---
title: it is important to keep front matter
---

# A heading that is important and long enough to be prose if it were

\`\`\`python
print("important code stays")  # it is important to keep this line as it is
\`\`\`

| column a | column b |
| -------- | -------- |

- a list item that is important and long enough to be considered but must stay as is

> a quote that is important and long enough to be considered but must stay as is

Short line here.

$PROSE
EOF
out=$(hz -q "$W/structure.md")
check "front matter passes through" contains "$out" "title: it is important to keep front matter"
check "headings pass through" contains "$out" "# A heading that is important"
check "code fences pass through" contains "$out" 'print("important code stays")'
check "tables pass through" contains "$out" "| column a | column b |"
check "lists pass through" contains "$out" "- a list item that is important"
check "quotes pass through" contains "$out" "> a quote that is important"
check "short lines pass through" contains "$out" "Short line here."
check "only the prose paragraph changed" contains "$out" "So, it is key to note"

printf '• a bullet marked with a dot that is important and long enough to be considered but must stay as is\n' >"$W/dot.md"
check "dot bullets pass through" equals "$(hz -q "$W/dot.md")" "$(cat "$W/dot.md")"

hz -q --report "$W/report.jsonl" "$W/prose.md" >/dev/null
check "--report records before, after and status" contains "$(cat "$W/report.jsonl")" '"status": "rewritten"'

printf 'Date: 2026-06-10\nStatus: design, approved direction, not yet implemented here\n' >"$W/fields.md"
check "key: value header lines pass through untouched" equals "$(hz -q "$W/fields.md")" "$(cat "$W/fields.md")"

printf 'It is important to note that this\nparagraph is wrapped over several\nlines and is long enough to count.\n' >"$W/wrapped.md"
out=$(hz -q "$W/wrapped.md")
check "a wrapped paragraph becomes one line" test "$(wc --lines <<<"$out")" -eq 1

printf 'DROPNUM it is important to note that we measured 1,594 tokens per second on the RTX card today.\n' >"$W/drop.md"
out=$(hz -q "$W/drop.md")
check "a candidate that loses a number is skipped for the next" contains "$out" "1,594"
check "and the good candidate is used" contains "$out" "key"
printf 'DROPNUM again it is important to note that we measured 7,001 tokens per second on the RTX card.\n' >"$W/drop1.md"
out=$(hz -q --tries 1 "$W/drop1.md")
check "with one try the bad candidate is rejected and the original kept" contains "$out" "important"
check "and the original number is still there" contains "$out" "7,001"

printf 'ALWAYSBAD it is important to note that we counted 42 widgets in total with plenty of other words.\n' >"$W/bad.md"
out=$(hz -q "$W/bad.md")
check "when every candidate loses a fact the paragraph is kept verbatim" contains "$out" "ALWAYSBAD it is important"
summary=$(hz "$W/bad.md" 2>&1 >/dev/null)
check "the summary reports it was kept by the fact check" contains "$summary" "1 kept by the fact check"

printf 'QUOTEWRAP it is important to note that the model wraps this whole paragraph in quotation marks.\n' >"$W/quote.md"
check "a rewrite wrapped in quotes is rejected and the original kept" contains "$(hz -q "$W/quote.md")" "QUOTEWRAP it is important"

printf 'BOLDSTRIP it is important to note that the model drops the **bold marker** from this whole paragraph.\n' >"$W/bold.md"
check "a rewrite that strips markdown emphasis is rejected" contains "$(hz -q "$W/bold.md")" "**bold marker**"

printf 'It is important to note that this **bold marker** paragraph keeps its emphasis through the rewrite today.\n' >"$W/bold2.md"
check "emphasis that survives is accepted" contains "$(hz -q "$W/bold2.md")" "**bold marker**"

printf "CURLYQ it is important to note that the repo's old name is kept by the script for this whole paragraph.\n" >"$W/curly.md"
check "typographic apostrophes are turned back into straight ones" contains "$(hz -q "$W/curly.md")" "repo's"

printf 'SAMEPARA it is important to note this paragraph comes back from the model without any change at all.\n' >"$W/same.md"
summary=$(hz "$W/same.md" 2>&1 >/dev/null)
check "an unchanged rewrite is reported as unchanged" contains "$summary" "1 unchanged"

printf 'See https://example.com/a-b for the `humanize --tries` option and 3.5 percent of cases in total today.\n' >"$W/facts.md"
out=$(hz -q "$W/facts.md")
check "urls, code spans and decimals survive" contains "$out" "https://example.com/a-b"

cp "$W/prose.md" "$W/inplace.md"
hz -q -i "$W/inplace.md"
check "in place keeps a .bak identical to the original" cmp --silent "$W/inplace.md.bak" "$W/prose.md"
check "in place rewrites the file" contains "$(cat "$W/inplace.md")" "So, it is key"

check "stdin to stdout works" contains "$(hz -q <"$W/prose.md")" "So, it is key"
check "--diff shows the changes" contains "$(hz -q --diff "$W/prose.md")" "key"
check "a document with no prose is passed through without a server" equals "$("$HZ" --server http://127.0.0.1:1 -q <<<'# only a heading')" "# only a heading"

"$HZ" --server http://127.0.0.1:1 -q "$W/prose.md" >/dev/null 2>&1
check "an unreachable server exits with code 3" equals "$?" "3"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
