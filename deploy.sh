#!/bin/bash
# ============================================================
# VLESS + Reality + Cloudflare WARP 一键部署脚本
# 适用于 Ubuntu/Debian 系统
# ============================================================
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "\n${CYAN}========== $1 ==========${NC}"; }

# ============================================================
# 参数检查
# ============================================================
if [ "$#" -lt 3 ]; then
    echo "用法: bash deploy.sh <服务器IP> <用户名> <SSH密钥路径>"
    echo "示例: bash deploy.sh 43.216.118.188 ubuntu ~/Downloads/key.pem"
    exit 1
fi

SERVER_IP="$1"
SERVER_USER="$2"
SSH_KEY="$3"

# 展开 ~ 路径
SSH_KEY="${SSH_KEY/#\~/$HOME}"

if [ ! -f "$SSH_KEY" ]; then
    log_error "SSH 密钥文件不存在: $SSH_KEY"
    exit 1
fi

chmod 600 "$SSH_KEY"

SSH_OPTS="-o ConnectTimeout=10 -o StrictHostKeyChecking=no -i $SSH_KEY"
SSH_CMD="ssh $SSH_OPTS ${SERVER_USER}@${SERVER_IP}"

log_info "目标服务器: ${SERVER_USER}@${SERVER_IP}"
log_info "SSH 密钥: ${SSH_KEY}"

# 测试连接
log_step "测试 SSH 连接"
if ! $SSH_CMD "echo 'SSH 连接成功'" 2>/dev/null; then
    log_error "无法连接到服务器，请检查 IP、用户名和密钥"
    exit 1
fi

# ============================================================
# Step 1: 安装基础依赖
# ============================================================
log_step "Step 1: 安装基础依赖"

$SSH_CMD "sudo bash -s" << 'REMOTE_SCRIPT'
set -e
export DEBIAN_FRONTEND=noninteractive

apt-get update -qq
apt-get install -y -qq wireguard-tools curl wget jq

# 启用 IP 转发
if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
fi
sysctl -w net.ipv4.ip_forward=1 > /dev/null 2>&1

echo "依赖安装完成"
REMOTE_SCRIPT

# ============================================================
# Step 2: 安装 Xray-core
# ============================================================
log_step "Step 2: 安装 Xray-core"

$SSH_CMD "sudo bash -s" << 'REMOTE_SCRIPT'
set -e

if command -v xray &> /dev/null; then
    echo "Xray 已安装，版本: $(xray version | head -1)"
else
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    echo "Xray 安装完成: $(xray version | head -1)"
fi
REMOTE_SCRIPT

# ============================================================
# Step 3: 生成密钥并配置 VLESS + Reality
# ============================================================
log_step "Step 3: 配置 VLESS + Reality"

XRAY_INFO=$($SSH_CMD "sudo bash -s" << 'REMOTE_SCRIPT'
set -e

# 生成 UUID
UUID=$(xray uuid)

# 生成 Reality 密钥对
OUTPUT=$(xray x25519)
PRIVATE_KEY=$(echo "$OUTPUT" | sed -n '1p' | awk '{print $NF}')
PUBLIC_KEY=$(echo "$OUTPUT" | sed -n '2p' | awk '{print $NF}')

# 生成 Short ID
SHORT_ID=$(openssl rand -hex 8)

# 写入配置
cat > /usr/local/etc/xray/config.json << EOF
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log"
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "www.microsoft.com:443",
          "xver": 0,
          "serverNames": [
            "www.microsoft.com",
            "microsoft.com"
          ],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": [
            "${SHORT_ID}"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "freedom",
      "tag": "warp",
      "sendThrough": "172.16.0.2",
      "settings": {
        "domainStrategy": "UseIP"
      }
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "domain": [
          "youtube.com",
          "youtu.be",
          "youtube-nocookie.com",
          "googlevideo.com",
          "ytimg.com",
          "ggpht.com",
          "yt.be"
        ],
        "outboundTag": "warp"
      },
      {
        "type": "field",
        "domain": [
          "google.com",
          "googleapis.com",
          "gstatic.com",
          "gvt1.com",
          "gvt2.com",
          "gcp.gvt2.com"
        ],
        "outboundTag": "warp"
      },
      {
        "type": "field",
        "ip": [
          "208.65.152.0/22",
          "208.117.224.0/19",
          "216.58.192.0/19",
          "172.217.0.0/16",
          "142.250.0.0/15",
          "74.125.0.0/16"
        ],
        "outboundTag": "warp"
      }
    ]
  }
}
EOF

