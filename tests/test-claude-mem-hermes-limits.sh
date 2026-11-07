#!/bin/bash
# claude-mem plugin honors CLAUDE_MEM_HERMES_* env (local patch 11-07), defaults otherwise.
set -euo pipefail
PLUGIN=$HOME/.hermes/plugins/claude-mem
PY=/usr/bin/python3
# Stub agent.memory_provider so the plugin imports without Hermes installed.
STUB=$(mktemp -d)
mkdir -p "$STUB/agent"
echo 'class MemoryProvider: pass' > "$STUB/agent/memory_provider.py"
trap 'rm -rf "$STUB"' EXIT

probe() { # probe <SESSION> <TURN> <LIMIT> [unset]
  (
    if [ "${4:-}" = unset ]; then
      unset CLAUDE_MEM_HERMES_SESSION_MAX CLAUDE_MEM_HERMES_TURN_MAX CLAUDE_MEM_HERMES_TURN_LIMIT
    else
      export CLAUDE_MEM_HERMES_SESSION_MAX=$1 CLAUDE_MEM_HERMES_TURN_MAX=$2 CLAUDE_MEM_HERMES_TURN_LIMIT=$3
    fi
    cd "$PLUGIN" && "$PY" -I -c '
import importlib.util, sys, os
sys.path.insert(0, "'"$STUB"'")
sys.path.insert(0, os.getcwd())
spec = importlib.util.spec_from_file_location("claude_mem_plugin", "client.py")
import types; pkg = types.ModuleType("pkg"); pkg.__path__ = [os.getcwd()]; sys.modules["pkg"] = pkg
spec = importlib.util.spec_from_file_location("pkg.__init__", "__init__.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(m.SESSION_BLOCK_MAX, m.TURN_NOTES_MAX, m.TURN_NOTES_LIMIT)'
  )
}

check() { # check <expected> <desc> <args...>
  local want=$1 desc=$2; shift 2
  local got; got=$(probe "$@")
  if [ "$got" != "$want" ]; then
    echo "FAIL: $desc: want '$want' got '$got'" >&2; exit 1
  fi
  echo "ok: $desc ($got)"
}

check "1500 1000 3" "env set" 1500 1000 3
check "6000 4000 5" "env unset" x x x unset
check "6000 4000 5" "env abc -> defaults" abc abc abc
check "6000 4000 5" "env non-positive -> defaults" 0 -5 0
echo PASS
