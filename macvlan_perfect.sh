#!/bin/bash
# =================================================================
# Docker Macvlan 配置脚本 (智能双栈 + 宿主机互通 + TTL兼容)
# =================================================================

# 颜色设置
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}错误: 请使用 root 用户运行此脚本。${NC}"
    exit 1
fi

echo -e "${CYAN}#########################################${NC}"
echo -e "${CYAN}#  Docker Macvlan 智能双栈终极修复版    #${NC}"
echo -e "${CYAN}#########################################${NC}"
echo ""

# [1/6] 智能匹配网关与物理网卡
echo -e "${YELLOW}[1/6] 智能匹配网关与物理网卡...${NC}"
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

# [2/6] 分析网络环境 (包含 IPv4 与 IPv6)
echo ""
echo -e "${YELLOW}[2/6] 分析网络环境...${NC}"
echo "--------------------------------------------------------"

REAL_SUBNET=$(ip -4 route show dev $IFACE | grep -v default | awk '{print $1}' | head -n 1)
if [ -z "$REAL_SUBNET" ]; then
    echo -e "${RED}错误: 无法获取该网卡的 IPv4 网段！${NC}"
    exit 1
fi
IP_PREFIX=$(echo $REAL_SUBNET | cut -d'.' -f1-3)

echo -e "  - IPv4 子网(Subnet): ${GREEN}${REAL_SUBNET}${NC}"
echo -e "  - IPv4 网关(Gateway): ${GREEN}${GATEWAY}${NC}"
echo -e "  - IPv4 前缀:          ${GREEN}${IP_PREFIX}.x${NC}"

echo "--------------------------------------------------------"
echo "正在检测 IPv6 环境..."
IPV6_SUBNET=$(ip -6 route show dev $IFACE | grep -v default | grep -vwE '^fe80' | grep '/' | awk '{print $1}' | head -n 1)

if [ -n "$IPV6_SUBNET" ]; then
    echo -e "  - 检测到 IPv6 网段 (CIDR): ${GREEN}${IPV6_SUBNET}${NC}"
    IPV6_GATEWAY=$(ip -6 route show default | grep $IFACE | awk '{print $3}' | head -n 1)
    
    if [[ "$IPV6_GATEWAY" == fe80* ]]; then
        echo -e "  - 检测到 IPv6 网关: ${YELLOW}${IPV6_GATEWAY}${NC} (本地链路地址)"
        echo -e "  - ${CYAN}提示: Docker 对 fe80 存在验证 Bug，将跳过网关绑定，交由 SLAAC 自动分配路由${NC}"
        IPV6_GATEWAY="" 
    elif [ -n "$IPV6_GATEWAY" ]; then
        echo -e "  - 检测到 IPv6 网关: ${GREEN}${IPV6_GATEWAY}${NC}"
    else
        echo -e "  - ${YELLOW}未检测到默认 IPv6 网关，交由 SLAAC 自动路由${NC}"
    fi
    ENABLE_IPV6=true
else
    echo -e "  - ${YELLOW}未检测到可用 IPv6 CIDR 网段，将降级使用纯 IPv4 模式。${NC}"
    ENABLE_IPV6=false
fi

# [3/6] 配置 Macvlan IP 范围
echo ""
echo -e "${YELLOW}[3/6] 配置 Macvlan IPv4 范围...${NC}"
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

# [4/6] 部署系统服务 (增加幂等性)
echo ""
echo -e "${YELLOW}[4/6] 部署宿主机互通服务...${NC}"
ip link del shim >/dev/null 2>&1

cat > /etc/systemd/system/macvlan-shim.service <<EOF
[Unit]
Description=Macvlan Shim Service for Host-to-Container Communication
Wants=network-online.target
After=network-online.target

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

cat >> /etc/systemd/system/macvlan-shim.service <<EOF

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable macvlan-shim.service >/dev/null 2>&1
systemctl restart macvlan-shim.service

