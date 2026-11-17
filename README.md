# server-toolkit

Xray / 3x-ui 服务器一键加固脚本。每个模块都可以单独运行、重复运行，改动前会备份，能撤销的都提供 `--undo`。

## 一键使用

```bash
curl -fsSL https://raw.githubusercontent.com/opxqo/server-toolkit/main/harden.sh -o /usr/local/sbin/harden && chmod +x /usr/local/sbin/harden && harden --all --allow-panel-from 你的IP,主控IP,业务面板IP
```

启用防火墙后，**另开一个 SSH 窗口**登录成功，再执行：

```bash
harden --confirm-firewall
```

180 秒内不确认，防火墙会自动恢复原状，防止把自己锁在外面。

不带参数运行 `harden` 会进入交互菜单，逐项询问。

## 模块

| 模块 | 做什么 | 撤销 |
|---|---|---|
| `--base` | 时间同步；自动安装安全更新（不自动重启） | — |
| `--bbr` | BBR + fq，TCP 缓冲区 64MB；OpenVZ/LXC 或旧内核自动跳过 | `--undo bbr` |
| `--ssh` | 检测到 root 公钥才关闭密码登录（通过 `sshd -t` 校验后才重载）；fail2ban 10 分钟失败 5 次封 1 小时 | `--undo ssh` |
| `--routing` | 通过本机 3x-ui API：屏蔽 `geoip:cn` / `geosite:cn` / 内网 / BT，删除「直连 cn」，屏蔽规则排在其它规则之前；其它规则与出站不动 | `--undo routing` |
| `--firewall` | ufw 默认拒绝入站；放行 SSH、本机节点端口、当前正在对外监听的端口；面板端口只允许 `--allow-panel-from` 的 IP | `--undo firewall` |
| `--audit` | 只读检查：非 443 端口、过于常见的 REALITY 伪装目标、serverNames 过多、面板公开、默认账号、面板无 HTTPS | — |

`--all` 依次执行以上全部模块；没有给 `--allow-panel-from` 时跳过防火墙。

## 注意

- **副节点**：`--allow-panel-from` 里必须包含主控的 IP，否则主控连不上副节点。
- `routing` 使用名为 `server-toolkit` 的临时 Token，结束时自动删除，不影响其它 Token。
- 修改端口、伪装目标会改变用户的订阅链接，本脚本只提示、不自动修改。
- 设置屏蔽回国流量后，用户使用**全局模式**时国内网站会打不开，切回规则模式即可。

## 测试

```bash
bash tests/routing-3xui.sh          # 在真实 3x-ui 容器里测试 routing
bash tests/system.sh debian:12      # base / ssh / firewall（需要 Docker）
bash tests/system.sh ubuntu:24.04
```

## License

MIT
