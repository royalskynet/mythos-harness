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
. "$(dirname "$0")/lib-test-guard.sh" "$TMP"  # F1：自己的 stub 設好之後才 source；沒設的 runner／tmux 換 guard stub
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

# ---------- 以下每段換一個乾淨的 MYTHOS_DIR，ledger 內容完全由本段決定 ----------
section() { # 名稱 → 換 MYTHOS_DIR／TSV，清 stub 紀錄
  export MYTHOS_DIR="$TMP/$1/mythos"
  TSV="$MYTHOS_DIR/state/dispatch-jobs.tsv"
  mkdir -p "$MYTHOS_DIR/state/deep"
}
row() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" hard "$TMP/$1.md" "$2" "$3" "$4" - deep >> "$TSV"; }
epoch_of() { awk -F'\t' -v id="$1" '$1 == id { print $4; exit }' "$TSV"; }
for r in C D E F G; do mkdir -p "$TMP/repo$r"; git -C "$TMP/repo$r" init -q; done
NOW="$(date +%s)"

# 6) F8：一次真升級，非目標列原文不變。升級前放 cancelled、notified-PASS、本輪排不進去的 queued、dcq 列。
section f8
row c-done $((NOW - 50)) pending "$TMP/repoC"; printf '0\n' > "$MYTHOS_DIR/state/deep/c-done.rc"
row c-target $((NOW - 40)) queued "$TMP/repoC"
row c-cxl $((NOW - 30)) cancelled "$TMP/repoC"
row c-noti $((NOW - 30)) notified-PASS "$TMP/repoC"
row d-run $((NOW - 20)) pending "$TMP/repoD"; printf 'fixture=1\n' > "$MYTHOS_DIR/state/deep/d-run.handle"
row d-wait $((NOW - 10)) queued "$TMP/repoD"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' o-1 mid "$TMP/o.md" "$NOW" pending "$TMP" - dcq >> "$TSV"
cp -R "$MYTHOS_DIR" "$TMP/f8/snapshot"
before="$TMP/f8/before.tsv"; cp "$TSV" "$before"
nontarget() { # $1 ledger → 印出 before 裡非目標列中，在 $1 找不到原文的列
  grep -v '^c-target	' "$before" | while IFS= read -r line; do grep -qxF -- "$line" "$1" || printf '%s\n' "$line"; done
}
: > "$STUB_LOG"
watch
track
[ "$(status_of c-target)" = pending ] || fail "6：c-target 沒被升級：$(status_of c-target)"
[ "$(started c-target)" = 1 ] || fail '6：c-target 沒被拉起 runner'
[ "$(status_of d-wait)" = queued ] || fail "6：被 d-run 擋住的 d-wait 被升級了：$(status_of d-wait)"
m="$(nontarget "$TSV")"
[ -z "$m" ] || fail "6：升級時改到了非目標列：$(printf '%s\n' "$m" | sed -n l)"
awk -F'\t' 'NF != 8 { bad=1 } END { exit bad }' "$TSV" || fail "6：ledger 不再是 8 欄 tab 分隔：$(sed -n l "$TSV")"
# 突變：dispatch-watch 的 promote_rows 改成「每列都設 pending」，同一份 ledger 真跑一輪，逐列比對必須抓到
MUT="$H/mut"; mkdir -p "$MUT"
ln -sf "$ROOT/bin/lib-ledger.sh" "$MUT/lib-ledger.sh"; ln -sf "$ROOT/bin/lib-events.mjs" "$MUT/lib-events.mjs"
[ "$(grep -cx '# end promote_rows' "$ROOT/bin/dispatch-watch")" = 1 ] || fail '6：dispatch-watch 找不到 promote_rows 結尾標記，突變做不了'
awk '{ print } $0 == "# end promote_rows" {
  print "promote_rows() { awk -F\"\\t\" -v now=\"$3\" '"'"'BEGIN { OFS=\"\\t\" } NR==FNR { next } { NF=8; $5=\"pending\"; $4=now } { print }'"'"' \"$1\" \"$2\"; }"
}' "$ROOT/bin/dispatch-watch" > "$MUT/dispatch-watch"
cmp -s "$ROOT/bin/dispatch-watch" "$MUT/dispatch-watch" && fail '6：突變沒生效'
rm -rf "$MYTHOS_DIR"; cp -R "$TMP/f8/snapshot" "$MYTHOS_DIR"
bash "$MUT/dispatch-watch" 9>&- || true
track
[ "$(status_of c-cxl)" = pending ] || fail "6：突變版沒把 cancelled 改成 pending，突變本身沒生效：$(status_of c-cxl)"
m="$(nontarget "$TSV")"
[ -n "$m" ] || fail '6：突變版（無條件全部 pending）也通過逐列比對，測試抓不到'

