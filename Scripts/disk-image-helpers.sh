#!/bin/bash
# Create only task-owned temporary images. No service restarts or unrelated detaches.
gitpier_create_temporary_dmg() {
  local source="$1" output="$2" volume="$3" attempt image log result
  [[ ! -e "$output" ]] || { echo "Refusing to overwrite $output" >&2; return 1; }
  for attempt in 1 2 3; do
    image="${output%.dmg}.attempt-$attempt.dmg"
    log="${output%.dmg}.attempt-$attempt.log"
    [[ ! -e "$image" && ! -e "$log" ]] || return 1
    if hdiutil create -srcfolder "$source" -volname "$volume" -fs HFS+ -format ULFO "$image" >"$log" 2>&1; then
      cat "$log" >&2
      mv "$image" "$output"
      return 0
    else
      result=$?
    fi
    cat "$log" >&2
    if ! grep -Fxq 'hdiutil: create failed - Resource busy' "$log" || [[ "$attempt" == 3 ]]; then
      echo "Temporary DMG creation failed on attempt $attempt (exit $result)." >&2
      return "$result"
    fi
    echo "Temporary DMG creation was busy; retrying after ${attempt}s (attempt $attempt/3)." >&2
    sleep "$attempt"
  done
}
