# macvlan
macvlan生成
bash <(wget -qO- https://gh-proxy.com/https://raw.githubusercontent.com/czerov/macvlan/main/macvlan_perfect.sh)

## TTL=1 兼容修复

脚本会检测公网 IPv4 回包 TTL 是否为 1。出现该问题时，Docker `host` 模式可以联网，
但 `bridge` 模式的回包会因转发后 TTL 降为 0 而被内核丢弃。

检测到问题后，脚本会询问是否安装 `docker-bridge-ttl.service`。该服务只对从物理网卡
进入、属于 `ESTABLISHED,RELATED` 连接且 TTL=1 的包执行 `TTL --ttl-inc 1`，不会修改
Docker 默认路由或清空防火墙规则。

注意：上面的远程安装命令读取 GitHub 仓库中的脚本。只有将本地修改重新发布到
`czerov/macvlan` 后，远程命令才会包含本次修复。

## 还原网络并删除 macvlan

```bash
bash <(wget -qO- https://gh-proxy.com/https://raw.githubusercontent.com/czerov/macvlan/main/macvlan_perfect.sh) --restore
```

还原模式会先检查名为 `macvlan` 的 Docker 网络是否仍连接容器。存在连接时会显示容器
并停止操作，不会强制断开或删除容器。确认后只删除空闲的 `macvlan` 网络、`shim` 接口、
关联路由和 `/etc/systemd/system/macvlan-shim.service`。

TTL 兼容服务与 macvlan 相互独立，默认保留，避免 Docker `bridge` 容器恢复后再次断网。
脚本检测到该服务时会单独询问是否删除。
