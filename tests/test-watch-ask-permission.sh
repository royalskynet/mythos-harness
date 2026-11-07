#!/usr/bin/env bash
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/watch-ask.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export MYTHOS_DIR="$TMP/mythos"
export DCQ_HOME="$TMP/dcq"
export TMUX_BIN="$TMP/tmux"
export TMUX_LOG="$TMP/tmux.log"
export MYTHOS_TRANSCRIPT_DIR="$TMP/router-transcript"
export CLAUDE_PROJECTS_DIR="$TMP/projects"
export CLAUDE_BIN="$TMP/claude"
export FAKE_AGENTS="$TMP/agents.json"
export STOP_RC="$TMP/stop.rc"
export CLAUDE_LOG="$TMP/claude.log"
export BG_AUTOHEAL=0  # 本檔驗舊路徑（事件交 Router）；自癒另見 test-bg-autoheal.sh
# stub 只做自己那件事、不 cat 任何會讀 stdin 的東西：watch 的 while-read 迴圈會把還沒讀的行交給子行程
cat > "$CLAUDE_BIN" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$CLAUDE_LOG"
case "$1" in
  agents) tr -d '\n' < "$FAKE_AGENTS"; printf '\n' ;;
  logs) printf 'log tail for %s\nsecond line\n' "$2" ;;
  stop) printf 'stopped %s\n' "$2"; exit "$(cat "$STOP_RC" 2>/dev/null || echo 0)" ;;
esac
exit 0
STUB
chmod +x "$CLAUDE_BIN"
. "$(dirname "$0")/lib-test-guard.sh" "$TMP"  # F1：自己的 stub 設好之後才 source
cat > "$TMP/tgsend.mjs" <<'STUB'
(await import("node:fs")).appendFileSync(process.env.TMP + "/tg.sent", "x\n"); process.stdin.resume();
process.exit(0);
STUB
export TG_SEND_BIN="$TMP/tgsend.mjs"
_guard_var BRIEF_BIN

cat > "$TMUX_BIN" <<'TMUX'
#!/bin/sh
printf '%s\n' "$*" >> "$TMUX_LOG"
case " $* " in
  " -L mythos send-keys -t mythos -l "*) esc="$(printf '%s' "$8" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
    printf '{"type":"user","message":{"role":"user","content":"%s"}}\n' "$esc" >> "$MYTHOS_TRANSCRIPT_DIR/router.jsonl" ;;
esac
case " $* " in *" capture-pane "*) echo 'idle screen' ;; esac
exit 0
TMUX
chmod +x "$TMUX_BIN"

mkdir -p "$MYTHOS_DIR/state/bg" "$MYTHOS_TRANSCRIPT_DIR" "$CLAUDE_PROJECTS_DIR"
printf '%s\n' '{"type":"user","message":{"content":"hi"}}' > "$MYTHOS_TRANSCRIPT_DIR/router.jsonl"
TSV="$MYTHOS_DIR/state/dispatch-jobs.tsv"
fail() { echo "FAIL: $*" >&2; exit 1; }
row() { # id backend epoch [status]
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" mid "$TMP/p.md" "$3" "${4:-pending}" "$TMP/worker" t-x "$2" >> "$TSV"
}
status_of() { awk -F "$(printf '\t')" -v i="$1" '$1==i {print $5; exit}' "$TSV"; }
agents() { # session 前綴 state…
  local out='[' sep='' p s
  while [ $# -gt 1 ]; do
    p="$1"; s="$2"; shift 2
    out="$out$sep{\"sessionId\":\"$p-1111-2222-3333-444455556666\",\"kind\":\"background\",\"state\":\"$s\"}"; sep=','
  done
  printf '%s]' "$out" > "$FAKE_AGENTS"
}
events() { [ -f "$MYTHOS_DIR/state/events.jsonl" ] && cat "$MYTHOS_DIR/state/events.jsonl"; }
export TMP

# 摘要含請示句（11-07 15:5x「要我再查一次嗎？」「回一句就好」）→ 不直發，事件交 Router（Router reply 有 ASK_PERMISSION 閘）
row bg-ask00001 bg "$(date +%s)"
printf 'thread=t-x\n摘要：\n都好了。\n要改成免費優先，回一句就好。\n---細節---\nx\n' > "$MYTHOS_DIR/state/bg/ask00001.result"
agents ask00001 done
bash "$ROOT/bin/dispatch-watch" 9>&- || fail 'ask：非零退出'
[ ! -s "$TMP/tg.sent" ] || fail 'ask：含請示句的摘要被直發了'
grep -q 'event_id=bg-ask00001-PASS' "$TMUX_LOG" || fail "ask：沒交 Router：$(cat "$TMUX_LOG")"
echo '(ask) ok'

# 對照：一般摘要照常直發
: > "$TMUX_LOG"
row bg-plain0001 bg "$(date +%s)"
printf 'thread=t-x\n摘要：\n都好了，今天結案 35 件。\n---細節---\nx\n' > "$MYTHOS_DIR/state/bg/plain0001.result"
agents plain0001 done
bash "$ROOT/bin/dispatch-watch" 9>&- || fail 'plain：非零退出'
[ -s "$TMP/tg.sent" ] || fail 'plain：一般摘要沒直發'
echo '(plain) ok'
echo WATCH-ASK PASS
