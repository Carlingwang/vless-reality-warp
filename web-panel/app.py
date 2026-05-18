#!/usr/bin/env python3
"""VLESS + Reality + WARP Web Management Panel"""

import json
import os
import subprocess
import hashlib
import secrets
import time
from functools import wraps
from datetime import datetime, timedelta

from flask import (
    Flask, render_template, request, redirect, url_for,
    flash, session, jsonify
)
from werkzeug.security import generate_password_hash, check_password_hash

app = Flask(__name__)
app.secret_key = secrets.token_hex(32)
app.permanent_session_lifetime = timedelta(minutes=30)

CONFIG_PATH = "/opt/proxy-panel/config.json"
XRAY_CONFIG_PATH = "/usr/local/etc/xray/config.json"

# ============================================================
# Login rate limiting
# ============================================================
login_attempts = {}
LOCKOUT_THRESHOLD = 5
LOCKOUT_SECONDS = 900


def is_locked_out(ip):
    if ip not in login_attempts:
        return False
    record = login_attempts[ip]
    if record["count"] >= LOCKOUT_THRESHOLD:
        if time.time() - record["first_attempt"] < LOCKOUT_SECONDS:
            return True
        else:
            del login_attempts[ip]
            return False
    return False


def record_login_attempt(ip, success):
    if success:
        login_attempts.pop(ip, None)
        return
    if ip not in login_attempts:
        login_attempts[ip] = {"count": 1, "first_attempt": time.time()}
    else:
        login_attempts[ip]["count"] += 1


def load_config():
    with open(CONFIG_PATH, "r") as f:
        return json.load(f)


def save_config(config):
    with open(CONFIG_PATH, "w") as f:
        json.dump(config, f, indent=2)


def load_xray_config():
    with open(XRAY_CONFIG_PATH, "r") as f:
        return json.load(f)


def save_xray_config(config):
    with open(XRAY_CONFIG_PATH, "w") as f:
        json.dump(config, f, indent=2)


def run_cmd(cmd):
    try:
        result = subprocess.run(
            cmd, shell=True, capture_output=True, text=True, timeout=15
        )
        return result.stdout.strip(), result.stderr.strip(), result.returncode
    except subprocess.TimeoutExpired:
        return "", "Command timed out", 1


