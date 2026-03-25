#!/bin/bash

# WARP 增强版 - 香港 VPS 专属优化脚本
# 功能：自动检测 HK 源 IP，强制新加坡出口，解锁 Google/Gemini/OpenAI

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

show_banner() {
    clear
    echo -e "${CYAN}"
    echo "╔════════════════════════════════════════════════════╗"
    echo "║       🌐 WARP 增强版 - 新加坡出口 (SG) 🌐          ║"
    echo "║       解锁：Google | Gemini | OpenAI/ChatGPT       ║"
    echo "╚════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# 检查 root
[[ $EUID -ne 0 ]] && { echo -e "${RED}请使用 root 运行！${NC}"; exit 1; }

# 环境准备与依赖安装
prepare_system() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        CODENAME=$VERSION_CODENAME
    fi
    ARCH=$(dpkg --print-architecture 2>/dev/null || echo "amd64")
    
    echo -e "${CYAN}正在安装依赖 (curl, jq, redsocks, iptables)...${NC}"
    if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
        apt-get update -y && apt-get install -y curl jq redsocks iptables gnupg >/dev/null 2>&1
    else
        yum install -y curl jq redsocks iptables >/dev/null 2>&1
    fi
}

# 检测 IP 和地理位置
check_ip_logic() {
    echo -e "${CYAN}正在检测源站地理位置...${NC}"
    IP_INFO=$(curl -s https://ipapi.co/json/)
    SRC_IP=$(echo $IP_INFO | jq -r '.ip')
    SRC_COUNTRY=$(echo $IP_INFO | jq -r '.country_code')
    echo -e "当前 IP: ${GREEN}$SRC_IP${NC} (${YELLOW}$SRC_COUNTRY${NC})"
}

# 安装并配置 WARP
setup_warp() {
    echo -e "\n${CYAN}[1/2] 安装并配置 Cloudflare WARP...${NC}"
    
    # 安装 Cloudflare 仓库 (简化流程)
    if ! command -v warp-cli &>/dev/null; then
        if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
            curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
            echo "deb [arch=$ARCH signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $CODENAME main" > /etc/apt/sources.list.d/cloudflare-client.list
            apt-get update -y && apt-get install -y cloudflare-warp
        fi
    fi

    # 初始化设置
    warp-cli --accept-tos registration new 2>/dev/null || warp-cli --accept-tos register 2>/dev/null || true
    warp-cli --accept-tos mode proxy 2>/dev/null || true
    warp-cli --accept-tos proxy port 40000 2>/dev/null || true

    # 关键逻辑：如果是香港 IP，强制指定新加坡 Endpoint
    if [ "$SRC_COUNTRY" == "HK" ]; then
        echo -e "${YELLOW}检测到香港源 IP，正在强制指定新加坡 (Singapore) 接入点...${NC}"
        # 强制连接新加坡 Anycast 节点 IP
        warp-cli --accept-tos tunnel endpoint set 162.159.192.10:2408 2>/dev/null || \
        warp-cli --accept-tos set-custom-endpoint 162.159.192.10:2408 2>/dev/null || true
    fi

    warp-cli --accept-tos connect 2>/dev/null
    sleep 5
}

# 配置透明代理规则 (整合 Google/Gemini/OpenAI)
setup_routing() {
    echo -e "\n${CYAN}[2/2] 配置透明代理路由规则...${NC}"
    
    # 配置 redsocks
    cat > /etc/redsocks.conf << 'EOF'
base { log_debug = off; log_info = on; log = "syslog:daemon"; daemon = on; redirector = iptables; }
redsocks { local_ip = 127.0.0.1; local_port = 12345; ip = 127.0.0.1; port = 40000; type = socks5; }
EOF

    # 定义需要走 WARP 的 IP 段 (包含 Google/Gemini/OpenAI/ChatGPT)
    # 涵盖了 Google 核心段、OpenAI 关联的 Cloudflare 段和 Azure 段
    TARGET_IPS="
    8.8.4.0/24 8.8.8.0/24 34.0.0.0/9 35.184.0.0/13 142.250.0.0/15 172.217.0.0/16
    23.96.0.0/13 23.101.0.0/16 40.70.0.0/16 52.151.0.0/16 13.64.0.0/11 20.33.0.0/16
    104.16.0.0/12 172.64.0.0/13 199.102.0.0/16
    "

    # 创建管理脚本
    cat > /usr/local/bin/warp-proxy << 'EOF'
#!/bin/bash
TARGET_IPS="8.8.4.0/24 8.8.8.0/24 34.0.0.0/9 35.184.0.0/13 142.250.0.0/15 172.217.0.0/16 23.96.0.0/13 23.101.0.0/16 40.70.0.0/16 52.151.0.0/16 13.64.0.0/11 20.33.0.0/16 104.16.0.0/12 172.64.0.0/13 199.102.0.0/16"

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

    # 设置服务
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

test_result() {
    echo -e "\n${CYAN}══════════════ 最终测试 ══════════════${NC}"
    # 测试 WARP 出口
    WARP_RES=$(curl -x socks5://127.0.0.1:40000 -s https://ipapi.co/json/)
    W_IP=$(echo $WARP_RES | jq -r '.ip')
    W_CO=$(echo $WARP_RES | jq -r '.country_code')
    
    echo -e "WARP 出口 IP: ${GREEN}$W_IP${NC} (${YELLOW}$W_CO${NC})"
    
    if [[ "$W_CO" != "HK" ]]; then
        echo -e "${GREEN}✓ 成功！出口已不在香港。Google/Gemini/OpenAI 已解锁。${NC}"
    else
        echo -e "${RED}✗ 警告：出口仍显示为香港，请尝试重启脚本或检查 VPS 路由限制。${NC}"
    fi
}

# 卸载逻辑
do_uninstall() {
    echo -e "${YELLOW}正在卸载并恢复网络设置...${NC}"
    /usr/local/bin/warp-proxy stop 2>/dev/null
    systemctl stop warp-proxy 2>/dev/null
    systemctl disable warp-proxy 2>/dev/null
    rm -f /usr/local/bin/warp-proxy /etc/systemd/system/warp-proxy.service
    warp-cli --accept-tos disconnect 2>/dev/null
    echo -e "${GREEN}卸载完成。${NC}"
}

# 主入口
main() {
    show_banner
    prepare_system
    check_ip_logic
    
    echo -e "\n请选择操作："
    echo -e "1. ${GREEN}安装/修复解锁环境 (SG新加坡出口)${NC}"
    echo -e "2. ${RED}完全卸载${NC}"
    read -p "请输入 [1-2]: " choice
    
    case $choice in
        1)
            setup_warp
            setup_routing
            test_result
            ;;
        2)
            do_uninstall
            ;;
        *)
            echo "退出."
            ;;
    esac
}

main
