#!/usr/bin/env bash
# bin/hermes-upgrade 的還原與回寫：假 hermes（update＝上游改到在地修改隔壁行、刪掉另一個在地改過的檔、遷移 config）。
# 期望：context 被上游改過的在地修改用 -3 套回且不留 index；相鄰行衝突退回上游版不留標記並列 WARN；上游刪檔列 WARN、config 遷移回寫 repo 且 chat id 換回變數、UPGRADE_OK。
set -u
SRC="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL $*"; exit 1; }

# 假 repo（只放腳本＋恆過的契約）
mkdir -p "$T/repo/bin" "$T/repo/profiles/mythos" "$T/repo/profiles/mythos-worker"
cp "$SRC/bin/hermes-upgrade" "$T/repo/bin/"
printf '#!/bin/sh\necho CONTRACT_OK\n' > "$T/repo/bin/hermes-contract"; chmod +x "$T/repo/bin/hermes-contract"
for p in mythos mythos-worker; do
  printf "_config_version: 47\nchat_id: '\${MYTHOS_TG_CHAT_ID}'\n" > "$T/repo/profiles/$p/config.yaml"
  mkdir -p "$T/home/.hermes/profiles/$p"
done

# 假 hermes-agent：a.py 第 5 行、c.py 第 5 行、gone.py 有在地修改
A="$T/agent"; mkdir -p "$A"; git -C "$A" init -q; git -C "$A" config user.email t@t; git -C "$A" config user.name t
seq 1 10 > "$A/a.py"; seq 1 10 > "$A/c.py"; echo keep > "$A/gone.py"; git -C "$A" add -A; git -C "$A" commit -qm base
sed -i '' 's/^5$/5-local/' "$A/a.py" "$A/c.py"; echo local > "$A/gone.py"

cat > "$T/hermes" <<EOF
#!/usr/bin/env bash
case "\$1 \${2:-}" in
  "update "*)
    git -C "$A" stash push -q -u
    sed -i '' 's/^2\$/2-upstream/' "$A/a.py"; sed -i '' 's/^4\$/4-upstream/' "$A/c.py"; git -C "$A" rm -q gone.py; git -C "$A" commit -qam up
    for p in mythos mythos-worker; do printf "_config_version: 53\nchat_id: '123456789'\n" > "$T/home/.hermes/profiles/\$p/config.yaml"; done ;;
  "--version "*) echo "Hermes test" ;;
  *) : ;;
esac
EOF
chmod +x "$T/hermes"

out="$(HOME="$T/home" HERMES_AGENT_ROOT="$A" HERMES_BIN="$T/hermes" "$T/repo/bin/hermes-upgrade" 2>&1)"
echo "$out" | grep -q 'UPGRADE_OK' || { echo "$out"; fail "沒有 UPGRADE_OK"; }
grep -qx '2-upstream' "$A/a.py" && grep -qx '5-local' "$A/a.py" || fail "a.py 鄰行在地修改沒套回：$(tr '\n' ' ' < "$A/a.py")"
[ -z "$(git -C "$A" diff --cached --name-only)" ] || { git -C "$A" status --short; fail "套回後 index 留有暫存"; }
echo "$out" | grep -q 'WARN 在地修改套不上 gone.py' || fail "上游刪檔沒列 WARN"
echo "$out" | grep -q 'WARN 在地修改套不上 c.py' || fail "相鄰行衝突沒列 WARN"
grep -q '^<<<<<<<' "$A/c.py" && fail "c.py 留下衝突標記"
grep -qx '4-upstream' "$A/c.py" || fail "c.py 沒退回上游版"
for p in mythos mythos-worker; do
  c="$T/repo/profiles/$p/config.yaml"
  grep -q '_config_version: 53' "$c" || fail "$p config 遷移沒回寫"
  grep -q '123456789' "$c" && fail "$p 回寫的 config 留有 chat id"
  grep -qF '${MYTHOS_TG_CHAT_ID}' "$c" || fail "$p chat id 沒換回變數"
done
echo PASS
