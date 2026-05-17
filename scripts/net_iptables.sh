#!/bin/bash

# ==========================================
# 流量监控一键安装 & 管理脚本
# 安装后可用 llcx 命令快速调出管理菜单
# 功能：
# 1. 自动安装流量监控（vnstat + iptables）
# 2. llcx 管理菜单：查看流量、修改上限、修改放行端口、重置
# ==========================================

CONFIG_FILE="/etc/llcx.conf"
CHECK_SCRIPT="/root/check_traffic.sh"
RESET_SCRIPT="/root/reset_network.sh"
LLCX_BIN="/usr/local/bin/llcx"

RED='\033[91m'
GREEN='\033[92m'
YELLOW='\033[93m'
CYAN='\033[96m'
NC='\033[0m'

# 检查 root 权限
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}错误：请使用 root 权限运行此脚本。${NC}"
    exit 1
fi

# 自动获取网卡
INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
if [ -z "$INTERFACE" ]; then
    echo -e "${RED}错误：无法检测到网卡名称。${NC}"
    exit 1
fi

# ==========================================
# 配置管理
# ==========================================

init_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        cat > "$CONFIG_FILE" <<EOF
LIMIT=180
ALLOWED_PORTS=22
EOF
    fi
    source "$CONFIG_FILE"
}

load_config() {
    source "$CONFIG_FILE"
}

save_config() {
    cat > "$CONFIG_FILE" <<EOF
LIMIT=$LIMIT
ALLOWED_PORTS=$ALLOWED_PORTS
EOF
}

# ==========================================
# 生成监控脚本
# ==========================================

generate_check_script() {
    load_config
    cat > "$CHECK_SCRIPT" <<'CHECKEOF'
#!/bin/bash
export LC_ALL=C
source /etc/llcx.conf

LOG_FILE="/var/log/traffic_monitor.log"
INTERFACE="PLACEHOLDER_INTERFACE"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

if [ "$(id -u)" -ne 0 ]; then
    echo "错误：需要 root 权限"
    exit 1
fi

VNSTAT_RAW=$(vnstat -i "$INTERFACE" --oneline b 2>/dev/null)
TX_BYTES=$(echo "$VNSTAT_RAW" | cut -d ';' -f 10)

if [[ -z "$TX_BYTES" || ! "$TX_BYTES" =~ ^[0-9]+$ ]]; then
    TX_BYTES=0
fi

TX_GB=$(echo "scale=2; $TX_BYTES / 1073741824" | bc 2>/dev/null)
if [[ -z "$TX_GB" ]]; then
    TX_GB="0.00"
fi

echo "========================================"
echo " 网卡接口    : $INTERFACE"
echo " 当前时间    : $(date '+%Y-%m-%d %H:%M:%S')"
echo " 精确出站(TX): $TX_BYTES Bytes"
echo " 换算出站(TX): $TX_GB GB"
echo " 流量上限    : $LIMIT GB"
echo " 放行端口    : $ALLOWED_PORTS"
echo "========================================"

log "当前出站流量: $TX_GB GB (限制: $LIMIT GB)"

OVER=$(echo "$TX_GB >= $LIMIT" | bc 2>/dev/null)
if [ "$OVER" = "1" ]; then
    echo "状态: [警告] 流量已超限，正在应用防火墙规则..."
    log "警告：流量超出限制！执行封禁策略..."

    iptables -F
    iptables -X
    iptables -P INPUT DROP
    iptables -P FORWARD DROP
    iptables -P OUTPUT ACCEPT

    iptables -A INPUT -i lo -j ACCEPT
    iptables -A OUTPUT -o lo -j ACCEPT
    iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

    IFS=',' read -ra PORTS <<< "$ALLOWED_PORTS"
    for port in "${PORTS[@]}"; do
        port=$(echo "$port" | tr -d ' ')
        if [[ -n "$port" ]]; then
            iptables -A INPUT -p tcp --dport "$port" -j ACCEPT
            iptables -A INPUT -p udp --dport "$port" -j ACCEPT
        fi
    done

    log "网络已限制（放行端口: $ALLOWED_PORTS）。"
else
    echo "状态: [正常] 流量未超限。"
    log "流量正常。"
fi
CHECKEOF

    # 替换网卡占位符
    sed -i "s|PLACEHOLDER_INTERFACE|$INTERFACE|g" "$CHECK_SCRIPT"
    chmod +x "$CHECK_SCRIPT"
}

