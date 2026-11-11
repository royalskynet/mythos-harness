#!/usr/bin/env bash
# worker 派工前 lint 閘：bin/deep-lint 能找到同目錄 wo-verify，並正確放行／擋下工單；
# SOUL 要求派前先跑它。無網路、無模型。
set -uo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/deep-lint.XXXXXX"); trap 'rm -rf "$tmp"' EXIT
fail=0
ck() { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 (got $2, want $3)"; fail=1; fi; }
for f in bin/deep-lint bin/wo-verify; do
  ck "$f 是 100755" "$(git ls-files -s "$f" | awk '{print $1}')" 100755
done
mk() { # $1=file $2=acceptance body (or empty = no block)
  { printf '# t\n\n## 任務\n\n做事。\n\n'
    if [ -n "$2" ]; then printf '## 驗收\n\n```bash\n%s\n```\n\n預期：rc=0。\n\n' "$2"; fi
    printf '## 禁止\n\n- 禁止改 fixture。\n'; } > "$1"
}
mk "$tmp/good.md" 'test -d /'
mk "$tmp/none.md" ''
mk "$tmp/bang.md" '! grep -q x /etc/hostname'
mk "$tmp/vacuous.md" 'ls /'
out=$(bin/deep-lint "$tmp/good.md" 2>&1); rc=$?
ck "合格工單 rc=0" "$rc" 0
case "$out" in *'LINT OK'*) ;; *) echo "FAIL: 合格工單沒印 LINT OK — $out"; fail=1;; esac
case "$out" in *unchecked*) echo "FAIL: wo-verify 沒被找到（unchecked）"; fail=1;; esac
bin/deep-lint "$tmp/none.md" >/dev/null 2>&1; ck "無驗收區塊 rc=1" "$?" 1
out=$(bin/deep-lint "$tmp/bang.md" 2>&1); rc=$?
ck "! 否定斷言 rc=1" "$rc" 1
out=$(bin/deep-lint "$tmp/vacuous.md" 2>&1)
case "$out" in *'無任何會非零退出的斷言'*) echo "ok: 空轉驗收會警告";; *) echo "FAIL: 空轉驗收未警告 — $out"; fail=1;; esac
grep -q 'bin/deep-lint' profiles/mythos-worker/SOUL.md; ck "worker SOUL 要求派前 deep-lint" "$?" 0
[ "$fail" = 0 ] && echo "DEEP-LINT PASS"
exit "$fail"