# 7) F4：A 已寫 rc、B queued，watcher 還沒跑時派 C → C 也 queued；跑 watcher → 先拉起 B
section f4
: > "$TMP/tE-a.md"; : > "$TMP/tE-b.md"; : > "$TMP/tE-c.md"
: > "$STUB_LOG"
ida="$(dispatch "$TMP/tE-a.md" "$TMP/repoE")"
idb="$(dispatch "$TMP/tE-b.md" "$TMP/repoE")"
track
[ "$(status_of "$idb")" = queued ] || fail "7：B 不是 queued：$(status_of "$idb")"
printf '0\n' > "$MYTHOS_DIR/state/deep/$ida.rc"
idc="$(dispatch "$TMP/tE-c.md" "$TMP/repoE")"
track
[ "$(status_of "$idc")" = queued ] || fail "7：A 落地、B 還在排，C 卻插隊：$(status_of "$idc")"
[ "$(started "$idc")" = 0 ] || fail '7：插隊的 C 啟動了 runner'
watch
track
[ "$(status_of "$idb")" = pending ] || fail "7：watcher 沒先拉起 B：$(status_of "$idb")"
[ "$(started "$idb")" = 1 ] || fail '7：B 沒啟動 runner'
[ "$(status_of "$idc")" = queued ] || fail "7：C 跟 B 同輪被拉起：$(status_of "$idc")"
[ "$(started "$idc")" = 0 ] || fail '7：C 跟 B 同輪啟動了 runner'

# 8) F2：runner 直接 exit 1、不寫 handle → 未逾 DEEP_HANDOFF_SEC 不動；逾時一輪只寫 rc=127＋handoff，
#    ledger 不改、由第 1 步出 FAIL（extra 帶原因），同 repo 的 queued 同一輪被拉起。寫不了（events 目錄唯讀）下輪可重掃。
section f3
printf '#!/bin/sh\nexit 1\n' > "$H/dead-runner"; chmod +x "$H/dead-runner"
: > "$TMP/tF-a.md"; : > "$TMP/tF-b.md"
: > "$STUB_LOG"
ida="$(DISPATCH_DEEP_RUN_BIN="$H/dead-runner" dispatch "$TMP/tF-a.md" "$TMP/repoF")"
idb="$(dispatch "$TMP/tF-b.md" "$TMP/repoF")"
[ "$(status_of "$ida")" = pending ] || fail "8：A 不是 pending：$(status_of "$ida")"
[ "$(status_of "$idb")" = queued ] || fail "8：B 不是 queued：$(status_of "$idb")"
watch
[ "$(status_of "$ida")" = pending ] || fail "8：還沒逾 DEEP_HANDOFF_SEC 就被收成：$(status_of "$ida")"
old=$(( $(date +%s) - 121 ))
awk -v id="$ida" -v t="$old" -F'\t' 'BEGIN{OFS="\t"} $1==id { $4=t } { print }' "$TSV" > "$TSV.k" && mv "$TSV.k" "$TSV"
watch
track
[ "$(tr -d '[:space:]' < "$MYTHOS_DIR/state/deep/$ida.rc")" = 127 ] || fail '8：rc 不是 127'
case "$(status_of "$ida")" in pending|failed) ;; *) fail "8：A 列狀態不是 pending 也不是 failed：$(status_of "$ida")" ;; esac
fail_n="$(jq -s --arg id "$ida" '[.[] | select(.job_id==$id and .status=="FAIL")] | length' "$MYTHOS_DIR/state/events.jsonl")"
[ "$fail_n" = 1 ] || fail "8：沒有正好一則 FAIL 事件：$(cat "$MYTHOS_DIR/state/events.jsonl" 2>&1)"
jq -e --arg id "$ida" 'select(.job_id==$id and .status=="FAIL" and (.extra | contains("runner 未啟動")))' "$MYTHOS_DIR/state/events.jsonl" >/dev/null \
  || fail "8：FAIL 的 extra 沒帶 runner 未啟動：$(cat "$MYTHOS_DIR/state/events.jsonl" 2>&1)"
