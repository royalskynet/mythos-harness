#!/usr/bin/env bash
# 11-07：免費模型名不准寫死。bin/free-models 從 dcq 免費層讀；讀不到 → exit 1，quick／oc-free-ask 跟著失敗，不退回舊名單
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/free-models.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
. "$(dirname "$0")/lib-test-guard.sh" "$TMP"
fail() { echo "FAIL: $*" >&2; exit 1; }
export LC_ALL=C  # launchd 沒設 LANG
printf '#!/bin/sh\n[ "$1" = plan ] && [ "$DCQ_ORDER" = free ] && printf "派法 free\\n  1 免費 opencode：oc/new-a-free oc/new-b-free\\n  2 freepool：x\\n"\nexit 0\n' > "$TMP/dcq"
chmod +x "$TMP/dcq"
out="$(env -u FREE_MODELS DCQ_BIN="$TMP/dcq" "$ROOT/bin/free-models" | tr '\n' ' ')"
[ "$out" = 'oc/new-a-free oc/new-b-free ' ] || fail "解析 dcq 免費層不對：$out"
rc=0; env -u FREE_MODELS DCQ_BIN="$TMP/nope" "$ROOT/bin/free-models" > "$TMP/o" 2>/dev/null || rc=$?
[ "$rc" = 1 ] && [ ! -s "$TMP/o" ] || fail "dcq 不在應 exit 1 且不印：rc=$rc $(cat "$TMP/o")"
# quick：清單取不到 → exit 5，不去跑任何模型
printf '#!/bin/sh\necho "$*" >> "%s/oc.log"\n' "$TMP" > "$TMP/opencode"; chmod +x "$TMP/opencode"
mkdir -p "$TMP/work"  # quick 沙箱禁寫 cwd，替身的 log 要留在 cwd 外
rc=0; env -u FREE_MODELS -u QUICK_PAID DCQ_BIN="$TMP/nope" QUICK_OC="$TMP/opencode" "$ROOT/bin/quick" "$TMP" '有沒有 x' >/dev/null 2>&1 || rc=$?
[ "$rc" = 5 ] || fail "quick 清單取不到應 exit 5，得到 $rc"
[ ! -s "$TMP/oc.log" ] || fail "quick 清單取不到還跑了模型：$(cat "$TMP/oc.log")"
# quick：清單有 → 照清單順序跑，不墊付費
: > "$TMP/oc.log"
env -u FREE_MODELS -u QUICK_PAID DCQ_BIN="$TMP/dcq" QUICK_OC="$TMP/opencode" "$ROOT/bin/quick" "$TMP/work" '有沒有 x' >"$TMP/quick.out" 2>"$TMP/quick.err" || true
if grep -q "sandbox.*Operation not permitted" "$TMP/quick.err"; then
  echo "SKIP nested-sandbox"
else
[ "$(grep -o '^run -m [^ ]*' "$TMP/oc.log" | cut -d' ' -f3 | tr '\n' ' ')" = 'oc/new-a-free oc/new-b-free ' ] || fail "quick 沒照免費清單跑或墊了付費：$(cat "$TMP/oc.log")"
fi
# oc-free-ask：沒給模型且清單取不到 → exit 4（scrub 前就停）
rc=0; echo hi | env -u FREE_MODELS -u OC_FREE_ASK_MODEL DCQ_BIN="$TMP/nope" "$ROOT/bin/oc-free-ask" >/dev/null 2>&1 || rc=$?
[ "$rc" = 4 ] || fail "oc-free-ask 清單取不到應 exit 4，得到 $rc"
! grep -n -E 'beam-free|iceman-contributor' "$ROOT/bin/quick" "$ROOT/bin/oc-free-ask" "$ROOT/bin/watchdog" || fail '程式裡還有寫死的免費模型名'
echo 'FREE-MODELS PASS'
