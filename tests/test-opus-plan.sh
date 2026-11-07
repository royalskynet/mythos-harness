#!/usr/bin/env bash
# bin/opus-plan 守門：brief 上限、假 claude 收到 --model opus 且 stdin 不是 pipe、缺 `## 驗收` 要 exit 1。
# 一律用假 claude，不碰真 Opus。
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/opus-plan-test.XXXXXX")"
[ "${KEEP:-}" = 1 ] || trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# 假 claude：記 argv、把 stdin 型態寫檔；照 $TMP/mode 寫 out.md（內容見下）
seq 1 60 > "$TMP/brief60"; seq 1 61 > "$TMP/brief61"
printf '使用者原話：修好登入\n' > "$TMP/brief"
echo good > "$TMP/mode"
# 假 claude 依格式找到 out.md 路徑（跟 bin/opus-plan 無關，這裡只驗參數與守門）
cat > "$TMP/claude" <<STUB
#!/bin/sh
printf '%s\n' "\$*" > "$TMP/argv"
if [ -p /dev/stdin ]; then echo pipe > "$TMP/stdin"; else echo not-pipe > "$TMP/stdin"; fi
[ -f "$TMP/stdin-input" ] || cat > "$TMP/stdin-input"
out=\$(printf '%s\n' "\$*" | sed -n 's|.*寫到 \([^ ]*\.md\)，.*|\1|p' | head -1)
[ -n "\$out" ] || exit 9
case "\$(cat "$TMP/mode")" in
  good) printf '# 標題\n工作目錄：/tmp\n\n## 背景\nx\n\n## 步驟\n1. y\n\n## 驗收\n\`\`\`bash\ntest -e /tmp\n\`\`\`\n預期：ok\n' > "\$out" ;;
  bad)  printf '# 標題\n工作目錄：/tmp\n\n## 步驟\n1. y\n' > "\$out" ;;
  none) ;;
esac
exit 0
STUB
chmod +x "$TMP/claude"
export OPUS_PLAN_CLAUDE_BIN="$TMP/claude"

run() { timeout 20 bash "$ROOT/bin/opus-plan" "$@" >/dev/null 2>&1 </dev/null; echo $?; }

# 1) 正常：exit 0、out.md 有 `## 驗收`、收到 --model opus、stdin 不是 pipe
[ "$(run "$TMP/brief" "$TMP/out.md")" = 0 ] || fail "正常 brief 應 exit 0"
grep -q '^## 驗收' "$TMP/out.md" || fail "out.md 缺 ## 驗收"
grep -q -- '--model opus' "$TMP/argv" || fail "沒收到 --model opus：$(cat "$TMP/argv")"
[ "$(cat "$TMP/stdin")" = not-pipe ] || fail "stdin 是 pipe，claude 可能吃行為輸入"
grep -q '修好登入' "$TMP/argv" || fail "brief 內容沒進 prompt"

# 2) 邊界：60 行收、61 行 exit 2
[ "$(run "$TMP/brief60" "$TMP/o60.md")" = 0 ] || fail "60 行 brief 應收"
[ "$(run "$TMP/brief61" "$TMP/o61.md")" = 2 ] || fail "61 行 brief 應 exit 2"
[ ! -e "$TMP/o61.md" ] || fail "拒收時不該寫 out"

# 3) 缺 `## 驗收` → exit 1
echo bad > "$TMP/mode"
[ "$(run "$TMP/brief" "$TMP/bad.md")" = 1 ] || fail "缺 ## 驗收 應 exit 1"

# 4) claude 什麼都沒寫 → exit 1
echo none > "$TMP/mode"
[ "$(run "$TMP/brief" "$TMP/none.md")" = 1 ] || fail "claude 沒寫 out 應 exit 1"

# 5) 用法錯 → exit 2
[ "$(run "$TMP/brief")" = 2 ] || fail "缺參數應 exit 2"
[ "$(run "$TMP/nope.md" "$TMP/x.md")" = 2 ] || fail "brief 不存在應 exit 2"

echo PASS
