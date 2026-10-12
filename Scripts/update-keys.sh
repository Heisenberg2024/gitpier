#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_keys=".build/artifacts/sparkle/Sparkle/bin/generate_keys"
[[ -x "$task_keys" ]] || { echo 'Resolve the Sparkle dependency first with Scripts/test.sh.' >&2; exit 1; }
task_account="GitPier-production"
umask 077
case "${1:-public}" in
  init) "$task_keys" --account "$task_account" ;;
  public) "$task_keys" --account "$task_account" -p ;;
  export)
    task_backup="${2:?Provide an absolute backup path outside the repository}"
    python3 - "$task_backup" "$PWD" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); root=Path(sys.argv[2])
assert p.is_absolute() and not p.resolve().is_relative_to(root.resolve()) and not p.exists(), 'Unsafe backup destination'
PY
    "$task_keys" --account "$task_account" -x "$task_backup"
    chmod 600 "$task_backup"
    ;;
  import) "$task_keys" --account "$task_account" -f "${2:?Provide a secure exported key file}" ;;
  *) echo 'Usage: update-keys.sh init|public|export /secure/path|import /secure/path' >&2; exit 1 ;;
esac