if ip link show shim >/dev/null 2>&1; then
    echo -e "${GREEN}√ Shim 服务启动成功！宿主机已连通 macvlan 接口。${NC}"
else
    echo -e "${RED}x Shim 接口未发现，请检查系统日志。${NC}"
fi

# [5/6] Docker 网络设置
echo ""
echo -e "${YELLOW}[5/6] Docker 网络设置...${NC}"
read -p "是否自动创建 Docker 网络？(y/n) [默认: y]: " CREATE_DOCKER
CREATE_DOCKER=${CREATE_DOCKER:-y}

if [[ "$CREATE_DOCKER" == "y" || "$CREATE_DOCKER" == "Y" ]]; then
    docker network rm macvlan >/dev/null 2>&1
    
    if [ "$ENABLE_IPV6" = true ]; then
        echo -e "检测到有效 IPv6 CIDR，启用 ${GREEN}IPv4/IPv6 双栈模式${NC} 构建 Macvlan..."
        IPV6_OPTS="--ipv6 --subnet=${IPV6_SUBNET}"
        [ -n "$IPV6_GATEWAY" ] && IPV6_OPTS="$IPV6_OPTS --gateway=${IPV6_GATEWAY}"
        
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
        echo -e "${RED}x Docker 网络创建失败！${NC}"
    fi
fi

# [6/6] 可选修复：上游将公网回包 TTL 设置为 1 时，Docker bridge 无法转发
echo ""
echo -e "${YELLOW}[6/6] 检测 Docker bridge 的 TTL=1 兼容需求...${NC}"
echo "--------------------------------------------------------"

IPTABLES_BIN=$(command -v iptables 2>/dev/null)
TTL_FIX_RECOMMENDED=false
TTL_FIX_REASON=""
PUBLIC_REPLY_TTL=""

if [ -n "$IPTABLES_BIN" ]; then
    TTL_RULE_ARGS=(-i "$IFACE" -m conntrack --ctstate ESTABLISHED,RELATED -m ttl --ttl-eq 1 -j TTL --ttl-inc 1)

    if "$IPTABLES_BIN" -t mangle -C PREROUTING "${TTL_RULE_ARGS[@]}" >/dev/null 2>&1; then
        TTL_FIX_RECOMMENDED=true
        TTL_FIX_REASON="检测到当前系统已有相同的临时 TTL 修复规则"
    elif command -v ping >/dev/null 2>&1; then
        PUBLIC_REPLY_TTL=$(ping -4 -c 1 -W 2 223.5.5.5 2>/dev/null | sed -nE 's/.*[Tt][Tt][Ll]=([0-9]+).*/\1/p' | head -n 1)
        if [ "$PUBLIC_REPLY_TTL" = "1" ]; then
            TTL_FIX_RECOMMENDED=true
            TTL_FIX_REASON="检测到公网 IPv4 回包 TTL=1；该回包经过 bridge 转发时会降为 0 并被内核丢弃"
        fi
    fi
fi

if [ "$TTL_FIX_RECOMMENDED" = true ]; then
    echo -e "  - ${RED}${TTL_FIX_REASON}${NC}"
    read -p "是否安装持久化 Docker bridge TTL 兼容服务？(y/n) [默认: y]: " INSTALL_TTL_FIX
    INSTALL_TTL_FIX=${INSTALL_TTL_FIX:-y}
else
    if [ -n "$PUBLIC_REPLY_TTL" ]; then
        echo -e "  - 当前检测到的公网回包 TTL: ${GREEN}${PUBLIC_REPLY_TTL}${NC}"
    else
        echo -e "  - ${YELLOW}未能确认公网回包 TTL，不会默认修改防火墙。${NC}"
    fi
    read -p "是否仍要安装 Docker bridge TTL 兼容服务？(y/n) [默认: n]: " INSTALL_TTL_FIX
    INSTALL_TTL_FIX=${INSTALL_TTL_FIX:-n}
fi

