# JD Argo + Hysteria2 节点安装脚本

一个面向 Ubuntu / Debian 的交互式脚本，使用 systemd 管理 Argo 临时隧道（VLESS + WebSocket）和 Hysteria2。支持 x86_64 与 ARM64。

## 一键安装

仓库发布后运行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/viperoooiii/JD-Argo-hy2/main/run.sh)
```

以 `root` 身份运行。菜单选项：

```text
1  安装 Argo 临时隧道
2  安装 Hysteria2
3  安装全部
0  退出
```

安装后执行 `jd` 查看当前节点链接，执行 `jdxz` 完全卸载；普通用户分别执行 `sudo jd` 和 `sudo jdxz`。`jd` 会读取当前 cloudflared 进程的日志，显示最新的临时隧道域名。服务与配置位于 `/opt/jd-node`，systemd 单元分别为 `jd-xray`、`jd-argo`、`jd-hy2`。

已通过旧版脚本安装的 VPS，重新运行上方一键命令并选择原来安装的选项，即可添加 `jdxz` 命令；运行中的节点及其链接会保留。`jdxz` 只清理由本仓库创建的服务和文件，不会卸载其他脚本的节点。系统历史 journal 日志由系统管理，不随 `jdxz` 清除。

若使用早期版本通过 `bash <(curl …)` 安装后，`jd` 报错或没有输出，可直接修复管理脚本：

```bash
sudo curl -fsSL https://raw.githubusercontent.com/viperoooiii/JD-Argo-hy2/main/run.sh -o /opt/jd-node/run.sh
sudo chmod 755 /opt/jd-node/run.sh
sudo jd
```

## 注意

- Argo 使用 Cloudflare Quick Tunnel，无需域名或 Tunnel Token。它适合临时使用；隧道进程重新建立后域名会变化，届时重新运行 `jd` 并更新客户端链接。Cloudflare 不保证 Quick Tunnel 的可用性。
- Hysteria2 默认使用 UDP 443，可在安装时选择其他端口。若 VPS 提供商有额外防火墙，需在其管理面板放行所选 UDP 端口。脚本仅在 UFW 已启用时自动添加规则。
- Hysteria2 使用自签证书，节点链接提供 `pinSHA256` 指纹校验。客户端需支持 Hysteria2 与该参数。
- 脚本会从 Xray、Cloudflare 和 Hysteria 的官方发布地址下载可执行文件。运行远程脚本前可先阅读 `run.sh`。
- 不会修改或删除其他脚本创建的服务。重复选择已运行的节点时会保留原节点信息。

## 排查

```bash
systemctl status jd-xray jd-argo jd-hy2
journalctl -u jd-argo -n 50 --no-pager
journalctl -u jd-hy2 -n 50 --no-pager
```

项目设计参考 [fireflies1145/jiaoben](https://github.com/fireflies1145/jiaoben)。