echo "UUID=${UUID}"
echo "PUBLIC_KEY=${PUBLIC_KEY}"
echo "SHORT_ID=${SHORT_ID}"
REMOTE_SCRIPT
)

# 解析输出
UUID=$(echo "$XRAY_INFO" | grep "^UUID=" | cut -d= -f2)
PUBLIC_KEY=$(echo "$XRAY_INFO" | grep "^PUBLIC_KEY=" | cut -d= -f2)
SHORT_ID=$(echo "$XRAY_INFO" | grep "^SHORT_ID=" | cut -d= -f2)

log_info "UUID: $UUID"
log_info "Public Key: $PUBLIC_KEY"
log_info "Short ID: $SHORT_ID"

# ============================================================
# Step 4: 安装 wgcf 并配置 WARP
# ============================================================
log_step "Step 4: 安装 wgcf + Cloudflare WARP"

$SSH_CMD "sudo bash -s" << 'REMOTE_SCRIPT'
set -e

cd /root

# 安装 wgcf
if [ ! -f /usr/local/bin/wgcf ]; then
    ARCH=$(uname -m)
    if [ "$ARCH" = "x86_64" ]; then
        WGCF_ARCH="amd64"
    elif [ "$ARCH" = "aarch64" ]; then
        WGCF_ARCH="arm64"
    else
        echo "不支持的架构: $ARCH"
        exit 1
    fi

    WGCF_VERSION=$(curl -s https://api.github.com/repos/ViRb3/wgcf/releases/latest | grep '"tag_name"' | sed 's/.*"v\(.*\)".*/\1/')
    wget -q "https://github.com/ViRb3/wgcf/releases/download/v${WGCF_VERSION}/wgcf_${WGCF_VERSION}_linux_${WGCF_ARCH}" -O /usr/local/bin/wgcf
    chmod +x /usr/local/bin/wgcf
    echo "wgcf v${WGCF_VERSION} 安装完成"
else
    echo "wgcf 已安装"
fi

# 注册 WARP 账号
if [ ! -f /root/wgcf-account.toml ]; then
    echo "y" | wgcf register 2>&1
    echo "WARP 账号注册完成"
else
    echo "WARP 账号已存在"
fi

# 生成 WireGuard 配置
wgcf generate 2>&1
echo "WireGuard 配置生成完成"
REMOTE_SCRIPT

# ============================================================
# Step 5: 配置 WireGuard 策略路由
# ============================================================
log_step "Step 5: 配置 WireGuard 策略路由"

$SSH_CMD "sudo bash -s" << 'REMOTE_SCRIPT'
set -e

# 从 wgcf 生成的配置中提取密钥
PRIVATE_KEY=$(grep "PrivateKey" /root/wgcf-profile.conf | awk '{print $NF}')
PUBLIC_KEY_PEER=$(grep "PublicKey" /root/wgcf-profile.conf | awk '{print $NF}')

# 写入带策略路由的 WireGuard 配置
cat > /etc/wireguard/wgcf.conf << EOF
[Interface]
PrivateKey = ${PRIVATE_KEY}
Address = 172.16.0.2/32
DNS = 1.1.1.1, 1.0.0.1
MTU = 1280
Table = off

PostUp = ip rule add from 172.16.0.2 lookup 51820
PostUp = ip route add default dev wgcf table 51820
PostUp = iptables -t mangle -A OUTPUT -s 172.16.0.2 -j MARK --set-mark 0x162
PostUp = ip rule add fwmark 0x162 lookup 51820

PostDown = ip rule del from 172.16.0.2 lookup 51820
PostDown = ip route del default dev wgcf table 51820
PostDown = iptables -t mangle -D OUTPUT -s 172.16.0.2 -j MARK --set-mark 0x162
PostDown = ip rule del fwmark 0x162 lookup 51820

[Peer]
PublicKey = ${PUBLIC_KEY_PEER}
AllowedIPs = 0.0.0.0/0
Endpoint = engage.cloudflareclient.com:2408
EOF

# 启动 WireGuard
wg-quick down wgcf 2>/dev/null || true
wg-quick up wgcf

# 验证 WARP 连通性
WARP_IP=$(curl -s --interface 172.16.0.2 --connect-timeout 10 https://www.cloudflare.com/cdn-cgi/trace | grep "^ip=" | cut -d= -f2)
WARP_STATUS=$(curl -s --interface 172.16.0.2 --connect-timeout 10 https://www.cloudflare.com/cdn-cgi/trace | grep "^warp=" | cut -d= -f2)

echo "WARP 出口 IP: ${WARP_IP}"
echo "WARP 状态: ${WARP_STATUS}"

if [ "$WARP_STATUS" != "on" ]; then
    echo "警告: WARP 未正常工作，请检查网络"
fi
REMOTE_SCRIPT

# ============================================================
# Step 6: 启动服务并设置开机自启
# ============================================================
log_step "Step 6: 启动服务并设置开机自启"

$SSH_CMD "sudo bash -s" << 'REMOTE_SCRIPT'
set -e

# 重启 Xray 加载新配置
systemctl daemon-reload
systemctl restart xray
systemctl enable xray > /dev/null 2>&1

# 启用 WireGuard 开机自启
systemctl enable wg-quick@wgcf > /dev/null 2>&1

sleep 2

# 验证
XRAY_STATUS=$(systemctl is-active xray)
WG_STATUS=$(systemctl is-active wg-quick@wgcf)
PORT_CHECK=$(ss -tlnp | grep ":443 " | wc -l)

echo "Xray 状态: ${XRAY_STATUS}"
echo "WireGuard 状态: ${WG_STATUS}"
echo "443 端口监听: ${PORT_CHECK} 个"
REMOTE_SCRIPT

# ============================================================
# Step 7: 外部可达性测试
# ============================================================
log_step "Step 7: 外部可达性测试"

if nc -z -w 5 "$SERVER_IP" 443 2>/dev/null; then
    log_info "端口 443 外部可达"
else
    log_warn "端口 443 外部不可达，请检查 Lightsail 防火墙是否放行 TCP 443"
fi

# ============================================================
# 输出连接信息
# ============================================================
log_step "部署完成 - 连接信息"

VLESS_LINK="vless://${UUID}@${SERVER_IP}:443?type=tcp&security=reality&sni=www.microsoft.com&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&flow=xtls-rprx-vision#MY-Reality"

echo ""
echo -e "${CYAN}=== 服务器信息 ===${NC}"
echo "服务器地址: ${SERVER_IP}"
echo "端口: 443"
echo ""
echo -e "${CYAN}=== VLESS + Reality 参数 ===${NC}"
echo "UUID: ${UUID}"
echo "Public Key: ${PUBLIC_KEY}"
echo "Short ID: ${SHORT_ID}"
echo "SNI: www.microsoft.com"
echo "Flow: xtls-rprx-vision"
echo "指纹: chrome"
echo ""
echo -e "${CYAN}=== WARP 信息 ===${NC}"
echo "WireGuard IP: 172.16.0.2"
echo "WARP 路由: YouTube, Google 全家桶"
echo ""
echo -e "${CYAN}=== 分享链接（复制导入客户端）===${NC}"
echo ""
echo "$VLESS_LINK"
echo ""
echo -e "${CYAN}=== 客户端推荐 ===${NC}"
echo "Windows/Mac: v2rayN, Nekoray, Hiddify"
echo "iOS: Shadowrocket, Stash"
echo "Android: v2rayNG, NekoBox"
echo ""
echo -e "${GREEN}部署完成！WARP 已配置，YouTube 等网站自动走 Cloudflare 出口。${NC}"
