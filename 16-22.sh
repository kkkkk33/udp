
#!/bin/bash
set -Eeuo pipefail

# ========== 配置区 ==========
LISTEN_PORT=10847
PASSWORD='AAAACchacha20chacha209AAAAA'
METHOD='aes-128-gcm'

# Telegram 推送配置：请填写新的 Token 和 Chat ID
TG_TOKEN='8526087156:AAHR5forb44MA061r0zgcPMiGtkkxHD5K6o'
TG_CHAT_ID='6303873752'
# ============================

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
PLAIN='\033[0m'

WORK_DIR='/etc/sing-box'
TEMP_DIR='/tmp/sing-box-install'

log()  { echo -e "${GREEN}[✓]${PLAIN} $*"; }
warn() { echo -e "${YELLOW}[!]${PLAIN} $*"; }
err()  { echo -e "${RED}[✗]${PLAIN} $*"; exit 1; }

# Telegram 推送函数：检查 HTTP 请求和 API 的 ok 字段
tg_send() {
    local message="$1"
    local response

    if [[ -z "$TG_TOKEN" || -z "$TG_CHAT_ID" ||
          "$TG_TOKEN" == '替换为新Token' ||
          "$TG_CHAT_ID" == '替换为ChatID' ]]; then
        warn "Telegram 配置未填写，跳过推送。"
        return 0
    fi

    log "正在推送消息到 Telegram..."

    if ! response=$(curl -sS \
        --connect-timeout 5 \
        --max-time 15 \
        -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${TG_CHAT_ID}" \
        --data-urlencode "text=${message}" 2>&1); then
        warn "Telegram 网络请求失败：${response}"
        return 0
    fi

    if printf '%s' "$response" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
    sys.exit(0 if data.get("ok") is True else 1)
except Exception:
    sys.exit(1)
'; then
        log "Telegram 推送成功。"
    else
        warn "Telegram API 未确认发送成功：${response}"
    fi

    return 0
}

# 检查是否为 root
if [[ "$EUID" -ne 0 ]]; then
    err "必须使用 root 用户运行此脚本。"
fi

# 检查架构
ARCH=$(uname -m)
case "$ARCH" in
    x86_64|amd64) SING_BOX_ARCH="amd64" ;;
    aarch64|arm64) SING_BOX_ARCH="arm64" ;;
    *) err "不支持的系统架构：$ARCH" ;;
esac

# 检查依赖
log "正在检查安装环境..."

if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        wget tar curl python3 ca-certificates
elif command -v yum >/dev/null 2>&1; then
    yum install -y wget tar curl python3 ca-certificates
elif command -v apk >/dev/null 2>&1; then
    apk add wget tar curl python3 ca-certificates
else
    err "未检测到支持的包管理器，请手动安装 wget、tar、curl 和 python3。"
fi

mkdir -p "$WORK_DIR/logs" "$TEMP_DIR"

# 获取最新版本
log "正在获取 sing-box 最新版本..."

