# WorkBuddy Remote

从另一台电脑的浏览器里，远程操作你这台机器上的 WorkBuddy —— 看会话、发消息、读长回答、看思考过程，跟坐在那台电脑前一样。

```
同一局域网（最快，10ms 级）
┌──────────────┐   直连 8797    ┌──────────────┐
│ 控制端        │ ─────────────► │ 被控端        │
└──────────────┘                │ WorkBuddy    │
                                └──────────────┘

不同网络（经公网中转）
┌──────────────┐   HTTPS    ┌──────────────┐   SSH 反向   ┌──────────────┐
│ 家里电脑      │ ─────────► │ 中转服务器     │ ◄────────── │ 公司工作机     │
│ 任意浏览器    │            │ (可选,有公网IP)│             │ WorkBuddy    │
└──────────────┘            └──────────────┘             └──────────────┘
```

控制端启动时会自动选路：同网段就直连，否则回退公网。详见
[同网段时自动走局域网](#同网段时自动走局域网)。

## ⚠️ 先搞清楚：你要装哪一端

装错是最常见的错误——在被控机上装了两遍，或者在控制机上装了桥，结果打开的是本机自己的 WorkBuddy。

| | **被控端（开发机/server）** | **控制端（你手上的电脑/client）** |
|---|---|---|
| 装在哪 | 跑着 WorkBuddy、你想远程操作的那台 | 你用来操作的那台 |
| 装什么 | 桥 + 启动脚本 + Node.js | 一个快捷方式，**不用 Node.js** |
| 用什么命令 | `workbuddy-remote` | `workbuddy` |
| 作用 | 把本机 WorkBuddy 变成可访问的服务 | 打开一个指向开发机的浏览器窗口 |
| 是否需要 | 必须 | 可选——有浏览器就够，装它是为了有个独立图标 |

**判断方法**：在要装的那台机器上问自己一句——「WorkBuddy 是装在这台机器上吗？」

- 是 → 装**被控端**（默认模式）
- 否 → 装**控制端**（加 `--client`）

## 它解决什么问题

WorkBuddy 是桌面应用，会话和上下文都在本机。想在另一台电脑上继续用，有几个绕不开的麻烦：

- **官方没有 PC-to-PC 的远程能力** —— 多端协同只能同账号看历史，不能操作另一台机器的活会话
- **CGNAT 打洞基本无解** —— 公司网络常是对称 NAT，Tailscale 之类会退化到境外中继，一次往返 1 秒以上，打字都卡
- **装客户端太重** —— 只是想在外面回一句话，不想先装个 App 再登录

这个项目绕开这些：直接驱动 WorkBuddy 自己的渲染进程（通过 CDP），把它的能力暴露成一个网页。所以看到的就是同一份真实会话，不是影子副本。

## 安装

### A. 被控端（在开发机上装）

**要求**：Node.js 18+、WorkBuddy 桌面版已安装（macOS / Linux）

```bash
curl -fsSL https://raw.githubusercontent.com/hacksmo/workbuddy-remote/main/install.sh | bash
```

装完得到一个 `workbuddy-remote` 命令：

```bash
workbuddy-remote            # 启动（会重启 WorkBuddy 开启调试端口）
workbuddy-remote --status   # 看状态
workbuddy-remote --stop     # 停桥
```

启动后终端打印带令牌的地址：

```
http://127.0.0.1:8797/?token=8550acac5c1b32ce...
```

这个地址就是控制端要用的。

> ⚠️ 启动时会重启 WorkBuddy 以获得调试端口，**正在跑的任务会中断**。
> 如果你的 WorkBuddy 已带 `--remote-debugging-port=9333` 启动，会跳过重启。

### B. 控制端（在你要用来操作的那台电脑上装）

不用装 Node.js，也不用克隆仓库。把上面打印的地址填进去：

**macOS —— 下载 DMG（推荐）**

从 [Releases](https://github.com/hacksmo/workbuddy-remote/releases/latest) 下载
`WorkBuddy-Remote.dmg`，双击挂载，把应用拖进「应用程序」。

第一次打开会问地址和密码；同一 Wi-Fi 下点「扫描」能自动找到被控端，不用手抄 IP。

> 首次打开若提示「无法验证开发者」，右键点图标选「打开」，在弹窗里再点一次
> 「打开」即可。只需一次（应用是 ad-hoc 签名，没有 Apple 开发者证书）。

也可以走命令行：

```bash
curl -fsSL https://raw.githubusercontent.com/hacksmo/workbuddy-remote/main/install.sh \
  | bash -s -- --client 'http://192.168.0.52:8797/?token=8550acac5c1b32ce...'
```

会得到一个 `workbuddy` 命令，以及 `/Applications/../WorkBuddy Remote.app`：

| 平台 | 装完得到什么 |
|---|---|
| **macOS** | `WorkBuddy Remote.app`，自动加进程序坞，带图标。原生壳（AppKit + WKWebView），点开就是独立窗口 |
| **Linux** | 应用菜单里的「WorkBuddy Remote」，带图标。点开同上 |

装完直接点图标就能连上开发机，不用开终端、不用记地址。

控制端本质只是个浏览器窗口，**不执行本机任何操作**。

> **macOS 走的是原生壳，不是「脚本 + Chrome --app」。** 原因值得记一下：
>
> - Dock 图标归属**进程**，脚本进程不连 WindowServer，Dock 里永远不会有图标。
>   早期版本 `exec` 成 Chrome 后，进程身份变成 Google Chrome，Dock 里只有 Chrome。
> - Chrome 的 `--app=` **没有单实例语义**：已有实例时它会把这条命令交给那个实例
>   「新开一个窗口」，于是点一次图标多一个窗口，永远堆着不消失。
>
> 原生壳由 AppKit 免费提供单实例、Dock 图标、Cmd+Tab 和
> 「点一下收起、再点一下回来」。源码在 `macos/shell.swift`，
> 用 `macos/build-dmg.sh` 打成通用二进制（Intel + Apple Silicon 都跑）。

> Linux 端需要 Chrome / Edge / Brave 等 Chromium 系浏览器才有独立窗口，
> 都没有时会退化成系统默认浏览器（有地址栏）。

> 其实连装都不用：浏览器打开那个地址就行。装控制端只是为了有个像原生应用的图标。

### C. 手动安装（不想用 curl | bash）

```bash
git clone https://github.com/hacksmo/workbuddy-remote.git
cd workbuddy-remote
./scripts/start.sh
```

## 常用配置

都用环境变量，不改代码：

| 变量 | 默认 | 说明 |
|---|---|---|
| `WB_PORT` | `8797` | 桥的 HTTP 端口 |
| `WB_HOST` | `auto` | 监听地址。`auto` = 回环 + 所有局域网 IP；也可显式写 `127.0.0.1,192.168.1.5` |
| `WB_LAN` | `1` | 设为 `0` 关掉局域网监听，只留回环（只想走隧道时用） |
| `WB_CDP_PORT` | `9333` | WorkBuddy 调试端口 |
| `WB_TOKEN` | 自动生成 | 访问令牌，存在 `~/.config/workbuddy-remote/token` |
| `WB_APP` | 自动探测 | WorkBuddy 可执行文件路径 |

```bash
# 默认就带局域网监听，不用配置

# 换端口
WB_PORT=9000 workbuddy-remote

# 不想让同网段的人访问（只走隧道）
WB_LAN=0 workbuddy-remote
```

## 同网段时自动走局域网

两台机器在同一个 WiFi / 局域网里时，控制端会**优先直连**，不用绕公网服务器：

```
同一网段   WLAN 内直连        10ms 以内
不同网络   经中转服务器 + 隧道   数百毫秒到数秒
```

实测同一台机器上两个入口的差距是 **287 倍**（8.6ms vs 2466ms），流量还不占服务器带宽。

原理很简单：被控端启动时把 RFC1918 私网地址一并监听，控制端启动器先各自试一次
`/health`，通则用局域网，不通就静默回退公网。探测超时只给 0.4 秒，不在同网段时
最多多花 0.4 秒，不会拖慢启动。

```bash
workbuddy            # 默认：局域网优先，失败自动回退公网
workbuddy --lan      # 只走局域网，连不上就报错（排查用）
workbuddy --public   # 强制走公网（怀疑直连有问题时对比用）
```

页面底部有个链路标识，直接告诉你现在走的是哪条路、延迟多少：

```
● 局域网 8ms      ● 公网 672ms      ● 本机 3ms
```

点它可以重新测一次。

**几个实现上的取舍：**

- **只认私网段**。`192.168/16`、`10/8`、`172.16~31`，排除 `100.x`（Tailscale）和
  `198.18/15`（Shadowrocket 等代理的 TUN 假地址）—— 监听这些地址没有意义。
- **失败必须静默**。局域网 IP 会随 DHCP 变化，今天是 `.52` 明天可能是 `.61`，
  探测失败是常态而不是异常，所以不弹任何错误。
- **不能「公网页面内部切局域网」**。HTTPS 页面里请求 `http://192.168.x.x` 会被
  浏览器按混合内容拦掉，所以只能「先探测局域网源，失败就整页跳公网」。
- **兼容 mDNS**。被控端同时上报 `xxx.local`，改名换 IP 后 Bonjour 还能解析到。
- **被控端自己探测，不要写死 IP**。被控端用 `--host auto`（开机自启的默认配置）自己枚举
  网卡上的 RFC1918 地址。写死 IP 的后果是换个网络就 `EADDRNOTAVAIL`，只剩本机可访问，
  而 LaunchAgent 的 `KeepAlive` 还会让它反复重启刷日志。

## 从外网访问（可选）

局域网之外要能连，需要一台有公网 IP 的服务器做中转。推荐用**反向 SSH 隧道**，而不是 VPN / 内网穿透：

原因是 CGNAT 只阻止外部主动连入，不阻止内部主动连出。把连接方向反过来，NAT 类型就不再是问题。

### 1. 中转服务器准备

```bash
# 在服务器上
sudo mkdir -p /var/www/certbot
# 把 deploy/nginx.conf.example 改成你的域名和端口，放到 /etc/nginx/conf.d/
sudo nginx -t && sudo systemctl reload nginx
sudo certbot certonly --webroot -w /var/www/certbot -d your.domain
```

> DNS 记录必须是**灰云（仅 DNS）**。开 Cloudflare 橙云会缓冲 SSE，实时推送直接失效。

### 2. 工作机建隧道

```bash
./scripts/tunnel.sh          # 首次运行会生成配置模板
vim ~/.config/workbuddy-remote/tunnel.env
./scripts/tunnel.sh
```

配置项：

```bash
TUNNEL_HOST=1.2.3.4          # 中转服务器
TUNNEL_USER=ubuntu
TUNNEL_KEY=~/.ssh/id_ed25519
TUNNEL_REMOTE_PORT=18797     # 服务器上监听的端口
TUNNEL_LOCAL_PORT=8797       # 本机桥端口
TUNNEL_BIND_IFACE=en0        # 见下方说明
```

### ⚠️ 关于 `TUNNEL_BIND_IFACE`

**如果你本机开着全局代理（Clash / Surge / Shadowrocket 的 TUN 模式），这一项必须填。**

否则 SSH 会走代理出口，路径变成 `本机 → 代理服务器 → 中转 → 代理 → 本机` 四跳，实测延迟从 110ms 涨到 1 秒以上。绑定物理网卡后直接连出。

判断方法：跑一下看隧道延迟

```bash
ssh -i ~/.ssh/id_ed25519 ubuntu@1.2.3.4 'echo $SSH_CLIENT'
```

如果显示的 IP 是你代理服务器的 IP，而不是你家宽带的 IP，就说明绕道了。

macOS 网卡名一般是 `en0`，Linux 用 `ip route get 1.1.1.1` 看。

### 3. 开机自启

```bash
./scripts/autostart.sh install     # macOS 用 LaunchAgent，Linux 用 systemd --user
./scripts/autostart.sh status
./scripts/autostart.sh uninstall
```

## 工作原理

三件事拼起来：

1. **WorkBuddy 带 `--remote-debugging-port=9333` 启动** —— Electron 会开一个 CDP 端口
2. **`bridge/cdp.mjs` 通过 CDP 连进渲染进程** —— 在里面执行 JS，直接调 `window.wb`（preload 暴露的 API）
3. **把能力包成 HTTP** —— 会话列表、消息、发消息、模型切换、中断、文件预览

好处是权限和桌面端完全一致，看到的就是真实会话本身。

### 关键 API（走 CDP 在页面内执行）

| 操作 | 调用 |
|---|---|
| 列会话 | `wb.conversations.list()` |
| 读消息 | `(await wb.conversations.get(id)).requestEntries()` |
| 发消息 | `(await wb.conversations.get(id)).sendPrompt(blocks)` |
| 中断 | `(await wb.conversations.get(id)).cancel()` |
| 读队列 | `(await wb.conversations.get(id)).queueManager.items()` |
| 排队操作 | `.queueManager.move(id, idx)` / `.delete(id)` / `.sendNow(id)`（= 引导，不中断） |
| 切模型 | `wb.invoke('wb:conversations:configSetModel', id, model)` |

几个踩过的坑，改代码时会碰到：

- **运行态是 `streaming`，不是 `working`** —— 判断是否在生成必须用 `streaming`
- **`create()` 返回句柄不是 id** —— 要建会话得用创建前后 `list()` 的差集拿 id
- **`requests()` 在流式期间会阻塞** —— 读消息用 `requestEntries()`
- **并发 evaluate 会串线** —— CDP 连接必须共享，且 evaluate 要串行排队
- **排队不要自己在浏览器里做** —— 见下节

### 排队消息必须走 `/send`

会话正在生成时，桌面端的输入框仍可发送，消息进队列等当前回复结束后依次发出。

网页端一开始想用 localStorage 自己维护队列（生成结束后再逐条发），**这是错的**：
消息被拦在浏览器里，压根没到 WorkBuddy，于是被控端桌面端完全看不到网页排队的消息。

正确做法是**照样调 `/send`** —— `sendPrompt()` 在生成期间会立即返回（约 60ms），
由 WorkBuddy 内部串行链排队。网页端只通过 `/queue` 把同一份队列读回来渲染，
两边共用一份真相，桌面端能看见，网页端也能排序 / 删除 / 引导。

| 操作 | 接口 |
|---|---|
| 读队列 | `GET /sessions/:id/queue` → `{items:[{id,seq,blocks}],paused,supported}` |
| 排序 / 删除 / 引导 | `POST /sessions/:id/queue` `{op:'move'|'delete'|'sendNow', itemId, index}` |

**`sendNow` 是「引导」，不是「打断」** —— 这个名字有迷惑性。实测它不会中断模型，
而是把这条消息插进**当前正在跑的那一轮**，模型接着往下做。桌面端那个箭头按钮
（tooltip：「引导会话，消息将被发出但模型不会中断」）调的就是它。引导后不会有新的
用户消息条目，内容直接出现在当前轮的助手回复里。真要中断得用 `cancel()`。

### 性能上的处理

远程用起来卡不卡，主要看这几处：

- **连接复用 + 串行队列** —— 共享一条 CDP 连接，evaluate 排队执行。`/health` 从 30ms 降到 1.2ms
- **增量拉取** —— 轮询只取尾部 3 条（`?tail=3`），流量从 362KB 降到 39.5KB
- **SSE 推送 + 轮询兜底** —— 事件驱动，延迟 400ms 内；空闲时降频到 15 秒
- **消息裁剪** —— 单条正文截断 6000 字，只取最近 16 条

## 目录结构

```
workbuddy-remote/
├── install.sh              一键安装（区分 server / client 两种角色）
├── scripts/
│   ├── start.sh            被控端启动器（跨平台，核心）
│   ├── autostart.sh        开机自启
│   └── tunnel.sh           反向 SSH 隧道（外网访问用）
├── bridge/
│   └── cdp.mjs             CDP 桥 + HTTP 服务
├── web/
│   ├── index.html          Web UI（单文件）
│   ├── md.js               Markdown 渲染（无依赖自写）
│   ├── fonts/              Inter 字体
│   └── icons/              PWA 图标
├── macos/
│   ├── shell.swift         原生壳源码（AppKit + WKWebView）
│   ├── build-dmg.sh        打 DMG（通用二进制 + 图标 + 签名）
│   └── bin/WorkBuddyRemote 预编译通用二进制（install.sh 下载它）
└── deploy/
    └── nginx.conf.example  中转服务器反代配置
```

## 卸载

```bash
# 被控端
workbuddy-remote --stop
./scripts/autostart.sh uninstall          # 装过自启的话
rm -rf ~/.local/share/workbuddy-remote ~/.config/workbuddy-remote
rm -f ~/.local/bin/workbuddy-remote

# 控制端（macOS）
rm -rf "$HOME/Applications/WorkBuddy Remote.app" \
       ~/.local/share/workbuddy-remote/client-profile
rm -f ~/.local/bin/workbuddy

# 控制端（Linux）
rm -f ~/.local/share/applications/workbuddy-remote.desktop \
      ~/.local/share/icons/hicolor/512x512/apps/workbuddy-remote.png \
      ~/.local/bin/workbuddy
rm -rf ~/.local/share/workbuddy-remote/client-profile
rm -f ~/.config/workbuddy-remote/lan-endpoint
```

别忘了局域网探测的缓存 `~/.config/workbuddy-remote/lan-endpoint`（一行，记录上次连通的地址）。

## 安全提醒

- **默认会监听局域网**（`WB_HOST=auto`）。同网段的人能访问到端口，但仍然需要令牌。
  不想这样就把 `WB_LAN=0` 关掉，或改用 `WB_LAN=0 workbuddy-remote` 启动。
- 令牌在 `~/.config/workbuddy-remote/token`（600），首次运行自动生成
- **`/preview/` 读本机文件的能力必须鉴权**，别把它加进免鉴权白名单 —— 那等于把
  整个 `Documents` / `Desktop` / `Downloads` 对全 WiFi 开放
- 令牌走 URL 参数，会留在浏览器历史里。公用设备建议手动换成更长的随机串
- 公网暴露时一定要设令牌，并且**不要**用 `WB_HOST=0.0.0.0`（那会监听所有网卡，
  包括未来的新网络）—— 用默认的 auto 或显式写 IP

## 国内网络下的安装问题

在 Ubuntu 24.04 上实测：`cdn.jsdelivr.net` 和 `raw.githubusercontent.com` 都会在
TLS 握手阶段被重置（`curl: (35) Recv failure: Connection reset by peer`）。
这影响的是**图标下载**，不影响主体功能 —— 装完能正常用，只是图标会退回内嵌的
128px 版本（肉眼可见变糊）。

安装脚本已经内置了一串镜像，按命中率排序，逐个试：

```
cdn.jsdelivr.net  →  ghproxy.net  →  gh-proxy.com
                  →  raw(sha)     →  raw(main)     →  ghfast.top
```

实测 `ghproxy.net` 和 `gh-proxy.com` 都可用（HTTP 200），`ghfast.top` 会超时。
每个源最多等 8 秒，全失败才用内嵌兜底图。

如果脚本跑到下载那步报 `curl: (35)`，说明当前网络这几个域名都不通。三种处理：

```bash
# 1. 挂着代理装（脚本会继承环境变量）
https_proxy=http://127.0.0.1:7890 bash install.sh --client '...'

# 2. 自己指定图标地址（放到能访问的地方）
WB_ICON_URL='https://你的地址/icon-512.png' bash install.sh --client '...'

# 3. 干脆不管 —— 图标糊一点，功能完全正常
```

装完想补高清图标也可以直接覆盖（Linux）：

```bash
curl -fsSL 'https://ghproxy.net/https://raw.githubusercontent.com/hacksmo/workbuddy-remote/main/assets/icon-512.png' \
  -o ~/.local/share/icons/hicolor/512x512/apps/workbuddy-remote.png
gtk-update-icon-cache -f -t ~/.local/share/icons/hicolor
```

## 常见问题

**启动后在应用菜单里点了没反应（Linux）**
用终端跑一次 `~/.local/bin/workbuddy` 看输出。常见原因是找不到 Chrome ——
脚本支持 Chrome / Edge / Brave / Chromium，都没有时会退回系统默认浏览器。
另外 `~/.local/bin` 不在 PATH 里不影响图标启动（`.desktop` 用的是绝对路径）。

**图标点了打开的是白屏**
说明连上了但页面挂了。看一眼 `http://<被控端>:8797/health` 是否返回
`{"ok":true}`；再看看被控端的 `~/.config/workbuddy-remote/logs/bridge.log`。

**SSH 里起的图形程序一断开就没了**
`nohup ... &` 会被会话结束带走，用 `setsid`：

```bash
setsid gtk-launch workbuddy-remote </dev/null >/tmp/wb.log 2>&1 &
```

**Ubuntu 空闲后自动锁屏，远程看不到窗口**
`loginctl unlock-session <id>`（先用 `loginctl list-sessions --no-legend` 找 seat0 那个）。
截图可以用 `import -window root /tmp/shot.png`（ImageMagick）。

## 已知限制

- **只支持 macOS / Linux** —— Windows 的 WorkBuddy 安装路径和进程模型没测过
- **必须重启 WorkBuddy** —— 调试端口只能在启动时指定，没法热加
- **历史分页未做** —— 一次最多取 16 条，很长的会话需要在桌面端看
- **非图片附件未支持** —— `resource_link` 类型的附件在网页端显示不出来
- **Linux 需自行确认 WorkBuddy 安装路径** —— 各发行版打包方式不同，找不到时用 `WB_APP` 指定

## License

MIT