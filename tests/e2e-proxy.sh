#!/usr/bin/env bash
#
# e2e-proxy.sh —— 真实端到端验证：用安装脚本自己产出的配置跑通一条真实隧道
#
# 与 run-tests.sh 的区别：run-tests.sh 验证「产物正确」，本脚本验证「真能上网」。
#
#   本机 SOCKS5 → Xray 客户端 ← 安装脚本生成的 client.json
#                    ↓ REALITY 隧道
#                 Xray 服务端 ← 安装脚本生成的 config.json
#                    ↓
#               目标网站（真实 HTTPS 请求）
#
# 用法：bash tests/e2e-proxy.sh [xray 二进制路径]
#

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${HERE}/../install-xray.sh"
XRAY_REAL="${1:-$(command -v xray || true)}"
[[ -n "$XRAY_REAL" && -x "$XRAY_REAL" ]] || {
  echo '需要 xray 二进制：bash tests/e2e-proxy.sh /path/to/xray'; exit 2; }

TAG='v26.3.27'
TARGET="${E2E_TARGET:-www.cloudflare.com}"
# bash 3.2 下 "空数组 + set -u" 会报 unbound variable，故用字符串传递
MODE_ARGS=''
case "${E2E_MODE:-plain}" in
  plain)  ;;
  enc)    MODE_ARGS='--encryption' ;;
  xhttp)  MODE_ARGS='--xhttp' ;;
  full)   MODE_ARGS='--encryption --mldsa65'
          TARGET='www.amazon.com' ;;   # 链长 4287，满足 ML-DSA-65 要求
  *)      echo "未知 E2E_MODE：${E2E_MODE}"; exit 2 ;;
esac
PROBE_URL="${E2E_URL:-https://www.cloudflare.com/cdn-cgi/trace}"

SANDBOX="$(mktemp -d)"
HTTP_PID=''
cleanup() {
  [[ -n "$HTTP_PID" ]] && kill "$HTTP_PID" 2>/dev/null
  if [[ "${E2E_KEEP:-0}" == '1' ]]; then echo "沙箱保留：$SANDBOX"; else rm -rf "$SANDBOX"; fi
}
trap cleanup EXIT

echo "内核：$("$XRAY_REAL" version | head -1)"
echo "宿主：$(uname -s) $(uname -m)"
echo

# ═══════════════════════════════════════════════════════════════════════════
#  伪装层：root + Linux + systemd（同 run-tests.sh 思路）
# ═══════════════════════════════════════════════════════════════════════════
BIN="${SANDBOX}/usr/local/bin"
CONFDIR="${SANDBOX}/usr/local/etc/xray"
DATDIR="${SANDBOX}/usr/local/share/xray"
LOGDIR="${SANDBOX}/var/log/xray"
SYSDIR="${SANDBOX}/etc/systemd/system"
MOCKBIN="${SANDBOX}/mockbin"
STAGE="${SANDBOX}/stage"
export MOCK_LOG="${SANDBOX}/mock.log"
mkdir -p "$BIN" "$CONFDIR" "$DATDIR" "$LOGDIR" "$SYSDIR" "$MOCKBIN" \
         "${SANDBOX}/etc/sysctl.d" "${SANDBOX}/etc/modules-load.d" "${STAGE}/${TAG}"

wm() { printf '%s\n' "$2" > "${MOCKBIN}/$1"; chmod +x "${MOCKBIN}/$1"; }
wm id '#!/usr/bin/env bash
[[ "${1:-}" == "-u" ]] && { echo 0; exit 0; }
exec /usr/bin/id "$@"'
wm uname '#!/usr/bin/env bash
case "${1:-}" in
  -s) echo Linux ;;
  -m) echo x86_64 ;;
  *)  echo Linux ;;
esac'
wm systemctl '#!/usr/bin/env bash
echo "systemctl $*" >> "${MOCK_LOG}"
exit 0'
wm sysctl '#!/usr/bin/env bash
case "$*" in
  *available_congestion_control*) echo "reno cubic bbr" ;;
  *tcp_congestion_control*) echo bbr ;;
  *default_qdisc*) echo fq ;;
