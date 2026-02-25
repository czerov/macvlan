#!/bin/bash
# =================================================================
# Docker Macvlan 完美一键配置脚本 (fnOS/Debian 终极双栈版)
# 1. 修复了原版 subnet 识别错误的 BUG
# 2. 增加了多本地 IPv6 检测，支持创建 IPv4/IPv6 双栈 Macvlan
# =================================================================

# 颜色设置
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}#########################################${NC}"
echo -e "${CYAN}#  Docker Macvlan 终极双栈修复版脚本    #${NC}"
echo -e "${CYAN}#########################################${NC}"
echo ""

# [1/5] 选择物理网卡
echo -e "${YELLOW}[1/5] 选择物理网卡...${NC}"
echo "--------------------------------------------------------"
echo "系统检测到以下物理网卡："
INTERFACES=$(ls /sys/class/net | grep -v 'lo\|docker\|veth\|br-\|shim')
echo -e "${GREEN}${INTERFACES}${NC}"
echo ""
read -p "请输入你要使用的物理网卡名称 (例如 enp3s0 或 eth0): " IFACE
if [[ -z "$IFACE" || ! -d "/sys/class/net/$IFACE" ]]; then
    echo -e "${RED}错误: 填写的网卡不存在！${NC}"
    exit 1
fi

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

GATEWAY=$(ip -4 route show default | grep $IFACE | awk '{print $3}' | head -n 1)
if [ -z "$GATEWAY" ]; then
    IP_PREFIX=$(echo $REAL_SUBNET | cut -d'.' -f1-3)
    GATEWAY="${IP_PREFIX}.1"
else
    IP_PREFIX=$(echo $REAL_SUBNET | cut -d'.' -f1-3)
fi

echo -e "  - IPv4 子网(Subnet): ${GREEN}${REAL_SUBNET}${NC} (已修复BUG)"
echo -e "  - IPv4 网关(Gateway): ${GREEN}${GATEWAY}${NC}"
echo -e "  - IPv4 前缀:         ${GREEN}${IP_PREFIX}.x${NC}"

# --- IPv6 检测 ---
echo "--------------------------------------------------------"
echo "正在检测 IPv6 环境..."
# 提取非 fe80 的真实 IPv6 网段
IPV6_SUBNET=$(ip -6 route show dev $IFACE | grep -v default | grep -vwE '^fe80' | awk '{print $1}' | head -n 1)

if [ -n "$IPV6_SUBNET" ]; then
    echo -e "  - 检测到 IPv6 网段: ${GREEN}${IPV6_SUBNET}${NC}"
    # 尝试提取 IPv6 网关 (如果有)
    IPV6_GATEWAY=$(ip -6 route show default | grep $IFACE | awk '{print $3}' | head -n 1)
    if [ -n "$IPV6_GATEWAY" ]; then
        echo -e "  - 检测到 IPv6 网关: ${GREEN}${IPV6_GATEWAY}${NC}"
    else
        echo -e "  - ${YELLOW}未检测到默认 IPv6 网关，Docker 网络将依赖 SLAAC 自动路由${NC}"
    fi
    ENABLE_IPV6=true
else
    echo -e "  - ${YELLOW}未检测到可用 IPv6 网段 (仅有 fe80 本地链路地址或无 IPv6)。${NC}"
    ENABLE_IPV6=false
fi

# [3/5] 配置 Macvlan IP 范围
echo ""
echo -e "${YELLOW}[3/5] 配置 Macvlan IPv4 范围...${NC}"
echo "--------------------------------------------------------"
echo "请规划一段 IPv4 专门给 Docker 容器和宿主机通信使用。"
echo "确保这段 IP 没有被家中其他设备占用！"
echo ""

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

# [4/5] 部署系统服务
echo ""
echo -e "${YELLOW}[4/5] 部署宿主机互通服务...${NC}"
echo "正在配置 Shim 接口实现宿主机与 Macvlan 容器互通..."

# 删除可能存在的残留
ip link del shim >/dev/null 2>&1

# 创建系统服务文件
cat > /etc/systemd/system/macvlan-shim.service <<EOF
[Unit]
Description=Macvlan Shim Service for Host-to-Container Communication
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=-/sbin/ip link del shim
ExecStart=/sbin/ip link add shim link ${IFACE} type macvlan mode bridge
ExecStart=/sbin/ip addr add ${SHIM_IP}/32 dev shim
ExecStart=/sbin/ip link set shim up
EOF

# 动态追加容器路由记录到服务中
for i in $(seq $START_IP_SUFFIX $END_IP_SUFFIX); do
    echo "ExecStart=/sbin/ip route add ${IP_PREFIX}.$i dev shim" >> /etc/systemd/system/macvlan-shim.service
done

# 启动并设置开机自启
systemctl daemon-reload
systemctl enable macvlan-shim.service >/dev/null 2>&1
systemctl restart macvlan-shim.service

if ip link show shim >/dev/null 2>&1; then
    echo -e "${GREEN}√ Shim 服务启动成功！宿主机已连通 macvlan 接口。${NC}"
else
    echo -e "${RED}x Shim 服务启动失败，请检查网络配置。${NC}"
fi

# [5/5] Docker 网络设置
echo ""
echo -e "${YELLOW}[5/5] Docker 网络设置...${NC}"
read -p "是否自动创建 Docker 网络？(y/n) [默认: y]: " CREATE_DOCKER
CREATE_DOCKER=${CREATE_DOCKER:-y}

if [[ "$CREATE_DOCKER" == "y" || "$CREATE_DOCKER" == "Y" ]]; then
    # 清理旧的错误网络
    docker network rm macvlan >/dev/null 2>&1
    
    if [ "$ENABLE_IPV6" = true ]; then
        echo -e "检测到 IPv6，启用 ${GREEN}IPv4/IPv6 双栈模式${NC} 构建 Macvlan..."
        
        # 组装 IPv6 参数
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
        echo -e "${RED}x Docker 网络创建失败！可能是 Docker 未运行或网卡名称有误。${NC}"
    fi
else
    echo "已跳过 Docker 网络创建。"
fi

echo ""
echo -e "${CYAN}=======================================================${NC}"
echo -e "${GREEN}                   全部配置完美完成！                  ${NC}"
echo -e "${CYAN}=======================================================${NC}"
echo ""
echo "请在你的 docker-compose.yml 文件中，复制粘贴以下内容："
echo "-------------------------------------------------------"
echo -e "services:"
echo -e "  your_service_name:"
echo -e "    image: your_image:latest"
echo -e "    container_name: macvlan_test"
echo -e "    restart: always"
echo -e "    networks:"
echo -e "      macvlan_net:"
echo -e "        ${YELLOW}# 请确保 IPv4 在 ${START_IP} - ${END_IP} 之间${NC}"
echo -e "        ${RED}ipv4_address: ${START_IP}${NC}"
if [ "$ENABLE_IPV6" = true ]; then
echo -e "        ${YELLOW}# IPv6 地址将由 Docker 自动分配，或手动指定 ipv6_address${NC}"
fi
echo ""
echo -e "networks:"
echo -e "  macvlan_net:"
echo -e "    external:"
echo -e "      name: macvlan"
echo "-------------------------------------------------------"
echo -e "${YELLOW}提示: ipv4_address 必须手动指定，且只能使用 ${START_IP_SUFFIX} 到 ${END_IP_SUFFIX} 之间的数字！${NC}"
echo ""
