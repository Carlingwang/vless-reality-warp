# VLESS + Reality + Cloudflare WARP 一键部署

在海外 VPS 上部署 VLESS + Reality 代理，并通过 Cloudflare WARP 为 YouTube、Google 等网站提供住宅级出口 IP。

## 架构

```
客户端设备
  ↓ VLESS + Reality (加密翻墙)
海外 VPS
  ↓ YouTube/Google 流量走 WireGuard 隧道
Cloudflare WARP (消费者级出口IP)
  ↓
目标网站
```

## 两层代理解决的问题

| 层 | 协议 | 作用 |
|----|------|------|
| 第一层 | VLESS + Reality | 翻墙、加密、隐藏真实 IP |
| 第二层 | WireGuard → WARP | 出口 IP 从机房 IP 变为 Cloudflare 消费者 IP |

## 系统要求

- Ubuntu 20.04+ / Debian 11+
- 1GB+ 内存
- 服务器位于海外（中国大陆无法使用）
- AWS Lightsail 需在控制台放行 TCP 443 入站

## 一键部署

```bash
bash deploy.sh <服务器IP> <用户名> <SSH密钥路径> <面板用户名> <面板密码>

# 示例
bash deploy.sh 43.216.118.188 ubuntu ~/Downloads/key.pem admin MyPass123
```

部署完成后会输出 VLESS 分享链接和 Web 管理面板地址。

## Web 管理面板

部署完成后自动安装 Web 管理面板，功能包括：

- **Dashboard**: 服务状态、服务器信息、VLESS 链接一键复制
- **Routing**: 可视化管理 WARP 路由（添加/删除走 WARP 的域名和 IP 段）
- **Logs**: 查看 Xray 和 WireGuard 日志
- **Settings**: 修改登录密码

访问地址: `http://服务器IP:8080`

需在 Lightsail 防火墙放行 TCP 8080 端口。

## 自动走 WARP 的网站

- YouTube (youtube.com, googlevideo.com, ytimg.com)
- Google (google.com, googleapis.com, gstatic.com)
- Google 视频流 IP 段

其他网站走直连出口，不受 WARP 影响。

## 客户端推荐

| 平台 | 推荐客户端 |
|------|-----------|
| Windows | v2rayN, Nekoray |
| macOS | v2rayN, Hiddify, ClashX Meta |
| iOS | Shadowrocket, Stash |
| Android | v2rayNG, NekoBox, Hiddify |

## 卸载

```bash
bash uninstall.sh <服务器IP> <用户名> <SSH密钥路径>
```

## 技术细节

- **Xray-core**: VLESS + Reality 服务端，端口 443
- **wgcf**: Cloudflare WARP 的开源命令行工具（https://github.com/ViRb3/wgcf）
- **WireGuard**: WARP 底层协议，通过策略路由实现仅特定流量走 WARP
- **策略路由**: 使用 `ip rule` + `iptables mark` 确保 WARP 不影响 SSH 和其他正常流量

## 为什么用 wgcf 而不是第三方脚本

wgcf 是 Cloudflare WARP 的开源 CLI 工具，7000+ star，Go 语言编写，代码透明：

```bash
wgcf register    # 注册 WARP 账号
wgcf generate    # 生成标准 WireGuard 配置
```

生成的配置是标准 WireGuard 格式，无隐藏逻辑，可直接审计。

## 故障排查

**YouTube 仍然不能看？**
- 确认 Lightsail 防火墙放行了 TCP 443
- 在客户端确认已导入正确的分享链接
- 检查服务器上 WireGuard 是否运行: `sudo wg show wgcf`

**SSH 连不上服务器？**
- WARP 使用策略路由，不影响 SSH。如遇问题，在 Lightsail 控制台用 Web Shell 执行:
  ```bash
  sudo wg-quick down wgcf
  sudo systemctl restart xray
  ```

**重装？**
```bash
# 先卸载
bash uninstall.sh <IP> <用户> <密钥>
# 再部署
bash deploy.sh <IP> <用户> <密钥> <面板用户名> <面板密码>
```
