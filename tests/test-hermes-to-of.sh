#!/usr/bin/env bash
# 11-08：hermes worker 模型鏈全敗 → dispatch-retry 改派 of（easy＝DCQ_ORDER=free）。假 dcq 記 env，不真的派。
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/hermes-of-test.XXXXXX")"
trap '{ [ -n "${KEEP:-}" ] || rm -rf "$TMP"; }' EXIT INT TERM
fail() { echo "FAIL: $*" >&2; exit 1; }
export MYTHOS_DIR="$TMP/mythos"
export DCQ_BIN="$TMP/dcq"
export DCQ_LOG="$TMP/dcq.log"
. "$(dirname "$0")/lib-test-guard.sh" "$TMP"
cat > "$DCQ_BIN" <<'STUB'
#!/bin/sh
if [ "$1" = add ]; then printf '%s\n' "DCQ_ORDER=${DCQ_ORDER:-unset} tier=$4 task=$2" >> "$DCQ_LOG"; echo "job-$$"; fi
exit 0
STUB
chmod +x "$DCQ_BIN"
mkdir -p "$MYTHOS_DIR/state/bg" "$TMP/worker"
: > "$DCQ_LOG"
TSV="$MYTHOS_DIR/state/dispatch-jobs.tsv"
p="$MYTHOS_DIR/state/bg/t-x-1.md"
printf '使用者原話：查一下 A 服務在不在\n' > "$p"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' bg-aaaa1111 mid "$p" 1 pending "$TMP/worker" t-x hermes > "$TSV"

bash "$ROOT/bin/dispatch-retry" bg-aaaa1111 "上一位 worker 的模型全部失敗（hermes 結束碼 1）" >/dev/null 2>"$TMP/err" || fail "retry 非零：$(cat "$TMP/err")"
[ "$(grep -c . "$DCQ_LOG")" = 1 ] || fail "dcq 應被呼叫一次：$(cat "$DCQ_LOG")"
grep -q '^DCQ_ORDER=free tier=easy ' "$DCQ_LOG" || fail "應走 of（free／easy）：$(cat "$DCQ_LOG")"
wo="$(sed -n 's/.* task=//p' "$DCQ_LOG")"
grep -q '查一下 A 服務在不在' "$wo" || fail '工單缺原任務'
grep -q '^## 驗收' "$wo" || fail '工單缺驗收段'
deep-lint "$wo" >/dev/null 2>&1 || fail "deep-lint 不過：$(deep-lint "$wo" 2>&1 | tail -3)"
( cd "$TMP/worker" && "$ROOT/bin/accept-paths-lint" "$wo" >/dev/null ) || fail 'accept-paths-lint 拒派'
# 負向對照：未動工驗收要失敗，寫了結論才過
blk="$(awk '/^```sh/{f=1;next} /^```/{f=0} f' "$wo")"
( bash -c "$blk" ) 2>/dev/null && fail '未動工驗收就過了'
res="$TMP/worker/of-results/$(printf '%s' "$blk" | sed -n 's/.*test -s //p')"
echo ok > "$res"
( bash -c "$blk" ) || fail '寫了結論驗收仍失敗'
[ "$(awk -F'\t' '$1=="bg-aaaa1111"{print $3}' "$MYTHOS_DIR/state/closeouts.tsv" 2>/dev/null)" = retried ] || fail '舊列應 closeouts=retried'
echo PASS
