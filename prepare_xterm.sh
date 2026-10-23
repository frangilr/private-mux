#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
FRONTEND="$ROOT/frontend"
VENDOR="$ROOT/PrivateTerm/Web/vendor"

if ! command -v npm >/dev/null 2>&1; then
    echo 'npm is required once to fetch pinned xterm.js assets. Install Node.js LTS.' >&2
    exit 1
fi

# Install no lifecycle scripts, no optional packages, no globally installed code.
# Exact versions are in frontend/package.json; npm creates package-lock.json.
(cd "$FRONTEND" && npm install --ignore-scripts --no-audit --no-fund --omit=optional)

mkdir -p "$VENDOR"
cp "$FRONTEND/node_modules/@xterm/xterm/lib/xterm.js" "$VENDOR/xterm.js"
cp "$FRONTEND/node_modules/@xterm/xterm/css/xterm.css" "$VENDOR/xterm.css"
cp "$FRONTEND/node_modules/@xterm/addon-fit/lib/addon-fit.js" "$VENDOR/addon-fit.js"

for dep in xterm addon-fit; do
    if [ "$dep" = xterm ]; then
        src="$FRONTEND/node_modules/@xterm/xterm"
    else
        src="$FRONTEND/node_modules/@xterm/addon-fit"
    fi
    if [ -f "$src/LICENSE" ]; then
        cp "$src/LICENSE" "$VENDOR/LICENSE-$dep.txt"
    else
        echo "Warning: no license at $src/LICENSE; review upstream MIT terms." >&2
    fi
done

printf '\nPinned terminal assets copied into PrivateTerm/Web/vendor.\n'
printf 'Files and SHA-256:\n'
shasum -a 256 "$VENDOR/xterm.js" "$VENDOR/addon-fit.js" "$VENDOR/xterm.css"
printf '\nOpen PrivateTerm.xcodeproj in Xcode and Run.\n'
