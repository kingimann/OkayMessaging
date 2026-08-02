#!/bin/bash
set -euo pipefail

# Only needed on Claude Code on the web — local machines manage their own SDK.
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

# CI (and CLAUDE.md) pin this toolchain; do not bump it here without bumping CI.
FLUTTER_VERSION="3.44.7"
FLUTTER_ROOT="/opt/flutter"

# The container is cached after the hook completes, so the download only
# happens on the first run of a fresh environment.
if [ ! -x "$FLUTTER_ROOT/bin/flutter" ]; then
  echo "Installing Flutter $FLUTTER_VERSION to $FLUTTER_ROOT..."
  curl -fsSL --retry 3 \
    "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz" \
    -o /tmp/flutter.tar.xz
  mkdir -p "$(dirname "$FLUTTER_ROOT")"
  tar -xJf /tmp/flutter.tar.xz -C "$(dirname "$FLUTTER_ROOT")"
  rm -f /tmp/flutter.tar.xz
fi

# The SDK ships as a git checkout; running as root trips git's ownership check.
git config --global --add safe.directory "$FLUTTER_ROOT" 2>/dev/null || true

export PATH="$FLUTTER_ROOT/bin:$PATH"
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  echo "export PATH=\"$FLUTTER_ROOT/bin:\$PATH\"" >> "$CLAUDE_ENV_FILE"
fi

cd "$CLAUDE_PROJECT_DIR"
flutter --version
flutter pub get
