#!/bin/zsh
# 构建 LanBox.app，输出到 build/LanBox.app
# 用法：./scripts/build-app.sh [release|debug]
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP="build/LanBox.app"
VERSION="1.0.0"
# 每次构建递增，系统据此刷新缓存的 App 图标（Dock、通知、Finder）
BUILD="$(date +%Y%m%d%H%M)"

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/LanBox"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/web"
cp "$BIN" "$APP/Contents/MacOS/LanBox"
cp Resources/web/index.html Resources/web/logo.svg "$APP/Contents/Resources/web/"

# 图标
swift scripts/make-icon.swift build/icon >/dev/null
iconutil -c icns build/icon/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
cp build/icon/touch-icon.png "$APP/Contents/Resources/web/touch-icon.png"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>app.lanbox.mac</string>
  <key>CFBundleName</key><string>LanBox</string>
  <key>CFBundleDisplayName</key><string>LanBox</string>
  <key>CFBundleExecutable</key><string>LanBox</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD}</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSLocalNetworkUsageDescription</key><string>LanBox 需要使用局域网，让同一网络中的手机和电脑访问你共享的文件。</string>
  <key>NSSupportsAutomaticTermination</key><false/>
  <!-- 允许把任意文件 / 文件夹拖到 Dock 图标上加入共享；Rank None 表示不抢默认打开方式 -->
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>共享的项目</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>None</string>
      <key>LSItemContentTypes</key><array><string>public.item</string><string>public.folder</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

xattr -cr "$APP"
codesign --force --deep --sign - "$APP" >/dev/null

# 重新登记到 LaunchServices，通知中心和 Dock 才会换成新图标
touch "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" >/dev/null 2>&1 || true
echo "已生成 $APP"
