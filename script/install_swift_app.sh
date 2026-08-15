#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Sticky"
PRODUCT_NAME="FloatingTodo"
BUNDLE_ID="com.cmi.floatingtodo"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
TARGET_BUNDLE="/Applications/$APP_NAME.app"
TRASH_DIR="$HOME/.Trash"
BACKUP_BUNDLE="$TRASH_DIR/$APP_NAME.replaced-$(date -u +%Y-%m-%dT%H-%M-%SZ).app"
LEGACY_BUNDLE="/Applications/FloatingTodo.app"
LEGACY_BACKUP_BUNDLE="$TRASH_DIR/FloatingTodo.renamed-$(date -u +%Y-%m-%dT%H-%M-%SZ).app"
ARM_EXECUTABLE="$ROOT_DIR/.build/arm64-apple-macosx/release/$PRODUCT_NAME"
INTEL_EXECUTABLE="$ROOT_DIR/.build/x86_64-apple-macosx/release/$PRODUCT_NAME"
UNIVERSAL_EXECUTABLE="$DIST_DIR/${PRODUCT_NAME}-universal"

cd "$ROOT_DIR"

swift build -c release --arch arm64
swift build -c release --arch x86_64
mkdir -p "$DIST_DIR"
lipo -create "$ARM_EXECUTABLE" "$INTEL_EXECUTABLE" -output "$UNIVERSAL_EXECUTABLE"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
cp "$UNIVERSAL_EXECUTABLE" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$ROOT_DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
mkdir -p "$APP_BUNDLE/Contents/Resources"
cp "$ROOT_DIR/FloatingTodo/Resources/"* "$APP_BUNDLE/Contents/Resources/"

# 将 Info.plist 和资源一并封入签名，确保系统权限请求能稳定识别 Sticky。
codesign --force --deep --sign - --identifier "$BUNDLE_ID" "$APP_BUNDLE"

if [[ -d "$TARGET_BUNDLE" ]]; then
  CURRENT_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$TARGET_BUNDLE/Contents/Info.plist")"
  if [[ "$CURRENT_ID" != "$BUNDLE_ID" ]]; then
    echo "Refusing to replace $TARGET_BUNDLE: bundle id is $CURRENT_ID" >&2
    exit 1
  fi
fi

if [[ -d "$LEGACY_BUNDLE" ]]; then
  LEGACY_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$LEGACY_BUNDLE/Contents/Info.plist")"
  if [[ "$LEGACY_ID" != "$BUNDLE_ID" ]]; then
    echo "Refusing to replace legacy bundle $LEGACY_BUNDLE: bundle id is $LEGACY_ID" >&2
    exit 1
  fi
fi

osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true

for _ in {1..10}; do
  if ! pgrep -f "^$TARGET_BUNDLE/Contents/MacOS/$APP_NAME$" >/dev/null; then
    break
  fi
  sleep 0.2
done

# LSUIElement 菜单栏应用偶尔会忽略 AppleScript quit；确保旧实例不再占用全局快捷键。
if pgrep -f "^$TARGET_BUNDLE/Contents/MacOS/$APP_NAME$" >/dev/null; then
  while IFS= read -r pid; do
    kill -TERM "$pid"
  done < <(pgrep -f "^$TARGET_BUNDLE/Contents/MacOS/$APP_NAME$")

  for _ in {1..10}; do
    if ! pgrep -f "^$TARGET_BUNDLE/Contents/MacOS/$APP_NAME$" >/dev/null; then
      break
    fi
    sleep 0.2
  done
fi

if pgrep -f "^$TARGET_BUNDLE/Contents/MacOS/$APP_NAME$" >/dev/null; then
  echo "Refusing to replace $TARGET_BUNDLE while Sticky is still running" >&2
  exit 1
fi

mkdir -p "$TRASH_DIR"
if [[ -d "$TARGET_BUNDLE" ]]; then
  mv "$TARGET_BUNDLE" "$BACKUP_BUNDLE"
fi

if [[ -d "$LEGACY_BUNDLE" ]]; then
  mv "$LEGACY_BUNDLE" "$LEGACY_BACKUP_BUNDLE"
fi

cp -R "$APP_BUNDLE" "$TARGET_BUNDLE"
open -n "$TARGET_BUNDLE"

echo "Installed: $TARGET_BUNDLE"
echo "Backup: $BACKUP_BUNDLE"