esac
exit 0'
wm modprobe '#!/usr/bin/env bash
exit 0'
for t in ufw firewall-cmd iptables netfilter-persistent; do
  wm "$t" '#!/usr/bin/env bash
exit 127'
done
wm apt-get '#!/usr/bin/env bash
exit 0'
JQ_REAL="$(command -v jq || true)"
[[ -n "$JQ_REAL" ]] && wm jq "#!/usr/bin/env bash
exec ${JQ_REAL} \"\$@\""
: > "$MOCK_LOG"

# 本地下载源：用宿主可执行的二进制冒充 Linux 包
# geoip/geosite 必须是真实数据，否则含 geoip: 规则的服务端配置无法通过校验
cp "$XRAY_REAL" "${STAGE}/${TAG}/xray"
GEO_SRC="$(dirname "$XRAY_REAL")"
if [[ -s "${GEO_SRC}/geoip.dat" && -s "${GEO_SRC}/geosite.dat" ]]; then
  cp "${GEO_SRC}/geoip.dat" "${GEO_SRC}/geosite.dat" "${STAGE}/${TAG}/"
else
  # 就地拉取官方 dat（几十 MB，仅首次）
  echo '▶ 获取真实 geoip.dat / geosite.dat …'
  GEO_ZIP="${SANDBOX}/geo.zip"
  if curl -fsSL --max-time 300 -o "$GEO_ZIP" \
      "https://github.com/XTLS/Xray-core/releases/download/${TAG}/Xray-linux-64.zip" 2>/dev/null \
     && unzip -oq "$GEO_ZIP" geoip.dat geosite.dat -d "${STAGE}/${TAG}" 2>/dev/null; then
    echo '  已获取'
  else
    echo '❌ 无法获取 geoip.dat，测试中止（服务端配置含 geoip 规则）'; exit 3
  fi
  rm -f "$GEO_ZIP"
fi
( cd "${STAGE}/${TAG}" && zip -q "Xray-linux-64.zip" xray geoip.dat geosite.dat )
SHA="$(shasum -a 256 "${STAGE}/${TAG}/Xray-linux-64.zip" | awk '{print $1}')"
printf 'SHA2-256= %s\n' "$SHA" > "${STAGE}/${TAG}/Xray-linux-64.zip.dgst"

HTTP_PORT="$(python3 -c 'import socket
s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
( cd "$STAGE" && exec python3 -m http.server "$HTTP_PORT" --bind 127.0.0.1 ) >/dev/null 2>&1 &
HTTP_PID=$!
sleep 1.5

# ═══════════════════════════════════════════════════════════════════════════
#  用安装脚本生成服务端配置 + 配套客户端配置
# ═══════════════════════════════════════════════════════════════════════════
PORT="$(python3 -c 'import socket
s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
SOCK_PORT="$(python3 -c 'import socket
s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
CLIENT_CONF="${SANDBOX}/client.json"
INSTALL_LOG="${SANDBOX}/install.log"

run_installer() {
  env -i \
    PATH="${MOCKBIN}:/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin" \
    HOME="$SANDBOX" TMPDIR="$SANDBOX" MOCK_LOG="$MOCK_LOG" \
    XRAY_INIT_OVERRIDE=systemd \
    XRAY_BIN="${BIN}/xray" XRAY_DAT="$DATDIR" XRAY_CONF_DIR="$CONFDIR" \
    XRAY_LOG_DIR="$LOGDIR" \
    SYSCTL_FILE="${SANDBOX}/etc/sysctl.d/bbr.conf" \
    MODULES_LOAD_DIR="${SANDBOX}/etc/modules-load.d" \
    UNIT_FILE="${SYSDIR}/xray.service" UNIT_DIR="${SYSDIR}/xray.service.d" \
    HELPER_BIN="${BIN}/xctl" \
    XRAY_DL_BASE="http://127.0.0.1:${HTTP_PORT}/" XRAY_LATEST_TAG="$TAG" \
    bash "$SCRIPT" "$@"
}

