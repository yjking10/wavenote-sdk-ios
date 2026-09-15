# wavenote-sdk-ios

WaveNote iOS 原生 Demo，演示扫描绑定连接、设备设置、空闲时文件同步、下载进度及原生音频播放。使用 **0.2.0-alpha.1** SDK 候选版本。

## 快速集成

iOS 15+；真机 arm64，模拟器 arm64/x86_64。验证工具链：Xcode 26.6 / Swift 6.3.3，支持 Swift / Objective-C。

本仓库随 Demo 提供编译后的 SDK：`Frameworks/WaveNoteSDK.xcframework`，工程已配置引用，无需另行下载或运行准备脚本。SDK 源码不包含在 Demo 中；`docs/`、日志和构建结果不提交 Git。

```bash
git clone https://github.com/yjking10/wavenote-sdk-ios.git
cd wavenote-sdk-ios
open WaveNoteDemo.xcodeproj
```

在 Xcode 中选择 `WaveNoteDemo` scheme 和运行设备，点击 Run。真机运行需在 Signing & Capabilities 中配置自己的 Signing Team 和 Bundle ID；模拟器运行无需真机签名。

集成到自己的工程时，将完整的 `Frameworks/WaveNoteSDK.xcframework` 添加到目标的 Frameworks, Libraries, and Embedded Content，设置为 Embed & Sign。Swift 使用 `import WaveNoteSDK`，Objective-C 使用 `@import WaveNoteSDK;`。更新 SDK 时替换完整 XCFramework 目录。

允许蓝牙访问。模拟器可以检查界面，不支持真实 BLE 连接。Info.plist 已包含蓝牙用途、后台 central 模式和本地网络用途说明；本 Demo 不加入热点。

## 主要调用顺序

1. 主线程配置 SDK，持有 Provider 和 Delegate，关闭自动重连。Demo 默认使用固定演示账户及持久化本地模拟归属；这不代表真实服务端绑定。
2. 用户点击扫描并选择设备；未绑定先绑定再连接，当前演示账户已绑定直接连接。选择后隐藏附近设备。
3. 等待 READY 后查询录音状态。仅明确停止录音时，查询 Note/Call 文件列表并顺序下载；录音中只显示当前文件和估算时长。
4. Delegate 更新逐文件进度，completion 确认下载和本地保存完成后显示播放按钮。原生播放器支持播放、暂停和进度显示。
5. 点击顶部已连接 SN 进入设置；电量等查询顺序执行，设置等待回读确认。增益使用 0–255 原始整数。
6. 断开时停止同步和播放、退出设置并隔离旧回调。断开保留模拟归属；解绑需确认，不清空设备内容。维护操作需确认，结果未确认不能当作执行成功。

接入代码：[Swift](App/SwiftIntegration.swift) · [Objective-C](App/ObjCIntegration.m) · [HTTP Provider](App/HTTPIdentityProvider.swift)。HTTP 示例只请求宿主提供的 HTTPS 服务，用户 Token 由宿主登录系统提供；Demo 界面不会发起真实身份请求。切换身份前取消旧请求并重新配置 SDK，不自动重试绑定或解绑。

SDK 日志默认由 Demo 开启，仅输出脱敏摘要；可在配置处调用 `openLog(false)` 关闭。不要记录凭据、原始身份或音频。模拟归属和音频保存在应用私有目录，卸载应用会清除；解绑保留本地音频。首页只展示当前设备的文件，不自动录音。同步失败后由用户重试。