[ "$(status_of "$idb")" = pending ] || fail "8：A 釋放後 B 沒被拉起：$(status_of "$idb")"
[ "$(started "$idb")" = 1 ] || fail '8：B 沒啟動 runner'
watch
[ "$(jq -s --arg id "$ida" '[.[] | select(.job_id==$id)] | length' "$MYTHOS_DIR/state/events.jsonl")" = 1 ] || fail '8：failed 的票下一輪又發事件'

# 8b) 寫不了就不能吞掉（可重掃）：state 在、deep 子目錄不存在且建不了 → 一輪不動（連 rc 都沒寫）；
#     恢復可寫 → 下一輪就寫 rc=127＋handoff 並出 FAIL 事件
section f3b
printf '#!/bin/sh\nexit 1\n' > "$H/dead2-runner"; chmod +x "$H/dead2-runner"
: > "$TMP/tG-a.md"
idh="$(DISPATCH_DEEP_RUN_BIN="$H/dead2-runner" dispatch "$TMP/tG-a.md" "$TMP/repoH")"
old=$(( $(date +%s) - 121 ))
awk -v id="$idh" -v t="$old" -F'\t' 'BEGIN{OFS="\t"} $1==id { $4=t } { print }' "$TSV" > "$TSV.k" && mv "$TSV.k" "$TSV"
rmdir "$MYTHOS_DIR/state/deep" && chmod 0555 "$MYTHOS_DIR/state" || fail '8b：準備唯讀環境失敗'
watch
[ ! -d "$MYTHOS_DIR/state/deep" ] || fail '8b：寫不了卻建出了 state/deep'
jq -e --arg id "$idh" 'select(.job_id==$id)' "$MYTHOS_DIR/state/events.jsonl" >/dev/null 2>&1 && fail '8b：寫不了卻有事件'
chmod 0755 "$MYTHOS_DIR/state"
watch
jq -e --arg id "$idh" 'select(.job_id==$id and .status=="FAIL")' "$MYTHOS_DIR/state/events.jsonl" >/dev/null \
  || fail "8b：恢復可寫後下一輪沒出 FAIL：$(cat "$MYTHOS_DIR/state/events.jsonl" 2>&1)"