# ==========================================
# 生成重置脚本
# ==========================================

generate_reset_script() {
    cat > "$RESET_SCRIPT" <<RESETEOF
#!/bin/bash
RESET_LOG="/var/log/network_reset.log"
TRAFFIC_LOG="/var/log/traffic_monitor.log"
INTERFACE="$INTERFACE"

log() {
    echo "\$(date '+%Y-%m-%d %H:%M:%S') - \$1" >> "\$RESET_LOG"
}

log "开始执行网络重置..."

[ -f "\$TRAFFIC_LOG" ] && rm -f "\$TRAFFIC_LOG" && log "已删除流量日志。"

iptables -P INPUT ACCEPT
iptables -P OUTPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -F
iptables -X
log "防火墙已重置。"

systemctl stop vnstat
vnstat --remove --force -i "\$INTERFACE"
vnstat --add -i "\$INTERFACE"
systemctl start vnstat
sleep 3
vnstat -i "\$INTERFACE" > /dev/null 2>&1
log "vnStat 已重置。"
echo "重置完成。"
RESETEOF
    chmod +x "$RESET_SCRIPT"
}

# ==========================================
# 生成 llcx 管理命令
# ==========================================

generate_llcx_command() {
    cat > "$LLCX_BIN" <<'LLCXEOF'
#!/bin/bash

CONFIG_FILE="/etc/llcx.conf"
CHECK_SCRIPT="/root/check_traffic.sh"
RESET_SCRIPT="/root/reset_network.sh"

RED='\033[91m'
GREEN='\033[92m'
YELLOW='\033[93m'
CYAN='\033[96m'
NC='\033[0m'

if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}错误：请使用 root 权限运行 (sudo llcx)${NC}"
    exit 1
fi

if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}错误：未找到配置文件，请先运行安装脚本。${NC}"
    exit 1
fi

source "$CONFIG_FILE"
INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n1)

regenerate_check_script() {
    source "$CONFIG_FILE"
    cat > "$CHECK_SCRIPT" <<INNEREOF
#!/bin/bash
export LC_ALL=C
source /etc/llcx.conf

LOG_FILE="/var/log/traffic_monitor.log"
INTERFACE="$INTERFACE"

log() {
    echo "\$(date '+%Y-%m-%d %H:%M:%S') - \$1" >> "\$LOG_FILE"
}

if [ "\$(id -u)" -ne 0 ]; then
    echo "错误：需要 root 权限"
    exit 1
fi

VNSTAT_RAW=\$(vnstat -i "\$INTERFACE" --oneline b 2>/dev/null)
TX_BYTES=\$(echo "\$VNSTAT_RAW" | cut -d ';' -f 10)

if [[ -z "\$TX_BYTES" || ! "\$TX_BYTES" =~ ^[0-9]+\$ ]]; then
    TX_BYTES=0
fi

TX_GB=\$(echo "scale=2; \$TX_BYTES / 1073741824" | bc 2>/dev/null)
if [[ -z "\$TX_GB" ]]; then
    TX_GB="0.00"
fi

echo "========================================"
echo " 网卡接口    : \$INTERFACE"
echo " 当前时间    : \$(date '+%Y-%m-%d %H:%M:%S')"
echo " 精确出站(TX): \$TX_BYTES Bytes"
echo " 换算出站(TX): \$TX_GB GB"
echo " 流量上限    : \$LIMIT GB"
echo " 放行端口    : \$ALLOWED_PORTS"
echo "========================================"

log "当前出站流量: \$TX_GB GB (限制: \$LIMIT GB)"

OVER=\$(echo "\$TX_GB >= \$LIMIT" | bc 2>/dev/null)
if [ "\$OVER" = "1" ]; then
    echo "状态: [警告] 流量已超限，正在应用防火墙规则..."
    log "警告：流量超出限制！执行封禁策略..."

    iptables -F
    iptables -X
    iptables -P INPUT DROP
    iptables -P FORWARD DROP
    iptables -P OUTPUT ACCEPT

    iptables -A INPUT -i lo -j ACCEPT
    iptables -A OUTPUT -o lo -j ACCEPT
    iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

    IFS=',' read -ra PORTS <<< "\$ALLOWED_PORTS"
    for port in "\${PORTS[@]}"; do
        port=\$(echo "\$port" | tr -d ' ')
        if [[ -n "\$port" ]]; then
            iptables -A INPUT -p tcp --dport "\$port" -j ACCEPT
            iptables -A INPUT -p udp --dport "\$port" -j ACCEPT
        fi
    done

    log "网络已限制（放行端口: \$ALLOWED_PORTS）。"
else
    echo "状态: [正常] 流量未超限。"
    log "流量正常。"
fi
INNEREOF
    chmod +x "$CHECK_SCRIPT"
}

