# 发布 LanBox 更新

LanBox 通过 Sparkle 检查 GitHub 最新正式 Release 的 `appcast.xml`。安装包和更新源均使用 Ed25519 签名，私钥保留在发布者 Mac 的登录钥匙串中，不放进 Git 或 Release。

## 一次性设置

运行以下命令，将 SwiftPM 构建文件和官方 Sparkle 工具放入系统本地缓存，避免同步目录中的签名干扰：

```sh
SWIFT_BUILD_DIR="$(python3 scripts/release-config.py build-path)"
swift package --disable-keychain --scratch-path "$SWIFT_BUILD_DIR" resolve
swift test --disable-keychain --scratch-path "$SWIFT_BUILD_DIR"
./scripts/test-updater.sh
```

Sparkle 工具位于该目录下的 `artifacts/sparkle/Sparkle/bin/`。`build-app.sh` 和 `prepare-release.sh` 会自动使用同一目录。

本项目的 Keychain 账号为 `app.lanbox.mac.sparkle`。当前公钥已经记录在 `Resources/UpdateConfig.json`，在新的发布电脑上应安全迁移原密钥，不能重新生成一个不同的密钥替代它。旧客户端只信任应用内的公钥。按照 [Sparkle 官方密钥文档](https://sparkle-project.org/documentation/#eddsa-ed25519-signatures) 备份与迁移，私钥备份应存到仓库之外的安全位置。

## 每次发布

1. 在 `Resources/UpdateConfig.json` 更新 `version`，保持 `publicEDKey`、`keychainAccount` 和 `feedURL` 不变。
2. 准备 Markdown Release 说明，运行测试并提交源代码。构建号由打包脚本生成 14 位 UTC 时间戳，发布时还会与上次更新源核对，必须严格递增。
3. 从干净的提交构建：

   ```sh
   ./scripts/prepare-release.sh /path/to/release-notes.md
   ```

4. 检查 `build/release/<版本>/` 中的安装包、更新说明和 `appcast.xml`。提交后的任何代码变动都需要重新构建。将该提交和对应 `v<版本>` 标签推送到 `erjin-zhi/lan-box`。
5. 运行：

   ```sh
   ./scripts/publish-release.sh
   ```

发布脚本先校验源码提交、远程标签、版本递增、签名与校验文件，再创建 draft Release。安装包、`appcast.xml` 和 `SHA256SUMS.txt` 全部上传且 SHA-256 回读一致后，才转为最新正式 Release，避免客户端先发现尚不存在的安装包。脚本不会覆盖已存在的 Release；如果上传中断，检查并处理遗留 draft 后重试。

`prepare-release.sh` 可以在开发期间运行以检查打包，但发布脚本会拒绝来自未提交工作区的包。源代码提交后需重新准备正式包。`release.json` 记录源码提交与构建号，仅作为本地发布校验材料。

## 签名与兼容性

当前安装包为 Apple Silicon / Intel 通用版，最低 macOS 26。应用使用 ad-hoc 代码签名，尚无 Developer ID 或 Apple 公证；Sparkle 的 Ed25519 签名用于验证更新来源和内容，不能替代 Apple 公证。

构建脚本完整嵌入 Sparkle framework，保留符号链接、helper 可执行权限与许可文件，并从内向外签名。不能用 `codesign --deep` 重签整个应用来替代这一流程；`--deep` 只用于签名验证。

应用在系统本地缓存中组装与签名，`build/LanBox.app` 是指向产物的符号链接，仍可直接用 `open build/LanBox.app` 启动。发布 ZIP 在系统临时目录中制作并解包验证，再放入项目的 `build/release/`。这样可避免 Documents/iCloud 的 File Provider 给 `.app` 和 `.xpc` 异步添加 FinderInfo，导致签名失败。安装使用时请从 Release ZIP 解压并移入「应用程序」。

1.0.0 没有更新器，用户需手动安装一次 1.1.0。此后可在应用中检查更新，默认每天自动检查；安装与重启由用户确认。需要改变更新源或签名密钥时，先阅读 [Sparkle 发布文档](https://sparkle-project.org/documentation/publishing/) 与 [密钥轮换说明](https://sparkle-project.org/documentation/#rotating-signing-keys)。
