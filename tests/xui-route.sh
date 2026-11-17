#!/usr/bin/env bash
# 在 3x-ui 容器内运行：问运行中的 Xray 某个连接会走哪个出站。
# 用法：bash tests/xui-route.sh DOMAIN [INBOUND_TAG]   输出出站 tag；Xray 刚重启时会重试。
set -Eeuo pipefail
cd "$(dirname "$0")/.."
eval "$(sed -n '/^PANEL_URL=""/,/^api_ok()/p' harden.sh)"
XUI_BIN=${XUI_BIN:-/app/x-ui}
# shellcheck disable=SC2034  # 被 eval 进来的 panel_setup 使用
TOKEN_NAME=route
panel_setup >/dev/null
for _ in $(seq 1 12); do
  resp=$(api POST xray/routeTest --data-urlencode "domain=$1" --data-urlencode port=443 \
    --data-urlencode network=tcp --data-urlencode "inboundTag=${2:-}" || true)
  if jq -e '.success == true' >/dev/null 2>&1 <<<"$resp"; then
    jq -r '.obj | if type == "string" then (fromjson? // .) else . end
      | if type != "object" then tostring
        elif (.matched == false) or ((.outboundTag // "") == "") then "default"
        else .outboundTag end' <<<"$resp"
    panel_cleanup; exit 0
  fi
  sleep 3
done
echo "routeTest failed: $resp" >&2
panel_cleanup; exit 1
