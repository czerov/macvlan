#!/bin/bash
# =================================================================
# Docker Macvlan 完美一键配置脚本 (智能双栈 + 幂等防错版)
# 1. 修复了原版 subnet 识别错误的 BUG
# 2. 增加了多本地 IPv6 检测，强制校验 CIDR 格式防止 Docker 报错
# 3. 智能匹配网卡：通过网关顺藤摸瓜寻找对应网卡
# 4. 服务幂等性：解决重复运行脚本导致 Systemd 报错的问题
# =================================================================

# 颜色设置
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}#########################################${NC}"
echo -e "${CYAN}#  Docker Macvlan 智能双栈终极修复版    #${NC}"
echo -e "${CYAN}#########################################${NC}"
echo ""

# [1/5] 智能匹配网关与物理网卡
echo -e "${YELLOW}[1/5] 智能匹配网关与物理网卡...${NC}"
echo "--------------------------------------------------------"
DEFAULT_GW=$(ip -4 route show default | awk '{print $3}' | head -n 1)

read -p "请输入你家路由器的网关 IP (例如 192.168.6.1) [默认: ${DEFAULT_GW}]: " INPUT_GW
INPUT_GW=${INPUT_GW:-$DEFAULT_GW}

if [[ -z "$INPUT_GW" ]]; then
    echo -e "${RED}错误: 网关 IP 不能为空！${NC}"
    exit 1
fi

