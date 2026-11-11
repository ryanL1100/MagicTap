# MagicTap

用于 Apple Magic Mouse 的 macOS 菜单栏触控工具。SwiftUI + AppKit 界面，C 桥接原始触控，所有处理在本机完成。

## 功能

- 一、二、三指轻触分别绑定动作，默认左键、右键、中键。
- 调亮 / 调暗屏幕，增大 / 减小音量，静音 / 取消静音。
- 为每个手势选择要打开的 App；已运行的应用切到前台。
- 调度中心、前进、后退；具体效果取决于系统和应用快捷键设置。
- 轻触时限和移动容差配置、预览模式、实时触控帧计数。

每个手势只能绑定一个动作。亮度、音量每次调整 6.25 个百分点。亮度优先控制内置显示器，没有内置屏幕时尝试主显示器；音量控制当前默认输出设备。不兼容的显示器或音频输出会显示失败原因。

## 需要打包吗？

- **已有 `.app`：** 直接运行，不需要再编译或压缩。
- **从源码运行或修改后试用：** 需要编译为 `.app`，运行 `./build.sh`。
- **复制到另一台电脑：** 可以直接复制 `.app`；也可运行 `./package.sh` 生成 ZIP，ZIP 只是传输容器。

不依赖 npm、Homebrew 包或第三方 Swift 库。当前工程通过命令行构建，不需要 `.xcodeproj`。

## 环境与构建

需要 macOS、Xcode 或含 Swift 编译器的 Command Line Tools。可先检查：

```sh
xcode-select -p
xcrun swiftc --version
```

没有开发工具时，可使用 `xcode-select --install` 安装。

```sh
git clone https://github.com/ryanL1100/MagicTap.git
cd MagicTap
./build.sh
```

输出为 `dist/MagicTap.app`。脚本编译 C 和 Swift、复制 `Info.plist`、做本地临时签名、验证签名，再运行内置自测。构建不会自动打开应用或更改权限。

```sh
open dist/MagicTap.app
```

**不要同时运行多个副本。** 如果已有授权可用的应用，先保留它，验证新构建后再替换。

脚本按当前 Mac 架构构建，不生成 Universal Binary。部署目标为 macOS 14.0；实际编译与设备验证环境为 Apple 芯片、macOS 26.2、Swift 6.2.1，其他系统和 Intel Mac 未验证。私有接口是否可用取决于系统版本。

## 可选：ZIP 打包

```sh
./package.sh
```

该命令会先构建和自测，再生成 `dist/MagicTap-0.2.0-arm64.zip`（文件名中的架构随当前 Mac 改变）。`dist/` 和应用二进制不会提交到 Git。

默认使用 `codesign --sign -` 临时签名，没有 Developer ID 签名或 Apple 公证。如有自己的签名证书，可设置：

```sh
MAGICTAP_SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' ./package.sh
```

脚本只负责签名，不包含 hardened runtime、公证或 App Store 发布流程；私有接口也不适合 App Store 上架。

## 使用与权限

1. 通过蓝牙连接 Magic Mouse，打开应用，点击“刷新设备”。目前通过名称包含 `Magic Mouse` 筛选设备，排除内置触控板。
2. 点击“开始识别”。每次启动默认暂停、默认勾选“仅预览，不执行动作”。
3. 先把所有手指抬离鼠标，再落下并抬起手指。默认有效时长 35–250 ms，移动容差为触控范围的 3.5%。
4. 在窗口底部确认识别结果。要执行点击或快捷键，点击“打开权限设置”，在“隐私与安全性 → 辅助功能”中为**实际运行的那一份应用**授权。
5. 必须等应用显示“辅助功能权限已开启”，再取消“仅预览”。系统列表开关开启并不一定代表当前副本已获得权限。
6. 亮度、音量和打开 App 不经过模拟点击，无需辅助功能权限。它们也受“仅预览”开关控制。
7. 鼠标断线或重新连接后，点击“刷新设备”。关闭设置窗口后应用继续在菜单栏运行，可在菜单中暂停或退出。

### 识别正常，但其他应用不能点击

若底部显示“需要辅助功能权限才能执行此动作”：

1. 退出其他副本，只保留准备使用的应用。
2. 在辅助功能列表中移除旧 MagicTap 记录，使用 `+` 重新选择实际使用的 `.app`。
3. 开启权限，按系统要求完成本人 Touch ID / 密码验证。
4. 如应用尚未更新状态，退出重开；确认应用自身显示已授权，再启动识别并关闭预览。

重新构建、替换文件或改用另一个副本后，临时签名对应的旧授权可能失效。建议将长期使用的应用放在固定位置，避免在多个副本之间切换。

### 一直收不到触控帧

检查蓝牙连接并刷新设备。仍无数据时，查看“隐私与安全性 → 输入监控”是否需要授权，按系统提示重启应用。

## 源码结构

| 文件 | 职责 |
| --- | --- |
| `Sources/MagicTap.swift` | SwiftUI 设置界面、菜单栏、配置、权限检查和动作分发 |
| `Sources/TapRecognizer.swift` | 轻触识别状态机与识别器自测 |
| `Sources/TouchBridge.h` / `.c` | 加载 MultitouchSupport，筛选鼠标并转发触控帧 |
| `Sources/SystemActions.swift` | CoreAudio 音量、DisplayServices 亮度、App 启动 |
| `Resources/Info.plist` | 应用标识、版本、最低系统版本和菜单栏配置 |
| `build.sh` | 编译、生成 `.app`、签名和自测 |
| `package.sh` | 构建并生成 ZIP |

## 诊断与自测

```sh
./dist/MagicTap.app/Contents/MacOS/MagicTap --self-test
./dist/MagicTap.app/Contents/MacOS/MagicTap --probe
./dist/MagicTap.app/Contents/MacOS/MagicTap --system-probe
./dist/MagicTap.app/Contents/MacOS/MagicTap --capture
```

- `--self-test`：识别器、音量/亮度边界、缺失 App 校验和动作权限分类测试，不模拟真实鼠标操作。
- `--probe`：列出触控设备及筛选结果。
- `--system-probe`：只读检查音频设备及显示器亮度接口。
- `--capture`：监听五秒触控并输出统计，不执行动作。请避免和正在监听的另一个副本同时使用。

另有 `--system-check`（将音量、亮度原值写回以检查可写性）和 `--open-app-check /System/Applications/Calculator.app`（实际打开指定应用）供开发诊断使用。

## 验证范围与限制

当前 0.2 源码从开发记录恢复；构建脚本整理为独立工程，不覆盖已经授权的运行副本。原有 0.2 应用已在 Lightning Magic Mouse 上确认收到真实触控、识别单指轻触；重新添加正确授权后，已确认能在其他应用中点击。本机音量与亮度接口读写检查、计算器启动检查已通过。双指、三指的准确率，以及新增系统动作与实际手势的完整联动仍需继续实测。

原始触控使用私有 MultitouchSupport 接口及未公开的触点结构，亮度使用私有 DisplayServices 接口；系统升级可能需要适配。音量使用 CoreAudio；一些 HDMI / 数字音频设备没有可调系统音量。

当前不支持双轻触、拖拽、双击计数、手指长时间搭放后的追加轻触、滑动动作、自动重连、开机启动或按应用配置。物理点击过滤也需要更多设备验证，仍属于实验版。

无网络请求、触控轨迹保存或外部上传；应用偏好保存在本机 UserDefaults。
