#!/usr/bin/env bash
# server-toolkit / harden.sh — Xray / 3x-ui 服务器一键加固。
# 每个模块可单独运行、可重复运行；改动前备份，能撤销的都提供 --undo。
# 用法见 harden.sh --help 或 README.md。
set -Eeuo pipefail

VERSION="1.0.0"
STATE_DIR=${STATE_DIR:-/var/lib/server-toolkit}
XUI_BIN=${XUI_BIN:-}
ROLLBACK_SECONDS=${ROLLBACK_SECONDS:-180}
TOKEN_NAME="server-toolkit"

C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_INFO=$'\033[36m'; C_DIM=$'\033[2m'; C_END=$'\033[0m'
ok()   { printf '%s ✓%s %s\n' "$C_OK" "$C_END" "$*"; }
info() { printf '%s==>%s %s\n' "$C_INFO" "$C_END" "$*"; }
warn() { printf '%s !%s %s\n' "$C_WARN" "$C_END" "$*" >&2; }
err()  { printf '%s ✗%s %s\n' "$C_ERR" "$C_END" "$*" >&2; }
die()  { err "$*"; exit 1; }

declare -a SUMMARY=()
note() { SUMMARY+=("$1|$2|$3"); }   # 模块|状态|说明

usage() {
  cat <<'EOF'
用法：harden [模块...] [选项]

模块（不带任何模块时进入交互菜单）：
  --all               依次执行 base bbr ssh routing firewall audit
  --base              时间同步 + 自动安装安全更新
  --bbr               开启 BBR，调大 TCP 缓冲区
  --ssh               仅允许密钥登录（检测到公钥才执行）+ fail2ban 防爆破
  --routing           3x-ui 路由：屏蔽回国流量、内网、BT，并把屏蔽规则排到最前
  --firewall          防火墙：只开放 SSH 与节点端口，面板端口仅白名单可访问
  --audit             只读检查：端口、伪装目标、面板暴露、默认账号

选项：
  --allow-panel-from IP[,IP...]  允许访问 3x-ui 面板端口的 IP（主控、业务面板、你自己）
  --allow-port PORT[,PORT...]    额外对外开放的端口（如网站 80,443）
  --confirm-firewall             确认防火墙可用，取消自动回滚
  --undo bbr|ssh|routing|firewall  撤销某个模块
  --yes                          不逐项确认
  --print-routing FILE           只打印路由改写结果，不连接面板（调试用）
  -h, --help                     显示本帮助
EOF
}