echo "正在通过网关 IP ($INPUT_GW) 顺藤摸瓜寻找对应网卡..."
IFACE=$(ip route get "$INPUT_GW" | grep dev | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')

if [[ -z "$IFACE" || ! -d "/sys/class/net/$IFACE" ]]; then
    echo -e "${RED}错误: 无法根据网关 $INPUT_GW 找到对应的物理网卡！${NC}"
    exit 1
fi

echo -e "  - 成功匹配到物理网卡: ${GREEN}${IFACE}${NC}"
GATEWAY=$INPUT_GW

# [2/5] 分析网络环境 (包含 IPv4 与 IPv6)
echo ""
echo -e "${YELLOW}[2/5] 分析网络环境...${NC}"
echo "--------------------------------------------------------"

# --- IPv4 检测 ---
REAL_SUBNET=$(ip -4 route show dev $IFACE | grep -v default | awk '{print $1}' | head -n 1)
if [ -z "$REAL_SUBNET" ]; then
    echo -e "${RED}错误: 无法获取该网卡的 IPv4 网段！${NC}"
    exit 1
fi
IP_PREFIX=$(echo $REAL_SUBNET | cut -d'.' -f1-3)

echo -e "  - IPv4 子网(Subnet): ${GREEN}${REAL_SUBNET}${NC}"
echo -e "  - IPv4 网关(Gateway): ${GREEN}${GATEWAY}${NC}"
echo -e "  - IPv4 前缀:         ${GREEN}${IP_PREFIX}.x${NC}"

# --- IPv6 检测 (增加 CIDR 严格过滤) ---
echo "--------------------------------------------------------"
echo "正在检测 IPv6 环境..."
# 提取非 fe80 的真实 IPv6 网段，强制要求包含 '/' 以确保是 CIDR 格式
IPV6_SUBNET=$(ip -6 route show dev $IFACE | grep -v default | grep -vwE '^fe80' | grep '/' | awk '{print $1}' | head -n 1)

if [ -n "$IPV6_SUBNET" ]; then
    echo -e "  - 检测到 IPv6 网段 (CIDR): ${GREEN}${IPV6_SUBNET}${NC}"
    IPV6_GATEWAY=$(ip -6 route show default | grep $IFACE | awk '{print $3}' | head -n 1)
    if [ -n "$IPV6_GATEWAY" ]; then
        echo -e "  - 检测到 IPv6 网关: ${GREEN}${IPV6_GATEWAY}${NC}"
    else
        echo -e "  - ${YELLOW}未检测到默认 IPv6 网关，Docker 网络将依赖 SLAAC 自动路由${NC}"
    fi
    ENABLE_IPV6=true
else
    echo -e "  - ${YELLOW}未检测到可用 IPv6 CIDR 网段，将降级使用纯 IPv4 模式。${NC}"
    ENABLE_IPV6=false
fi

# [3/5] 配置 Macvlan IP 范围
echo ""
echo -e "${YELLOW}[3/5] 配置 Macvlan IPv4 范围...${NC}"
echo "--------------------------------------------------------"
read -p "请输入宿主机通信专用 IP (最后一位数字) [推荐: 220]: " SHIM_IP_SUFFIX
SHIM_IP_SUFFIX=${SHIM_IP_SUFFIX:-220}

read -p "容器起始 IP (最后一位数字) [推荐: 221]: " START_IP_SUFFIX
START_IP_SUFFIX=${START_IP_SUFFIX:-221}

read -p "容器结束 IP (最后一位数字) [推荐: 230]: " END_IP_SUFFIX
END_IP_SUFFIX=${END_IP_SUFFIX:-230}

SHIM_IP="${IP_PREFIX}.${SHIM_IP_SUFFIX}"
START_IP="${IP_PREFIX}.${START_IP_SUFFIX}"
END_IP="${IP_PREFIX}.${END_IP_SUFFIX}"

echo ""
echo -e "将在宿主机添加路由: ${GREEN}${START_IP} -> ${END_IP}${NC}"
echo -e "宿主机通信 IP (Shim): ${GREEN}${SHIM_IP}${NC}"
echo "--------------------------------------------------------"

# [4/5] 部署系统服务 (增加幂等性)
echo ""
echo -e "${YELLOW}[4/5] 部署宿主机互通服务...${NC}"
echo "正在配置 Shim 接口实现宿主机与 Macvlan 容器互通..."

ip link del shim >/dev/null 2>&1

# 核心优化：在 ExecStart 前加 '-'，忽略已存在导致的报错
cat > /etc/systemd/system/macvlan-shim.service <<EOF
[Unit]
Description=Macvlan Shim Service for Host-to-Container Communication
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=-/sbin/ip link del shim
ExecStart=-/sbin/ip link add shim link ${IFACE} type macvlan mode bridge
ExecStart=-/sbin/ip addr add ${SHIM_IP}/32 dev shim
ExecStart=-/sbin/ip link set shim up
EOF

for i in $(seq $START_IP_SUFFIX $END_IP_SUFFIX); do
    echo "ExecStart=-/sbin/ip route add ${IP_PREFIX}.$i dev shim" >> /etc/systemd/system/macvlan-shim.service
done

systemctl daemon-reload
systemctl enable macvlan-shim.service >/dev/null 2>&1
systemctl restart macvlan-shim.service

if ip link show shim >/dev/null 2>&1; then
    echo -e "${GREEN}√ Shim 服务启动成功！宿主机已连通 macvlan 接口。${NC}"
else
    echo -e "${RED}x Shim 接口未发现，请检查系统日志。${NC}"
fi

# [5/5] Docker 网络设置
echo ""
echo -e "${YELLOW}[5/5] Docker 网络设置...${NC}"
read -p "是否自动创建 Docker 网络？(y/n) [默认: y]: " CREATE_DOCKER
CREATE_DOCKER=${CREATE_DOCKER:-y}

if [[ "$CREATE_DOCKER" == "y" || "$CREATE_DOCKER" == "Y" ]]; then
    docker network rm macvlan >/dev/null 2>&1
    
    if [ "$ENABLE_IPV6" = true ]; then
        echo -e "检测到有效 IPv6 CIDR，启用 ${GREEN}IPv4/IPv6 双栈模式${NC} 构建 Macvlan..."
        
        IPV6_OPTS="--ipv6 --subnet=${IPV6_SUBNET}"
        if [ -n "$IPV6_GATEWAY" ]; then
            IPV6_OPTS="$IPV6_OPTS --gateway=${IPV6_GATEWAY}"
        fi
        
        docker network create -d macvlan \
            --subnet=${REAL_SUBNET} \
            --gateway=${GATEWAY} \
            ${IPV6_OPTS} \
            -o parent=${IFACE} macvlan
            
    else
        echo -e "使用 ${YELLOW}纯 IPv4 模式${NC} 构建 Macvlan..."
        docker network create -d macvlan \
            --subnet=${REAL_SUBNET} \
            --gateway=${GATEWAY} \
            -o parent=${IFACE} macvlan
    fi
        
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}√ Docker 网络 (macvlan) 创建成功！${NC}"
    else
        echo -e "${RED}x Docker 网络创建失败！可能是配置冲突或 Docker 异常。${NC}"
    fi
else
    echo "已跳过 Docker 网络创建。"
fi

echo ""
echo -e "${CYAN}=======================================================${NC}"
echo -e "${GREEN}                   全部配置完美完成！                  ${NC}"
echo -e "${CYAN}=======================================================${NC}"
echo ""
