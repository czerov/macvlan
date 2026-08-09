# macvlan
macvlan生成
bash <(wget -qO- https://ghproxy.net/https://raw.githubusercontent.com/czerov/macvlan/main/macvlan_perfect.sh)

## TTL=1 兼容修复

脚本会检测公网 IPv4 回包 TTL 是否为 1。出现该问题时，Docker `host` 模式可以联网，
但 `bridge` 模式的回包会因转发后 TTL 降为 0 而被内核丢弃。

检测到问题后，脚本会询问是否安装 `docker-bridge-ttl.service`。该服务只对从物理网卡
进入、属于 `ESTABLISHED,RELATED` 连接且 TTL=1 的包执行 `TTL --ttl-inc 1`，不会修改
Docker 默认路由或清空防火墙规则。

注意：上面的远程安装命令读取 GitHub 仓库中的脚本。只有将本地修改重新发布到
`czerov/macvlan` 后，远程命令才会包含本次修复。
