#!/bin/bash
# Xcode build phase: ship the release Rust engine inside the menu bar app.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
export CARGO_TARGET_DIR="$REPO/rust/target"
cargo build --locked --manifest-path "$REPO/rust/Cargo.toml" --release -p tempo-cli
DEST="$TARGET_BUILD_DIR/$EXECUTABLE_FOLDER_PATH/tempo-backend"
mkdir -p "$(dirname "$DEST")"
cp "$CARGO_TARGET_DIR/release/tempo" "$DEST"
chmod 755 "$DEST"
# Signed with its entitlements only when the app is: `inherit` needs a sandboxed parent, and
# an unsigned development build of the app isn't one - the kernel would kill the child on
# launch. (sign-and-install.sh signs it with the entitlements on the machine it ships to.)
if [ "${CODE_SIGNING_ALLOWED:-NO}" = YES ] && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
  codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --timestamp=none --entitlements "$REPO/App/DeskpilotBar/Backend.entitlements" "$DEST"
else
  codesign --force --sign - --timestamp=none "$DEST"
fi
