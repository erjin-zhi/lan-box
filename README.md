# LanBox

macOS 菜单栏上的局域网文件共享工具。启动后自动创建一个临时共享文件夹，把文件拖进去，同一网络里的手机、平板、电脑用浏览器打开地址或扫码即可下载；对方也能把文件上传回 Mac。

- 原生 Swift（AppKit + SwiftUI），面向 macOS 26 及以上，界面采用 Liquid Glass 风格
- 无第三方依赖，内置基于 Network.framework 的 HTTP 服务器
- 访客端是浏览器网页，无需安装任何东西

## 构建与运行

```bash
./scripts/build-app.sh          # 生成 build/LanBox.app（Release）
open build/LanBox.app
```

想长期使用可以把 `build/LanBox.app` 拖进“应用程序”文件夹。首次运行时系统可能询问是否允许接收传入连接、发送通知，请选择允许。

## 使用

| 操作 | 说明 |
| --- | --- |
| 共享文件 | 把文件或文件夹拖到菜单栏图标，或拖进面板；也可以点“选择…” |
| 访问 | 面板里有地址和二维码，点二维码可放大成独立窗口，方便多台手机扫码 |
| 访问码 | 默认开启。扫码或用“拷贝链接”打开时自动带上访问码，手动输入地址时需要填 6 位数字 |
| 上传 | 访客点“上传到 Mac”，或在电脑浏览器里直接把文件 / 文件夹拖进网页 |
| 共享文件夹 | 默认是本次启动新建的临时文件夹；底部可切换为任意文件夹 |
| 设备 | 实时显示谁在线、在下载 / 上传什么；右键可阻止某台设备 |
| 传输 | 每个传输的进度、速度、剩余时间，可随时停止 |

### 替身（符号链接）

拖入的项目默认以符号链接加入共享文件夹，不会复制原文件。从共享中移除只删除链接，原文件不受影响。设置里可以改为“拷贝一份”。

- 原文件被移动或删除后，Mac 端会标红提示，网页上自动隐藏
- 文件夹、App 等文件包下载时即时打包为 zip（流式，不占临时空间）
- 访客上传的文件只会写入共享文件夹本身及其真实子文件夹，不会穿过替身写进你的原始文件夹

### 临时文件夹

位于系统临时目录 `…/T/LanBox/`。下次启动时，只含替身的旧临时文件夹会被清理；含有收到文件的不会删除。退出时如果临时文件夹里有收到的文件，会询问是否移到“下载”。

## 安全

- 只在局域网内提供服务，没有任何外网通信
- 访问码保存在 HttpOnly Cookie 中；同一 IP 连续输错 5 次锁定 1 分钟
- 更换访问码会让所有已连接设备重新验证
- 路径一律相对于共享文件夹解析，拒绝 `..` 和隐藏文件
- 网页内预览只对图片、音视频、PDF、纯文本开放，HTML / SVG 等一律作为附件下载

## 项目结构

```
Sources/LanBox/
  main.swift, AppDelegate.swift   菜单栏图标、弹出面板、拖放、二维码窗口、退出处理
  Model/AppModel.swift            应用状态、设置、共享文件夹管理、通知
  Model/ShareStore.swift          共享文件夹的读写、路径校验、替身
  Server/HTTPServer.swift         NWListener，端口被占用时自动顺延
  Server/HTTPConnection.swift     单个连接：解析请求头、流式读写
  Server/APIHandler.swift         路由：网页、列表、下载（Range / zip）、上传、缩略图、SSE
  Server/ServerHub.swift          设备、传输、实时事件推送
  Views/                          SwiftUI 界面
Resources/web/index.html          访客网页（单文件，无依赖）
scripts/build-app.sh              打包 .app 并 ad-hoc 签名
scripts/make-icon.swift           生成 App 图标
```

## 接口

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/` | 访客网页；`?k=访问码` 会写入 Cookie |
| POST | `/api/auth` | `{"pin": "123456"}` |
| GET | `/api/info` | 主机与本设备信息 |
| POST | `/api/hello` | 上报设备类型 / 名称 |
| GET | `/api/list?path=` | 列出文件夹 |
| GET | `/api/download?path=[&inline=1]` | 下载，支持 Range；文件夹自动打包 zip |
| GET | `/api/thumb?path=` | QuickLook 缩略图 |
| PUT | `/api/upload?dir=&name=` | 请求体即文件内容，`name` 可含子目录 |
| GET | `/api/events` | SSE：`files` `devices` `host` `transfer` `reset` `shutdown` |

命令行也能用：

```bash
curl -c jar "http://<地址>/?k=<访问码>" -o /dev/null
curl -b jar -T 文件.zip "http://<地址>/api/upload?dir=&name=文件.zip"
```

## 开发

改网页时用 `swift run`：开发模式下直接读取 `Resources/web/index.html`，刷新浏览器即可看到修改。
注意 `swift run` 启动的不是 .app，系统通知不可用；完整体验请用打包后的 App。
