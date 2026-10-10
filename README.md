# QuickScreenControl

macOS 菜单栏小工具：点击状态栏图标下拉面板（不是独立窗口），快速控制多块显示器。

## 功能

- **屏幕镜像**：任意屏幕可镜像到其他屏幕，或停止镜像恢复扩展。不限屏幕数量，也不依赖接口类型（DP / HDMI / USB-C）。
- **亮度**：内置屏走 DisplayServices；外接屏走 DDC/CI（Apple Silicon 的 IOAVService）。
- **对比度、色温**：对比度走 DDC（VCP 0x12），色温通过 gamma 表实现。
- **输入源切换**：DDC（VCP 0x60），切换前会弹出确认框。
- **预设**：把镜像、亮度、输入源、色温、恢复扩展等动作组合成一个预设，按顺序执行。
- **全局快捷键**：`⌃⌥⌘↑` / `⌃⌥⌘↓` 调节所有可控屏亮度；`⌃⌥⌘1`–`3` 应用对应槽位的预设。
- **自动规则**：某块屏接入或断开时自动执行预设。
- **定时亮度**：每天在指定时间把某块屏调到指定亮度。
- **URL Scheme**：`quickscreen://preset/<预设名>`，可从脚本或快捷指令调用。
- **开机启动**：通过 SMAppService 注册登录项。

## 系统要求

- macOS 14 及以上（目标运行环境为 macOS 26）
- Xcode 26 命令行工具 / Swift 6.x（用于构建）
- Apple Silicon（DDC 依赖 IOAVService）

## 构建与运行

本项目使用 SwiftPM 构建，不需要 Xcode 工程。

```bash
./scripts/build_app.sh                 # 生成 build/QuickScreenControl.app（release + ad-hoc 签名）
open build/QuickScreenControl.app
```

安装到应用目录：

```bash
cp -R build/QuickScreenControl.app /Applications/
open /Applications/QuickScreenControl.app
```

开发时可以直接用 `swift build`，产物在 `.build/debug/QuickScreenControl`。

### 命令行诊断

诊断模式不启动菜单栏界面，直接在终端输出结果：

```bash
.build/debug/QuickScreenControl --probe                # 列出显示器、亮度与 DDC 服务
.build/debug/QuickScreenControl --probe --set 50       # 所有可控屏设为 50% 并回读
.build/debug/QuickScreenControl --probe --mirror-test   # 第 1 块镜像到第 2 块，2 秒后恢复扩展
```

> `--set` 与 `--mirror-test` 会真实改动显示器，请在可以接受的前提下使用。

## 配置

配置保存在：

```
~/Library/Application Support/QuickScreenControl/config.json
```

屏幕以 `厂商-型号-序列号` 作为稳定标识，不依赖插口或临时编号。

## 项目结构

| 文件 | 作用 |
|---|---|
| `Sources/QuickScreenControl/main.swift` | 入口；`--probe` 走诊断，否则以 accessory 模式启动 |
| `Sources/QuickScreenControl/AppDelegate.swift` | 状态栏图标、NSPopover 弹出、设置窗口、URL 处理 |
| `Sources/QuickScreenControl/PanelView.swift` | 下拉面板的 SwiftUI 界面（每块屏一张卡片） |
| `Sources/QuickScreenControl/SettingsView.swift` | 设置窗口：预设、自动规则、定时亮度、屏幕名称 |
| `Sources/QuickScreenControl/AppModel.swift` | 核心状态、动作执行、定时与插拔规则、快捷键 |
| `Sources/QuickScreenControl/Config.swift` | 数据模型（预设、规则、定时）与配置读写 |
| `Sources/QuickScreenControl/Displays.swift` | 枚举在线屏幕、身份匹配、镜像切换 |
| `Sources/QuickScreenControl/DDC.swift` | IOAVService 的 DDC/CI 读写，EDID 与 DisplayHints 身份解析 |
| `Sources/QuickScreenControl/Brightness.swift` | 亮度控制器（内置 / DDC），写入串行合并 |
| `Sources/QuickScreenControl/Tint.swift` | 色温（gamma 表） |
| `Sources/QuickScreenControl/Hotkeys.swift` | 全局快捷键（Carbon RegisterEventHotKey） |
| `Sources/QuickScreenControl/Probe.swift` | `--probe` 诊断 |
| `scripts/build_app.sh` | 打包 `.app`、写入 Info.plist、ad-hoc 签名 |

## 已知注意点

- **DDC 写入**需要连发两次才能稳定生效；**DDC 读取**偶尔会收到空包，已做重试。
- **设备匹配**：DDC 代理与显示器的 `DisplayHints`（EDID UUID）挂在同一个 `iop-dcpextN-nub` 子树下，据此关联。EDID UUID 不含序列号，所以两块同型号的屏幕无法区分，会退化为按顺序配对。
- **输入源切换**可能让 Mac 无法再通过 DDC 切回，需要按显示器按钮或在对应设备上操作。
- **私有接口**（DisplayServices、IOAVService、IORegistry 结构）未经公开文档保证，系统大版本更新后可能需要调整。
- **未签名分发**：使用 ad-hoc 签名，首次打开若被系统拦截，右键选择"打开"。
- 镜像状态下 `NSScreen` 可能暂时缺失，屏幕名称会从缓存或 IORegistry 的 `ProductName` 读取。

## 许可

本项目基于 [MIT License](LICENSE) 发布。
