#!/bin/bash

# WARP 智能修复版 - 增加安全预检
# 只有在代理通路完全打通的情况下才会应用拦截规则

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# 1. 彻底清理环境
cleanup() {
    echo -e "${YELLOW}正在清理旧规则...${NC}"
    pkill -9 redsocks 2>/dev/null
    iptables -t nat -D OUTPUT -j WARP_GOOGLE 2>/dev/null
    iptables -t nat -F WARP_GOOGLE 2>/dev/null
    iptables -t nat -X WARP_GOOGLE 2>/dev/null
}

# 2. 检测地理位置并设置 WARP
setup_warp_endpoint() {
    # 强制安装依赖
    apt-get update && apt-get install -y curl jq redsocks iptables >/dev/null 2>&1
    
    INFO=$(curl -s --max-time 5 https://ipapi.co/json/ || echo '{"country_code":"UNKNOWN"}')
    COUNTRY=$(echo "$INFO" | jq -r '.country_code')

    # 注册与基本配置
    warp-cli --accept-tos registration new 2>/dev/null || true
    warp-cli --accept-tos mode proxy 2>/dev/null
    warp-cli --accept-tos proxy port 40000 2>/dev/null
    
    if [ "$COUNTRY" == "HK" ]; then
        echo -e "${YELLOW}检测到香港源 IP，强制连接新加坡端点...${NC}"
        warp-cli --accept-tos tunnel endpoint set 162.159.192.10:2408 2>/dev/null
    else
        warp-cli --accept-tos tunnel endpoint reset 2>/dev/null
    fi
    
    warp-cli --accept-tos connect 2>/dev/null
    sleep 5
}

# 3. 启动透明代理并进行“通路预检”
start_proxy_safely() {
    # 写入 redsocks 配置
    cat > /etc/redsocks.conf << 'EOF'
base { log_debug = off; log_info = on; log = "syslog:daemon"; daemon = on; redirector = iptables; }
redsocks { local_ip = 127.0.0.1; local_port = 12345; ip = 127.0.0.1; port = 40000; type = socks5; }
EOF

    # 启动 redsocks
    pkill -9 redsocks 2>/dev/null
    redsocks -c /etc/redsocks.conf
    sleep 2

    # 【核心预检】：测试 SOCKS5 通道是否真的通了
    echo -e "${CYAN}正在预检代理通道...${NC}"
    CHECK=$(curl -x socks5://127.0.0.1:40000 -s --max-time 5 https://www.google.com -o /dev/null -w "%{http_code}")
    
    if [ "$CHECK" != "200" ]; then
        echo -e "${RED}错误：WARP 代理通道不可用 (状态码: $CHECK)，为了防止断网，脚本已停止应用拦截规则。${NC}"
        cleanup
        exit 1
    fi
    
    echo -e "${GREEN}通路预检成功，开始应用域名 IP 拦截...${NC}"

    # 定义目标 IP 段
    TARGET_IPS="8.8.8.8 8.8.4.4 34.0.0.0/9 142.250.0.0/15 172.217.0.0/16 104.16.0.0/12 172.64.0.0/13"

    # 应用规则
    iptables -t nat -N WARP_GOOGLE 2>/dev/null || iptables -t nat -F WARP_GOOGLE
    for ip in $TARGET_IPS; do
        iptables -t nat -A WARP_GOOGLE -d $ip -p tcp -j REDIRECT --to-ports 12345
    done
    iptables -t nat -I OUTPUT -j WARP_GOOGLE
    echo -e "${GREEN}✓ 解锁规则已生效！${NC}"
}

# 执行主流程
cleanup
setup_warp_endpoint
start_proxy_safely
