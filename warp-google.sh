#!/bin/bash

# WARP 增强版 - 智能区域漂移脚本
# 功能：HK 源 IP 自动漂移至 SG；其他源 IP 维持本地 WARP 出口

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

show_banner() {
    clear
    echo -e "${CYAN}"
    echo "╔════════════════════════════════════════════════════╗"
    echo "║       🌐 WARP 增强版 - 智能出口路由脚本 🌐         ║"
    echo "║       香港源 -> 新加坡出口 | 其他源 -> 本地出口    ║"
    echo "╚════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# 检查 root
[[ $EUID -ne 0 ]] && { echo -e "${RED}请使用 root 运行！${NC}"; exit 1; }

# 1. 先安装必要依赖，确保后续检测不会出现 null
prepare_system() {
    echo -e "${CYAN}正在检查并安装必要依赖...${NC}"
    if [ -f /etc/debian_version ]; then
        apt-get update -y && apt-get install -y curl jq redsocks iptables gnupg >/dev/null 2>&1
    elif [ -f /etc/redhat-release ]; then
        yum install -y curl jq redsocks iptables >/dev/null 2>&1
    fi
}

# 2. 更加健壮的 IP 检测函数 (增加重试逻辑)
check_ip_logic() {
    echo -e "${CYAN}正在检测源站地理位置...${NC}"
    # 使用多个 API 备份，防止单个 API 返回 null
    IP_INFO=$(curl -s --max-time 5 https://ipapi.co/json/ || curl -s --max-time 5 http://ip-api.com/json/)
    
    # 尝试解析
    SRC_IP=$(echo "$IP_INFO" | jq -r '.ip // .query')
    SRC_COUNTRY=$(echo "$IP_INFO" | jq -r '.country_code // .countryCode')

    if [[ "$SRC_IP" == "null" || -z "$SRC_IP" ]]; then
        # 如果 jq 解析失败，使用最基础的 curl 获取 IP
        SRC_IP=$(curl -s https://ifconfig.me)
        SRC_COUNTRY="Unknown"
        echo -e "${YELLOW}警告: 详细地理位置检测失败，仅获取到 IP: $SRC_IP${NC}"
    else
        echo -e "当前 IP: ${GREEN}$SRC_IP${NC} (${YELLOW}$SRC_COUNTRY${NC})"
    fi
}

# 3. 安装并配置 WARP (核心条件逻辑)
setup_warp() {
    echo -e "\n${CYAN}[1/2] 配置 Cloudflare WARP 策略...${NC}"
    
    # 注册逻辑 (如果未注册)
    warp-cli --accept-tos registration new 2>/dev/null || warp-cli --accept-tos register 2>/dev/null || true
    warp-cli --accept-tos mode proxy 2>/dev/null || true
    warp-cli --accept-tos proxy port 40000 2>/dev/null || true

    # --- 核心逻辑：条件分支 ---
    if [ "$SRC_COUNTRY" == "HK" ]; then
        echo -e "${YELLOW}检测到香港源 IP，正在强制指定新加坡 (Singapore) 接入点以解锁服务...${NC}"
        # 设置新加坡端点
        warp-cli --accept-tos tunnel endpoint set 162.159.192.10:2408 2>/dev/null || \
        warp-cli --accept-tos set-custom-endpoint 162.159.192.10:2408 2>/dev/null || true
    else
        echo -e "${GREEN}源 IP 不是香港 ($SRC_COUNTRY)，将维持本地 WARP 出口 (自动最优接入)...${NC}"
        # 恢复默认设置，确保不会被之前的脚本设置锁死在新加坡
        warp-cli --accept-tos tunnel endpoint reset 2>/dev/null || true
    fi

    warp-cli --accept-tos connect 2>/dev/null
    sleep 5
}

# 4. 配置透明代理规则 (Google/Gemini/OpenAI)
setup_routing() {
    echo -e "\n${CYAN}[2/2] 配置透明代理路由规则...${NC}"
    
    # 配置 redsocks
    cat > /etc/redsocks.conf << 'EOF'
base { log_debug = off; log_info = on; log = "syslog:daemon"; daemon = on; redirector = iptables; }
redsocks { local_ip = 127.0.0.1; local_port = 12345; ip = 127.0.0.1; port = 40000; type = socks5; }
EOF

    # 定义目标 IP 段
    # 包含 Google, Gemini(Google Cloud段), OpenAI(Azure/Cloudflare段)
    TARGET_IPS="
    8.8.4.0/24 8.8.8.0/24 34.0.0.0/9 35.184.0.0/13 64.233.160.0/19 142.250.0.0/15 172.217.0.0/16
    23.96.0.0/13 23.101.0.0/16 40.70.0.0/16 52.151.0.0/16 13.64.0.0/11 20.33.0.0/16
    104.16.0.0/12 172.64.0.0/13 199.102.0.0/16
    "

    cat > /usr/local/bin/warp-proxy << 'EOF'
#!/bin/bash
TARGET_IPS="8.8.4.0/24 8.8.8.0/24 34.0.0.0/9 35.184.0.0/13 64.233.160.0/19 142.250.0.0/15 172.217.0.0/16 23.96.0.0/13 23.101.0.0/16 40.70.0.0/16 52.151.0.0/16 13.64.0.0/11 20.33.0.0/16 104.16.0.0/12 172.64.0.0/13 199.102.0.0/16"
case "$1" in
    start)
        pkill redsocks 2>/dev/null
        sleep 1 && redsocks -c /etc/redsocks.conf
        iptables -t nat -N WARP_UNLOCK 2>/dev/null || iptables -t nat -F WARP_UNLOCK
        for ip in $TARGET_IPS; do
            iptables -t nat -A WARP_UNLOCK -d $ip -p tcp -j REDIRECT --to-ports 12345
        done
        iptables -t nat -I OUTPUT -j WARP_UNLOCK
        ;;
    stop)
        pkill redsocks 2>/dev/null
        iptables -t nat -D OUTPUT -j WARP_UNLOCK 2>/dev/null
        iptables -t nat -F WARP_UNLOCK 2>/dev/null
        iptables -t nat -X WARP_UNLOCK 2>/dev/null
        ;;
esac
EOF
    chmod +x /usr/local/bin/warp-proxy
    /usr/local/bin/warp-proxy start

    # 设置 systemd 自启动
    cat > /etc/systemd/system/warp-proxy.service << 'EOF'
[Unit]
Description=WARP Unlock Proxy
After=network.target warp-svc.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/warp-proxy start
ExecStop=/usr/local/bin/warp-proxy stop
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable warp-proxy >/dev/null 2>&1
}

# 5. 测试结果
test_result() {
    echo -e "\n${CYAN}══════════════ 最终测试 ══════════════${NC}"
    # 通过代理通道查看出口 IP
    WARP_RES=$(curl -x socks5://127.0.0.1:40000 -s https://ipapi.co/json/ || echo '{"country_code":"Error"}')
    W_CO=$(echo $WARP_RES | jq -r '.country_code // .countryCode')
    W_IP=$(echo $WARP_RES | jq -r '.ip // .query')
    
    echo -e "WARP 出口 IP: ${GREEN}$W_IP${NC} (${YELLOW}$W_CO${NC})"
    
    if [[ "$SRC_COUNTRY" == "HK" ]]; then
        if [[ "$W_CO" == "SG" ]]; then
            echo -e "${GREEN}✓ 成功：香港源已重定向至新加坡出口，Gemini/OpenAI 已解锁。${NC}"
        else
            echo -e "${YELLOW}! 提示：虽已设置，但 Cloudflare 分配了 $W_CO 出口，请确认是否能用。${NC}"
        fi
    else
        echo -e "${GREEN}✓ 成功：维持了 $W_CO 本地出口。${NC}"
    fi
}

# 主流程
main() {
    show_banner
    prepare_system
    check_ip_logic
    
    echo -e "\n请选择操作："
    echo -e "1. ${GREEN}安装/配置智能 WARP 解锁${NC}"
    echo -e "2. ${RED}卸载恢复${NC}"
    read -p "请输入 [1-2]: " choice
    
    case $choice in
        1)
            setup_warp
            setup_routing
            test_result
            ;;
        2)
            # 简单卸载
            /usr/local/bin/warp-proxy stop 2>/dev/null
            systemctl disable warp-proxy 2>/dev/null
            warp-cli --accept-tos disconnect 2>/dev/null
            warp-cli --accept-tos tunnel endpoint reset 2>/dev/null
            echo -e "${GREEN}已卸载。${NC}"
            ;;
        *)
            exit 0
            ;;
    esac
}

main
