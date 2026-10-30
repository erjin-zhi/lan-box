# LanBox 图标设计 · 线条信号盒

工具类 App 的简约线条标志：一个开口的等轴测盒子，盒口升起局域网信号（一个点、两道弧）。
盒子代表“放文件的地方”，信号代表“在局域网里共享”。

- App 图标：石墨色圆角方块（#3C3F45 → #1D1E22 的轻微纵向渐变，顶部 10% 白色描边作为边缘高光），白色线条盒身（#F5F5F7），信号用唯一的强调色浅青（#64D2FF）。盒口和右侧面有极淡的填充，增加一点体积感。
- 菜单栏：22 × 22 pt 单色 template，1.35 pt 圆头线条，与 App 标志同一套坐标（64 单位网格 × 0.43）。面板收起时是盒子 + 信号点；面板展开时多一道信号弧。服务停止时的灰化和在线设备数量沿用原行为。
- App 内标志（顶部的 LanBox 标志）、网页左上角标志和浏览器标签页图标都直接使用同一份矢量文件。

## 文件

- `Resources/web/logo.svg`：唯一的矢量母版（64 × 64，含圆角方块）。改图标只改这一个文件。
- `scripts/make-icon.swift`：从母版导出 macOS AppIcon.iconset（16–1024 px，四周留 9.8% 并加投影）和 180 px 网页 touch icon（满版方图，iOS 自己裁圆角）。构建脚本再打包 ICNS。
- `Sources/LanBox/Server/WebAssets.swift`：App 内标志和 favicon 读同一个母版，按显示尺寸做光学调整。
- `Sources/LanBox/Support/BoxStatusIcon.swift`：菜单栏图标的原生绘制；`menubar-closed.svg` / `menubar-open.svg` 是对应的可编辑矢量稿，`.png` / `@2x.png` 为 22 / 44 px 导出。
- `AppIcon-preview.png`：1024 px 导出预览。

## 光学调整

线宽随显示尺寸变化（64 单位网格）：128 px 以上 2.9，≤128 px 3.2，≤64 px 3.6，≤32 px 4.6，≤16 px 5.8。
16 px 去掉外圈信号弧和侧面明暗，只保留盒子、信号点和内圈弧。
`make-icon.swift` 与 `WebAssets.logoSVG(forPixels:)` 使用同一套规则，改动时两处一起改。

## 旧方案

此前的“悬浮玻璃盒”位图方案（`AppIcon-source.png`）已不再参与构建。