echo "▶ 运行安装脚本生成配置（模式 ${E2E_MODE:-plain}，端口 ${PORT}，伪装目标 ${TARGET}）"
# shellcheck disable=SC2086
if run_installer --port "$PORT" --sni "$TARGET" --client-config "$CLIENT_CONF" \
     $MODE_ARGS > "$INSTALL_LOG" 2>&1; then
  echo '  安装流程 ok'
else
  echo '  ❌ 安装流程失败：'; tail -20 "$INSTALL_LOG" | sed 's/^/    /'; exit 1
fi
[[ -f "$CONFDIR/config.json" ]] || { echo '❌ 未生成服务端配置'; exit 1; }
[[ -f "$CLIENT_CONF" ]]        || { echo '❌ 未生成客户端配置'; exit 1; }

# 服务端监听地址改为回环，客户端地址占位符改为回环 + 本机 SOCKS 端口
jq --argjson p "$PORT" '.inbounds[0].port = $p | .inbounds[0].listen = "127.0.0.1"' \
   "$CONFDIR/config.json" > "${SANDBOX}/server.json"
XPATH="$(jq -r '.inbounds[0].streamSettings.xhttpSettings.path // empty' "$CONFDIR/config.json")"
jq --argjson p "$PORT" --argjson s "$SOCK_PORT" --arg xp "$XPATH" \
   '(.outbounds[] | select(.tag=="proxy") | .settings.address) = "127.0.0.1"
  | (.outbounds[] | select(.tag=="proxy") | .settings.port) = $p
  | (.inbounds[] | select(.protocol=="socks") | .port) = $s
  | (if $xp != "" then (.outbounds[] | select(.tag=="proxy") | .streamSettings.xhttpSettings) = {"path": $xp, "mode": "auto"} else . end)' \
   "$CLIENT_CONF" > "${SANDBOX}/client.run.json"

echo '  服务端与客户端配置已生成'
echo

# ═══════════════════════════════════════════════════════════════════════════
#  启动真实进程
# ═══════════════════════════════════════════════════════════════════════════
printf '▶ 启动服务端进程 … '
XRAY_LOCATION_ASSET="$DATDIR" "$BIN/xray" run -config "${SANDBOX}/server.json" > "${SANDBOX}/server.log" 2>&1 &
SRV_PID=$!
sleep 2
if kill -0 "$SRV_PID" 2>/dev/null; then echo 'ok'; else
  echo '❌ 失败'; cat "${SANDBOX}/server.log" | sed 's/^/    /'; exit 1
fi

printf '▶ 启动客户端进程 … '
XRAY_LOCATION_ASSET="$DATDIR" "$BIN/xray" run -config "${SANDBOX}/client.run.json" > "${SANDBOX}/client.log" 2>&1 &
CLI_PID=$!
sleep 2
if kill -0 "$CLI_PID" 2>/dev/null; then echo 'ok'; else
  echo '❌ 失败'; cat "${SANDBOX}/client.log" | sed 's/^/    /'; exit 1
fi
echo

# ═══════════════════════════════════════════════════════════════════════════
#  通过隧道发起真实 HTTPS 请求
# ═══════════════════════════════════════════════════════════════════════════
echo "▶ 经 SOCKS5 127.0.0.1:${SOCK_PORT} 请求 ${PROBE_URL}"
RESP="$(curl -sS --max-time 30 --socks5-hostname "127.0.0.1:${SOCK_PORT}" \
        "$PROBE_URL" 2>"${SANDBOX}/curl.err")"
CURL_RC=$?
echo
if [[ $CURL_RC -eq 0 && -n "$RESP" ]]; then
  printf '%s\n' "$RESP" | head -8 | sed 's/^/    /'
  echo
  echo '✅ 端到端代理成功：安装脚本产出的配置可真实承载流量'
  kill "$SRV_PID" "$CLI_PID" 2>/dev/null
  exit 0
fi

echo '❌ 端到端代理失败'
echo "curl 退出码：$CURL_RC"
sed 's/^/    /' "${SANDBOX}/curl.err" 2>/dev/null | head -5
echo '--- 服务端日志 ---'; tail -15 "${SANDBOX}/server.log" | sed 's/^/    /'
echo '--- 客户端日志 ---'; tail -15 "${SANDBOX}/client.log" | sed 's/^/    /'
exit 1
