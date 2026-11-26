<div align="center">

<img src="assets/icon-512.png" width="112" alt="WorkBuddy Remote">

# WorkBuddy Remote

**在另一台电脑上，接着用工位上那台 WorkBuddy。**

官方的远程只在**手机和平板**上 —— 桌面端没有「连另一台电脑」这个入口。<br>
这个项目补的就是这一格：任何一台电脑打开浏览器，就是工位那台的完整界面。

[![Release](https://img.shields.io/github/v/release/hacksmo/workbuddy-remote?color=0071e3&label=release)](https://github.com/hacksmo/workbuddy-remote/releases/latest)
[![License](https://img.shields.io/badge/license-MIT-34c759)](LICENSE)
[![Access](https://img.shields.io/badge/访问方式-任意浏览器-5e5ce6)](#三步上手)
[![Latency](https://img.shields.io/badge/局域网-8.6ms-0f9d58)](#同网段时自动走近路)

</div>

<br>

<img src="assets/shots/app-main.jpg" alt="另一台电脑上的完整界面" width="100%">

<br>

<p align="center">
<img src="assets/shots/app-mobile.jpg" alt="手机浏览器里打开的样子" width="238">
</p>

<p align="center"><sub>顺手做的：手机浏览器也能开，窄屏下侧栏收成抽屉、表格可横划。<br>
主场景仍然是电脑连电脑。</sub></p>

<br>

## 它解决什么

官方已经把「手机连电脑」「平板连电脑」做完了。缺的是**电脑连电脑**。

打开设置里的设备连接，能看到的只有两项：`允许移动设备远程连接`，
和 `远程控制插件 (WorkBuddy Remote)` —— 后者写的是「安装插件后，可在**手机上**
实时查看并操控这台电脑」。桌面端始终没有「连另一台电脑」这个入口。

这个缺口不小。真正要干活的时候，你需要的是键盘、多窗口、能并排看两份文档、
能把代码贴进会话里 —— 手机那块屏替代不了。场景很具体：

- 在家里的台式机前，想接着用公司那台机器上跑了一半的任务
- 在会议室、客户现场，手边只有别人的电脑或一台备用机
- 两台自己的机器，一台在跑长任务，另一台想看着、想插话

这几种情况下，官方 App 帮不上忙，因为它没有桌面版。

也不该退回去用远程桌面 —— 那传的是整屏像素，滚动一条长回答要等画面刷新，
而且被控机上你正在干别的，屏幕一直在动，对方看得一清二楚。

这个项目换个思路：**不搬像素，直接把那个界面开给你。**
在被控机上跑一个小服务，另一台电脑用浏览器打开 —— 同一个会话、同一份队列、同一个进度。
手机的浏览器同样能打开，但那是顺带的能力，不是重点。

> **和官方那个同名插件没关系。** 设置里那个 `WorkBuddy Remote` 是官方内置的插件，
> 用来给手机远控做授权，走的是官方云端通道。这个项目是独立的，走本机调试端口，
> 两者不共用链路，开着关着都不影响对方。

<br>

## 三步上手

### 一、在 WorkBuddy 那台机器上装

```bash
curl -fsSL https://raw.githubusercontent.com/hacksmo/workbuddy-remote/main/install.sh | bash
```

> **问自己一句：WorkBuddy 是装在这台机器上吗？**
> 是 → 就是这一步，装的是**被控端**，装完继续看第二步。
> 不是 → 这台是你要用来连过去的电脑。**通常什么都不用装**，装完被控端直接用浏览器开就行。
> 只有想让它也有个 App 图标时，才回来看「想要一个像 App 的图标」那一节。

### 二、启动

```bash
workbuddy-remote
```

终端会把它能用的地址全列出来，每条都带着密码：

```
访问地址
  （仅本机）
  http://127.0.0.1:8797/?token=8550acac5c1b32ce...

  （同网段直连，免公网）
  http://192.168.0.52:8797/?token=8550acac5c1b32ce...
```

> 启动时会重启一次 WorkBuddy，正在跑的任务会中断 —— 调试端口只能启动时指定，没法热加。
> 如果你的 WorkBuddy 本来就是带调试端口启动的，会自动跳过重启。

`workbuddy-remote --status` 随时可以再列出这些地址（忘了二维码/网址时不用翻终端历史）
和当前运行状态，`--stop` 停掉。注意 `--stop` 会一并关掉开机自启，要恢复重新跑一次
`./scripts/autostart.sh install`。

### 三、另一台电脑，浏览器打开

同一 Wi-Fi 下，用上面**「同网段直连」那条地址**，在另一台电脑的浏览器里打开就行。
**那台电脑什么都不用装**，不用装 WorkBuddy，也不用装 Node.js。

换个网络（比如在客户现场、或者用别家的网）就看下面「从外网访问」。

界面和桌面端一致，键盘快捷键、多窗口、并排看文档都是你熟悉的那套 ——
因为它就是桌面端的界面，只是渲染在另一块屏幕上。

<br>

## 能做什么

| | 能力 | 说明 |
|---|---|---|
| 💻 | **电脑连电脑** | 官方没有的那一格。另一台电脑的浏览器，就是工位那台的完整界面 |
| 💬 | **完整对话** | 发消息、看思考过程、读长回答，Markdown 和代码块正常显示 |
| 📋 | **会话列表** | 按空间分组，和桌面端侧栏一致 |
| ⏹ | **随时叫停** | 跑偏了立刻中断 |
| 🔀 | **切换模型** | 与桌面端同一套配置 |
| 🖼 | **粘贴图片** | 剪贴板里的图直接发 |
| 📥 | **排队消息** | 生成期间可以继续发，排在后面等，**和桌面端共用同一个队列** |
| ➤ | **插话引导** | 不排队，把消息塞进当前这一轮，模型不中断，边跑边纠方向 |
| 🖥 | **预览面板** | 会话里产出的 HTML、图片、本机文件，右侧直接打开看 |
| 🔗 | **链路提示** | 页面底部实时显示走的是局域网还是公网、延迟多少 |
| 📱 | **顺带能用手机** | 手机浏览器同样能开，窄屏收侧栏、表格可横划 |

<br>

## 几个想得比较细的地方

### 同网段时自动走近路

控制端启动时先探一下局域网，通就直连，不通静默回退到公网，你不用管。
同一条链路两个入口实测差 **287 倍**（8.6ms vs 2466ms），而且直连不占服务器带宽。

### 排队消息和桌面端是同一份

很多远程工具在这里偷懒：把消息先存在浏览器里，等回复结束再发出去。
后果是你排在队里的消息，**坐在那台机器前的人完全看不到**。

这里排队走的是 WorkBuddy 自己的队列，两边看的是同一份真相 ——
你在这台电脑上排的三条，回到工位打开桌面端，它们还在队列里等着。

### 走公网也不卡

用反向隧道而不是内网穿透。原因是：公司和运营商的网络通常只拦「外面主动连进来」，
不拦「里面主动连出去」。把方向反过来，这类网络就不再是问题，
不用跟 NAT 类型较劲，也不用装客户端。

页面数据是增量推送的，一条长回答在往上滚的时候不会整段重传。

### 不会把你的东西暴露给全公司

默认监听局域网，但**没有密码进不来**；密码自动生成，存在本机、权限 600。
介意同网段可见就 `WB_LAN=0`，只留隧道。

### 手机上也真的能用（顺带）

重点虽然是电脑连电脑，但既然用的是浏览器，手机自然也能开。
所以窄屏也做了：侧栏收成抽屉，点一下会话自动收回；
输入框字号设成 16px，否则 iOS 聚焦时会自己放大页面；
长表格改成横向滚动，而不是把中文一列压成一个字一行。

临时用手机看一眼可以，真要改东西还是建议回电脑上 —— 手机那块屏装不下并排两份文档。

<br>

## 为什么不用远程桌面

如果只是「想在另一台电脑上操作」，远程桌面当然能做。区别在于传什么：

| | 远程桌面 | 这个项目 |
|---|---|---|
| 传的东西 | 整屏像素 | 结构化内容 |
| 一条长回答往上滚 | 等画面刷新 | 文字直接流过来 |
| 被控机在干别的 | 屏幕一直在动，对方全看见 | 只看这个会话 |
| 网络不好时 | 整屏重传，糊成马赛克 | 只补增量，还能读 |
| 手机上看 | 得缩放拖拽 | 原生排版的网页 |

实测同一条链路，局域网直连 **8.6ms** 就能刷出新内容。

<br>

## 想要一个像 App 的图标？（可选）

浏览器打开已经能用了。如果你天天都要连过去，可以做得更像一个正常应用 ——
Dock 里有图标、Cmd+Tab 能切、点一下收起再点一下回来 ——
那就在**你手上这台电脑**装一个控制端。

> 注意：控制端**不需要** Node.js，也不用装 WorkBuddy，它只是一个窗口。
> 装错是最常见的错误：在被控机上装两遍，或者在控制机上装了桥。

### macOS

<a href="https://github.com/hacksmo/workbuddy-remote/releases/latest/download/WorkBuddy-Remote.dmg">
<img src="https://img.shields.io/badge/下载_DMG-692KB-0071e3?style=for-the-badge&logo=apple&logoColor=white" alt="下载 DMG" height="36">
</a>

双击挂载，把应用拖进「应用程序」。首次打开填地址和密码 ——

<img src="assets/shots/app-setup.jpg" alt="首次配置" width="62%">

同一 Wi-Fi 下点「**扫描**」，一秒多就能自动找到被控端，不用手抄 IP。

> **首次打开提示「无法验证开发者」？** 右键点图标选「打开」，弹窗里再点一次「打开」。
> 只需一次 —— 应用没有买 Apple 的开发者证书（$99/年，个人项目没买）。

### Linux

```bash
curl -fsSL https://raw.githubusercontent.com/hacksmo/workbuddy-remote/main/install.sh \
  | bash -s -- --client 'http://192.168.0.52:8797/?token=8550acac5c1b32ce...'
```

应用菜单里出现「WorkBuddy Remote」，点开是独立窗口，没有地址栏。

> macOS 也可以用同一条命令装，效果和上面的 DMG 一样，只是没有图标美化。

<br>

## 从外网访问（可选）

上面那步是同一 Wi-Fi 下的用法。如果两台电脑不在一个网里 —— 在家连公司、
在客户现场连自己的机器 —— 就需要一台有公网 IP 的服务器，最省事的是几十块一个月的轻量云。

```bash
./scripts/tunnel.sh          # 首次运行生成配置模板
vim ~/.config/workbuddy-remote/tunnel.env
./scripts/tunnel.sh          # 再跑一次就连上
```

脚本会建一条反向 SSH 隧道，把被控端的端口映射到你的域名。
之后在任何网络下用 `https://你的域名/?token=...` 都能打开。

<details>
<summary><b>⚠️ 开了全局代理的话，这一项必须配</b></summary>

<br>

`TUNNEL_BIND_IFACE` 填你的物理网卡（macOS 一般是 `en0`）。

不填的后果：隧道会走代理出口，路径变成「本机 → 代理 → 中转 → 代理 → 本机」四跳，
实测延迟从 110ms 涨到 1 秒以上，打字能感觉到滞后。

判断方法：

```bash
ssh -i ~/.ssh/id_ed25519 ubuntu@1.2.3.4 'echo $SSH_CLIENT'
```

显示的 IP 是代理服务器而不是你家宽带，就说明绕道了。

</details>

<details>
<summary><b>⚠️ 域名解析要关掉橙云</b></summary>

<br>

如果域名托管在 Cloudflare，必须用「仅 DNS」模式（灰云）。
开了橙云会缓冲实时推送，页面就变成要手动刷新才有新内容。

</details>

<br>

## 配置

全走环境变量，不用改代码：

| 变量 | 默认 | 说明 |
|---|---|---|
| `WB_PORT` | `8797` | 服务端口 |
| `WB_HOST` | `auto` | 监听地址。`auto` = 本机 + 所有局域网地址 |
| `WB_LAN` | `1` | 设 `0` 关掉局域网监听，只留本机 |
| `WB_TOKEN` | 自动生成 | 密码，存在 `~/.config/workbuddy-remote/token`（600） |

```bash
WB_PORT=9000 workbuddy-remote      # 换端口
WB_LAN=0 workbuddy-remote          # 只走隧道，不让同网段访问
```

<br>

## 安全

这东西本质是「把工位的 WorkBuddy 开放给网络上的某个人」，请认真对待：

- **默认监听局域网，但没有密码进不来。** 介意同网段可见就 `WB_LAN=0`
- **密码走网址参数**，会留在浏览器历史里。公用设备上建议换成一串更长的随机字符
- **公网暴露时别用 `WB_HOST=0.0.0.0`** —— 那会监听所有网卡，包括以后新接入的网络。
  用默认的 `auto`，或者显式写死 IP
- **文件预览接口能读本机文件，必须带密码。** 别把它加进免密码白名单 ——
  那等于把整个「文档 / 桌面 / 下载」对全公司开放

<br>

## 常见问题

<details>
<summary><b>点了图标打开是白屏</b></summary>

<br>

说明连上了但页面没起来。先看 `http://<被控端>:8797/health` 是不是返回 `{"ok":true}`，
再看被控端的 `~/.config/workbuddy-remote/logs/bridge.log`。

</details>

<details>
<summary><b>提示连不上 WorkBuddy</b></summary>

<br>

大多数情况是 WorkBuddy 没带调试端口启动。`workbuddy-remote --stop` 再重新 `workbuddy-remote` 一次
（会重启 WorkBuddy，正在跑的任务会中断）。

</details>

<details>
<summary><b>打开很慢，或者一直转圈</b></summary>

<br>

先确认两台机器是不是同一个 Wi-Fi（同名 Wi-Fi 的 2.4G / 5G 有时是两张网）。
页面底部有链路提示，写着公网的话说明没走近路。

</details>

<details>
<summary><b>安装时下载图标失败（curl: (35)）</b></summary>

<br>

部分网络下访问 GitHub / CDN 会在握手阶段被重置。只影响**图标**，功能不受影响 ——
脚本内置了多条镜像会自动重试，全失败就用内嵌的兜底图（看着糊一点，能正常用）。

想手动补一张：

```bash
WB_ICON_URL='https://你的地址/icon-512.png' bash install.sh --client '...'
```

</details>

<details>
<summary><b>SSH 里起的图形程序一断开就没了</b></summary>

<br>

`nohup ... &` 会被会话结束带走，用 `setsid`：

```bash
setsid gtk-launch workbuddy-remote </dev/null >/tmp/wb.log 2>&1 &
```

</details>

<br>

## 已知限制

- **被控端需要 macOS / Linux** —— 也就是装着 WorkBuddy 的那台机器。
  **你用来连的那台电脑不受限制**，Windows、Mac、Linux 都行，有浏览器就能用
- **必须重启一次 WorkBuddy** —— 调试端口只能启动时指定
- **很长的会话看不全** —— 一次取最近 16 条，更早的要去桌面端翻
- **非图片附件显示不出来** —— 文档类附件在网页端还没有渲染
- **这是官方缺口的补丁，不是官方功能** —— 它依赖桌面端的调试入口，
  如果哪天官方封掉这个入口，或者自己补上了桌面版远控，这个项目就该退场了

<br>

## 它是怎么做到的

WorkBuddy 桌面端本身留了一个调试入口，可以在它自己的界面里执行脚本。
这个项目把这个入口包成普通网页 —— 你在浏览器里点一下，真正执行的地方还是那台机器上的
WorkBuddy 本体，权限、模型配置、会话队列都是它自己的，所以不存在「同步不及时」这回事。

macOS 的图标版另外做了个约 250KB 的小外壳。原因很实际：用脚本拉起浏览器拿不到 Dock 图标，
而且点两次会开出两个窗口。

<br>

## 卸载

```bash
# 被控端
workbuddy-remote --stop
./scripts/autostart.sh uninstall
rm -rf ~/.local/share/workbuddy-remote ~/.config/workbuddy-remote
rm -f ~/.local/bin/workbuddy-remote

# 控制端（装了的话）
rm -rf "$HOME/Applications/WorkBuddy Remote.app"
rm -f ~/.local/bin/workbuddy ~/.config/workbuddy-remote/lan-endpoint
```

<br>

---

<div align="center">

MIT License<br>
<sub>做这个东西的原因是：<b>我只是想在沙发上把工位上那个任务看完。</b></sub>

</div>