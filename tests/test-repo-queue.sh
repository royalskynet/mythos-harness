#!/usr/bin/env bash
# 同 repo 寫入佇列（C3）驗收：同一個 git repo 同時只能有一張 deep 票在跑，其餘 queued，第一張落地後由 dispatch-watch 拉起。
# 全部用暫存 MYTHOS_DIR／DCQ_HOME／假 tmux／假 runner（DISPATCH_DEEP_RUN_BIN），不碰真的 state、tmux、dcq。
# 假 runner 只記 argv 後 exec sleep 30；背景 pid 登記到 BG_PIDS，EXIT trap 一律清掉。
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/repo-queue-test.XXXXXX")"
BG_PIDS=()
cleanup() {
  for p in ${BG_PIDS[@]+"${BG_PIDS[@]}"}; do
    for k in $(pgrep -P "$p" 2>/dev/null); do kill "$k" 2>/dev/null || true; done
    kill "$p" 2>/dev/null || true
  done
  [ -n "${KEEP:-}" ] || rm -rf "$TMP"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# stub 一律放 harness 目錄，不落進會被掃描的 MYTHOS_DIR
H="$TMP/harness"; mkdir -p "$H"
export MYTHOS_DIR="$TMP/mythos"
export DCQ_HOME="$TMP/dcq"
export CLAUDE_PROJECTS_DIR="$TMP/projects"
export MYTHOS_TRANSCRIPT_DIR="$TMP/router"
export TMUX_BIN="$H/tmux"
export DISPATCH_DEEP_RUN_BIN="$H/stub-runner"
export STUB_LOG="$H/stub.log"
export STUB_PIDS="$H/stub.pids"
export REVIEW_JUDGE="$H/no-judge"
mkdir -p "$MYTHOS_DIR/state/deep" "$DCQ_HOME/done" "$DCQ_HOME/failed" "$DCQ_HOME/running" "$DCQ_HOME/pending" \
  "$CLAUDE_PROJECTS_DIR" "$MYTHOS_TRANSCRIPT_DIR"
printf '%s\n' '{"type":"user","message":{"content":"hi"}}' > "$MYTHOS_TRANSCRIPT_DIR/router.jsonl"
printf '#!/bin/sh\necho idle\nexit 0\n' > "$TMUX_BIN"; chmod +x "$TMUX_BIN"
cat > "$DISPATCH_DEEP_RUN_BIN" <<'STUB'
#!/bin/sh
printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$STUB_LOG"
echo "$$" >> "$STUB_PIDS"
exec sleep 30
STUB
chmod +x "$DISPATCH_DEEP_RUN_BIN"
: > "$STUB_LOG"; : > "$STUB_PIDS"

TSV="$MYTHOS_DIR/state/dispatch-jobs.tsv"
ERR="$H/err"
status_of() { awk -F'\t' -v id="$1" '$1 == id { print $5; exit }' "$TSV"; }
started() { awk -F'\t' -v id="$1" '$1 == id' "$STUB_LOG" | wc -l | tr -d ' '; }
runners() { grep -c . "$STUB_PIDS" 2>/dev/null | tr -d ' '; }
dispatch() { DISPATCH_THREAD= bash "$ROOT/bin/dispatch" "$1" "$2" hard 2>"$ERR"; }
watch() { bash "$ROOT/bin/dispatch-watch" 9>&- || fail 'dispatch-watch 非零退出'; }
# 把 pid 檔裡全部的 runner 記進 cleanup
track() { while IFS= read -r p; do [ -n "$p" ] && BG_PIDS+=("$p"); done < "$STUB_PIDS"; }

for r in A B; do mkdir -p "$TMP/repo$r/sub"; git -C "$TMP/repo$r" init -q; done
: > "$TMP/tA.md"; : > "$TMP/tA2.md"; : > "$TMP/tB.md"; : > "$TMP/tB2.md"

# 1) 同一 repo 兩張（一個給子目錄）→ 第一張 pending 並啟動、第二張 queued 不啟動
id1="$(dispatch "$TMP/tA.md" "$TMP/repoA/sub")"
id2="$(dispatch "$TMP/tA2.md" "$TMP/repoA")"
track
[ "$(status_of "$id1")" = pending ] || fail "1：第一張不是 pending：$(status_of "$id1")"
[ "$(status_of "$id2")" = queued ] || fail "1：第二張不是 queued：$(status_of "$id2")"
grep -qF "已排隊：${id1}" "$ERR" || fail "1：排隊訊息沒帶第一張 id：$(cat "$ERR")"
[ "$(started "$id1")" = 1 ] || fail '1：第一張沒啟動 runner'
[ "$(started "$id2")" = 0 ] || fail '1：queued 那張被啟動了 runner'
[ "$(runners)" = 1 ] || fail "1：runner 數不是 1：$(runners)"

# 2) 第一張寫 rc=0 → 跑一輪 dispatch-watch → 第二張 pending、runner 啟動
printf '0\n' > "$MYTHOS_DIR/state/deep/$id1.rc"
watch
track
[ "$(status_of "$id2")" = pending ] || fail "2：第一張落地後第二張沒變 pending：$(status_of "$id2")"
[ "$(started "$id2")" = 1 ] || fail '2：第二張沒被拉起 runner'
[ "$(runners)" = 2 ] || fail "2：runner 數不是 2：$(runners)"
# 拉起只改那一列：其餘列狀態不動、整檔仍是 8 欄 tab 分隔（曾因 awk 沒設 OFS／s[$1] 副作用整檔變空白分隔、全改 pending）
[ "$(status_of "$id1")" = pending ] || fail "2：沒被拉起的列狀態被改：$(status_of "$id1")"
awk -F'\t' 'NF != 8 { bad=1 } END { exit bad }' "$TSV" || fail "2：ledger 不再是 8 欄 tab 分隔：$(sed -n l "$TSV")"

# 3) 不同 repo → 不排隊；同 repo 子目錄 → 排隊
id3="$(dispatch "$TMP/tB.md" "$TMP/repoB")"
[ "$(status_of "$id3")" = pending ] || fail "3：不同 repo 也被排隊：$(status_of "$id3")"
id4="$(dispatch "$TMP/tB2.md" "$TMP/repoA/sub")"
[ "$(status_of "$id4")" = queued ] || fail "3：同 repo 子目錄沒排隊：$(status_of "$id4")"
track
# 同 top 還有 pending 未落地（id2）→ 這輪不拉起 id4
watch
[ "$(status_of "$id4")" = queued ] || fail "3：同 repo 還有票在跑卻被拉起：$(status_of "$id4")"
[ "$(started "$id4")" = 0 ] || fail '3：同 repo 還有票在跑卻啟動了 runner'

# 4) cancel queued → cancelled、exit 0（沒有 handle），之後 queue 也不會拉起它
bash "$ROOT/bin/dispatch-cancel" "$id4" 2>/dev/null || fail '4：cancel queued 非零退出'
[ "$(status_of "$id4")" = cancelled ] || fail "4：cancel queued 後不是 cancelled：$(status_of "$id4")"
watch
track
[ "$(started "$id4")" = 0 ] || fail '4：cancelled 的票被 queue 拉起'

# 5) queued 逾 6 小時：watchdog 不把它算進 pending 逾時
id5="$(dispatch "$TMP/tA.md" "$TMP/repoA")"
[ "$(status_of "$id5")" = queued ] || fail "5：預期 queued：$(status_of "$id5")"
old=$(( $(date +%s) - 30000 ))
awk -v id="$id5" -v t="$old" -F'\t' 'BEGIN{OFS="\t"} $1==id { $4=t } { print }' "$TSV" > "$TSV.k" && mv "$TSV.k" "$TSV"
track
# watchdog 的外部依賴一律換成假的（不叫 claude、不叫模型、不打 scrub），只看 L0 第 4 步
printf '#!/bin/sh\nexit 0\n' > "$H/true"; chmod +x "$H/true"
printf '#!/bin/sh\nexit 1\n' > "$H/false"; chmod +x "$H/false"
MYTHOS_BRIEF_DIR="$H/brief" WATCHDOG_CLAUDE_BIN="$H/true" WATCHDOG_LLM_LEGS="$H/false" WATCHDOG_SCRUB_CMD="$H/false" \
  WATCHDOG_CANARY_CMD="$H/true" WATCHDOG_LLM_TIMEOUT_S=3 bash "$ROOT/bin/watchdog" >/dev/null 2>&1 || true
BRIEF="$H/brief/mythos-watchdog.tsv"
[ -f "$BRIEF" ] || fail '5：watchdog 沒寫出告警檔'
grep -qF "派工 $id5 queued 逾 6 小時" "$BRIEF" || fail "5：queued 逾 6 小時沒另計告警：$(cat "$BRIEF")"
grep -F "$id5" "$BRIEF" | grep -q '卡在 pending' && fail '5：queued 被當成 pending 逾時告警'

echo 'REPO-QUEUE PASS'