def login_required(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        if not session.get("logged_in"):
            return redirect(url_for("login"))
        return f(*args, **kwargs)
    return decorated


def is_warp_routing_enabled():
    """Check if Xray routing rules currently point traffic to warp outbound."""
    try:
        xray_config = load_xray_config()
        rules = xray_config.get("routing", {}).get("rules", [])
        for rule in rules:
            if rule.get("outboundTag") == "warp":
                return True
    except Exception:
        pass
    return False


def set_warp_routing(enable):
    """Switch Xray routing rules between warp and direct outbound."""
    xray_config = load_xray_config()
    rules = xray_config.get("routing", {}).get("rules", [])
    target_tag = "warp" if enable else "direct"
    changed = False
    for rule in rules:
        if enable:
            if rule.get("outboundTag") == "direct":
                # Only switch back rules that have domain or ip fields (warp rules)
                if "domain" in rule or "ip" in rule:
                    rule["outboundTag"] = "warp"
                    changed = True
        else:
            if rule.get("outboundTag") == "warp":
                rule["outboundTag"] = "direct"
                changed = True
    if changed:
        save_xray_config(xray_config)
        run_cmd("systemctl restart xray")
    return changed


# ============================================================
# Routes: Auth
# ============================================================
@app.route("/login", methods=["GET", "POST"])
def login():
    if session.get("logged_in"):
        return redirect(url_for("dashboard"))

    if request.method == "POST":
        client_ip = request.remote_addr
        if is_locked_out(client_ip):
            flash("登录尝试过多，请15分钟后再试", "error")
            return render_template("login.html")

        username = request.form.get("username", "")
        password = request.form.get("password", "")
        config = load_config()

        if (
            username == config["username"]
            and check_password_hash(config["password_hash"], password)
        ):
            session.permanent = True
            session["logged_in"] = True
            session["username"] = username
            record_login_attempt(client_ip, True)
            return redirect(url_for("dashboard"))
        else:
            record_login_attempt(client_ip, False)
            flash("用户名或密码错误", "error")

    return render_template("login.html")


@app.route("/logout")
def logout():
    session.clear()
    return redirect(url_for("login"))


# ============================================================
# Routes: Dashboard
# ============================================================
@app.route("/")
@login_required
def dashboard():
    # Xray status
    _, _, xray_rc = run_cmd("systemctl is-active xray")
    xray_running = xray_rc == 0

    # WireGuard status
    wg_out, _, wg_rc = run_cmd("wg show wgcf")
    wg_running = wg_rc == 0 and "interface" in wg_out

    # WARP routing status (from Xray config)
    warp_routing = is_warp_routing_enabled()

    # Overall WARP status: both WireGuard up AND routing enabled
    warp_active = wg_running and warp_routing

    # WARP IP (only check when active)
    warp_ip = "N/A"
    if warp_active:
        out, _, rc = run_cmd(
            "curl -s --interface 172.16.0.2 --connect-timeout 5 "
            "https://www.cloudflare.com/cdn-cgi/trace | grep '^ip='"
        )
        if rc == 0 and "=" in out:
            warp_ip = out.split("=")[1]

    # Server info
    mem_out, _, _ = run_cmd("free -h | awk '/Mem:/ {print $3\"/\"$2}'")
    uptime_out, _, _ = run_cmd("uptime -p")
    cpu_out, _, _ = run_cmd("nproc")
    load_out, _, _ = run_cmd("cat /proc/loadavg | awk '{print $1, $2, $3}'")

    # Xray config info
    xray_config = load_xray_config()
    uuid = ""
    short_id = ""
    public_key = ""
    sni = "www.microsoft.com"
    port = 443

    try:
        inbounds = xray_config.get("inbounds", [{}])
        if inbounds:
            inbound = inbounds[0]
            port = inbound.get("port", 443)
            clients = inbound.get("settings", {}).get("clients", [])
            if clients:
                uuid = clients[0].get("id", "")
            reality = inbound.get("streamSettings", {}).get("realitySettings", {})
            short_ids = reality.get("shortIds", [])
            if short_ids:
                short_id = short_ids[0]
            sni_list = reality.get("serverNames", [])
            if sni_list:
                sni = sni_list[0]
    except (KeyError, IndexError):
        pass

    # Get public key from wgcf account
    pub_key_out, _, _ = run_cmd(
        "cat /root/wgcf-profile.conf | grep PublicKey | awk '{print $3}'"
    )
    if pub_key_out:
        public_key = pub_key_out

    server_ip, _, _ = run_cmd(
        "curl -s --connect-timeout 5 ifconfig.me || hostname -I | awk '{print $1}'"
    )

    vless_link = (
        f"vless://{uuid}@{server_ip}:{port}"
        f"?type=tcp&security=reality&sni={sni}&fp=chrome"
        f"&pbk={public_key}&sid={short_id}"
        f"&flow=xtls-rprx-vision#MY-Reality"
    )

    return render_template(
        "dashboard.html",
        xray_running=xray_running,
        wg_running=wg_running,
        warp_routing=warp_routing,
        warp_active=warp_active,
        warp_ip=warp_ip,
        memory=mem_out,
        uptime=uptime_out,
        cpu_count=cpu_out,
        load=load_out,
        uuid=uuid,
        port=port,
        sni=sni,
        short_id=short_id,
        public_key=public_key,
        server_ip=server_ip,
        vless_link=vless_link,
    )


# ============================================================
# Routes: Routing Management
# ============================================================
@app.route("/routing")
@login_required
def routing():
    xray_config = load_xray_config()
    rules = xray_config.get("routing", {}).get("rules", [])

    warp_domains = []
    warp_ips = []
    for rule in rules:
        if rule.get("outboundTag") == "warp":
            warp_domains.extend(rule.get("domain", []))
            warp_ips.extend(rule.get("ip", []))

    return render_template(
        "routing.html", warp_domains=warp_domains, warp_ips=warp_ips
    )


@app.route("/routing/add_domain", methods=["POST"])
@login_required
def add_domain():
    domain = request.form.get("domain", "").strip()
    if not domain:
        flash("域名不能为空", "error")
        return redirect(url_for("routing"))

    xray_config = load_xray_config()
    rules = xray_config.get("routing", {}).get("rules", [])

    domain_rule = None
    for rule in rules:
        if rule.get("outboundTag") == "warp" and "domain" in rule:
            domain_rule = rule
            break

    if domain_rule is None:
        domain_rule = {"type": "field", "domain": [domain], "outboundTag": "warp"}
        rules.append(domain_rule)
    else:
        if domain not in domain_rule["domain"]:
            domain_rule["domain"].append(domain)
        else:
            flash(f"域名 {domain} 已存在", "error")
            return redirect(url_for("routing"))

    xray_config["routing"]["rules"] = rules
    save_xray_config(xray_config)
    run_cmd("systemctl restart xray")
    flash(f"已添加域名: {domain}", "success")
    return redirect(url_for("routing"))


@app.route("/routing/delete_domain", methods=["POST"])
@login_required
def delete_domain():
    domain = request.form.get("domain", "").strip()
    xray_config = load_xray_config()
    rules = xray_config.get("routing", {}).get("rules", [])

    for rule in rules:
        if rule.get("outboundTag") == "warp" and "domain" in rule:
            if domain in rule["domain"]:
                rule["domain"].remove(domain)

    xray_config["routing"]["rules"] = rules
    save_xray_config(xray_config)
    run_cmd("systemctl restart xray")
    flash(f"已删除域名: {domain}", "success")
    return redirect(url_for("routing"))


@app.route("/routing/add_ip", methods=["POST"])
@login_required
def add_ip():
    ip_cidr = request.form.get("ip", "").strip()
    if not ip_cidr:
        flash("IP 段不能为空", "error")
        return redirect(url_for("routing"))

    xray_config = load_xray_config()
    rules = xray_config.get("routing", {}).get("rules", [])

    ip_rule = None
    for rule in rules:
        if rule.get("outboundTag") == "warp" and "ip" in rule:
            ip_rule = rule
            break

    if ip_rule is None:
        ip_rule = {"type": "field", "ip": [ip_cidr], "outboundTag": "warp"}
        rules.append(ip_rule)
    else:
        if ip_cidr not in ip_rule["ip"]:
            ip_rule["ip"].append(ip_cidr)
        else:
            flash(f"IP 段 {ip_cidr} 已存在", "error")
            return redirect(url_for("routing"))

    xray_config["routing"]["rules"] = rules
    save_xray_config(xray_config)
    run_cmd("systemctl restart xray")
    flash(f"已添加 IP 段: {ip_cidr}", "success")
    return redirect(url_for("routing"))


@app.route("/routing/delete_ip", methods=["POST"])
@login_required
def delete_ip():
    ip_cidr = request.form.get("ip", "").strip()
    xray_config = load_xray_config()
    rules = xray_config.get("routing", {}).get("rules", [])

    for rule in rules:
        if rule.get("outboundTag") == "warp" and "ip" in rule:
            if ip_cidr in rule["ip"]:
                rule["ip"].remove(ip_cidr)

    xray_config["routing"]["rules"] = rules
    save_xray_config(xray_config)
    run_cmd("systemctl restart xray")
    flash(f"已删除 IP 段: {ip_cidr}", "success")
    return redirect(url_for("routing"))


# ============================================================
# Routes: Logs
# ============================================================
@app.route("/logs")
@login_required
def logs():
    log_type = request.args.get("type", "xray")
    lines = int(request.args.get("lines", 50))

    if log_type == "xray":
        log_content, _, _ = run_cmd(
            f"tail -n {lines} /var/log/xray/error.log 2>/dev/null || echo '日志为空'"
        )
    elif log_type == "access":
        log_content, _, _ = run_cmd(
            f"tail -n {lines} /var/log/xray/access.log 2>/dev/null || echo '日志为空'"
        )
    elif log_type == "wireguard":
        log_content, _, _ = run_cmd("wg show wgcf")
        if not log_content:
            log_content = "WireGuard 未运行"
    else:
        log_content = "未知日志类型"

    return render_template(
        "logs.html", log_content=log_content, log_type=log_type, lines=lines
    )


# ============================================================
# Routes: Settings
# ============================================================
@app.route("/settings")
@login_required
def settings():
    config = load_config()
    return render_template(
        "settings.html", username=config["username"], port=config.get("port", 8080)
    )


@app.route("/settings/change_password", methods=["POST"])
@login_required
def change_password():
    current_pw = request.form.get("current_password", "")
    new_pw = request.form.get("new_password", "")
    confirm_pw = request.form.get("confirm_password", "")

    config = load_config()

    if not check_password_hash(config["password_hash"], current_pw):
        flash("当前密码错误", "error")
        return redirect(url_for("settings"))

    if len(new_pw) < 8:
        flash("新密码至少8个字符", "error")
        return redirect(url_for("settings"))

    if new_pw != confirm_pw:
        flash("两次输入的密码不一致", "error")
        return redirect(url_for("settings"))

    config["password_hash"] = generate_password_hash(new_pw)
    save_config(config)
    flash("密码修改成功", "success")
    return redirect(url_for("settings"))


# ============================================================
# Routes: Service Control
# ============================================================
@app.route("/service/<action>", methods=["POST"])
@login_required
def service_action(action):
    if action == "restart_xray":
        _, err, rc = run_cmd("systemctl restart xray")
        if rc == 0:
            flash("Xray 已重启", "success")
        else:
            flash(f"Xray 重启失败: {err}", "error")
    elif action == "restart_warp":
        # Restart WireGuard and ensure routing is set to warp
        run_cmd("wg-quick down wgcf 2>/dev/null")
        _, err, rc = run_cmd("wg-quick up wgcf")
        if rc == 0:
            set_warp_routing(True)
            flash("WARP 已重新连接", "success")
        else:
            flash(f"WARP 重启失败: {err}", "error")
    elif action == "warp_on":
        _, err, rc = run_cmd("wg-quick up wgcf")
        if rc == 0:
            set_warp_routing(True)
            flash("WARP 已开启，YouTube/Google 走 Cloudflare 出口", "success")
        else:
            flash(f"WARP 开启失败: {err}", "error")
    elif action == "warp_off":
        # Step 1: Switch Xray routing to direct (so traffic flows immediately)
        set_warp_routing(False)
        # Step 2: Stop WireGuard
        _, err, rc = run_cmd("wg-quick down wgcf")
        if rc == 0:
            flash("WARP 已关闭，所有流量走直连", "success")
        else:
            # WireGuard might already be down, still count as success
            # since routing is already switched to direct
            flash("WARP 已关闭，所有流量走直连", "success")
    else:
        flash("未知操作", "error")

    return redirect(request.referrer or url_for("dashboard"))


@app.route("/api/warp_status")
@login_required
def warp_status():
    # Check WireGuard interface
    wg_out, _, wg_rc = run_cmd("wg show wgcf")
    wg_running = wg_rc == 0 and "interface" in wg_out

    # Check Xray routing
    warp_routing = is_warp_routing_enabled()

    if wg_running and warp_routing:
        # Check if really connected (has handshake)
        out, _, _ = run_cmd("wg show wgcf latest-handshakes")
        if out:
            parts = out.strip().split()
            if len(parts) >= 2 and int(parts[1]) > 0:
                return jsonify({"status": "connected"})
        return jsonify({"status": "connecting"})
    elif not wg_running and not warp_routing:
        return jsonify({"status": "disconnected"})
    else:
        # Inconsistent state
        return jsonify({"status": "partial"})


# ============================================================
# Main
# ============================================================
if __name__ == "__main__":
    config = load_config()
    port = config.get("port", 8080)
    app.run(host="0.0.0.0", port=port, debug=False)
