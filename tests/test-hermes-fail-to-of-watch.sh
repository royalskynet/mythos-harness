#!/usr/bin/env bash
# 11-08：hermes worker 結束碼非 0（結果檔空）→ dispatch-watch 先呼叫 DISPATCH_RETRY_BIN（轉派 of）。
#   轉派成功 → 靜默（不出 FAIL 事件，log 記「hermes 全失敗，靜默重派 of」）；轉派失敗 → 出 FAIL 事件。
# 全程在 mktemp 沙箱：不碰真的 ~/.hermes、不打 TG。
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/hermes-f2of.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export MYTHOS_DIR="$TMP/mythos"
export BRIEF_LINES_DIR="$TMP/brief"
export DCQ_HOME="$TMP/dcq"
export MYTHOS_WORKER_DIR="$TMP/worker"
export MYTHOS_WORKER_DB="$TMP/no-such-state.db"   # worker-latency 不讀真的 ~/.hermes 庫
export MYTHOS_TRANSCRIPT_DIR="$TMP/rt"
export CLAUDE_PROJECTS_DIR="$TMP/projects"
export CLAUDE_BIN="$TMP/claude"
export TG_SEND_BIN="$TMP/tg-stub"
export TG_LOG="$TMP/tg.log"
export DISPATCH_RETRY_BIN="$TMP/retry"
export RETRY_LOG="$TMP/retry.log"
export RETRY_OK_ID="bg-ffff0001"                  # 只有這一列的轉派會成功（exit 0），另一列 exit 1
export BG_AUTOHEAL=0
export CTX_GUARD_OFF=1
mkdir -p "$MYTHOS_DIR/state/bg" "$MYTHOS_DIR/logs" "$DCQ_HOME" "$MYTHOS_WORKER_DIR" "$MYTHOS_TRANSCRIPT_DIR" "$CLAUDE_PROJECTS_DIR"
printf '%s\n' '{"type":"user","message":{"content":"hi"}}' > "$MYTHOS_TRANSCRIPT_DIR/router.jsonl"
printf '#!/bin/sh\nexit 0\n' > "$CLAUDE_BIN"; chmod +x "$CLAUDE_BIN"
printf '#!/bin/sh\necho "$*" >> "%s"\nexit 0\n' "$TG_LOG" > "$TG_SEND_BIN"; chmod +x "$TG_SEND_BIN"
cat > "$DISPATCH_RETRY_BIN" <<'STUB'
#!/bin/sh
echo "retry $1" >> "$RETRY_LOG"
[ "$1" = "$RETRY_OK_ID" ] && exit 0
exit 1
STUB
chmod +x "$DISPATCH_RETRY_BIN"
. "$(dirname "$0")/lib-test-guard.sh" "$TMP"

TSV="$MYTHOS_DIR/state/dispatch-jobs.tsv"
EV="$MYTHOS_DIR/state/events.jsonl"
WATCH_LOG="$MYTHOS_DIR/logs/dispatch-watch.log"
fail() { echo "FAIL: $*" >&2; exit 1; }
watch() { DW_DEADLINE_ARMED=1 bash "$ROOT/bin/dispatch-watch" 9>&- >/dev/null 2>>"$TMP/dw.err" || fail 'dispatch-watch 非零退出'; }
ev_count() { # job 狀態 → 事件數
  [ -f "$EV" ] || { echo 0; return; }
  jq -s --arg id "$1" --arg st "$2" '[.[] | select(.job_id==$id and .status==$st)] | length' "$EV"
}
any_ev_count() { # job → 任何狀態的事件數
  [ -f "$EV" ] || { echo 0; return; }
  jq -s --arg id "$1" '[.[] | select(.job_id==$id)] | length' "$EV"
}

P="$MYTHOS_DIR/state/bg/t-demo.md"
printf 'thread=t-demo\n查一下 A 服務\n' > "$P"
row() { # 短id：hermes 列；結果檔空、結束碼 1
  printf 'bg-%s\tmid\t%s\t%s\tpending\t%s\tt-demo\thermes\n' "$1" "$P" "$(date +%s)" "$TMP/w" >> "$TSV"
  printf '%s\n' "$1" > "$MYTHOS_DIR/state/bg/$1.rkey"
  : > "$MYTHOS_DIR/state/bg/r-$1.result"
  printf '1\n' > "$MYTHOS_DIR/state/bg/r-$1.result.rc"
}
row ffff0001   # 轉派 of 成功 → 應靜默
row ffff0002   # 轉派 of 失敗 → 應出 FAIL
watch

grep -qx 'retry bg-ffff0001' "$RETRY_LOG" 2>/dev/null || fail "bg-ffff0001 沒先轉派 of：$(cat "$RETRY_LOG" 2>/dev/null)"
grep -qx 'retry bg-ffff0002' "$RETRY_LOG" 2>/dev/null || fail "bg-ffff0002 沒先轉派 of：$(cat "$RETRY_LOG" 2>/dev/null)"
[ "$(ev_count bg-ffff0001 FAIL)" = 0 ] || fail "轉派 of 成功卻出 FAIL 事件：$(cat "$EV")"
[ "$(any_ev_count bg-ffff0001)" = 0 ] || fail "靜默轉派不該產生任何事件：$(cat "$EV")"
grep -q '靜默重派 of：bg-ffff0001' "$WATCH_LOG" || fail "watch log 沒有「靜默重派 of」：$(cat "$WATCH_LOG" 2>/dev/null)"
[ "$(ev_count bg-ffff0002 FAIL)" = 1 ] || fail "轉派 of 失敗卻沒有 FAIL 事件：$(cat "$EV" 2>/dev/null)"
grep -q '靜默重派 of：bg-ffff0002' "$WATCH_LOG" && fail "轉派失敗的那列不該被記成靜默重派"
[ ! -s "$TG_LOG" ] || fail "不該送 TG：$(cat "$TG_LOG")"

echo 'FAIL_TO_OF_OK'
