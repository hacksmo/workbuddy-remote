# 反代到桥的公共头。抽出来是因为 /app 和 / 两个 location 都要用，
# 复制两份以后改一处漏一处。
proxy_http_version 1.1;

proxy_set_header Host              $host;
proxy_set_header X-Real-IP         $remote_addr;
proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;

# Connection 头必须只设一次，且由这里统一决定：
#   - 普通请求：$wb_conn 为空 → 上游保活，nginx 可复用连接（keepalive 生效）
#   - SSE / WebSocket：$wb_conn 为 upgrade → 走升级握手
# 若像常见写法那样硬写 Connection ""，keepalive 有效但 SSE 断不了；
# 硬写 upgrade 则所有请求都无法复用。用 map 二者兼得。
proxy_set_header Upgrade    $http_upgrade;
proxy_set_header Connection $wb_conn;

# SSE 与长轮询：别让 nginx 提前掐断
proxy_read_timeout  3600s;
proxy_send_timeout  3600s;
proxy_connect_timeout 10s;