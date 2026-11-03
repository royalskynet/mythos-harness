#!/usr/bin/env bash
# 驗收：bin/dispatch 路由只看難度（11-02 使用者定，不分急緩）：easy／mid→dcq 派of（free）、hard→deep；舊第四參數照收不理。
set -euo pipefail

SRC="$(cd "$(dirname "$0")/../bin" && pwd)/dispatch"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# dispatch 用自己的位置找 bin/dispatch-deep-run，所以整支搬進假目錄
mkdir -p "$TMP/m/bin"
cp "$SRC" "$TMP/m/bin/dispatch"
cat > "$TMP/m/bin/dispatch-deep-run" <<EOS
#!/usr/bin/env bash
echo "\$1" >> "$TMP/deep.log"
EOS
cat > "$TMP/dcq" <<EOS
#!/usr/bin/env bash
[ "\$1" = add ] && { echo "add order=\${DCQ_ORDER:-unset} tier=\$4" >> "$TMP/dcq.log"; echo job-\$\$; }
exit 0
EOS
chmod +x "$TMP/m/bin/"* "$TMP/dcq"
echo '# t' > "$TMP/task.md"

run() { : > "$TMP/dcq.log"; : > "$TMP/deep.log"
  MYTHOS_DIR="$TMP/m" DCQ_BIN="$TMP/dcq" bash "$TMP/m/bin/dispatch" "$TMP/task.md" "$TMP" "$@" >/dev/null
  sleep 0.3  # deep 走 nohup 背景
}

run easy;        grep -q 'order=free tier=easy' "$TMP/dcq.log" || fail "easy 應走 dcq free：$(cat "$TMP/dcq.log")"
run mid;         grep -q 'order=free tier=mid' "$TMP/dcq.log" || fail "mid 應走 dcq free：$(cat "$TMP/dcq.log")"
[ "$(tail -1 "$TMP/m/state/dispatch-jobs.tsv" | cut -f6)" = "$TMP" ] || fail "O 列要記 cwd（第 6 欄），dispatch-retry 才重派得了"
[ -s "$TMP/deep.log" ] && fail "mid 不該叫 deep"
run hard;        [ -s "$TMP/deep.log" ] || fail "hard 應走 deep"
[ -s "$TMP/dcq.log" ] && fail "hard 不該進 dcq"
run mid urgent;  grep -q 'order=free tier=mid' "$TMP/dcq.log" || fail "舊第四參數 urgent 應被忽略"
run hard later;  [ -s "$TMP/deep.log" ] || fail "舊第四參數 later 應被忽略"

set +e
MYTHOS_DIR="$TMP/m" DCQ_BIN="$TMP/dcq" bash "$TMP/m/bin/dispatch" "$TMP/task.md" "$TMP" huge >/dev/null 2>&1
rc=$?
set -e
[ "$rc" = 2 ] || fail "不認得的難度應 exit 2，得到 $rc"

echo "DISPATCH-ROUTE PASS"
