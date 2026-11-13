# bluetooth_sound

一个 macOS 14+ 菜单栏应用，支持 Apple 芯片和 Intel Mac。打开后会出现在菜单栏。

- 单击图标切换整台 Mac 的蓝牙开关。蓝牙开启时，图标跟随系统的当前声音输出。蓝牙关闭时显示带斜线的蓝牙标志。
- 双指辅助点按（或右键、Control-单击）打开设备菜单。选取已配对设备即可连接。连接音频设备时，应用会等待系统识别该设备，再把它设为声音输出。已连接设备还可以通过子菜单断开连接。支持上报电量的设备会显示电量。
- 菜单里的「打开蓝牙设置」可以前往 macOS 的蓝牙设置配对新设备。
- 在 Spotlight 搜索 `bluetooth_sound` 并打开，或从 Finder 打开应用，即可切换简体中文或 English，以及设置登录时启动。关闭设置窗口后，应用会继续在菜单栏运行。

初次使用请在 macOS 的提示中允许蓝牙访问。双指点按使用系统的「触控板 → 辅助点按」设置。启用登录启动前，可以先把应用拖入「应用程序」文件夹，再从该位置打开。

## 构建

打开 `bluetooth_sound.xcodeproj` 并运行 `bluetooth_sound` 方案。使用 Xcode 27 可通过命令行构建双架构 Release：

```sh
xcodebuild -project bluetooth_sound.xcodeproj -scheme bluetooth_sound \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath .build/Xcode ONLY_ACTIVE_ARCH=NO 'ARCHS=arm64 x86_64' build
```

本地构建使用临时签名。整机蓝牙开关调用 macOS 的私有 IOBluetooth 接口，适用于本地使用，其兼容性取决于系统版本。设备连接和声音输出使用 IOBluetooth 和 Core Audio。无第三方运行时依赖。

实现参考了 [blueutil](https://github.com/toy/blueutil) 的蓝牙开关接口，以及 [ToothFairy](https://c-command.com/toothfairy/help/introduction) 的设备连接交互。
