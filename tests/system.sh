#!/usr/bin/env bash
# shellcheck disable=SC2034  # 变量在 check 的 eval 字符串里使用
# 在 Debian / Ubuntu 容器里测试 base、ssh、firewall（含自动回滚）。
# 用法：bash tests/system.sh [镜像]   默认 debian:12；需要 Docker（firewall 用 --privileged）
set -Eeuo pipefail
IMAGE=${1:-debian:12}
NAME="st-system-test"
ROOT=$(cd "$(dirname "$0")/.." && pwd)

cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup
docker run -d --privileged --name "$NAME" -v "$ROOT:/toolkit:ro" "$IMAGE" sleep infinity >/dev/null
run() { docker exec -e STATE_DIR=/var/lib/st -e ROLLBACK_SECONDS=8 "$NAME" bash -c "$1"; }
run 'export DEBIAN_FRONTEND=noninteractive; apt-get -qq update && apt-get -qq install -y openssh-server python3 iproute2 >/dev/null && ssh-keygen -A >/dev/null && mkdir -p /run/sshd'

fail=0
check() { if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1"; fail=1; fi; }

echo "== [$IMAGE] base"
run 'bash /toolkit/harden.sh --base --yes' >/dev/null 2>&1 || true
check "已装 unattended-upgrades"      'run "dpkg -s unattended-upgrades >/dev/null 2>&1"'
check "已开启自动安全更新"            'run "grep -q Unattended-Upgrade\ \\\"1\\\" /etc/apt/apt.conf.d/20auto-upgrades"'

echo "== [$IMAGE] ssh（没有公钥）"
out=$(run 'bash /toolkit/harden.sh --ssh --yes' 2>&1 || true)
check "没有公钥时不关密码登录"        '! run "test -f /etc/ssh/sshd_config.d/10-server-toolkit.conf"'
check "提示先上传公钥"                'grep -q "ssh-copy-id" <<<"$out"'
check "fail2ban sshd 规则已写入"      'run "grep -q \"enabled  = true\" /etc/fail2ban/jail.d/server-toolkit-sshd.conf"'

echo "== [$IMAGE] ssh（有公钥）"
run 'mkdir -p /root/.ssh && echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeKeyForTestOnlyAAAAAAAAAAAAAAAAAAAAAAAA test" >/root/.ssh/authorized_keys'
run 'bash /toolkit/harden.sh --ssh --yes' >/dev/null 2>&1 || true
check "生效值：密码登录关闭"          'run "sshd -T 2>/dev/null | grep -qx \"passwordauthentication no\""'
check "生效值：root 仅密钥"           'run "sshd -T 2>/dev/null | grep -qx \"permitrootlogin without-password\""'
run 'bash /toolkit/harden.sh --undo ssh' >/dev/null 2>&1 || true
check "撤销后恢复密码登录"            'run "sshd -T 2>/dev/null | grep -qx \"passwordauthentication yes\""'

echo "== [$IMAGE] firewall"
# 模拟 3x-ui：面板 2053 + API；本机入站 443，副节点入站 8443（不应放行）；另有网站在 80 监听
run 'mkdir -p /opt/fake && cat >/opt/fake/x-ui <<"EOF"
#!/usr/bin/env bash
case "$*" in
  *-getApiToken*) echo "apiToken: test-token" ;;
  *-getListen*)   echo "listenIP: " ;;
  *-show*)        printf "Warning: Panel is not secure with SSL\nport: 2053\nwebBasePath: /\n" ;;
  *-v*)           echo "v-test" ;;
esac
EOF
chmod +x /opt/fake/x-ui
cat >/opt/fake/api.py <<"EOF"
import json, http.server
class H(http.server.BaseHTTPRequestHandler):
    def _send(self, body):
        data = json.dumps(body).encode(); self.send_response(200)
        self.send_header("Content-Type", "application/json"); self.end_headers(); self.wfile.write(data)
    def do_GET(self):
        if self.path.endswith("/inbounds/list"):
            self._send({"success": True, "obj": [{"port": 443, "nodeId": None}, {"port": 8443, "nodeId": 3}]})
        elif self.path.endswith("/setting/apiTokens"):
            self._send({"success": True, "obj": []})
        else: self._send({"success": False})
    def do_POST(self): self._send({"success": True})
    def log_message(self, *a): pass
http.server.ThreadingHTTPServer(("0.0.0.0", 2053), H).serve_forever()
EOF
(setsid python3 /opt/fake/api.py >/dev/null 2>&1 &)
(setsid python3 -m http.server 80 --bind 0.0.0.0 >/dev/null 2>&1 &)
sleep 1'

status() { run 'ufw status' 2>/dev/null; }
run 'XUI_BIN=/opt/fake/x-ui bash /toolkit/harden.sh --firewall --yes --allow-panel-from 203.0.113.7' >/dev/null 2>&1 || true
st=$(status)
check "防火墙已启用"                  'grep -q "Status: active" <<<"$st"'
check "SSH 22 公开"                   'grep -qE "^22/tcp +ALLOW +Anywhere" <<<"$st"'
check "本机入站 443 公开"             'grep -qE "^443 +ALLOW +Anywhere" <<<"$st"'
check "网站 80 保持公开"              'grep -qE "^80 +ALLOW +Anywhere" <<<"$st"'
check "面板 2053 只允许白名单"        'grep -qE "^2053/tcp +ALLOW +203\.0\.113\.7" <<<"$st" && ! grep -qE "^2053.* +ALLOW +Anywhere" <<<"$st"'
check "副节点入站 8443 不放行"        '! grep -qE "^8443" <<<"$st"'
sleep 12
check "未确认时自动回滚"              'status | grep -q "Status: inactive"'

run 'XUI_BIN=/opt/fake/x-ui bash /toolkit/harden.sh --firewall --yes --allow-panel-from 203.0.113.7' >/dev/null 2>&1 || true
run 'bash /toolkit/harden.sh --confirm-firewall' >/dev/null
sleep 12
check "确认后不再回滚"                'status | grep -q "Status: active"'
run 'bash /toolkit/harden.sh --undo firewall' >/dev/null 2>&1 || true
check "撤销后恢复为未启用"            'status | grep -q "Status: inactive"'

exit $fail