show_status() {
    echo ""
    bash "$CHECK_SCRIPT"
}

set_limit() {
    source "$CONFIG_FILE"
    echo ""
    echo -e "当前流量上限: ${CYAN}${LIMIT} GB${NC}"
    read -p "请输入新的流量上限 (GB): " new_limit
    if [[ "$new_limit" =~ ^[0-9]+$ ]] && [ "$new_limit" -gt 0 ]; then
        LIMIT=$new_limit
        cat > "$CONFIG_FILE" <<CONFEOF
LIMIT=$LIMIT
ALLOWED_PORTS=$ALLOWED_PORTS
CONFEOF
        regenerate_check_script
        echo -e "${GREEN}流量上限已更新为: ${LIMIT} GB${NC}"
    else
        echo -e "${RED}输入无效，请输入正整数。${NC}"
    fi
}

set_ports() {
    source "$CONFIG_FILE"
    echo ""
    echo -e "当前超限放行端口: ${CYAN}${ALLOWED_PORTS}${NC}"
    echo -e "${YELLOW}提示: SSH(22) 始终放行，多个端口用逗号分隔${NC}"
    echo "示例: 22,80,443,8080"
    read -p "请输入新的放行端口: " new_ports
    if [[ -z "$new_ports" ]]; then
        echo -e "${RED}输入不能为空。${NC}"
        return
    fi
    if [[ ! ",$new_ports," == *",22,"* ]]; then
        new_ports="22,$new_ports"
    fi
    ALLOWED_PORTS=$new_ports
    cat > "$CONFIG_FILE" <<CONFEOF
LIMIT=$LIMIT
ALLOWED_PORTS=$ALLOWED_PORTS
CONFEOF
    regenerate_check_script
    echo -e "${GREEN}放行端口已更新为: ${ALLOWED_PORTS}${NC}"
}

manual_reset() {
    echo ""
    echo -e "${YELLOW}警告：将重置流量统计并解除所有防火墙限制！${NC}"
    read -p "确认重置? (y/n): " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        bash "$RESET_SCRIPT"
        echo -e "${GREEN}已重置。${NC}"
    else
        echo "已取消。"
    fi
}

show_config() {
    source "$CONFIG_FILE"
    echo ""
    echo "========================================"
    echo -e " 流量上限 : ${CYAN}${LIMIT} GB${NC}"
    echo -e " 放行端口 : ${CYAN}${ALLOWED_PORTS}${NC}"
    echo -e " 配置文件 : $CONFIG_FILE"
    echo -e " 监控脚本 : $CHECK_SCRIPT"
    echo -e " 重置脚本 : $RESET_SCRIPT"
    echo "========================================"
}

