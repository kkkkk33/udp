#!/bin/bash
set -e

# ========== 配置区 ==========
TG_TOKEN="8526087156:AAHR5forb44MA061r0zgcPMiGtkkxHD5K6o"
TG_CHAT_ID="6303873752"
LISTEN_PORT=11404  # 👈 已经为您改成了您截图中的端口 11404

# aes-128-gcm 的明文密码
SS_PWD="YourCustomSecurePassword123!" 
# ============================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }

# ── 1. 检查并安装 Docker ────────────────────────────────────────
log "检查 Docker 环境..."
if ! command -v docker &>/dev/null; then
    warn "Docker 未安装，正在安装..."
    apt-get update -qq && apt-get install -y -qq docker.io
    systemctl start docker && systemctl enable docker
    log "Docker 安装完成"
fi
docker info &>/dev/null || err "Docker 守护进程未运行，请检查"

# ── 2. 清理旧容器 ──────────────────────────────────────────────
log "清理旧容器..."
docker rm -f ss-rust shadow-tls 2>/dev/null || true
sleep 1

if command -v fuser &>/dev/null; then
    fuser -k ${LISTEN_PORT}/tcp 2>/dev/null || true
    fuser -k ${LISTEN_PORT}/udp 2>/dev/null || true
    sleep 1
fi

# ── 3. 启动 Shadowsocks-Rust (TCP + UDP 转发双开启) ─────────────
log "启动 Shadowsocks-Rust 容器..."
docker run -d \
    --name ss-rust \
    --restart always \
    --network host \
    ghcr.io/shadowsocks/ssserver-rust:latest \
    ssserver \
        --server-addr "0.0.0.0:${LISTEN_PORT}" \
        --encrypt-method "aes-128-gcm" \
        --password "${SS_PWD}" \
        --timeout 300 \
        -u  # 👈 核心修改：-u 代表同时开启 TCP 和 UDP 支持，完美匹配小火箭的“UDP转发”

log "等待 Shadowsocks 启动..."
sleep 3

# ── 4. 验证容器状态 ─────────────────────────────────────────────
log "验证容器运行状态..."
SS_STATUS=$(docker inspect -f '{{.State.Status}}' ss-rust 2>/dev/null)
if [ "$SS_STATUS" != "running" ]; then
    warn "ss-rust 状态异常: $SS_STATUS"
    docker logs ss-rust 2>&1 | tail -30
    err "服务未能正常启动"
fi

# ── 5. 获取服务器公网 IP ────────────────────────────────────────
log "获取公网 IP..."
SERVER_IP=$(curl -s --max-time 10 ://icanhazip.com || \
            curl -s --max-time 10 api.ipify.org || \
            curl -s --max-time 10 ifconfig.me)
[ -z "$SERVER_IP" ] && err "无法获取公网 IP"
log "服务器 IP：$SERVER_IP"

# ── 6. 生成 Shadowrocket 专用节点链接 ──────────────────────────
log "生成节点链接..."
SS_B64=$(python3 -c "
import base64
raw = 'aes-128-gcm:${SS_PWD}'
b64 = base64.b64encode(raw.encode()).decode().rstrip('=')
print(b64)
")

SS_LINK="ss://${SS_B64}@${SERVER_IP}:${LISTEN_PORT}#SS_AES128_GCM"

# ── 7. 推送节点链接到 Telegram ─────────────────────────────────
log "推送配置到 Telegram..."
curl -s -X POST "https://telegram.org{TG_TOKEN}/sendMessage" \
    -d "chat_id=${TG_CHAT_ID}" \
    --data-urlencode "text=🔗 小火箭一键链接 (AES-128-GCM):
${SS_LINK}" >/dev/null

# ── 8. 本地输出汇总 ────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════"
echo "  Shadowsocks 部署完成汇总"
echo "══════════════════════════════════════════════"
echo "  服务器IP    : ${SERVER_IP}"
echo "  监听端口    : ${LISTEN_PORT}"
echo "  加密算法    : aes-128-gcm"
echo "  SS 密码     : ${SS_PWD}"
echo "  功能状态    : TCP 网页与 UDP 转发均已开启"
echo "══════════════════════════════════════════════"
echo "  一键链接:"
echo "  ${SS_LINK}"
echo "══════════════════════════════════════════════"
echo ""
log "配置已推送到 Telegram，请查收！"
