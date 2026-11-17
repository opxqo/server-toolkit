#!/usr/bin/env bash
# shellcheck disable=SC2034  # 变量在 check 的 eval 字符串里使用
# 在真实 3x-ui 容器里测试 routing 模块：改写正确、幂等、可撤销、不碰其它规则和出站。
# 用法：bash tests/routing-3xui.sh   （需要 Docker）
set -Eeuo pipefail
IMAGE=${IMAGE:-ghcr.io/mhsanaei/3x-ui:v3.11.0}
NAME="st-routing-test"
ROOT=$(cd "$(dirname "$0")/.." && pwd)

cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup
docker run -d --name "$NAME" -v "$ROOT:/toolkit:ro" "$IMAGE" >/dev/null
for _ in $(seq 1 30); do docker exec "$NAME" sh -c 'nc -z 127.0.0.1 2053 2>/dev/null || wget -q -O /dev/null http://127.0.0.1:2053/ 2>/dev/null' && break; sleep 1; done
docker exec "$NAME" apk add --no-cache bash jq curl sqlite >/dev/null

run() { docker exec -e XUI_BIN=/app/x-ui -e STATE_DIR=/tmp/st "$NAME" bash -c "$1"; }

# 用一份带「直连 cn」与住宅出站规则的模板作为起点
run 'cd /toolkit && source <(sed -n "/^PANEL_URL=\"\"/,/^api_ok()/p" harden.sh) && XUI_BIN=/app/x-ui && TOKEN_NAME=seed && panel_setup &&
     api POST xray/update --data-urlencode "xraySetting@tests/fixture-xray.json" | jq -e ".success" >/dev/null && panel_cleanup'

get() { run 'cd /toolkit && source <(sed -n "/^PANEL_URL=\"\"/,/^api_ok()/p" harden.sh) && XUI_BIN=/app/x-ui && TOKEN_NAME=probe && panel_setup && api POST xray/ | jq -r .obj | jq -S .xraySetting; panel_cleanup'; }
before=$(get)

fail=0
check() { if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1"; fail=1; fi; }

echo "== 第一次运行"
run 'bash /toolkit/harden.sh --routing --yes' || true
after=$(get)
check "api 规则仍在第一位"              '[[ $(jq -r ".routing.rules[0].outboundTag" <<<"$after") == api ]]'
check "第 2~4 条都是 blocked"           '[[ $(jq -r "[.routing.rules[1:4][].outboundTag] | unique | join(\",\")" <<<"$after") == blocked ]]'
check "屏蔽 geoip:cn 与 private"        'jq -e "any(.routing.rules[]; .outboundTag==\"blocked\" and ((.ip//[])|index(\"geoip:cn\")) and ((.ip//[])|index(\"geoip:private\")))" >/dev/null <<<"$after"'
check "屏蔽 geosite:cn"                 'jq -e "any(.routing.rules[]; .outboundTag==\"blocked\" and ((.domain//[])|index(\"geosite:cn\")))" >/dev/null <<<"$after"'
check "直连规则里不再有 cn"             '! jq -e "any(.routing.rules[]; .outboundTag==\"direct\" and (((.ip//[])+(.domain//[])) | any(test(\"cn\"))))" >/dev/null <<<"$after"'
check "直连规则里其它域名保留"          'jq -e "any(.routing.rules[]; .outboundTag==\"direct\" and ((.domain//[])|index(\"domain:keep.example\")))" >/dev/null <<<"$after"'
check "住宅入站规则保留"                'jq -e "any(.routing.rules[]; .outboundTag==\"residential-out\" and .inboundTag==[\"in-10001-tcp\"])" >/dev/null <<<"$after"'
check "出站完全不变"                    '[[ $(jq -S .outbounds <<<"$before") == "$(jq -S .outbounds <<<"$after")" ]]'
token_count() { run "sqlite3 /etc/x-ui/x-ui.db \"select count(*) from api_tokens where name='server-toolkit'\""; }
check "临时 Token 已删除"               '[[ $(token_count) == 0 ]]'

echo "== 第二次运行（幂等）"
second=$(run 'bash /toolkit/harden.sh --routing --yes' 2>&1 || true)
grep -q "无需修改" <<<"$second" && echo "  ok   提示无需修改" || { echo "  FAIL 第二次运行又改了配置"; fail=1; }
check "两次结果相同"                    '[[ $(get) == "$after" ]]'

echo "== 撤销"
run 'bash /toolkit/harden.sh --undo routing' >/dev/null
check "恢复为原配置"                    '[[ $(get) == "$before" ]]'

exit $fail