# 8c) F1：票已落地（rc 已寫／ledger 列非 pending）→ 遲到的 runner 不啟動、不寫 handle
printf '#!/bin/sh\necho "$*" >> "%s"
' "$STUB_LOG" > "$H/late-runner"; chmod +x "$H/late-runner"
: > "$TMP/tG-b.md"
section f1
n0="$(wc -l < "$STUB_LOG" | tr -d ' ')"
printf '0\n' > "$MYTHOS_DIR/state/deep/land-rc.rc"
MYTHOS_DIR="$MYTHOS_DIR" DEEP_RUN_BIN="$H/late-runner" bash "$ROOT/bin/dispatch-deep-run" land-rc "$TMP/tG-b.md" "$TMP/repoH" 2>"$H/late.err" || fail "8c：rc 已存在時 runner 非零退出：$(cat "$H/late.err")"
[ "$(wc -l < "$STUB_LOG" | tr -d ' ')" = "$n0" ] || fail '8c：rc 已存在卻還是呼叫了 deep-run'
[ ! -f "$MYTHOS_DIR/state/deep/land-rc.handle" ] || fail '8c：rc 已存在卻寫了 handle'
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' land-fail hard "$TMP/tG-b.md" "$(date +%s)" failed "$TMP/repoH" - deep >> "$TSV"
MYTHOS_DIR="$MYTHOS_DIR" DEEP_RUN_BIN="$H/late-runner" bash "$ROOT/bin/dispatch-deep-run" land-fail "$TMP/tG-b.md" "$TMP/repoH" 2>"$H/late.err" || fail "8c：列 failed 時 runner 非零退出：$(cat "$H/late.err")"
[ "$(wc -l < "$STUB_LOG" | tr -d ' ')" = "$n0" ] || fail '8c：列 failed 卻還是呼叫了 deep-run'
[ ! -f "$MYTHOS_DIR/state/deep/land-fail.handle" ] || fail '8c：列 failed 卻寫了 handle'

# 9) F5：入列 7 小時的 queued 升級 → epoch 改成升級當下；dispatch-watch 不發 REVIEW、watchdog 不告警 pending 逾 6 小時
section f5
row g-done $((NOW - 25300)) pending "$TMP/repoG"; printf '0\n' > "$MYTHOS_DIR/state/deep/g-done.rc"
row g-q $((NOW - 25200)) queued "$TMP/repoG"
: > "$STUB_LOG"
t0="$(date +%s)"
watch
track
[ "$(status_of g-q)" = pending ] || fail "9：g-q 沒被升級：$(status_of g-q)"
[ "$(epoch_of g-q)" -ge "$t0" ] || fail "9：升級後 epoch 還是入列時間：$(epoch_of g-q)"
jq -e 'select(.job_id=="g-q" and .status=="REVIEW")' "$MYTHOS_DIR/state/events.jsonl" >/dev/null 2>&1 && fail '9：剛升級就發 REVIEW'
rm -rf "$H/brief"
MYTHOS_BRIEF_DIR="$H/brief" WATCHDOG_CLAUDE_BIN="$H/true" WATCHDOG_LLM_LEGS="$H/false" WATCHDOG_SCRUB_CMD="$H/false" \
  WATCHDOG_CANARY_CMD="$H/true" WATCHDOG_LLM_TIMEOUT_S=3 bash "$ROOT/bin/watchdog" >/dev/null 2>&1 || true
grep -F 'g-q' "$H/brief/mythos-watchdog.tsv" 2>/dev/null | grep -q '卡在 pending' && fail '9：剛升級的票被當成 pending 逾 6 小時'
# 對照：同一份 watchdog 對真的老 pending 會告警（確認上一行不是因為 watchdog 沒跑）
row g-old $((NOW - 25200)) pending "$TMP/repoC"; printf 'fixture=1\n' > "$MYTHOS_DIR/state/deep/g-old.handle"
rm -rf "$H/brief"
MYTHOS_BRIEF_DIR="$H/brief" WATCHDOG_CLAUDE_BIN="$H/true" WATCHDOG_LLM_LEGS="$H/false" WATCHDOG_SCRUB_CMD="$H/false" \
  WATCHDOG_CANARY_CMD="$H/true" WATCHDOG_LLM_TIMEOUT_S=3 bash "$ROOT/bin/watchdog" >/dev/null 2>&1 || true
grep -F 'g-old' "$H/brief/mythos-watchdog.tsv" 2>/dev/null | grep -q '卡在 pending' || fail "9：對照組老 pending 沒告警，上面的斷言無效：$(cat "$H/brief/mythos-watchdog.tsv" 2>&1)"

echo 'REPO-QUEUE PASS'
