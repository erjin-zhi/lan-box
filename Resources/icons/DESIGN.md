# LanBox 图标设计 · 黄色纸箱

- App 图标：工业黄纸箱、封箱胶带、深石墨底座，侧面双向箭头表达局域网文件收发。
- 菜单栏：22 × 22 pt，1.35 pt 圆头线条，单色 template，自动适配系统菜单栏外观。
- 两态共用同一箱身：共享面板显示时打开箱盖，关闭时合上；点击外部、Esc、再次点击及程序主动展开均跟随面板实际状态。
- 图标不再因传输或拖拽临时变成其他符号；服务停止时的灰化和在线设备数量沿用原行为。

## 文件

- `AppIcon-source.png`：内置 image_gen 生成的透明背景原图，保留未修改的原始像素。
- `menubar-closed.svg` / `menubar-open.svg`：可编辑矢量稿。
- 对应 `.png` / `@2x.png`：22 / 44 px 透明底导出。
- `preview.html`：菜单栏两态、深浅外观和点击演示。
- `menubar-preview.png`：菜单栏两态的静态预览。
- `Sources/LanBox/Support/BoxStatusIcon.swift`：与 SVG 坐标一致的原生模板绘制。
- `scripts/make-icon.swift`：从原图导出完整 AppIcon.iconset 和 touch icon，构建脚本再打包 ICNS。

## App 图标最终提示词

生成方式：内置 image_gen 工具，`transparent_background: true`。

```text
Use case: stylized-concept
Asset type: finished macOS application icon for LanBox, a local-network file sharing utility.
Primary request: a premium yellow cardboard shipping box with a restrained engineered industrial-tool feel.
Composition: a SINGLE centered app icon, square 1024x1024 image. Large closed cubic cardboard box in precise three-quarter isometric view, showing top and two sides. Use an understated charcoal rounded-square macOS icon tile behind the box, tile occupying approximately 82% of the canvas with a generous continuous rounded corner radius. Transparent outside the tile, including soft exterior shadow. Box occupies most of the tile but stays comfortably inside it.
Materials: golden yellow kraft paper, visibly cardboard rather than metal or plastic, very subtle fine paper grain, precise folded edges, thick well-aligned lid panels, a single slightly darker ochre packing tape strip across the top and down the near face. Simple dark crease along the top central seam, crisp bevel highlights.
Engineering character: carefully constructed geometry, squared proportions, clean alignment, a small understated dark pair of opposing horizontal transfer arrows printed on one face. Details must remain simple enough to read as a box at 32 pixels.
Color palette: warm industrial yellow and amber cardboard, deeper ochre on the shaded side, warm ivory on top highlights, charcoal graphite tile.
Lighting: soft studio lighting from upper left; controlled shallow dimensionality, smooth compact shadow, tasteful high-end native Mac utility icon.
Text: no text.
Constraints: finished standalone usable icon artwork, not a design sheet, no mockup, no labels, no title, no watermark, no giant arrows, no online dot, no blue, no shiny metal, no handles, no lid flaps opened. Actual alpha transparency outside the rounded tile.
```