LATEST_VERSION=$(curl -fsSL --connect-timeout 10 --max-time 30 \
    https://api.github.com/repos/SagerNet/sing-box/releases/latest |
    python3 -c '
import json, sys
try:
    print(json.load(sys.stdin)["tag_name"].lstrip("v"))
except Exception:
    sys.exit(1)
') || LATEST_VERSION=""

if [[ -z "$LATEST_VERSION" ]]; then
    warn "无法获取最新版本，使用备用版本 1.10.0。"
    LATEST_VERSION="1.10.0"
fi

DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/v${LATEST_VERSION}/sing-box-${LATEST_VERSION}-linux-${SING_BOX_ARCH}.tar.gz"

log "正在下载 sing-box v${LATEST_VERSION}..."

if ! curl -fL --connect-timeout 10 --max-time 180 \
    "$DOWNLOAD_URL" -o "$TEMP_DIR/sing-box.tar.gz"; then
    tg_send "❌ sing-box 安装失败：下载程序失败。服务器：$(hostname)"
    err "下载失败，请检查网络或版本下载地址。"
fi

# 解压到临时目录并检查程序
tar -xzf "$TEMP_DIR/sing-box.tar.gz" -C "$TEMP_DIR"

BIN_PATH=$(find "$TEMP_DIR" -type f -name sing-box -print -quit)
if [[ -z "$BIN_PATH" ]]; then
    tg_send "❌ sing-box 安装失败：压缩包中没有找到可执行文件。服务器：$(hostname)"
    err "压缩包中未找到 sing-box 可执行文件。"
fi

install -m 755 "$BIN_PATH" "$WORK_DIR/sing-box"
rm -rf "$TEMP_DIR"

# 生成配置
log "正在生成 Shadowsocks 配置..."

cat > "$WORK_DIR/config.json" <<EOF
{
  "log": {
    "level": "info",
    "output": "$WORK_DIR/logs/box.log",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "shadowsocks",
      "tag": "ss-in",
      "listen": "::",
      "listen_port": $LISTEN_PORT,
      "method": "$METHOD",
      "password": "$PASSWORD"
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF

# 验证配置兼容性
if ! "$WORK_DIR/sing-box" check -c "$WORK_DIR/config.json"; then
    tg_send "❌ sing-box 配置检查失败。服务器：$(hostname)"
    err "配置检查失败，请检查 $WORK_DIR/config.json"
fi

# 创建 systemd 服务
log "正在配置 systemd 服务..."

cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=$WORK_DIR
ExecStart=$WORK_DIR/sing-box run -c $WORK_DIR/config.json
Restart=on-failure
RestartSec=5
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

# 配置防火墙
if command -v ufw >/dev/null 2>&1; then
    ufw allow "${LISTEN_PORT}/tcp" || warn "UFW TCP 规则添加失败"
    ufw allow "${LISTEN_PORT}/udp" || warn "UFW UDP 规则添加失败"
elif command -v firewall-cmd >/dev/null 2>&1; then
    firewall-cmd --zone=public --add-port="${LISTEN_PORT}/tcp" --permanent ||
        warn "Firewalld TCP 规则添加失败"
    firewall-cmd --zone=public --add-port="${LISTEN_PORT}/udp" --permanent ||
        warn "Firewalld UDP 规则添加失败"
    firewall-cmd --reload || warn "Firewalld 重载失败"
elif command -v iptables >/dev/null 2>&1; then
    iptables -C INPUT -p tcp --dport "$LISTEN_PORT" -j ACCEPT 2>/dev/null ||
        iptables -I INPUT -p tcp --dport "$LISTEN_PORT" -j ACCEPT
    iptables -C INPUT -p udp --dport "$LISTEN_PORT" -j ACCEPT 2>/dev/null ||
        iptables -I INPUT -p udp --dport "$LISTEN_PORT" -j ACCEPT
fi

# 启动服务
log "正在启动 sing-box..."

systemctl daemon-reload
systemctl enable sing-box

if ! systemctl restart sing-box; then
    journalctl -u sing-box -n 30 --no-pager || true
    tg_send "❌ sing-box 启动失败。服务器：$(hostname)，端口：${LISTEN_PORT}"
    err "服务启动失败，请检查 systemctl status sing-box 和日志。"
fi

sleep 2

if ! systemctl is-active --quiet sing-box; then
    journalctl -u sing-box -n 30 --no-pager || true
    tg_send "❌ sing-box 未能保持运行。服务器：$(hostname)，端口：${LISTEN_PORT}"
    err "服务未处于运行状态。"
fi

# 获取公网 IPv4
log "正在获取服务器公网 IP..."

SERVER_IP=""
for URL in https://api.ipify.org https://ipv4.icanhazip.com https://ifconfig.me; do
    SERVER_IP=$(curl -4 -fsS --connect-timeout 5 --max-time 10 "$URL" 2>/dev/null || true)
    [[ -n "$SERVER_IP" ]] && break
done

if [[ -z "$SERVER_IP" ]]; then
    tg_send "⚠️ sing-box 已启动，但无法获取公网 IP。服务器：$(hostname)，端口：${LISTEN_PORT}"
    err "无法获取公网 IP，请检查服务器网络。"
fi

# 生成 Shadowsocks 链接
log "正在生成 SS 链接..."

SS_USERINFO=$(python3 - "$METHOD" "$PASSWORD" <<'PY'
import base64
import sys
raw = f"{sys.argv[1]}:{sys.argv[2]}".encode()
print(base64.urlsafe_b64encode(raw).decode().rstrip("="))
PY
)

SS_LINK="ss://${SS_USERINFO}@${SERVER_IP}:${LISTEN_PORT}#SingBox-SS"

# Telegram 推送
MESSAGE="✅ sing-box 部署成功
服务器：$(hostname)
IP：${SERVER_IP}
端口：${LISTEN_PORT}
协议：Shadowsocks
加密：${METHOD}
服务状态：运行中

SS 节点链接：
${SS_LINK}"

tg_send "$MESSAGE"

# 本地输出汇总
echo ""
echo "========================================="
echo "  sing-box 部署完成"
echo "========================================="
echo "服务器 IP : $SERVER_IP"
echo "监听端口  : $LISTEN_PORT"
echo "协议      : Shadowsocks"
echo "加密方式  : $METHOD"
echo "服务状态  : $(systemctl is-active sing-box)"
echo "SS 链接   :"
echo "$SS_LINK"
echo "========================================="

systemctl status sing-box --no-pager -l || true
log "部署流程完成。"
