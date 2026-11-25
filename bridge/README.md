# CDP 桥

把 WorkBuddy 渲染进程的能力暴露成 HTTP。

## 前置

WorkBuddy 必须带调试端口启动：

```bash
# macOS
open -a WorkBuddy --args --remote-debugging-port=9333
# Linux
workbuddy --remote-debugging-port=9333
```

用 `scripts/start.sh` 会自动处理这一步。

## 用法

```bash
node cdp.mjs --phost 127.0.0.1 --port 8797 --cdp 9333 --token <令牌>
node cdp.mjs --probe        # 只探测，列出 target 和可用 API
```

## 端点

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/` | Web UI |
| GET | `/health` | 存活检查 |
| GET | `/info` | 主机信息 |
| GET | `/sessions` | 会话列表 |
| GET | `/sessions/:id/messages?tail=N` | 消息（N 只影响条数） |
| POST | `/sessions/:id/send` | 发消息，body `{blocks}` |
| POST | `/sessions/:id/cancel` | 中断生成 |
| POST | `/sessions/:id/delete` | 删除会话 |
| GET | `/sessions/:id/config` | 读配置 |
| POST | `/sessions/:id/model` | 切模型 |
| GET | `/spaces` | 分组 |
| GET | `/models` | 模型列表 |
| GET | `/events` | SSE 事件流 |
| GET | `/preview/<绝对路径>` | 文件预览 |
| POST | `/eval` | 在页面内执行 JS（调试用） |

除 `/health`、`/info`、`/`、静态资源外，都需要令牌：

```
Authorization: Bearer <token>     或     ?token=<token>
```

## 实现要点

- **一条共享 CDP 连接**，evaluate 走串行队列。并发 evaluate 会让回调串线
- **不开 `Runtime.enable`**，只用 `Runtime.evaluate`，省掉大量事件开销
- **`/events` 是 SSE**，泵每 250ms 取一次页面内累积的事件队列
- **gzip 只压 >1KB 的响应**，小响应压了反而更慢
