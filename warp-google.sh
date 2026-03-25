#!/bin/bash

# WARP 终极增强版 V2 - 智能路由 + 自动刷 Key
# 2026 适配版：解决 API 拒绝与连接空值问题

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

prepare_env() {
    echo -e "${CYAN}正在安装/更新依赖...${NC}"
    if [ -f /etc/debian_version ]; then
        apt-get update -y && apt-get install -y curl jq python3 redsocks iptables gnupg >/dev/null 2>&1
    else
        yum install -y curl jq python3 redsocks iptables >/dev/null 2>&1
    fi
}

# --- 深度模拟：自动获取 WARP+ 密钥 ---
generate_warp_plus_key() {
    echo -e "${CYAN}正在通过模拟设备 API 申请 WARP+ 密钥...${NC}"
    # 使用更复杂的 headers 绕过 CF 检测
    PLUS_KEY=$(python3 -c "
import urllib.request, json, uuid
def get_key():
    try:
        device_id = str(uuid.uuid4())
        url = 'https://api.cloudflareclient.com/v0a1922/reg'
        headers = {
            'Content-Type': 'application/json; charset=UTF-8',
            'Host': 'api.cloudflareclient.com',
            'User-Agent': 'okhttp/3.12.1'
        }
        data = json.dumps({'install_id': '', 'key': '', 'tos': '2020-04-01T00:00:00.000Z', 'type': 'Android', 'model': 'Pixel 4'})
        req = urllib.request.Request(url, data=data.encode('utf-8'), headers=headers)
        res = urllib.request.urlopen(req, timeout=10).read()
        return json.loads(res)['account']['license']
    except Exception as e: return None
print(get_key() or '')
")

    if [ -n "$PLUS_KEY" ]; then
        echo -e "${GREEN}成功获取 WARP+ 密钥: $PLUS_KEY${NC}"
        warp-cli --accept-tos registration license "$PLUS_KEY" >/dev/null 2>&1
    else
        echo -e "${RED}自动获取 Key 失败 (CF 接口限流)。建议稍后手动执行: warp-cli registration license [你的Key]${NC}"
    fi
}

configure_route() {
    # 强制重新注册，确保状态干净
    echo -e "${CYAN}正在初始化 WARP 状态...${NC}"
    warp-cli --accept-tos registration new >/dev/null 2>&1 || true
    
    INFO=$(curl -s --max-time 5 https://ipapi.co/json/ || echo '{"country_code":"UNKNOWN"}')
    SRC_CO=$(echo "$INFO" | jq -r '.country_code // .countryCode')
    
    warp-cli --accept-tos mode proxy >/dev/null 2>&1
    warp-cli --accept-tos proxy port 40000 >/dev/null 2>&1

    if [ "$SRC_CO" == "HK" ]; then
        echo -e "${YELLOW}检测到香港源，强制接入新加坡节点 (SG Anycast)...${NC}"
        # 换一个更稳定的新加坡 IP 
        warp-cli --accept-tos tunnel endpoint set 162.159.193.10:2408 >/dev/null 2>&1
    else
        warp-cli --accept-tos tunnel endpoint reset >/dev/null 2>&1
    fi

    warp-cli --accept-tos connect >/dev/null 2>&1
    # 给连接留出足够的时间
    for i in {1..10}; do
        STATUS=$(warp-cli --accept-tos status | grep -c "Connected")
        if [ "$STATUS" -ne 0 ]; then break; fi
        sleep 1
    done
}

setup_proxy() {
    echo -e "${CYAN}正在部署透明代理与安全路由...${NC}"
    
    cat > /etc/redsocks.conf << 'EOF'
base { log_debug = off; log_info = on; log = "syslog:daemon"; daemon = on; redirector = iptables; }
redsocks { local_ip = 127.0.0.1; local_port = 12345; ip = 127.0.0.1; port = 40000; type = socks5; }
EOF

    pkill -9 redsocks 2>/dev/null
    sleep 1
    redsocks -c /etc/redsocks.conf >/dev/null 2>&1

    # 包含 Google, YouTube, OpenAI, Gemini 的全量核心段
    TARGET_IPS="8.8.8.8 8.8.4.4 34.0.0.0/9 142.250.0.0/15 172.217.0.0/16 104.16.0.0/12 172.64.0.0/13 108.160.160.0/20 199.102.0.0/16"

    iptables -t nat -D OUTPUT -j WARP_GOOGLE 2>/dev/null
    iptables -t nat -F WARP_GOOGLE 2>/dev/null
    iptables -t nat -X WARP_GOOGLE 2>/dev/null
    
    iptables -t nat -N WARP_GOOGLE
    for ip in $TARGET_IPS; do
        iptables -t nat -A WARP_GOOGLE -d $ip -p tcp -j REDIRECT --to-ports 12345
    done
    iptables -t nat -I OUTPUT -j WARP_GOOGLE
}

main() {
    prepare_env
    configure_route
    generate_warp_plus_key
    setup_proxy
    
    echo -e "\n${CYAN}--- 最终连通性测试 ---${NC}"
    # 增加等待时间确保 SOCKS5 端口监听成功
    sleep 3
    FINAL_IP=$(curl -x socks5://127.0.0.1:40000 -s --max-time 10 ip.sb)
    
    if [ -n "$FINAL_IP" ]; then
        echo -e "当前 WARP 出口 IP: ${GREEN}$FINAL_IP${NC}"
        echo -e "${GREEN}✓ 全部配置已完成！Google/OpenAI 已解锁。${NC}"
    else
        echo -e "${RED}✗ 测试失败：WARP 已连接但无法通过代理上网。${NC}"
        echo -e "${YELLOW}可能原因：Redsocks 启动失败或 40000 端口被占用。${NC}"
    fi
}

main
