#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Sticky"
PRODUCT_NAME="FloatingTodo"
BUNDLE_ID="com.cmi.floatingtodo"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
ARM_EXECUTABLE="$ROOT_DIR/.build/arm64-apple-macosx/release/$PRODUCT_NAME"
INTEL_EXECUTABLE="$ROOT_DIR/.build/x86_64-apple-macosx/release/$PRODUCT_NAME"
UNIVERSAL_EXECUTABLE="$DIST_DIR/${PRODUCT_NAME}-universal"

cd "$ROOT_DIR"

if [[ -n "$(git status --porcelain)" ]]; then
  echo "Refusing to package: the Git working tree is not clean." >&2
  exit 1
fi

if git ls-files --error-unmatch "Floating Todo.md" >/dev/null 2>&1 \
  || [[ -n "$(git ls-files 'Sticky/*.md')" ]] \
  || [[ -n "$(git ls-files '.floating-todo/*')" ]]; then
  echo "Refusing to package: personal Sticky or Obsidian data is tracked by Git." >&2
  exit 1
fi

if git grep -nE '/Users/(shweh|andreas)/|Library/Mobile Documents/iCloud~md~obsidian' \
  -- . ':(exclude)script/package_release.sh'; then
  echo "Refusing to package: a personal absolute path is present in tracked files." >&2
  exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
  echo "Refusing to package: invalid CFBundleShortVersionString '$VERSION'." >&2
  exit 1
fi

ARCHIVE_NAME="$APP_NAME-$VERSION-macOS-universal.zip"
ARCHIVE_PATH="$DIST_DIR/$ARCHIVE_NAME"
CHECKSUM_PATH="$ARCHIVE_PATH.sha256"

swift build -c release --arch arm64
swift build -c release --arch x86_64

mkdir -p "$DIST_DIR"
lipo -create "$ARM_EXECUTABLE" "$INTEL_EXECUTABLE" -output "$UNIVERSAL_EXECUTABLE"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$UNIVERSAL_EXECUTABLE" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$ROOT_DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$ROOT_DIR/FloatingTodo/Resources/"* "$APP_BUNDLE/Contents/Resources/"

codesign --force --deep --sign - --identifier "$BUNDLE_ID" "$APP_BUNDLE"
lipo -verify_arch arm64 x86_64 "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
codesign --verify --deep --strict "$APP_BUNDLE"
plutil -lint "$APP_BUNDLE/Contents/Info.plist"

rm -f "$ARCHIVE_PATH" "$CHECKSUM_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ARCHIVE_PATH"
(
  cd "$DIST_DIR"
  shasum -a 256 "$ARCHIVE_NAME" > "$ARCHIVE_NAME.sha256"
)
unzip -t "$ARCHIVE_PATH" >/dev/null

if unzip -Z1 "$ARCHIVE_PATH" | grep -E '(^|/)(todos\.json|config\.json|Floating Todo\.md)$|/Sticky/.*\.md$' >/dev/null; then
  echo "Refusing to release: personal data was found in the archive." >&2
  exit 1
fi

echo "Release package ready: $ARCHIVE_PATH"
echo "Checksum: $CHECKSUM_PATH"
