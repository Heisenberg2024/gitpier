#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
Scripts/build-app.sh
ditto -c -k --sequesterRsrc --keepParent dist/GitPier.app dist/GitPier-1.0.0-macos.zip
shasum -a 256 dist/GitPier-1.0.0-macos.zip > dist/GitPier-1.0.0-macos.zip.sha256
printf 'Local archive: %s/dist/GitPier-1.0.0-macos.zip\n' "$PWD"
