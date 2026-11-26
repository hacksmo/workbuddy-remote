# macOS 原生壳：为什么不能用「脚本 + Chrome --app」

这份笔记记录踩坑结论，避免以后又走回头路。

## 两个死结

### 1. Dock 图标归属「进程」，不是「窗口」

Dock 里那个图标是**进程**申请来的。bash 脚本进程不连 WindowServer，
所以即使包成 `.app`、plist 写满、图标资源齐全，Dock 里也不会出现。

早期尝试：脚本里 `exec` 成 Chrome。结果进程身份变成 Google Chrome ——
Dock 里只有 Chrome，还是没 WorkBuddy Remote。

### 2. Chrome `--app=` 没有单实例语义

实测：已有实例在跑时执行 `chrome --app=URL`，它会把这行命令交给那个
实例处理，行为是「新开一个窗口」。同一个 URL 也一样。于是点一次图标
多一个窗口，永远堆着不消失。

中间试过用 AppleScript 找已有窗口再激活（`focus_existing`），能挡住
重复开窗，但这只是补丁 —— 而且仍然没有 Dock 图标。

### 3. 顺手试过 `app_mode_loader`，也失败

Chrome/Edge 的 PWA 走 `~/Applications/Chrome Apps.localized/*.app`，
executable 是浏览器内部的 `app_mode_loader`。照抄 YouTube.app 的
plist 结构，报：

```
No suitable profile found.
Using user data dir /Users/shuimo/Library     ← 路径被空格截断到 ~/Library
```

`CrAppModeUserDataDir` 不能含空格，且要求 Chrome 主进程以同一 profile
运行。清 `~/Library/Singleton*`、手动让 Chrome 以同 profile 跑，都没用。
这条路依赖浏览器内部状态，不可靠。还顺带产出 `~/Library/Default`（4.4M）
垃圾目录。

## 竞品都是原生壳

| 工具 | 技术 |
|---|---|
| Fluid / Unite | macOS 原生 WebKit |
| Pake | Tauri（系统 WebView + Rust），几 MB |
| WebCatalog / Rambox / Station | Electron |
| Nativefier | Electron，2023 年 9 月已归档 |
| Chrome/Edge PWA | 浏览器托管的 app_mode_loader（见上，不可控） |

没有一个用「脚本 + Chrome --app」。原因就是上面两条 —— 这两件事只能由
进程本身提供。

## 原生壳免费拿到的东西

AppKit 里几行代码，等于把一堆边界情况都解决了：

```swift
// 单实例：点 Dock 图标时已有窗口就提到前面，没有才新建
func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool

// 关窗不退出，留在 Dock 里
func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
```

Dock 图标、Cmd+Tab、窗口最小化/恢复、菜单栏、About 面板，全部自动。

## 踩过的四个位置/生命周期坑

### 坑 1：NSAlert 在窗口未建立时居中算错

首次配置用 `NSAlert` 弹窗，实测弹到 `Y=-940`（屏幕外），用户以为应用
没启动。改成窗口内的 HTML 引导页 —— 位置一定正确，还能放「扫描」按钮。

### 坑 2：`setFrameAutosaveName` 在多显示器下恢复出屏幕外坐标

autosave 记录的格式是 `x y w h screenX screenY screenW screenH`，带
「上次所在屏幕」。用户三块屏（主屏 1710×1112、左侧竖屏 1080×1920、
上方屏 1920×1080），恢复出来 `Y=1251` / `Y=-971`，窗口完全看不见。

改成自己算位置，不用 autosave。

### 坑 3：`NSScreen.main` 是「接收键盘事件的屏」，不是主屏

三屏环境下 `NSScreen.main` 指到上方的外接屏（`{0,1112}, 1920×1080`），
窗口开到那里去了。带菜单栏的主屏是 `NSScreen.screens.first`。

### 坑 4：`isReleasedWhenClosed` 默认 true，关窗后引用悬空

关窗后 `window` 变量指向已释放对象，点 Dock 图标 → `applicationShouldHandleReopen`
里访问它 → 直接崩溃，进程消失。表现为「关窗后点 Dock，应用没了」。

```swift
w.isReleasedWhenClosed = false   // 必须
```

## 打包

`macos/build-dmg.sh` 出通用二进制：

```bash
swiftc -O -target arm64-apple-macos12.0  -o /tmp/a macos/shell.swift
swiftc -O -target x86_64-apple-macos12.0 -Xlinker -U \
  -Xlinker '__swift_FORCE_LOAD_$_swiftCompatibility56' -o /tmp/b macos/shell.swift
lipo -create /tmp/a /tmp/b -output macos/bin/WorkBuddyRemote
```

那个 `-U __swift_FORCE_LOAD_$_swiftCompatibility56` 是必须的：CLT 里的
`libswiftCompatibility56.a` 只有 arm64 切片，交叉编译 x86_64 时链接会报
`Undefined symbols for architecture x86_64`。这个符号是给旧系统兜底用的，
本壳最低 macOS 12，去掉无害。

最终 250KB（strip 后），DMG 679KB。