# WorkBuddy Remote

从另一台电脑的浏览器里，远程操作你这台机器上的 WorkBuddy —— 看会话、发消息、读长回答、看思考过程，跟坐在那台电脑前一样。

不需要装客户端。一个浏览器标签页就够。

```
┌──────────────┐   HTTPS    ┌──────────────┐   SSH 反向   ┌──────────────┐
│ 家里电脑      │ ─────────► │ 中转服务器     │ ◄────────── │ 公司工作机     │
│ 任意浏览器    │            │ (可选,有公网IP)│             │ WorkBuddy    │
└──────────────┘            └──────────────┘             └──────────────┘
                                                          ↑ 也可以直连局域网
```

## 它解决什么问题

WorkBuddy 是桌面应用，会话和上下文都在本机。想在另一台电脑上继续用，有几个绕不开的麻烦：

- **官方没有 PC-to-PC 的远程能力** —— 多端协同只能同账号看历史，不能操作另一台机器的活会话
- **CGNAT 打洞基本无解** —— 公司网络常是对称 NAT，Tailscale 之类会退化到境外中继，一次往返 1 秒以上，打字都卡
- **装客户端太重** —— 只是想在外面回一句话，不想先装个 App 再登录

这个项目绕开这些：直接驱动 WorkBuddy 自己的渲染进程（通过 CDP），把它的能力暴露成一个网页。所以看到的就是同一份真实会话，不是影子副本。

## 一行安装

**要求**：Node.js 18+、WorkBuddy 桌面版已安装（macOS / Linux）

```bash
curl -fsSL https://raw.githubusercontent.com/hacksmo/workbuddy-remote/main/install.sh | bash
```

装完会得到一个 `workbuddy-remote` 命令：

```bash
workbuddy-remote            # 启动（会重启 WorkBuddy 开启调试端口）
workbuddy-remote --status   # 看状态
workbuddy-remote --stop     # 停桥
```

启动后终端会打印一个带令牌的地址：

```
http://127.0.0.1:8797/?token=8550acac5c1b32ce...
```

在浏览器打开即可。想让它像原生应用，用 Chrome / Edge 的「安装此应用」或 Safari 的「添加到程序坞」。

> ⚠️ 启动时会重启 WorkBuddy 以获得调试端口，**正在跑的任务会中断**。
> 如果你的 WorkBuddy 已经带 `--remote-debugging-port=9333` 启动，会跳过重启。

### 手动安装（不想用 curl | bash）

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
| `WB_HOST` | `127.0.0.1` | 监听地址。要局域网访问设为 `0.0.0.0` |
| `WB_CDP_PORT` | `9333` | WorkBuddy 调试端口 |
| `WB_TOKEN` | 自动生成 | 访问令牌，存在 `~/.config/workbuddy-remote/token` |
| `WB_APP` | 自动探测 | WorkBuddy 可执行文件路径 |

```bash
# 局域网内其他设备也能访问
WB_HOST=0.0.0.0 workbuddy-remote

# 换个端口
WB_PORT=9000 workbuddy-remote
```

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
| 切模型 | `wb.invoke('wb:conversations:configSetModel', id, model)` |

几个踩过的坑，改代码时会碰到：

- **运行态是 `streaming`，不是 `working`** —— 判断是否在生成必须用 `streaming`
- **`create()` 返回句柄不是 id** —— 要建会话得用创建前后 `list()` 的差集拿 id
- **`requests()` 在流式期间会阻塞** —— 读消息用 `requestEntries()`
- **并发 evaluate 会串线** —— CDP 连接必须共享，且 evaluate 要串行排队

### 性能上的处理

远程用起来卡不卡，主要看这几处：

- **连接复用 + 串行队列** —— 共享一条 CDP 连接，evaluate 排队执行。`/health` 从 30ms 降到 1.2ms
- **增量拉取** —— 轮询只取尾部 3 条（`?tail=3`），流量从 362KB 降到 39.5KB
- **SSE 推送 + 轮询兜底** —— 事件驱动，延迟 400ms 内；空闲时降频到 15 秒
- **消息裁剪** —— 单条正文截断 6000 字，只取最近 16 条

## 目录结构

```
workbuddy-remote/
├── install.sh              一键安装
├── scripts/
│   ├── start.sh            启动器（跨平台，核心）
│   ├── autostart.sh        开机自启
│   └── tunnel.sh           反向 SSH 隧道
├── bridge/
│   └── cdp.mjs             CDP 桥 + HTTP 服务
├── web/
│   ├── index.html          Web UI（单文件）
│   ├── md.js               Markdown 渲染（无依赖自写）
│   ├── fonts/              Inter 字体
│   └── icons/              PWA 图标
└── deploy/
    └── nginx.conf.example  中转服务器反代配置
```

## 安全提醒

- 桥默认只监听 `127.0.0.1`，外部访问不到
- 令牌在 `~/.config/workbuddy-remote/token`（600），首次运行自动生成
- 令牌走 URL 参数，会留在浏览器历史里。公用设备建议手动换成更长的随机串
- 不要在没有令牌的情况下把 `WB_HOST` 设成 `0.0.0.0` 暴露到公网

## 已知限制

- **只支持 macOS / Linux** —— Windows 的 WorkBuddy 安装路径和进程模型没测过
- **必须重启 WorkBuddy** —— 调试端口只能在启动时指定，没法热加
- **历史分页未做** —— 一次最多取 16 条，很长的会话需要在桌面端看
- **非图片附件未支持** —— `resource_link` 类型的附件在网页端显示不出来
- **Linux 需自行确认 WorkBuddy 安装路径** —— 各发行版打包方式不同，找不到时用 `WB_APP` 指定

## License

MIT