need_root() { [[ $EUID -eq 0 ]] || die "请用 root 执行"; }
have() { command -v "$1" >/dev/null 2>&1; }
is_debian() { [[ -r /etc/os-release ]] && grep -qiE '^(ID|ID_LIKE)=.*(debian|ubuntu)' /etc/os-release; }
apt_install() {
  local missing=() p
  for p in "$@"; do dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p"); done
  ((${#missing[@]})) || return 0
  info "安装 ${missing[*]}"
  DEBIAN_FRONTEND=noninteractive apt-get -qq update >/dev/null
  DEBIAN_FRONTEND=noninteractive apt-get -qq install -y --no-install-recommends "${missing[@]}" >/dev/null
}
confirm() { # confirm "问题"：--yes 时直接通过
  [[ ${ASSUME_YES:-0} == 1 ]] && return 0
  local answer; read -r -p "$1 [Y/n] " answer </dev/tty || answer=n
  [[ -z $answer || $answer =~ ^[Yy] ]]
}
stamp() { date +%Y%m%d%H%M%S; }

# ============================================================================ preflight
preflight() {
  need_root
  mkdir -p "$STATE_DIR/backup"; chmod 700 "$STATE_DIR"
  if is_debian; then
    apt_install jq curl ca-certificates
  else
    warn "不是 Debian / Ubuntu：依赖 apt 的模块（base、ssh 的 fail2ban、firewall）会跳过"
    have jq && have curl || die "请先安装 jq 和 curl"
  fi
  if [[ -z $XUI_BIN ]]; then
    local c; for c in /usr/local/x-ui/x-ui /usr/local/x-node/x-ui /app/x-ui; do [[ -x $c ]] && { XUI_BIN=$c; break; }; done
  fi
  if [[ -n $XUI_BIN ]]; then ok "找到 3x-ui：$XUI_BIN"; else warn "没有找到 3x-ui，routing / firewall 的端口识别 / audit 会跳过（可用 XUI_BIN=路径 指定）"; fi
}

# ============================================================================ base
mod_base() {
  is_debian || { note base 跳过 "非 Debian / Ubuntu"; return; }
  info "时间同步 + 自动安全更新"
  if systemctl is-active -q chrony 2>/dev/null || systemctl is-active -q chronyd 2>/dev/null; then
    ok "已在用 chrony 同步时间"
  else
    apt_install systemd-timesyncd || true
    timedatectl set-ntp true 2>/dev/null || warn "开启 NTP 失败（容器环境可忽略）"
  fi
  apt_install unattended-upgrades
  cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
  ok "已开启自动安装安全更新（默认只装安全补丁，不自动重启）"
  note base 完成 "时间同步、自动安全更新"
}

# ============================================================================ bbr
BBR_CONF=/etc/sysctl.d/99-server-toolkit-bbr.conf
BBR_KEYS=(net.core.default_qdisc net.ipv4.tcp_congestion_control net.core.rmem_max net.core.wmem_max
          net.ipv4.tcp_rmem net.ipv4.tcp_wmem net.ipv4.tcp_mtu_probing net.ipv4.tcp_fastopen)
mod_bbr() {
  info "BBR 与 TCP 参数"
  local virt kernel major minor
  virt=$(systemd-detect-virt 2>/dev/null || true)
  if [[ -e /proc/user_beancounters || $virt == openvz || $virt == lxc* ]]; then
    note bbr 跳过 "${virt:-OpenVZ} 容器不能改内核参数，请让机房开启或换 KVM"; return
  fi
  kernel=$(uname -r); major=${kernel%%.*}; minor=${kernel#*.}; minor=${minor%%.*}
  if ! (( major > 4 || (major == 4 && minor >= 9) )); then note bbr 跳过 "内核 $kernel 低于 4.9"; return; fi
  if ! sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
    modprobe tcp_bbr 2>/dev/null || true
    if ! sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
      note bbr 跳过 "内核不支持 BBR"; return
    fi
    echo tcp_bbr >/etc/modules-load.d/server-toolkit-bbr.conf
  fi
  # /etc/sysctl.conf 最后加载，会覆盖 sysctl.d；同名项注释掉（先备份）
  if [[ -f /etc/sysctl.conf ]]; then
    local pattern; pattern=$(IFS='|'; echo "${BBR_KEYS[*]//./\\.}")
    if grep -qE "^[[:space:]]*($pattern)[[:space:]]*=" /etc/sysctl.conf; then
      cp -p /etc/sysctl.conf "$STATE_DIR/backup/sysctl.conf.$(stamp)"
      sed -i -E "s/^([[:space:]]*($pattern)[[:space:]]*=)/# server-toolkit: \1/" /etc/sysctl.conf
      warn "/etc/sysctl.conf 中的同名设置已注释（备份在 $STATE_DIR/backup）"
    fi
  fi
  cat >"$BBR_CONF" <<'EOF'
# server-toolkit：撤销用 harden --undo bbr
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.ipv4.tcp_rmem=4096 87380 67108864
net.ipv4.tcp_wmem=4096 65536 67108864
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_fastopen=3
EOF
  sysctl --system >/dev/null 2>&1 || true
  local cc qd; cc=$(sysctl -n net.ipv4.tcp_congestion_control); qd=$(sysctl -n net.core.default_qdisc)
  if [[ $cc == bbr && $qd == fq ]]; then ok "拥塞控制 bbr，队列 fq"; note bbr 完成 "bbr + fq，TCP 缓冲 64MB"
  else note bbr 失败 "写入后实际为 $cc / $qd"; fi
}
undo_bbr() {
  rm -f "$BBR_CONF" /etc/modules-load.d/server-toolkit-bbr.conf; sysctl --system >/dev/null 2>&1 || true
  ok "已删除 BBR 设置，当前：$(sysctl -n net.ipv4.tcp_congestion_control)（重启后完全恢复默认）"
}

# ============================================================================ ssh
SSH_DROPIN=/etc/ssh/sshd_config.d/10-server-toolkit.conf
F2B_JAIL=/etc/fail2ban/jail.d/server-toolkit-sshd.conf
ssh_reload() { systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || service ssh reload 2>/dev/null || true; }
mod_ssh() {
  info "SSH 加固"
  have sshd || { note ssh 跳过 "没有安装 openssh-server"; return; }
  local keys=/root/.ssh/authorized_keys
  if [[ -f $keys ]] && grep -qE '^[[:space:]]*(ssh-(ed25519|rsa|dss)|ecdsa-sha2-|sk-)' "$keys"; then
    if ! grep -qiE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' /etc/ssh/sshd_config; then
      note ssh 部分完成 "sshd_config 没有 Include sshd_config.d，未改登录方式"
    else
      mkdir -p /etc/ssh/sshd_config.d
      cat >"$SSH_DROPIN" <<'EOF'
# server-toolkit：撤销用 harden --undo ssh
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
EOF
      if sshd -t 2>/dev/null; then
        ssh_reload
        if sshd -T 2>/dev/null | grep -qx 'passwordauthentication no'; then
          ok "已关闭密码登录（当前连接不受影响；请另开窗口确认密钥能登录）"
        else
          warn "配置已写入，但实际生效值不是 no，可能被其它配置覆盖：sshd -T | grep passwordauth"
        fi
      else
        rm -f "$SSH_DROPIN"; note ssh 失败 "sshd -t 校验失败，已撤回"; return
      fi
    fi
  else
    warn "root 没有配置 SSH 公钥，为避免把你锁在外面，不关闭密码登录"
    warn "先在你电脑上执行 ssh-copy-id root@服务器，再重跑 harden --ssh"
    note ssh 部分完成 "无公钥，未关闭密码登录"
  fi
  if is_debian; then
    apt_install fail2ban
    mkdir -p /etc/fail2ban/jail.d
    local backend=systemd; [[ -f /var/log/auth.log ]] && backend=auto
    cat >"$F2B_JAIL" <<EOF
# server-toolkit：SSH 防爆破
[sshd]
enabled  = true
backend  = $backend
maxretry = 5
findtime = 10m
bantime  = 1h
EOF
    systemctl enable -q fail2ban 2>/dev/null || true
    systemctl restart fail2ban 2>/dev/null || service fail2ban restart 2>/dev/null || true
    ok "fail2ban：10 分钟内失败 5 次封禁 1 小时"
  fi
  [[ -f $SSH_DROPIN ]] && note ssh 完成 "仅密钥登录 + fail2ban"
}
undo_ssh() { rm -f "$SSH_DROPIN" "$F2B_JAIL"; ssh_reload; systemctl restart fail2ban 2>/dev/null || true; ok "已恢复 SSH 原有登录方式，移除 fail2ban 的 sshd 规则"; }

# ============================================================================ 3x-ui API
PANEL_URL=""; TOKEN=""
panel_setup() {
  [[ -n $XUI_BIN ]] || return 1
  [[ -n $PANEL_URL && -n $TOKEN ]] && return 0
  local show port base listen scheme=http
  show=$("$XUI_BIN" setting -show 2>/dev/null) || return 1
  port=$(awk -F': ' '/^port:/{print $2}' <<<"$show" | tr -d '[:space:]')
  base=$(awk -F': ' '/^webBasePath:/{print $2}' <<<"$show" | tr -d '[:space:]')
  grep -q "^Panel is secure with SSL" <<<"$show" && scheme=https
  listen=$("$XUI_BIN" setting -getListen 2>/dev/null | awk -F': ' '/listenIP/{print $2}' | tr -d '[:space:]' || true)
  [[ -z $listen || $listen == 0.0.0.0 || $listen == :: ]] && listen=127.0.0.1
  [[ $listen == *:* ]] && listen="[$listen]"
  [[ $base == /* ]] || base="/$base"; [[ $base == */ ]] || base="$base/"
  [[ -n $port ]] || return 1
  PANEL_PORT=$port
  PANEL_URL="$scheme://$listen:$port${base}panel/api"
  TOKEN=$("$XUI_BIN" setting -getApiToken -tokenName "$TOKEN_NAME" -tokenScope admin 2>/dev/null | awk '/^apiToken:/{print $2}' || true)
  [[ -n $TOKEN ]] || { warn "无法生成临时 API Token"; return 1; }
  trap panel_cleanup EXIT
}
panel_cleanup() { # 删掉本脚本的临时 Token；不影响其它 Token
  [[ -n $TOKEN && -n $PANEL_URL ]] || return 0
  local id
  id=$(api GET setting/apiTokens 2>/dev/null | jq -r --arg n "$TOKEN_NAME" '.obj[]? | select(.name==$n) | .id' | head -n1 || true)
  [[ -n $id ]] && api POST "setting/apiTokens/delete/$id" --data-urlencode "expectedScope=admin" >/dev/null 2>&1 || true
  TOKEN=""
}
api() { # api METHOD PATH [curl 参数...]
  local method=$1 path=$2; shift 2
  curl -fsS -k --max-time 30 -X "$method" -H "Authorization: Bearer $TOKEN" "$PANEL_URL/$path" "$@"
}
api_ok() { jq -e '.success == true' >/dev/null; }

# ============================================================================ routing
# 规则改写（纯 jq，便于测试）：屏蔽 private / cn / BT；从直连规则里去掉 cn；屏蔽规则排在 api 规则之后、其它规则之前。
read -r -d '' ROUTING_JQ <<'JQ' || true
def matcher_keys: ["domain","ip","port","sourcePort","network","source","sourceIP","user","inboundTag","protocol","attrs","localIP","localPort","vlessRoute","process"];
def has_matcher: . as $r | any(matcher_keys[]; ($r[.] // null) | . != null and . != [] and . != "");
def pure_block($k): .outboundTag == "blocked" and (has($k)) and ([to_entries[] | select(.key as $x | matcher_keys | index($x)) | .key] == [$k]);
def ensure_block($k; $vals):
  if any(.[]; pure_block($k)) then
    (first(to_entries[] | select(.value | pure_block($k)) | .key)) as $i
    | .[$i][$k] = ((.[$i][$k] // []) + ($vals - (.[$i][$k] // [])))
  else . + [{type: "field", outboundTag: "blocked", ($k): $vals}] end;
def cn_domains: ["geosite:cn", "regexp:.*\\.cn$"];
.routing = (.routing // {})
| .routing.rules = (
    (.routing.rules // [])
    | map(
        if .outboundTag == "direct" then
          . as $orig
          | (if has("ip") then .ip -= ["geoip:cn"] else . end)
          | (if has("domain") then .domain -= cn_domains else . end)
          | if ($orig | has_matcher) and (has_matcher | not) then empty
            else with_entries(select(.key as $k | (["ip","domain"] | index($k) | not) or (.value != []))) end
        else . end)
    | ensure_block("ip"; ["geoip:private", "geoip:cn"])
    | ensure_block("domain"; ["geosite:cn"])
    | ensure_block("protocol"; ["bittorrent"])
    | . as $rules
    | [ $rules[] | select(.outboundTag == "api") ] as $api
    | [ $rules[] | select(.outboundTag != "api" and (pure_block("ip") or pure_block("domain") or pure_block("protocol"))) ] as $blk
    | [ $rules[] | select(.outboundTag != "api" and ((pure_block("ip") or pure_block("domain") or pure_block("protocol")) | not)) ] as $rest
    | $api + $blk + $rest )
| .outbounds = (if any((.outbounds // [])[]; .tag == "blocked") then .outbounds
                else (.outbounds // []) + [{tag: "blocked", protocol: "blackhole", settings: {}}] end)
JQ

mod_routing() {
  info "3x-ui 路由：屏蔽回国流量 / 内网 / BT"
  panel_setup || { note routing 跳过 "没有找到可用的 3x-ui 面板"; return; }
  local resp current next test_url backup
  resp=$(api POST xray/) || { note routing 失败 "读取 Xray 配置失败"; return; }
  api_ok <<<"$resp" || { note routing 失败 "读取 Xray 配置被拒绝"; return; }
  current=$(jq -r '.obj' <<<"$resp" | jq -c '.xraySetting' || true)
  test_url=$(jq -r '.obj' <<<"$resp" | jq -r '.outboundTestUrl // empty')
  # 没有出站时追加的 blocked 会成为默认出站，等于断网，宁可不改
  jq -e '(.outbounds // []) | length > 0' >/dev/null <<<"$current" || { note routing 失败 "Xray 模板没有任何出站，未修改"; return; }
  next=$(jq -c "$ROUTING_JQ" <<<"$current")
  [[ $(jq -r '.outbounds[0].tag' <<<"$next") != blocked ]] || { note routing 失败 "默认出站会变成 blocked，未修改"; return; }
  if [[ $(jq -S . <<<"$current") == "$(jq -S . <<<"$next")" ]]; then
    ok "路由规则已经是目标状态，无需修改"; note routing 完成 "已是目标状态"; return
  fi
  backup="$STATE_DIR/backup/xray-$(stamp).json"
  jq . <<<"$current" >"$backup"; chmod 600 "$backup"
  local tmp; tmp=$(mktemp); jq . <<<"$next" >"$tmp"
  resp=$(api POST xray/update --data-urlencode "xraySetting@$tmp" --data-urlencode "outboundTestUrl=$test_url") || true
  rm -f "$tmp"
  if ! api_ok <<<"$resp"; then
    note routing 失败 "面板拒绝保存：$(jq -r '.msg // "未知原因"' <<<"$resp" 2>/dev/null)"; return
  fi
  local saved; saved=$(api POST xray/ | jq -r '.obj' | jq -c '.xraySetting' || true)
  if [[ $(jq -S . <<<"$saved") == "$(jq -S . <<<"$next")" ]]; then
    ok "已保存并重启 Xray（原配置备份：$backup）"
    note routing 完成 "屏蔽 cn / private / BT，屏蔽规则已置顶"
  else
    note routing 失败 "保存后读回的配置与预期不一致，请在面板里检查"
  fi
}
undo_routing() {
  local latest; latest=$(ls -1t "$STATE_DIR"/backup/xray-*.json 2>/dev/null | head -n1 || true)
  [[ -n $latest ]] || die "没有找到路由备份"
  panel_setup || die "连不上 3x-ui 面板"
  api POST xray/update --data-urlencode "xraySetting@$latest" | api_ok || die "恢复失败"
  ok "已恢复为 $latest"
}

# ============================================================================ firewall
FW_DIR="$STATE_DIR/firewall"
fw_listen_ports() { # 对外监听的 TCP 端口（排除仅本机）
  ss -H -ltn 2>/dev/null | awk '{print $4}' | while read -r addr; do
    local host=${addr%:*}
    [[ $host == 127.* || $host == "[::1]" || $host == "::1" ]] && continue
    echo "${addr##*:}"
  done | sort -u
}
mod_firewall() {
  info "防火墙"
  is_debian || { note firewall 跳过 "非 Debian / Ubuntu"; return; }
  apt_install ufw iproute2
  local ssh_port panel_port="" ports=() p
  ssh_port=$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}' || true); ssh_port=${ssh_port:-22}
  if panel_setup; then
    panel_port=$PANEL_PORT
    while read -r p; do [[ -n $p ]] && ports+=("$p"); done < <(
      api GET inbounds/list | jq -r '.obj[]? | select((.nodeId // 0) == 0) | .port' | sort -un)
  else
    warn "没有连上 3x-ui，只按当前监听端口放行"
  fi
  # 所有正在对外监听的端口默认保持开放，避免误伤网站或其它服务；面板端口单独处理
  while read -r p; do ports+=("$p"); done < <(fw_listen_ports)
  local extra; IFS=',' read -r -a extra <<<"${ALLOW_PORTS:-}"; ports+=("${extra[@]}")
  mapfile -t ports < <(printf '%s\n' "${ports[@]}" | grep -E '^[0-9]+$' | grep -vx "$ssh_port" | { [[ -n $panel_port ]] && grep -vx "$panel_port" || cat; } | sort -un)

  local allow_from=(); IFS=',' read -r -a allow_from <<<"${ALLOW_PANEL_FROM:-}"
  if [[ -n $panel_port && ${#allow_from[@]} -eq 0 ]]; then
    warn "没有指定 --allow-panel-from，面板端口 $panel_port 保持公开。建议填主控 / 业务面板 / 你自己的 IP"
    ports+=("$panel_port")
  fi

  echo "    SSH：$ssh_port（公开）"
  echo "    公开端口：${ports[*]:-无}"
  [[ -n $panel_port && ${#allow_from[@]} -gt 0 ]] && echo "    面板 $panel_port 仅允许：${allow_from[*]}"
  confirm "按上面的规则启用防火墙？（${ROLLBACK_SECONDS} 秒内不确认会自动回滚）" || { note firewall 跳过 "未确认"; return; }

  # 备份当前状态，安排自动回滚
  mkdir -p "$FW_DIR"; rm -rf "$FW_DIR/snapshot"; mkdir -p "$FW_DIR/snapshot"
  cp -a /etc/ufw/. "$FW_DIR/snapshot/" 2>/dev/null || true
  ufw status 2>/dev/null | grep -q "Status: active" && echo active >"$FW_DIR/was" || echo inactive >"$FW_DIR/was"
  cat >"$FW_DIR/rollback.sh" <<EOF
#!/usr/bin/env bash
cp -a "$FW_DIR/snapshot/." /etc/ufw/
if [[ \$(cat "$FW_DIR/was") == active ]]; then ufw --force reload; else ufw --force disable; fi
echo "server-toolkit: firewall rolled back at \$(date)" >>"$FW_DIR/rollback.log"
EOF
  chmod 700 "$FW_DIR/rollback.sh"

  ufw --force reset >/dev/null
  ufw default deny incoming >/dev/null; ufw default allow outgoing >/dev/null
  ufw allow "$ssh_port/tcp" comment 'ssh' >/dev/null
  for p in "${ports[@]}"; do ufw allow "$p" comment 'public' >/dev/null; done
  if [[ -n $panel_port && ${#allow_from[@]} -gt 0 ]]; then
    local ip; for ip in "${allow_from[@]}"; do
      ufw allow from "$ip" to any port "$panel_port" proto tcp comment 'panel' >/dev/null
    done
  fi
  ufw --force enable >/dev/null
  fw_schedule_rollback
  ok "防火墙已启用"
  warn "请在 ${ROLLBACK_SECONDS} 秒内【另开一个 SSH 窗口】登录成功后执行：harden --confirm-firewall"
  warn "不确认的话会自动恢复原状态，防止把你锁在外面"
  note firewall 待确认 "${ROLLBACK_SECONDS}s 内执行 harden --confirm-firewall，否则自动回滚"
}
fw_schedule_rollback() {
  if [[ -d /run/systemd/system ]] && have systemd-run; then
    systemctl stop server-toolkit-fw-rollback.timer 2>/dev/null || true
    systemd-run --quiet --unit server-toolkit-fw-rollback --on-active="${ROLLBACK_SECONDS}" "$FW_DIR/rollback.sh"
  else
    setsid bash -c "sleep ${ROLLBACK_SECONDS}; [[ -f '$FW_DIR/pending' ]] && '$FW_DIR/rollback.sh'; rm -f '$FW_DIR/pending'" >/dev/null 2>&1 &
  fi
  touch "$FW_DIR/pending"
}
confirm_firewall() {
  need_root
  systemctl stop server-toolkit-fw-rollback.timer 2>/dev/null || true
  rm -f "$FW_DIR/pending"
  ok "防火墙已确认，自动回滚已取消"
}
undo_firewall() { [[ -x $FW_DIR/rollback.sh ]] || die "没有防火墙备份"; "$FW_DIR/rollback.sh"; rm -f "$FW_DIR/pending"; ok "防火墙已恢复为启用前的状态"; }

# ============================================================================ audit
COMMON_TARGETS='microsoft|apple|icloud|amazon|aws\.|google|samsung|amd\.com|sony|cloudflare|yahoo|bing\.com|github|nvidia|intel\.com|tesla'
mod_audit() {
  info "检查（只读）"
  local issues=0
  if [[ -n $XUI_BIN ]]; then
    local show; show=$("$XUI_BIN" setting -show 2>/dev/null || true)
    grep -q "hasDefaultCredential: true" <<<"$show" && { warn "面板仍在用默认账号密码，请立即修改"; issues=$((issues+1)); }
    grep -q "not secure with SSL" <<<"$show" && { warn "面板没有启用 HTTPS，登录密码会明文传输"; issues=$((issues+1)); }
  fi
  if panel_setup; then
    local inbounds; inbounds=$(api GET inbounds/list | jq -c '[.obj[]? | select((.nodeId // 0) == 0)]' || echo '[]')
    while IFS=$'\t' read -r port remark target names count; do
      [[ $port == 443 ]] || { warn "入站「$remark」使用 $port 端口，非 443 端口更容易被关注"; issues=$((issues+1)); }
      if [[ -n $target ]] && grep -qiE "$COMMON_TARGETS" <<<"$target $names"; then
        warn "入站「$remark」的伪装目标 $target 过于常见，建议用面板扫描器扫本机 /24 网段挑邻居站点"; issues=$((issues+1))
      fi
      (( count > 3 )) && { warn "入站「$remark」配了 $count 个 serverNames，保留 1~2 个即可"; issues=$((issues+1)); }
    done < <(jq -r '.[] | (.streamSettings | if type=="string" then (fromjson? // {}) else (. // {}) end) as $s
      | select($s.security == "reality")
      | [ (.port|tostring), (.remark // .tag // "-"),
          ($s.realitySettings.target // $s.realitySettings.dest // ""),
          (($s.realitySettings.serverNames // []) | join(",")),
          (($s.realitySettings.serverNames // []) | length | tostring) ] | @tsv' <<<"$inbounds")
    if [[ -n ${PANEL_PORT:-} ]] && ss -H -ltn "sport = :$PANEL_PORT" 2>/dev/null | awk '{print $4}' | grep -qvE '^(127\.|\[::1\])'; then
      local fw; fw=$(ufw status 2>/dev/null || true)
      if ! grep -q "Status: active" <<<"$fw" || grep -qE "^$PANEL_PORT(/tcp)? +ALLOW +Anywhere" <<<"$fw"; then
        warn "面板端口 $PANEL_PORT 对公网开放，扫描器可识别出 3x-ui。建议 harden --firewall --allow-panel-from <IP>"; issues=$((issues+1))
      fi
    fi
  fi
  [[ -n $XUI_BIN ]] && echo "    版本：$("$XUI_BIN" -v 2>/dev/null | head -n1)"
  if (( issues == 0 )); then ok "没有发现问题"; note audit 完成 "没有发现问题"; else note audit 有建议 "$issues 项，见上方黄色提示"; fi
}

# ============================================================================ main
summary() {
  ((${#SUMMARY[@]})) || return 0
  printf '\n%s汇总%s\n' "$C_INFO" "$C_END"
  local row m s d color
  for row in "${SUMMARY[@]}"; do
    IFS='|' read -r m s d <<<"$row"
    case $s in 完成) color=$C_OK;; 失败) color=$C_ERR;; *) color=$C_WARN;; esac
    printf '  %-9s %s%-6s%s %s%s%s\n' "$m" "$color" "$s" "$C_END" "$C_DIM" "$d" "$C_END"
  done
}

main() {
  local mods=() undo="" do_confirm=0
  ASSUME_YES=0; ALLOW_PANEL_FROM=""; ALLOW_PORTS=""; ALL=0
  while (($#)); do
    case $1 in
      --all) mods+=(base bbr ssh routing firewall audit); ALL=1 ;;
      --base|--bbr|--ssh|--routing|--firewall|--audit) mods+=("${1#--}") ;;
      --allow-panel-from) ALLOW_PANEL_FROM=${2:?缺少 IP}; shift ;;
      --allow-port) ALLOW_PORTS=${2:?缺少端口}; shift ;;
      --confirm-firewall) do_confirm=1 ;;
      --undo) undo=${2:?缺少模块名}; shift ;;
      --yes|-y) ASSUME_YES=1 ;;
      --print-routing) jq "$ROUTING_JQ" "${2:?缺少文件}"; return ;;
      -h|--help) usage; return ;;
      -v|--version) echo "$VERSION"; return ;;
      *) usage; die "未知参数：$1" ;;
    esac
    shift
  done
  ((do_confirm)) && { confirm_firewall; return; }
  if [[ -n $undo ]]; then
    preflight
    case $undo in bbr) undo_bbr ;; ssh) undo_ssh ;; routing) undo_routing ;; firewall) undo_firewall ;; *) die "不支持撤销：$undo" ;; esac
    return
  fi
  if ((${#mods[@]} == 0)); then
    [[ -t 0 || -r /dev/tty ]] || { usage; return 1; }
    local m
    for m in base bbr ssh routing firewall audit; do
      confirm "执行 $m？" && mods+=("$m")
    done
    if [[ " ${mods[*]} " == *" firewall "* && -z $ALLOW_PANEL_FROM ]]; then
      read -r -p "允许访问面板的 IP（逗号分隔，留空则面板保持公开）：" ALLOW_PANEL_FROM </dev/tty || true
    fi
  fi
  preflight
  local m; for m in "${mods[@]}"; do
    if [[ $m == firewall && $ALL == 1 && -z $ALLOW_PANEL_FROM ]]; then
      note firewall 跳过 "--all 需配合 --allow-panel-from 才启用防火墙"; continue
    fi
    "mod_$m"
  done
  summary
}

main "$@"
