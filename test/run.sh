#!/bin/sh
# Converter test: convert the fixture journals, diff against the expected turns, validate
# with funes itself when a binary is on PATH, then smoke setup add/remove against a
# sandboxed JCODE_HOME and FUNES_HOME.
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

js=
for c in node bun; do
    command -v "$c" >/dev/null 2>&1 && { js=$c; break; }
done
[ -n "$js" ] || { echo "no JS runtime on PATH" >&2; exit 1; }

"$js" "$HERE/../convert.mjs" "$HERE/fixture" "$TMP/out"

SID=session_fox_1000000000000_abcdef
diff -u "$HERE/expected.funes.jsonl" "$TMP/out/$SID.funes.jsonl"
if ls "$TMP/out" | grep -q canary; then echo "debug session produced a file" >&2; exit 1; fi

# A re-run is a no-op: identical content is not rewritten.
before=$(stat -f %m "$TMP/out/$SID.funes.jsonl")
sleep 1
"$js" "$HERE/../convert.mjs" "$HERE/fixture" "$TMP/out" >/dev/null
after=$(stat -f %m "$TMP/out/$SID.funes.jsonl")
[ "$before" = "$after" ] || { echo "unchanged session was rewritten" >&2; exit 1; }

if command -v funes >/dev/null 2>&1; then
    funes index --check "$TMP/out"
fi

# setup add/remove against a fake jcode home holding one journal.
export FUNES_HOME="$TMP/funes" FUNES_AGENT_ID=jcode FUNES_BIN=funes
export JCODE_HOME="$TMP/jcode"

# Installed as funes installs it: a copy in the agents dir, so the state files setup writes
# beside itself never land in the checkout, even when an assertion fails before setup remove.
BUNDLE="$FUNES_HOME/agents/jcode"
mkdir -p "$BUNDLE"
(cd "$HERE/.." && tar -cf - --exclude .git .) | (cd "$BUNDLE" && tar -xf -)

mkdir -p "$JCODE_HOME/sessions"
cp "$HERE/fixture/$SID.journal.jsonl" "$JCODE_HOME/sessions/"
cat >"$JCODE_HOME/config.toml" <<'EOF'
[keybindings]
scroll_up = "ctrl+k"

[hooks]
pre_tool_timeout_ms = 5000
turn_end = "~/bin/notify-me"
EOF
printf '{}' >"$JCODE_HOME/mcp.json"

sh "$BUNDLE/setup" add 0x7067/funes-memory

grep -q '"funes"' "$JCODE_HOME/mcp.json" || { echo "MCP server not registered" >&2; exit 1; }
grep -q 'turn_end = .*funes.sh' "$JCODE_HOME/config.toml" || { echo "turn_end not wired" >&2; exit 1; }
grep -q 'session_end = .*funes.sh' "$JCODE_HOME/config.toml" || { echo "session_end not wired" >&2; exit 1; }
grep -q 'notify-me' "$BUNDLE/previous/turn_end" || { echo "previous hook not recorded" >&2; exit 1; }
[ -f "$FUNES_HOME/spool/jcode/$SID.funes.jsonl" ] || { echo "seed did not convert" >&2; exit 1; }

grep -q 'HF_HUB_USER_AGENT_ORIGIN.*funes; agent/jcode' "$JCODE_HOME/mcp.json" || { echo "MCP server not tagged" >&2; exit 1; }

mkdir -p "$TMP/bin"
cat >"$TMP/bin/funes" <<'FAKE'
#!/bin/sh
printf '%s|%s: %s\n' "${HF_HUB_USER_AGENT_ORIGIN:-}" "${JOB_TOKEN:-}" "$*" >>"$FUNES_TEST_CLI_LOG"
FAKE
printf '#!/bin/sh\necho "jcode v9.9.9 (abc)"\n' >"$TMP/bin/jcode"
chmod +x "$TMP/bin/funes" "$TMP/bin/jcode"
export FUNES_TEST_CLI_LOG="$TMP/cli.log"
PATH="$TMP/bin:$PATH" HF_HUB_USER_AGENT_ORIGIN=mine JOB_TOKEN=abc FUNES_HOOK_UNSET="JOB_TOKEN" \
    JCODE_HOOK_EVENT=turn_end sh "$BUNDLE/hooks/funes.sh"
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$FUNES_TEST_CLI_LOG" ] && break; sleep 0.5; done
expected="mine; funes; agent/jcode; agent_version/9.9.9|: index --harness jcode"
[ "$(cat "$FUNES_TEST_CLI_LOG")" = "$expected" ] || { echo "funes was asked: $(cat "$FUNES_TEST_CLI_LOG")" >&2; exit 1; }

sh "$BUNDLE/setup" remove
! grep -q '"funes"' "$JCODE_HOME/mcp.json" || { echo "MCP server left behind" >&2; exit 1; }
grep -q 'turn_end = .*notify-me' "$JCODE_HOME/config.toml" || { echo "previous hook not restored" >&2; exit 1; }
! grep -q 'session_end' "$JCODE_HOME/config.toml" || { echo "session_end left behind" >&2; exit 1; }
[ ! -d "$FUNES_HOME/spool/jcode" ] || { echo "spool not removed" >&2; exit 1; }

echo "ok"
