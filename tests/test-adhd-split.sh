#!/usr/bin/env bash
# 出口只有行太長時按標點拆行、不丟內容（11-07 冒煙首行 60 字事故）
cd "$(dirname "$0")/.." || exit 1
t='磁碟剩一百二十GB，主要被 Docker 映像佔掉，清掉沒在用的映像大約可以再多出四十GB。'
o="$(printf '%s\n' "$t" | node bin/adhd-lint.mjs --truncate)"
printf '%s\n' "$o" | node bin/adhd-lint.mjs || { echo "FAIL 拆完仍不過 lint"; exit 1; }
[ "$(printf '%s' "$o" | tr -d '\n')" = "$t" ] || { echo "FAIL 內容被丟：$o"; exit 1; }

# 3 行無編號、遠低於 220 字：合併尾段，不丟提問
t2='磁碟剩 120GB，Docker 映像吃掉大半。

清掉沒在用的映像大約能多出 40GB。
要我現在清嗎？'
o2="$(printf '%s\n' "$t2" | node bin/adhd-lint.mjs --truncate)"
printf '%s\n' "$o2" | node bin/adhd-lint.mjs || { echo "FAIL 合併後不過 lint"; exit 1; }
case "$o2" in *'要我現在清嗎'*) ;; *) echo "FAIL 提問被丟：$o2"; exit 1;; esac
case "$o2" in *'回「詳細」看全文'*) echo "FAIL 不該截斷：$o2"; exit 1;; esac

# 真正超過 220 字的多行文字仍走截斷
long="$(printf '很長的結論一行。\n'; for i in 1 2 3 4 5 6 7 8; do printf '這是第%s段補充說明，內容很多很多很多很多很多很多很多。\n' "$i"; done)"
o3="$(printf '%s\n' "$long" | node bin/adhd-lint.mjs --truncate)"
case "$o3" in *'回「詳細」看全文'*) ;; *) echo "FAIL 超長沒截斷：$o3"; exit 1;; esac
# 11-08 audit#6：無標點單行 300 字不再原樣放行：去空白 ≤220 且過 lint、帶「詳細」
t4="$(printf '甲%.0s' $(seq 1 300))"
o4="$(printf '%s' "$t4" | node bin/adhd-lint.mjs --truncate)"
[ "$(printf '%s' "$o4" | tr -d '[:space:]' | wc -m)" -le 220 ] || { echo "FAIL 單行超長沒截斷：$o4"; exit 1; }
printf '%s\n' "$o4" | node bin/adhd-lint.mjs || { echo "FAIL 單行超長截斷後不過 lint"; exit 1; }
case "$o4" in *'回「詳細」看全文'*) ;; *) echo "FAIL 缺詳細尾巴：$o4"; exit 1;; esac
echo "PASS test-adhd-split"
