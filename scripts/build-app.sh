#!/bin/zsh
# 用法：./scripts/build-app.sh [release|debug] [native|universal|arm64|x86_64]
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
TARGET_ARCH="${2:-native}"
SWIFT_BUILD_DIR="$(python3 scripts/release-config.py build-path)"
BUILD_ARGS=(--disable-keychain --scratch-path "$SWIFT_BUILD_DIR" -c "$CONFIG")
case "$TARGET_ARCH" in
  native) ;;
  universal) BUILD_ARGS+=(--arch arm64 --arch x86_64) ;;
  arm64|x86_64) BUILD_ARGS+=(--arch "$TARGET_ARCH") ;;
  *) echo "不支持的架构：$TARGET_ARCH" >&2; exit 1 ;;
esac
# 14 位 UTC 构建号可跨时区比较，并大于 1.0.0 使用的 12 位构建号。
BUILD="$(date -u +%Y%m%d%H%M%S)"
python3 scripts/release-config.py get version >/dev/null
swift build "${BUILD_ARGS[@]}"
BIN="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)/LanBox"
SPARKLE_ROOT="$SWIFT_BUILD_DIR/artifacts/sparkle/Sparkle"
SPARKLE_SOURCE="$SPARKLE_ROOT/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
[[ -d "$SPARKLE_SOURCE" ]] || { echo "构建目录中缺少 Sparkle.framework：$SPARKLE_SOURCE" >&2; exit 1; }

# Documents/iCloud 的 File Provider 会异步给 .app/.xpc 附加 FinderInfo。
# 在系统本地缓存中完成组装和签名；项目内仅保留同名入口，避免清理 xattr 的竞态。
BUILD_WORK="$(mktemp -d "$(getconf DARWIN_USER_CACHE_DIR)/LanBox-build.XXXXXXXX")"
APP="$BUILD_WORK/LanBox.app"
BUILD_SUCCEEDED=false
trap 'if [[ "$BUILD_SUCCEEDED" != true ]]; then rm -rf "$BUILD_WORK"; fi' EXIT
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/web" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/LanBox"
cp Resources/web/index.html Resources/web/logo.svg "$APP/Contents/Resources/web/"
ditto --norsrc --noextattr --noqtn --noacl "$SPARKLE_SOURCE" "$APP/Contents/Frameworks/Sparkle.framework"
cp "$SPARKLE_ROOT/LICENSE" "$APP/Contents/Resources/Sparkle-LICENSE.txt"
python3 scripts/release-config.py plist "$APP" "$BUILD"

swift scripts/make-icon.swift "$BUILD_WORK/icon" >/dev/null
iconutil -c icns "$BUILD_WORK/icon/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
cp "$BUILD_WORK/icon/touch-icon.png" "$APP/Contents/Resources/web/touch-icon.png"

# 从内向外签名；不使用 --deep 重签，避免覆盖 Sparkle helper 的独立 entitlement。
xattr -cr "$APP"
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
codesign --force --sign - "$SPARKLE/XPCServices/Installer.xpc"
codesign --force --sign - --preserve-metadata=entitlements "$SPARKLE/XPCServices/Downloader.xpc"
codesign --force --sign - "$SPARKLE/Autoupdate"
codesign --force --sign - "$SPARKLE/Updater.app"
codesign --force --sign - "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --sign - "$APP"

# 重新登记到 LaunchServices，刷新 Dock/通知图标；清理系统重新附加的 FinderInfo。
touch "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" >/dev/null 2>&1 || true
xattr -cr "$APP"
codesign --verify --deep --strict "$APP"
mkdir -p build
rm -rf build/LanBox.app
ln -s "$APP" build/LanBox.app
BUILD_SUCCEEDED=true
echo "已生成 build/LanBox.app（构建 $BUILD，签名产物：$APP）"
