#!/usr/bin/env bash
# 出口只有行太長時按標點拆行、不丟內容（11-07 冒煙首行 60 字事故）
cd "$(dirname "$0")/.." || exit 1
t='磁碟剩一百二十GB，主要被 Docker 映像佔掉，清掉沒在用的映像大約可以再多出四十GB。'
o="$(printf '%s\n' "$t" | node bin/adhd-lint.mjs --truncate)"
printf '%s\n' "$o" | node bin/adhd-lint.mjs || { echo "FAIL 拆完仍不過 lint"; exit 1; }
[ "$(printf '%s' "$o" | tr -d '\n')" = "$t" ] || { echo "FAIL 內容被丟：$o"; exit 1; }
echo "PASS test-adhd-split"
