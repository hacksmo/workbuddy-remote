#!/usr/bin/env bash
# 把官网静态站 + nginx 配置部署到 wb.hackmo.net。
#
#   ./deploy/deploy-site.sh              # 同步站点文件并重载 nginx
#   ./deploy/deploy-site.sh --dry-run    # 只看会改什么
#
# 前提：本机已配置免密 ssh 别名 aws-vps，且服务器端 sudo -n 可用。
#
# 部署形态（见 nginx-wb.conf）：
#   /            静态官网（/var/www/wb）
#   /app         应用本体，反代到 127.0.0.1:18797（ssh -R 隧道）
#   其余路径     照旧反代到桥（/events、/md.js、/icons/…）
set -euo pipefail

HOST_ALIAS="${WB_SSH_HOST:-aws-vps}"
REMOTE_SITE="${WB_REMOTE_SITE:-/var/www/wb}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

DRY=""
[ "${1:-}" = "--dry-run" ] && DRY="--dry-run"

if [ ! -f "$ROOT/site/index.html" ] || [ ! -f "$ROOT/site/site.css" ]; then
    echo "❌ 找不到 site/index.html 或 site/site.css（ROOT=$ROOT）" >&2
    exit 1
fi

echo "→ 同步站点文件到 $HOST_ALIAS:$REMOTE_SITE"
rsync -az --delete $DRY -e ssh "$ROOT/site/" "$HOST_ALIAS:$REMOTE_SITE/"

if [ -n "$DRY" ]; then
    echo "→ [dry-run] 不做 nginx 改动"
    exit 0
fi

echo "→ 上传 nginx 配置"
scp -q "$ROOT/deploy/wb-proxy.inc" "$HOST_ALIAS:/tmp/wb-proxy.inc"
scp -q "$ROOT/deploy/nginx-wb.conf" "$HOST_ALIAS:/tmp/wb.conf.new"
ssh "$HOST_ALIAS" '
    set -e
    # 每次改动前留一份备份，nginx 配置改错会导致整站 502
    sudo -n cp /etc/nginx/conf.d/wb.conf \
        "/etc/nginx/conf.d/wb.conf.bak-$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
    sudo -n mkdir -p /etc/nginx/snippets
    sudo -n mv /tmp/wb-proxy.inc /etc/nginx/snippets/wb-proxy.inc
    sudo -n mv /tmp/wb.conf.new /etc/nginx/conf.d/wb.conf
    # 先测语法，不通过就别 reload —— 旧配置还在跑，站点不受影响
    sudo -n nginx -t
'
ssh "$HOST_ALIAS" 'sudo -n systemctl reload nginx'
echo "✓ 已部署：https://wb.hackmo.net/"