uninstall() {
    echo ""
    echo -e "${YELLOW}将卸载流量监控（删除脚本、配置、定时任务）${NC}"
    read -p "确认卸载? (y/n): " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        crontab -l 2>/dev/null | grep -v "check_traffic.sh" | grep -v "reset_network.sh" | crontab -
        rm -f "$CHECK_SCRIPT" "$RESET_SCRIPT" "$CONFIG_FILE" "$0"
        iptables -P INPUT ACCEPT
        iptables -P OUTPUT ACCEPT
        iptables -P FORWARD ACCEPT
        iptables -F
        iptables -X
        echo -e "${GREEN}已卸载，防火墙已恢复。${NC}"
        exit 0
    else
        echo "已取消。"
    fi
}

while true; do
    source "$CONFIG_FILE"
    echo ""
    echo -e "${CYAN}========== 流量监控管理 (llcx) ==========${NC}"
    echo "[1] 查看当前流量状态"
    echo "[2] 修改流量上限 (当前: ${LIMIT} GB)"
    echo "[3] 修改超限放行端口 (当前: ${ALLOWED_PORTS})"
    echo "[4] 查看当前配置"
    echo "[5] 手动重置流量和防火墙"
    echo "[6] 卸载流量监控"
    echo "[0] 退出"
    echo -e "${CYAN}=========================================${NC}"
    read -p "请选择: " choice

    case $choice in
        1) show_status ;;
        2) set_limit ;;
        3) set_ports ;;
        4) show_config ;;
        5) manual_reset ;;
        6) uninstall ;;
        0) echo "已退出。"; break ;;
        *) echo -e "${RED}输入无效${NC}" ;;
    esac
done
LLCXEOF
    chmod +x "$LLCX_BIN"
}

# ==========================================
# 安装流程
# ==========================================

do_install() {
    echo -e "${CYAN}--> 检测到网卡: $INTERFACE${NC}"

    # 换源
    echo "--> 换源为 MIT 镜像（非 CDN）..."
    SOURCE_FILE="/etc/apt/sources.list.d/debian.sources"
    cat > "$SOURCE_FILE" <<SRCEOF
Types: deb
URIs: http://debian.csail.mit.edu/debian
Suites: bookworm bookworm-updates bookworm-backports
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://debian.csail.mit.edu/debian-security
Suites: bookworm-security
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
SRCEOF

    # 安装依赖
    echo "--> 更新软件源并安装依赖..."
    rm -rf /var/lib/apt/lists/*
    apt-get update -y
    apt-get install -y vnstat bc

    # 配置 vnstat
    echo "--> 配置 vnStat..."
    vnstat --add -i "$INTERFACE" 2>/dev/null || true
    systemctl enable vnstat
    systemctl restart vnstat
    sleep 5

    # 初始化配置
    init_config

    # 生成脚本
    echo "--> 生成监控脚本..."
    generate_check_script
    generate_reset_script

    # 安装 llcx 命令
    echo "--> 安装 llcx 管理命令..."
    generate_llcx_command

    # 设置定时任务
    echo "--> 设置定时任务..."
    crontab -l > /tmp/cron_bk 2>/dev/null || true
    sed -i '/check_traffic.sh/d' /tmp/cron_bk
    sed -i '/reset_network.sh/d' /tmp/cron_bk
    echo "*/5 * * * * /root/check_traffic.sh" >> /tmp/cron_bk
    echo "0 0 1 * * /root/reset_network.sh" >> /tmp/cron_bk
    crontab /tmp/cron_bk
    rm -f /tmp/cron_bk

    echo ""
    echo -e "${GREEN}===========================================${NC}"
    echo -e "${GREEN} 安装完成！${NC}"
    echo -e "${GREEN}===========================================${NC}"
    echo " 管理命令: sudo llcx"
    echo " 查看流量: sudo bash /root/check_traffic.sh"
    echo " 默认上限: ${LIMIT} GB"
    echo " 放行端口: ${ALLOWED_PORTS}"
    echo -e "${GREEN}===========================================${NC}"
}

do_install
