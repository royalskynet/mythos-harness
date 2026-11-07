#!/usr/bin/env bash
# adhd-lint --truncate：Hermes 出口用的機械截斷。短訊原樣、超長 ≤220 字且帶「回「詳細」看全文」；
# tg-send 沿用同一支截斷（不再自帶一份）。
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/adhd-trunc.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
L="$ROOT/bin/adhd-lint.mjs"
strip() { printf '%s' "$1" | tr -d ' \n' | wc -m | tr -d ' '; }

# 1) 短訊原樣
out="$(printf '收到\n' | node "$L" --truncate)" || fail "短訊 exit 非 0"
[ "$out" = '收到' ] || fail "短訊被改：$out"

# 2) 超長訊息：≤220 字、含「回「詳細」看全文」
long=$(printf '已完成三件事，以下說明。\n%.0s' 1 2 3 4 5 6 7 8 9 10)
out="$(printf '%s\n' "$long" | node "$L" --truncate)" || fail "長訊 exit 非 0"
n=$(strip "$out")
[ "$n" -le 220 ] || fail "長訊沒截到 220 內：$n"
case "$out" in *'回「詳細」看全文'*) ;; *) fail "長訊缺「回「詳細」看全文」：$out" ;; esac

# 2b) 單行無空白長串（沒有「詳細」可取回）：不切字、不硬塞尾巴
out="$(head -c 5000 /dev/zero | tr '\0' x | node "$L" --truncate)"
case "$out" in *'詳細'*) fail "單行長串不該加詳細尾巴" ;; esac

# 3) 不過 lint 的長文（超過 6 行）：第一行是結論、編號最多留 3 條
in="$(printf '結論一句\n1. 第一件\n2. 第二件\n3. 第三件\n4. 第四件\n5. 第五件\n6. 第六件')"
out="$(printf '%s' "$in" | node "$L" --truncate)"
case "$out" in '結論一句'*) ;; *) fail "第一行不是結論：$out" ;; esac
! printf '%s' "$out" | grep -q '^4\. ' || fail "編號敲過 3 條：$out"

# 4) 原用法不變：lint 不過 exit 1
set +e
printf '%s\n' "$long" | node "$L" >/dev/null 2>&1; rc=$?
set -e
[ "$rc" = 1 ] || fail "lint 不過應 exit 1：$rc"
printf '收到\n' | node "$L" >/dev/null 2>&1 || fail "lint 過應 exit 0"

# 5) tg-send 與它行為一致（tg-send 用同一支 trauncate）：ADHD_MAX_CHARS 覆寫生效
text="$(printf '%s' "$long" | ADHD_MAX_CHARS=60 node "$L" --truncate)"
[ "$(strip "$text")" -le 60 ] || fail "ADHD_MAX_CHARS=60 沒生效：$(strip "$text")"

echo 'ADHD-TRUNCATE PASS'
