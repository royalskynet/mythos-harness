#!/usr/bin/env bash
# 把 router/worker/ 範本同步到 worker 目錄（dispatcher-bg 計畫第 1 項）。run.sh／router/start.sh 啟動時呼叫。
# 只覆蓋範本內的檔，不刪目標既有其他檔（worker 自己寫的東西要留著）；範本裡的 __MYTHOS_DIR__ 換成本 repo 的絕對路徑
# （worker 的 cwd 不是 Mythos，bin／state／gate 都要絕對路徑；不靠 bg session 會不會繼承環境變數）。
set -eu
SRC="$(cd "$(dirname "$0")/worker" && pwd)"
REPO="${MYTHOS_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
DEST="${MYTHOS_WORKER_DIR:-$HOME/bots/mythos-worker}"
case "$DEST" in "$REPO"|"$REPO"/*) echo "worker 目錄不能在 Mythos 底下（會往上載入 Router 的 CLAUDE.md）：${DEST}" >&2; exit 2 ;; esac
mkdir -p "$DEST/.claude"
if command -v rsync >/dev/null 2>&1; then
  rsync -a "$SRC/" "$DEST/"
else
  cp "$SRC/CLAUDE.md" "$DEST/CLAUDE.md"
  cp "$SRC/.claude/settings.json" "$SRC/.claude/hard.json" "$DEST/.claude/"
fi
esc="$(printf '%s' "$REPO" | sed -e 's/[\\|&]/\\&/g')"
for f in "$DEST/CLAUDE.md" "$DEST/.claude/settings.json"; do
  sed "s|__MYTHOS_DIR__|${esc}|g" "$f" > "$f.tmp.$$" && mv "$f.tmp.$$" "$f"
done
chmod 644 "$DEST/CLAUDE.md" "$DEST"/.claude/*.json
