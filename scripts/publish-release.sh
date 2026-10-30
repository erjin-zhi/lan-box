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
  [[ "$(gh release view "$TAG" --repo "$REPOSITORY" --json isDraft --jq .isDraft)" == true ]] || {
    echo "$TAG 已公开，不会覆盖公开安装包或 appcast。" >&2; exit 1
  }
  # 中断后只恢复同标签草稿，公开版本不可覆盖。
  gh release upload "$TAG" --repo "$REPOSITORY" --clobber \
    "$OUTPUT/$ARCHIVE" "$OUTPUT/appcast.xml" "$OUTPUT/SHA256SUMS.txt"
  gh release edit "$TAG" --repo "$REPOSITORY" \
    --title "LanBox $TAG" --notes-file "$OUTPUT/release-notes.md"
else
  gh release create "$TAG" --repo "$REPOSITORY" --verify-tag --draft \
    --title "LanBox $TAG" --notes-file "$OUTPUT/release-notes.md" \
    "$OUTPUT/$ARCHIVE" "$OUTPUT/appcast.xml" "$OUTPUT/SHA256SUMS.txt"
fi

# 回读 draft 的附件大小与 GitHub 计算的 SHA-256；完整后才切换 latest feed。
# GitHub 的按标签接口仅返回已发布 Release，草稿必须按 ID 读取。
RELEASE_ID="$(gh release view "$TAG" --repo "$REPOSITORY" --json databaseId --jq .databaseId)"
gh api "repos/$REPOSITORY/releases/$RELEASE_ID" > "$OUTPUT/github-release.json"
python3 scripts/release-config.py check-upload "$OUTPUT"
gh release edit "$TAG" --repo "$REPOSITORY" --draft=false --latest
gh release view "$TAG" --repo "$REPOSITORY" --json url --jq .url
