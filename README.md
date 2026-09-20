# wavenote-sdk-ios

WaveNote iOS 原生 Demo，演示扫描绑定连接、设备设置、空闲时文件同步、已完成/总文件数、逐文件进度及原生音频播放。使用 **0.2.0-alpha.1** SDK 候选版本。

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

## R202 开发鉴权配置

仅为联调，可在本机未提交的 `App/Info.plist` 中填入 `DEV_CLOUD_PRIVATE_KEY_PKCS8_B64`、`DEV_AUTH_USER_PUBLIC_KEY_SPKI_B64` 和 `DEV_AUTH_USER_PRIVATE_KEY_PKCS8_B64`。Demo 使用云私钥对 SN 做 RS256 签名，并将用户密钥交给 SDK 完成 1001–1003。严禁将生产云私钥或用户私钥放入 App、日志或仓库；生产版本必须向云端请求签名和密钥材料。

## 主要调用顺序

1. 主线程配置 SDK，持有 Provider 和 Delegate，关闭自动重连。Demo 默认使用固定演示账户及持久化本地模拟归属；这不代表真实服务端绑定。
2. 用户点击扫描并选择设备；未绑定先绑定再连接，当前演示账户已绑定直接连接。选择后隐藏附近设备。
3. SDK在BLE通知订阅就绪后优先自动同步时间，初始化完成才发布READY，宿主无需调用时间接口。等待 READY 后查询录音状态。仅明确停止录音时，查询 Note/Call 最新文件列表并顺序下载；录音中只显示当前文件和估算时长。Demo 先调用 `files.findLocalAudio` 查询当前用户的本地音频，未命中或大小变化时调用 `files.downloadToStorage`。SDK 在下载前持久化未完成任务，按用户、设备 SN、模式、文件名和原始大小核对任务。重连后复用匹配任务的原目标，传入 `resume=true`，由 SDK 验证断点；列表中已不存在或大小变化的文件不续传旧任务。
4. 页面显示“检查断点 / 继续下载 / 重新封装”。原始下载已确认完成时，SDK只重试封装。Delegate 更新下载及封装进度，同时展示已完成同步文件数/总文件数；封装100%仍需等待 SDK 完成索引保存并返回 completion，才显示播放按钮。完成后移除未完成任务索引。原生播放器支持播放、暂停和进度显示。文件 position 不连续时，SDK 确认 306 停止后仅将该文件标为失败；Demo 显示成功/失败/总数并继续后续文件，同一连接不重试失败项，重连后再核对断点并显式续传。306 未确认则停止本轮并断开连接。
5. 点击顶部已连接 SN 进入设置；电量等查询顺序执行，设置等待回读确认。增益使用 0–255 原始整数。
6. 断开时停止同步和播放、退出设置并隔离旧回调。断开保留模拟归属；解绑需确认，不清空设备内容。维护操作需确认，结果未确认不能当作执行成功。

接入代码：[Swift](App/SwiftIntegration.swift) · [Objective-C](App/ObjCIntegration.m) · [HTTP Provider](App/HTTPIdentityProvider.swift)。HTTP 示例只请求宿主提供的 HTTPS 服务，用户 Token 由 Provider 从宿主登录系统取得，不进入 SDK 配置；Demo 界面不会发起真实身份请求。退出登录时先调用 `clearConfiguration()`，再取消旧请求、删除该用户密钥缓存并清理登录态；绑定、解绑和不确定的设备命令均不自动重试。

SDK 日志默认由 Demo 开启，仅输出脱敏摘要；可在配置处调用 `openLog(false)` 关闭。不要记录凭据、原始身份或音频。模拟归属和音频保存在应用私有目录，卸载应用会清除；解绑保留本地音频。首页只展示当前设备的文件，不自动录音。同步失败后保留任务和原始文件，由用户重连后继续；同一会话不会重复续传。元数据缺失或损坏时明确报错，不自动覆盖或丢弃原文件。新目录为 `wavenote/安全编码的userIdentifier/SHA256(SN)/SHA256("mode:文件名")/设备文件主名.ogg`，由 SDK 管理。旧 Demo 的 Recordings/recordings 目录原样保留，不自动迁移或认领。文件匹配不包含设备端内容哈希，不能识别同名同大小的内容替换。

文件同步成功并保存完成索引后，Demo输出一条 `[FileCompleted]` JSON日志，包含完整DemoAudioRow字段（file.name/size/mode/key、received、status、localPath）。缓存复用成功也会输出；重复或旧completion不重复记录。日志只包含文件元信息，localPath 的用户目录段替换为 `[redacted]`，不包含音频字节、原始 SN 或凭据。

如果 APP 在 SDK 写出正式 Ogg 后、持久化完成索引前退出，下次查询或托管下载时，SDK 会校验该 Ogg的页CRC、序号、流标识、Opus头、时长、EOS和对应原始字节数；通过后原子补写完成索引，复用原文件，不重新下载。校验失败保留文件和任务并报错；补写索引失败也保留任务，供下次重试。此检查针对SDK生成的Ogg结构，不等同于完整音频解码或设备内容哈希验证。

APP 重启后可直接调用 `files.findLocalAudio(serialNumber, mode, fileName, completion)`，无需 BLE 连接。只查询当前配置用户；无匹配返回空结果，损坏返回错误。Demo 同步收到损坏的完成缓存时会让 `downloadToStorage` 删除该文件目录中的普通缓存并重新下载；符号链接、异常目录和未完成断点仍会保留错误，绝不自动删除。同名文件大小变化时先清理旧内容，再以同一目标名重新下载；新下载期间不保留旧内容。原 `download` 指定路径接口仍可使用，但不会纳入托管查询。
