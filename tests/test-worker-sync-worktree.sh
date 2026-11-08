#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
# 獨立 git 夾具，不更動主倉 worktree 清單；HOME 隔離，突變也不會污染正式 worker。
mkdir -p "$TMP/main/router"
cp "$ROOT/router/worker-sync.sh" "$TMP/main/router/"
cp -R "$ROOT/router/worker" "$TMP/main/router/worker"
git -C "$TMP/main" init -q
git -C "$TMP/main" add router
git -C "$TMP/main" -c user.name=Fixture -c user.email=fixture commit -qm fixture
git -C "$TMP/main" worktree add -q --detach "$TMP/linked"
mkdir -p "$TMP/home/bots/mythos-worker"
printf 'sentinel\n' > "$TMP/home/bots/mythos-worker/CLAUDE.md"
if (unset MYTHOS_WORKER_DIR MYTHOS_DIR; HOME="$TMP/home" bash "$TMP/linked/router/worker-sync.sh") > "$TMP/out" 2>&1; then fail 'linked worktree 未拒寫'; fi
grep -q MYTHOS_WORKER_DIR "$TMP/out" || fail '拒寫未說明隔離設定'
[ "$(cat "$TMP/home/bots/mythos-worker/CLAUDE.md")" = sentinel ] || fail '拒寫仍污染檔案'
MYTHOS_DIR="$TMP/linked" MYTHOS_WORKER_DIR="$TMP/isolated" bash "$TMP/linked/router/worker-sync.sh"
grep -Fq "$TMP/linked" "$TMP/isolated/CLAUDE.md" || fail '明確隔離目錄未同步'
(unset MYTHOS_WORKER_DIR MYTHOS_DIR; HOME="$TMP/home" bash "$TMP/main/router/worker-sync.sh")
grep -Fq "$TMP/main" "$TMP/home/bots/mythos-worker/CLAUDE.md" || fail '主倉正常同步失敗'
echo 'WORKER-SYNC-WORKTREE PASS'
