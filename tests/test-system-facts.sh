#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/repo/bin" "$TMP/router" "$TMP/worker"
cp "$ROOT"/bin/{dispatch,opus-plan,plan-ticket,quick,free-models} "$TMP/repo/bin/"
export SYSTEM_FACTS_REPO="$TMP/repo" SYSTEM_FACTS_ROUTER_PROFILE="$TMP/router" SYSTEM_FACTS_WORKER_PROFILE="$TMP/worker"
fail() { echo "FAIL: $*" >&2; exit 1; }
fixture() {
  cat <<EOF
model:
  default: $1
  provider: fixture
fallback_providers:
  - provider: backup
    model: $2
EOF
}
for suffix in alpha beta; do
  fixture "router-$suffix" "router-back-$suffix" > "$TMP/router/config.yaml"
  fixture "worker-$suffix" "worker-back-$suffix" > "$TMP/worker/config.yaml"
  "$ROOT/bin/system-facts" > "$TMP/out"
  for model in router worker; do
    grep -q "fixture/$model-$suffix" "$TMP/out" || fail "$model 模型未跟著變"
    grep -q "backup/$model-back-$suffix" "$TMP/out" || fail "$model fallback 未跟著變"
  done
done
python3 - "$TMP/repo/bin" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1])/'opus-plan'; s=p.read_text(); s=re.sub(r'(-p --model )\S+',r'\g<1>fixture-planner',s); s=re.sub(r'(OPUS_PLAN_FALLBACK_MODEL:-)[^}]+',r'\g<1>fixture-backup',s); p.write_text(s)
p=Path(sys.argv[1])/'dispatch'; s=p.read_text().replace('ORDER:-default','ORDER:-fixture-order'); p.write_text(s)
PY
"$ROOT/bin/system-facts" > "$TMP/out"
grep -q 'fixture-planner → fixture-backup' "$TMP/out" || fail '計畫模型未跟著變'
grep -q 'mid=fixture-order；hard=fixture-order' "$TMP/out" || fail '派工順序未跟著變'
# 缺少一個設定，該項必須報錯且保留其他可讀項目。
sed '/default:/d' "$TMP/worker/config.yaml" > "$TMP/config"
mv "$TMP/config" "$TMP/worker/config.yaml"
if "$ROOT/bin/system-facts" > "$TMP/out"; then fail '缺模型仍成功'; fi
grep -Fq "worker（背景執行）模型：讀不到（$TMP/worker/config.yaml）" "$TMP/out" || fail '缺項未指出來源'
grep -q 'fixture/router-beta' "$TMP/out" || fail '缺項影響其他項目'
echo 'SYSTEM-FACTS PASS'
