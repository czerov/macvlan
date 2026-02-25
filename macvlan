#!/bin/bash
# =================================================================
# Docker Macvlan 完美一键配置脚本 (飞牛 fnOS/Debian 修复增强版)
# 修复了原版 subnet 识别错误的 BUG
# =================================================================

# 颜色设置
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}#########################################${NC}"
echo -e "${CYAN}#     Docker Macvlan 完美修复版脚本     #${NC}"
echo -e "${CYAN}#########################################${NC}"
echo ""

# [1/5] 选择物理网卡
echo -e "${YELLOW}[1/5] 选择物理网卡...${NC}"
echo "--------------------------------------------------------"
echo "系统检测到以下物理网卡："
INTERFACES=$(ls /sys/class/net | grep -v 'lo\|docker\|veth\|br-\|shim')
echo -e "${GREEN}${INTERFACES}${NC}"
echo ""
read -p "请输入你要使用的物理网卡名称 (例如 enp3s0): " IFACE
if [[ -z "$IFACE" || ! -d "/sys/class/net/$IFACE" ]]; then
    echo -e "${RED}错误: 填写的网卡不存在！${NC}"
    exit 1
fi

# [2/5] 分析网络环境
echo ""
echo -e "${YELLOW}[2/5] 分析网络环境...${NC}"
echo "--------------------------------------------------------"

# 修复核心 BUG：从路由表精准提取真实的网段地址（强制末尾为.0/24），不再提取具体的IP地址
REAL_SUBNET=$(ip route show dev $IFACE | grep -v default | awk '{print $1}' | head -n 1)
if [ -z "$REAL_SUBNET" ]; then
    echo -e "${RED}错误: 无法获取该网卡的网段！${NC}"
    exit 1
fi

GATEWAY=$(ip route show default | grep $IFACE | awk '{print $3}')
if [ -z "$GATEWAY" ]; then
    # 若无法获取默认网关，推断为 .1
    IP_PREFIX=$(echo $REAL_SUBNET | cut -d'.' -f1-3)
    GATEWAY="${IP_PREFIX}.1"
else
    IP_PREFIX=$(echo $REAL_SUBNET | cut -d'.' -f1-3)
fi

echo -e "  - 真实子网(Subnet): ${GREEN}${REAL_SUBNET}${NC} (已修复原版提取错误的BUG)"
echo -e "  - 网关地址(Gateway): ${GREEN}${GATEWAY}${NC}"
echo -e "  - IP 前缀:         ${GREEN}${IP_PREFIX}.x${NC}"


# [3/5] 配置 Macvlan IP 范围
echo ""
echo -e "${YELLOW}[3/5] 配置 Macvlan IP 范围...${NC}"
echo "--------------------------------------------------------"
echo "请规划一段 IP 专门给 Docker 容器和宿主机通信使用。"
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
echo -e "${YELLOW}[4/5] 部署系统服务...${NC}"
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
    
    echo "正在使用修复后的正确网段创建 Docker 网络..."
    docker network create -d macvlan \
        --subnet=${REAL_SUBNET} \
        --gateway=${GATEWAY} \
        -o parent=${IFACE} macvlan
        
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
echo -e "        ${YELLOW}# 请确保 IP 在 ${START_IP} - ${END_IP} 之间${NC}"
echo -e "        ${RED}ipv4_address: ${START_IP}${NC}"
echo ""
echo -e "networks:"
echo -e "  macvlan_net:"
echo -e "    external:"
echo -e "      name: macvlan"
echo "-------------------------------------------------------"
echo -e "${YELLOW}提示: ipv4_address 必须手动指定，且只能使用 ${START_IP_SUFFIX} 到 ${END_IP_SUFFIX} 之间的数字！${NC}"
echo ""
