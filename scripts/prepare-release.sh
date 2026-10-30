#!/bin/zsh
# 构建通用安装包与已签名的 appcast，不访问或修改 GitHub Release。
# 用法：./scripts/prepare-release.sh path/to/release-notes.md
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $# -eq 1 && -f "$1" ]] || { echo "用法：$0 path/to/release-notes.md" >&2; exit 1; }
NOTES="${1:A}"
VERSION="$(python3 scripts/release-config.py get version)"
REPOSITORY="$(python3 scripts/release-config.py get repository)"
ACCOUNT="$(python3 scripts/release-config.py get keychainAccount)"
PUBLIC_KEY="$(python3 scripts/release-config.py get publicEDKey)"
SWIFT_BUILD_DIR="$(python3 scripts/release-config.py build-path)"
SPARKLE_BIN="$SWIFT_BUILD_DIR/artifacts/sparkle/Sparkle/bin"
SOURCE_REVISION="$(git rev-parse HEAD)"
SOURCE_STATUS="$(git status --porcelain)"
SOURCE_DIFF="$(git diff HEAD | shasum -a 256)"

swift package --disable-keychain --scratch-path "$SWIFT_BUILD_DIR" resolve
[[ "$("$SPARKLE_BIN/generate_keys" --account "$ACCOUNT" -p)" == "$PUBLIC_KEY" ]] || {
  echo "本机 Keychain 的更新公钥与 Resources/UpdateConfig.json 不一致。" >&2; exit 1
}
./scripts/build-app.sh release universal
mkdir -p build/release
STAGING="$(mktemp -d "$(getconf DARWIN_USER_TEMP_DIR)/LanBox-release.XXXXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
ARCHIVE="LanBox-${VERSION}-macOS-universal.zip"
OUTPUT="$PWD/build/release/$VERSION"
APP_BUNDLE="$PWD/build/LanBox.app"
APP_BUNDLE="${APP_BUNDLE:A}"

# 只打包应用，保留 framework 符号链接和可执行权限。
xattr -cr "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"
ditto -c -k --keepParent --norsrc --noextattr --noqtn --noacl "$APP_BUNDLE" "$STAGING/$ARCHIVE"
cp "$NOTES" "$STAGING/${ARCHIVE%.zip}.md"
"$SPARKLE_BIN/generate_appcast" --account "$ACCOUNT" \
  --download-url-prefix "https://github.com/$REPOSITORY/releases/download/v$VERSION/" \
  --link "https://github.com/$REPOSITORY" \
  --maximum-deltas 0 --embed-release-notes \
  -o "$STAGING/appcast.xml" "$STAGING"

# 检查下载者拿到的实际归档，而不仅仅是打包前的应用。
ditto -x -k "$STAGING/$ARCHIVE" "$STAGING/verify"
codesign --verify --deep --strict "$STAGING/verify/LanBox.app"
[[ "$(lipo -archs "$STAGING/verify/LanBox.app/Contents/MacOS/LanBox")" == "x86_64 arm64" || \
   "$(lipo -archs "$STAGING/verify/LanBox.app/Contents/MacOS/LanBox")" == "arm64 x86_64" ]] || {
  echo "Release 必须同时包含 arm64 与 x86_64。" >&2; exit 1
}
(cd "$STAGING" && shasum -a 256 "$ARCHIVE" appcast.xml > SHA256SUMS.txt)
[[ "$(git rev-parse HEAD)" == "$SOURCE_REVISION" && \
   "$(git status --porcelain)" == "$SOURCE_STATUS" && \
   "$(git diff HEAD | shasum -a 256)" == "$SOURCE_DIFF" ]] || {
  echo "构建过程中源代码发生变化，请重新准备发布包。" >&2; exit 1
}
python3 scripts/release-config.py manifest "$STAGING"
python3 scripts/release-config.py validate "$STAGING"
cp "$NOTES" "$STAGING/release-notes.md"
mkdir -p "$OUTPUT"
for file in "$ARCHIVE" appcast.xml SHA256SUMS.txt release.json release-notes.md; do
  mv "$STAGING/$file" "$OUTPUT/$file"
done
echo "发布文件已准备好：$OUTPUT"
echo "提交源代码并推送 v$VERSION 标签后，运行 ./scripts/publish-release.sh"
