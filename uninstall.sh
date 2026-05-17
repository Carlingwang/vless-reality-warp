#!/bin/bash
# ============================================================
# VLESS + Reality + Cloudflare WARP 完全卸载脚本
# ============================================================
set -e

if [ "$#" -lt 3 ]; then
    echo "用法: bash uninstall.sh <服务器IP> <用户名> <SSH密钥路径>"
    exit 1
fi

SERVER_IP="$1"
SERVER_USER="$2"
SSH_KEY="${3/#\~/$HOME}"

SSH_OPTS="-o ConnectTimeout=10 -o StrictHostKeyChecking=no -i $SSH_KEY"
SSH_CMD="ssh $SSH_OPTS ${SERVER_USER}@${SERVER_IP}"

echo "正在卸载..."

$SSH_CMD "sudo bash -s" << 'REMOTE_SCRIPT'
set -e

# 停止并禁用服务
systemctl stop proxy-panel 2>/dev/null || true
systemctl disable proxy-panel 2>/dev/null || true
systemctl stop wg-quick@wgcf 2>/dev/null || true
systemctl disable wg-quick@wgcf 2>/dev/null || true
systemctl stop xray 2>/dev/null || true
systemctl disable xray 2>/dev/null || true

# 卸载 Xray
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove 2>/dev/null || true
rm -rf /usr/local/etc/xray /usr/local/bin/xray /usr/local/share/xray /var/log/xray
rm -f /etc/systemd/system/xray.service /etc/systemd/system/xray@.service
rm -rf /etc/systemd/system/xray.service.d /etc/systemd/system/xray@.service.d

# 卸载 WireGuard 配置
wg-quick down wgcf 2>/dev/null || true
rm -f /etc/wireguard/wgcf.conf

# 卸载 wgcf
rm -f /usr/local/bin/wgcf
rm -f /root/wgcf-account.toml /root/wgcf-profile.conf

# 卸载 Web 面板
rm -rf /opt/proxy-panel
rm -f /etc/systemd/system/proxy-panel.service

# 清理 iptables 规则
iptables -t mangle -D OUTPUT -s 172.16.0.2 -j MARK --set-mark 0x162 2>/dev/null || true
ip rule del from 172.16.0.2 lookup 51820 2>/dev/null || true
ip rule del fwmark 0x162 lookup 51820 2>/dev/null || true
ip route del default dev wgcf table 51820 2>/dev/null || true

# 清理 sysctl
sed -i '/net.ipv4.ip_forward=1/d' /etc/sysctl.conf
sysctl -p 2>/dev/null || true

systemctl daemon-reload

echo "卸载完成"
REMOTE_SCRIPT

echo "所有组件已完全卸载。"
