#!/bin/bash

# WARP 一键脚本 - 智能区域优化版
# 保持原始透明代理逻辑，仅针对香港源 IP 优化出口

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# 1. 预执行：安装必要工具，防止检测 IP 时出现 null
prepare_tools() {
    if [ -f /etc/debian_version ]; then
        apt-get update -y >/dev/null 2>&1
        apt-get install -y curl jq >/dev/null 2>&1
    elif [ -f /etc/redhat-release ]; then
        yum install -y curl jq >/dev/null 2>&1
    fi
}

# 2. 增强型 IP 检测
get_geo_info() {
    # 尝试多个接口，确保不返回 null
    local info=$(curl -s --max-time 5 https://ipapi.co/json/ || curl -s --max-time 5 http://ip-api.com/json/)
    SRC_IP=$(echo "$info" | jq -r '.ip // .query')
    SRC_COUNTRY=$(echo "$info" | jq -r '.country_code // .countryCode')
    
    if [[ "$SRC_IP" == "null" || -z "$SRC_IP" ]]; then
        SRC_IP=$(curl -s ifconfig.me)
        SRC_COUNTRY="UNKNOWN"
    fi
}

# 3. 配置 WARP（核心：仅对香港执行端点偏移）
configure_warp_logic() {
    echo -e "\n${CYAN}[1/3] 配置 WARP 客户端...${NC}"
    
    # 基础注册与模式设置
    warp-cli --accept-tos registration new 2>/dev/null || warp-cli --accept-tos register 2>/dev/null || true
    warp-cli --accept-tos mode proxy 2>/dev/null || true
    warp-cli --accept-tos proxy port 40000 2>/dev/null || true

    # --- 智能出口逻辑 ---
    if [ "$SRC_COUNTRY" == "HK" ]; then
        echo -e "${YELLOW}检测到香港源 IP，正在将 WARP 接入点定向至新加坡 (SG)...${NC}"
        # 强制新加坡端点
        warp-cli --accept-tos tunnel endpoint set 162.159.192.10:2408 2>/dev/null || \
        warp-cli --accept-tos set-custom-endpoint 162.159.192.10:2408 2>/dev/null || true
    else
        echo -e "${GREEN}源 IP ($SRC_COUNTRY) 非香港，使用默认就近接入逻辑。${NC}"
        # 恢复默认设置，防止被之前的脚本设置锁死
        warp-cli --accept-tos tunnel endpoint reset 2>/dev/null || true
    fi

    warp-cli --accept-tos connect 2>/dev/null
    sleep 3
}

# 4. 配置透明代理（完全沿用你原始脚本的 iptables 逻辑，仅补充 OpenAI/Gemini IP）
setup_transparent_proxy() {
    echo -e "\n${CYAN}[2/3] 安装透明代理组件...${NC}"
    
    # 安装 redsocks
    if [ -f /etc/debian_version ]; then
        apt-get install -y redsocks iptables >/dev/null 2>&1
    else
        yum install -y redsocks iptables >/dev/null 2>&1
    fi

    # 原始配置逻辑：创建 redsocks.conf
    cat > /etc/redsocks.conf << 'EOF'
base {
    log_debug = off;
    log_info = on;
    log = "syslog:daemon";
    daemon = on;
    redirector = iptables;
}
redsocks {
    local_ip = 127.0.0.1;
    local_port = 12345;
    ip = 127.0.0.1;
    port = 40000;
    type = socks5;
}
EOF

    # 原始配置逻辑：创建管理脚本 /usr/local/bin/warp-google
    # 这里加入了 OpenAI 和 Gemini 的常用网段，保持原有 start/stop 结构
    cat > /usr/local/bin/warp-google << 'SCRIPT'
#!/bin/bash

# 包含 Google、OpenAI、Gemini 的核心网段
TARGET_IPS="
8.8.4.0/24 8.8.8.0/24 34.0.0.0/9 35.184.0.0/13 35.192.0.0/12 35.224.0.0/12 35.240.0.0/13
64.233.160.0/19 66.102.0.0/20 66.249.64.0/19 72.14.192.0/18 74.125.0.0/16 104.132.0.0/14
108.177.0.0/17 142.250.0.0/15 172.217.0.0/16 172.253.0.0/16 173.194.0.0/16 209.85.128.0/17
216.58.192.0/19 216.239.32.0/19 104.16.0.0/12 172.64.0.0/13
"

start() {
    pkill redsocks 2>/dev/null
    redsocks -c /etc/redsocks.conf
    iptables -t nat -N WARP_GOOGLE 2>/dev/null || iptables -t nat -F WARP_GOOGLE
    for ip in $TARGET_IPS; do
        iptables -t nat -A WARP_GOOGLE -d $ip -p tcp -j REDIRECT --to-ports 12345
    done
    iptables -t nat -C OUTPUT -j WARP_GOOGLE 2>/dev/null || iptables -t nat -A OUTPUT -j WARP_GOOGLE
}

stop() {
    pkill redsocks 2>/dev/null
    iptables -t nat -D OUTPUT -j WARP_GOOGLE 2>/dev/null
    iptables -t nat -F WARP_GOOGLE 2>/dev/null
    iptables -t nat -X WARP_GOOGLE 2>/dev/null
}

case "$1" in
    start) start ;;
    stop) stop ;;
    restart) stop; sleep 1; start ;;
    *) echo "Usage: $0 {start|stop|restart}" ;;
esac
SCRIPT

    chmod +x /usr/local/bin/warp-google
    /usr/local/bin/warp-google start

    # 创建 systemd 服务（原始逻辑）
    cat > /etc/systemd/system/warp-google.service << 'EOF'
[Unit]
Description=WARP Google/AI Proxy
After=network.target warp-svc.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/warp-google start
ExecStop=/usr/local/bin/warp-google stop
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable warp-google 2>/dev/null
    echo -e "${GREEN}✓ 透明代理已启动 (Google/OpenAI/Gemini)${NC}"
}

# 5. 主流程
main() {
    clear
    echo -e "${CYAN}=== WARP 智能解锁脚本 ===${NC}"
    prepare_tools
    get_geo_info
    echo -e "源 IP: ${GREEN}$SRC_IP${NC} 位置: ${GREEN}$SRC_COUNTRY${NC}"
    
    # 执行安装
    configure_warp_logic
    setup_transparent_proxy
    
    # 测试
    echo -e "\n${CYAN}测试出口 IP...${NC}"
    local TEST_IP=$(curl -x socks5://127.0.0.1:40000 -s --max-time 5 ip.sb)
    echo -e "WARP 代理出口: ${GREEN}$TEST_IP${NC}"
}

main
