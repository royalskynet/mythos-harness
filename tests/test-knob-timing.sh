#!/usr/bin/env bash
# 旋鈕時序（C1）驗收：DEEP_STALL_MIN 改了，dispatch-watch 的 STALL 時機要跟著變。
# 一張 deep pending 票、無 rc、transcript 剛寫（7 分鐘前）：
#   knobs.env 無（預設 15）→ 無 STALL；knobs.env DEEP_STALL_MIN=5 → 有 STALL。
# 突變：拿掉讀 knobs 區塊的 dispatch-watch 副本，第二條必須 fail（測試自己斷言，不靠眼睛）。
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/knob-timing-test.XXXXXX")"
trap '[ -n "${KEEP:-}" ] || rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

fresh() { # 目錄：全新 MYTHOS_DIR／transcript＋一張 7 分鐘前有進度的 deep 票
  F="$1"
  rm -rf "$F"; mkdir -p "$F/mythos/state/deep" "$F/projects" "$F/router" "$F/dcq/done" "$F/dcq/failed" "$F/dcq/running" "$F/dcq/pending"
  printf '%s\n' '{"type":"user","message":{"content":"hi"}}' > "$F/router/router.jsonl"
  # transcript 目錄＝cwd 路徑把 / 與 . 換成 -（watch 的 slug_of）
  slug="$(printf '%s' "$F/cwd" | sed 's#[/.]#-#g')"
  mkdir -p "$F/projects/$slug"
  printf '{"type":"assistant"}\n' > "$F/projects/$slug/s.jsonl"
  touch -t "$(date -v-7M +%Y%m%d%H%M)" "$F/projects/$slug/s.jsonl"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' deep-1 hard "$F/t.md" "$(date +%s)" pending "$F/cwd" - deep > "$F/mythos/state/dispatch-jobs.tsv"
}
fwatch() { # 目錄 [dispatch-watch 路徑]
  env -u DEEP_STALL_MIN -u DEEP_REVIEW_MIN MYTHOS_DIR="$1/mythos" DCQ_HOME="$1/dcq" CLAUDE_PROJECTS_DIR="$1/projects" \
    MYTHOS_TRANSCRIPT_DIR="$1/router" TMUX_BIN="$TMP/tmux" REVIEW_JUDGE="$TMP/nonexistent-judge" \
    bash "${2:-$ROOT/bin/dispatch-watch}" 9>&-
}
has_stall() { [ -f "$1/mythos/state/events.jsonl" ] && jq -e 'select(.job_id=="deep-1" and .status=="STALL")' "$1/mythos/state/events.jsonl" >/dev/null 2>&1; }

printf '#!/bin/sh\ncase " $* " in *" capture-pane "*) echo idle ;; esac\nexit 0\n' > "$TMP/tmux"; chmod +x "$TMP/tmux"

# 1) 沒 knobs：預設 15 分鐘 → 7 分鐘不算停滯
fresh "$TMP/a"
fwatch "$TMP/a" || fail '第一輪（無 knobs）非零退出'
has_stall "$TMP/a" && fail '沒改旋鈕卻發了 STALL（預設 15 分鐘）'

# 2) knobs DEEP_STALL_MIN=5 → 同一張票要 STALL
printf 'DEEP_STALL_MIN=5\n' > "$TMP/a/mythos/state/watchdog-knobs.env"
fwatch "$TMP/a" || fail '第二輪（knobs=5）非零退出'
has_stall "$TMP/a" || fail 'DEEP_STALL_MIN=5 沒發 STALL'

# 3) 突變：拿掉讀 knobs 那一段，同樣的資料第二條要 fail
#    突變版自己補回預設值（原本那行在拿掉的區塊裡）：只驗「不看 knobs」這件事。
#    lib-ledger.sh／lib-events.mjs 一起複製：少了 lib-events 事件寫不進去，突變版會「因為壞掉」而沒有 STALL（假陰性）
mkdir -p "$TMP/mut/bin"
awk '/^KNOBS_FILE=/ { skip=1 }
     skip && /^DEEP_REVIEW_MIN=/ { skip=0; print "DEEP_STALL_MIN=\"${DEEP_STALL_MIN:-15}\"" }
     !skip' "$ROOT/bin/dispatch-watch" > "$TMP/mut/bin/dispatch-watch"
cp "$ROOT/bin/lib-ledger.sh" "$ROOT/bin/lib-events.mjs" "$TMP/mut/bin/"
grep -q 'KNOBS_FILE' "$TMP/mut/bin/dispatch-watch" && fail '突變版還留著讀 knobs 的碼'
grep -q '^DEEP_STALL_MIN="${DEEP_STALL_MIN:-15}"$' "$TMP/mut/bin/dispatch-watch" || fail '突變版沒補回預設值'
# 對照：突變版本身能發 STALL（環境變數直接給 5），證明下面的「沒 STALL」是因為不讀 knobs、不是突變版壞掉
fresh "$TMP/c"
env DEEP_STALL_MIN=5 MYTHOS_DIR="$TMP/c/mythos" DCQ_HOME="$TMP/c/dcq" CLAUDE_PROJECTS_DIR="$TMP/c/projects" \
  MYTHOS_TRANSCRIPT_DIR="$TMP/c/router" TMUX_BIN="$TMP/tmux" REVIEW_JUDGE="$TMP/nonexistent-judge" \
  bash "$TMP/mut/bin/dispatch-watch" 9>&- || fail '突變版對照組非零退出'
has_stall "$TMP/c" || fail '突變版對照組（env DEEP_STALL_MIN=5）沒發 STALL：突變版本身壞了'
fresh "$TMP/b"
printf 'DEEP_STALL_MIN=5\n' > "$TMP/b/mythos/state/watchdog-knobs.env"
fwatch "$TMP/b" "$TMP/mut/bin/dispatch-watch" || fail '突變版非零退出'
has_stall "$TMP/b" && fail '突變版（不讀 knobs）竟然也發 STALL，測試沒抓到旋鈕'

echo 'KNOB-TIMING PASS'
