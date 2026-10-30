#!/bin/zsh
# 发布 prepare-release.sh 生成且已验证的文件。先上传 draft，再设为最新正式版本。
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="$(python3 scripts/release-config.py get version)"
REPOSITORY="$(python3 scripts/release-config.py get repository)"
OUTPUT="$PWD/build/release/$VERSION"
TAG="v$VERSION"
ARCHIVE="LanBox-${VERSION}-macOS-universal.zip"

python3 scripts/release-config.py check-publish "$OUTPUT"
[[ -f "$OUTPUT/release-notes.md" ]] || { echo "缺少 Release 说明。" >&2; exit 1; }
if gh release view "$TAG" --repo "$REPOSITORY" >/dev/null 2>&1; then
  echo "$TAG 已存在。请检查已有 Release，不会自动覆盖公开安装包或 appcast。" >&2
  exit 1
fi

gh release create "$TAG" --repo "$REPOSITORY" --verify-tag --draft \
  --title "LanBox $TAG" --notes-file "$OUTPUT/release-notes.md" \
  "$OUTPUT/$ARCHIVE" "$OUTPUT/appcast.xml" "$OUTPUT/SHA256SUMS.txt"

# 回读 draft 的附件大小与 GitHub 计算的 SHA-256；完整后才切换 latest feed。
gh api "repos/$REPOSITORY/releases/tags/$TAG" > "$OUTPUT/github-release.json"
python3 scripts/release-config.py check-upload "$OUTPUT"
gh release edit "$TAG" --repo "$REPOSITORY" --draft=false --latest
gh release view "$TAG" --repo "$REPOSITORY" --json url --jq .url