if [[ "$INSTALL_TTL_FIX" == "y" || "$INSTALL_TTL_FIX" == "Y" ]]; then
    if [ -z "$IPTABLES_BIN" ]; then
        echo -e "${RED}x 未找到 iptables，无法安装 TTL 兼容服务。${NC}"
    elif ! "$IPTABLES_BIN" -t mangle -j TTL -h >/dev/null 2>&1; then
        echo -e "${RED}x 当前内核或 iptables 不支持 TTL target，未修改防火墙。${NC}"
    else
        cat > /etc/systemd/system/docker-bridge-ttl.service <<EOF
[Unit]
Description=Docker Bridge TTL=1 Compatibility Service
Wants=network-online.target
After=network-online.target docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c '${IPTABLES_BIN} -t mangle -C PREROUTING -i ${IFACE} -m conntrack --ctstate ESTABLISHED,RELATED -m ttl --ttl-eq 1 -j TTL --ttl-inc 1 >/dev/null 2>&1 || ${IPTABLES_BIN} -t mangle -I PREROUTING 1 -i ${IFACE} -m conntrack --ctstate ESTABLISHED,RELATED -m ttl --ttl-eq 1 -j TTL --ttl-inc 1'
ExecStop=/bin/sh -c '${IPTABLES_BIN} -t mangle -C PREROUTING -i ${IFACE} -m conntrack --ctstate ESTABLISHED,RELATED -m ttl --ttl-eq 1 -j TTL --ttl-inc 1 >/dev/null 2>&1 && ${IPTABLES_BIN} -t mangle -D PREROUTING -i ${IFACE} -m conntrack --ctstate ESTABLISHED,RELATED -m ttl --ttl-eq 1 -j TTL --ttl-inc 1 || true'

[Install]
WantedBy=multi-user.target
EOF

        systemctl daemon-reload
        if systemctl enable docker-bridge-ttl.service >/dev/null 2>&1 && \
           systemctl restart docker-bridge-ttl.service && \
           "$IPTABLES_BIN" -t mangle -C PREROUTING "${TTL_RULE_ARGS[@]}" >/dev/null 2>&1; then
            echo -e "${GREEN}√ Docker bridge TTL 兼容服务已安装并生效。${NC}"
        else
            echo -e "${RED}x TTL 兼容服务启动失败，请运行 systemctl status docker-bridge-ttl.service 查看日志。${NC}"
        fi
    fi
else
    echo -e "  - ${CYAN}未安装 TTL 兼容服务，现有防火墙规则保持不变。${NC}"
fi

# =================================================================
# 新增：完美一键 Compose 解说输出
# =================================================================
echo ""
echo -e "${CYAN}=======================================================${NC}"
echo -e "${YELLOW}请在你的 ${GREEN}docker-compose.yml${YELLOW} 文件中，复制粘贴以下内容：${NC}"
echo -e "${RED}务必复制以下部分，否则无法使用！${NC}"
echo -e "${CYAN}-------------------------------------------------------${NC}"

# 使用 cat 直接输出 YAML 内容，并嵌入变量
cat <<EOF
services:
  your_service_name:
    image: your_image:latest
    container_name: macvlan_test
    restart: always
    networks:
      macvlan_net:
        # 请确保 IP 在 ${START_IP} - ${END_IP} 之间
        ipv4_address: ${START_IP}

networks:
  macvlan_net:
    external:
      name: macvlan
EOF

echo -e "${CYAN}-------------------------------------------------------${NC}"
echo -e "${YELLOW}提示：${RED}ipv4_address${YELLOW} 必须手动指定，且只能使用 ${GREEN}${START_IP_SUFFIX}${YELLOW} 到 ${GREEN}${END_IP_SUFFIX}${YELLOW} 之间的数字！${NC}"
echo -e "${CYAN}=======================================================${NC}"
echo -e "${GREEN}                全部配置完美完成！                     ${NC}"
echo -e "${CYAN}=======================================================${NC}"
