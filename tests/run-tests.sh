#!/usr/bin/env bash
#
# run-tests.sh —— install-xray.sh 的端到端测试
#
# 原理：把所有安装路径指向沙箱，并用包装层伪造「root + Linux + systemd」，
#       驱动真实 xray 二进制跑完整安装流程，再逐项校验产物。
#       配置校验、密钥配对、链接参数都用真实 xray 内核验证，不是文本比对。
#
# 用法：bash tests/run-tests.sh [xray 二进制路径]
#

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${HERE}/../install-xray.sh"
XRAY_REAL="${1:-$(command -v xray || true)}"

PASS=0
FAIL=0
pass()  { printf '  \033[0;32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
fail()  { printf '  \033[0;31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }
head_() { printf '\n\033[1;36m▶ %s\033[0m\n' "$*"; }

# check <描述> <命令...>：退出码必须为 0
check() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi
}
# refute <描述> <命令...>：退出码必须非 0
refute() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then fail "$desc"; else pass "$desc"; fi
}

[[ -n "$XRAY_REAL" && -x "$XRAY_REAL" ]] || {
  echo '需要真实 xray 二进制：bash tests/run-tests.sh /path/to/xray'; exit 2; }
echo "使用 xray 二进制：$XRAY_REAL"
echo "内核版本：$("$XRAY_REAL" version | head -1)"

SANDBOX="$(mktemp -d)"
HTTP_PID=''
cleanup() { [[ -n "$HTTP_PID" ]] && kill "$HTTP_PID" 2>/dev/null; rm -rf "$SANDBOX"; }
trap cleanup EXIT

# ═══════════════════════════════════════════════════════════════════════════
#  沙箱与伪造层
# ═══════════════════════════════════════════════════════════════════════════

BIN="${SANDBOX}/usr/local/bin"
CONFDIR="${SANDBOX}/usr/local/etc/xray"
DATDIR="${SANDBOX}/usr/local/share/xray"
LOGDIR="${SANDBOX}/var/log/xray"
SYSDIR="${SANDBOX}/etc/systemd/system"
SYSCTL="${SANDBOX}/etc/sysctl.d/99-xray-bbr.conf"
MOCKBIN="${SANDBOX}/mockbin"
export MOCK_LOG="${SANDBOX}/mock.log"
mkdir -p "$BIN" "$CONFDIR" "$DATDIR" "$LOGDIR" "$SYSDIR" "$(dirname "$SYSCTL")" "$MOCKBIN"

write_mock() { # write_mock <名字> <内容>
  printf '%s\n' "$2" > "${MOCKBIN}/$1"
  chmod +x "${MOCKBIN}/$1"
}

# 伪造 root
write_mock id '#!/usr/bin/env bash
[[ "${1:-}" == "-u" ]] && { echo 0; exit 0; }
exec /usr/bin/id "$@"'

# 伪造 Linux / x86_64
write_mock uname '#!/usr/bin/env bash
case "${1:-}" in
  -s) echo Linux ;;
  -m) echo x86_64 ;;
  *)  echo Linux ;;
esac'

# 伪造 systemd：记录调用；is-active 依据 MOCK_SVC_STATE 决定退出码
write_mock systemctl '#!/usr/bin/env bash
echo "systemctl $*" >> "${MOCK_LOG}"
if [[ "${1:-}" == "is-active" ]]; then
  [[ "${MOCK_SVC_STATE:-active}" == "active" ]] && exit 0 || exit 3
fi
exit 0'

# 伪造 sysctl：报告支持 BBR
write_mock sysctl '#!/usr/bin/env bash
echo "sysctl $*" >> "${MOCK_LOG}"
case "$*" in
  *available_congestion_control*) echo "reno cubic bbr" ;;
  *-n*net.ipv4.tcp_congestion_control*) echo "bbr" ;;
  *-n*net.core.default_qdisc*) echo "fq" ;;
esac
exit 0'

write_mock modprobe '#!/usr/bin/env bash
exit 0'

# 主机防火墙一律「未启用」，避免污染真实系统
for t in ufw firewall-cmd iptables iptables-save netfilter-persistent; do
  write_mock "$t" "#!/usr/bin/env bash
echo \"$t \$*\" >> \"\${MOCK_LOG}\"
exit 127"
done

# 包管理器：依赖已具备，只需存在
for t in apt-get dnf yum zypper pacman apk; do
  write_mock "$t" '#!/usr/bin/env bash
exit 0'
done

# jq 若宿主存在则透传（生产环境常见），否则脚本会走内核回退分支
JQ_REAL="$(command -v jq || true)"
if [[ -n "$JQ_REAL" ]]; then
  write_mock jq "#!/usr/bin/env bash
exec ${JQ_REAL} \"\$@\""
fi

: > "$MOCK_LOG"

# 统一的运行环境（关键：不暴露真机的 rc-service，避免误判为 OpenRC）
run_installer() {
  env -i \
    PATH="${MOCKBIN}:/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin" \
    HOME="$SANDBOX" \
    TMPDIR="${SANDBOX}" \
    MOCK_LOG="$MOCK_LOG" \
    MOCK_SVC_STATE="${MOCK_SVC_STATE:-active}" \
    XRAY_INIT_OVERRIDE="${INIT_OVERRIDE:-systemd}" \
    XRAY_BIN="${BIN}/xray" \
    XRAY_DAT="$DATDIR" \
    XRAY_CONF_DIR="$CONFDIR" \
    XRAY_LOG_DIR="$LOGDIR" \
    SYSCTL_FILE="$SYSCTL" \
    MODULES_LOAD_DIR="${SANDBOX}/etc/modules-load.d" \
    UNIT_FILE="${SYSDIR}/xray.service" \
    UNIT_DIR="${SYSDIR}/xray.service.d" \
    HELPER_BIN="${BIN}/xctl" \
    XRAY_DL_BASE="http://127.0.0.1:${HTTP_PORT}/" \
    XRAY_LATEST_TAG="${LATEST_TAG:-v26.3.27}" \
    bash "$SCRIPT" "$@"
}

# ═══════════════════════════════════════════════════════════════════════════
#  准备可下载的「Linux」压缩包（内容为真实二进制）
# ═══════════════════════════════════════════════════════════════════════════

TAG='v26.3.27'
STAGE="${SANDBOX}/stage"
mkdir -p "${STAGE}/${TAG}"
cp "$XRAY_REAL" "${STAGE}/${TAG}/xray"

# geoip/geosite 必须是真实数据：桩文件会让含 geoip: 规则的路由校验失败
GEO_BASE="https://github.com/${XRAY_REPO:-XTLS/Xray-core}/releases/download/${TAG}"
fetch_geo() { # fetch_geo <文件名>
  local src="$1" dst="${STAGE}/${TAG}/$1" tmpzip="${SANDBOX}/geo.zip"
  if curl -fsSL --connect-timeout 8 --max-time 120 -o "$tmpzip" "${GEO_BASE}/Xray-linux-64.zip" 2>/dev/null; then
    unzip -oq "$tmpzip" "$src" -d "${STAGE}/${TAG}" 2>/dev/null && [[ -s "$dst" ]] && return 0
  fi
  printf 'stub-not-a-real-database\n' > "$dst"
  return 1
}
GEO_REAL=1
fetch_geo geoip.dat   || GEO_REAL=0
fetch_geo geosite.dat || GEO_REAL=0
if [[ "$GEO_REAL" -eq 1 ]]; then
  echo "已获取真实 geoip.dat / geosite.dat（$(du -h "${STAGE}/${TAG}/geoip.dat" | cut -f1)）"
else
  echo '⚠️  无法获取真实 geoip.dat，含 geoip 规则的配置校验将失败'
fi
rm -f "${SANDBOX}/geo.zip"
( cd "${STAGE}/${TAG}" && zip -q "Xray-linux-64.zip" xray geoip.dat geosite.dat )
SHA="$(shasum -a 256 "${STAGE}/${TAG}/Xray-linux-64.zip" | awk '{print $1}')"
printf 'SHA2-256= %s\n' "$SHA" > "${STAGE}/${TAG}/Xray-linux-64.zip.dgst"

# 用系统分配的空闲端口，避免与残留进程冲突
HTTP_PORT="$(python3 -c 'import socket
s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
( cd "$STAGE" && exec python3 -m http.server "$HTTP_PORT" --bind 127.0.0.1 ) > "${SANDBOX}/http.log" 2>&1 &
HTTP_PID=$!
sleep 1.5

# 确认下载源可用，否则后面所有测试都会因为同一个原因失败
if curl -fsS -o /dev/null "http://127.0.0.1:${HTTP_PORT}/${TAG}/Xray-linux-64.zip"; then
  echo "下载源就绪：http://127.0.0.1:${HTTP_PORT}/${TAG}/Xray-linux-64.zip"
else
  echo '❌ 本地下载源启动失败，测试中止'; cat "${SANDBOX}/http.log"; exit 3
fi

# ═══════════════════════════════════════════════════════════════════════════
head_ '1. 语法与自检'
check 'bash -n install-xray.sh' bash -n "$SCRIPT"
check 'bash -n run-tests.sh'    bash -n "${BASH_SOURCE[0]}"
check '--help 可正常输出'        bash "$SCRIPT" --help
refute '未知参数应报错退出'      bash "$SCRIPT" --definitely-not-a-flag

# ═══════════════════════════════════════════════════════════════════════════
head_ '2. 完整安装（--port 8443 --sni www.microsoft.com --encryption --mldsa65）'
OUT="${SANDBOX}/install.out"
run_installer --port 8443 --sni www.microsoft.com --encryption --mldsa65 > "$OUT" 2>&1
RC=$?
if [[ $RC -eq 0 ]]; then
  pass '安装流程退出码 0'
else
  fail "安装流程退出码 $RC"
  sed 's/^/    /' "$OUT" | tail -30
fi

# 安装必须产出可用配置，否则后面的断言全部无意义 —— 直接中止并打印现场
if [[ ! -f "${CONFDIR}/config.json" ]]; then
  printf '\n\033[0;31m❌ 配置未生成，测试中止。以下为安装输出与临时校验文件：\033[0m\n'
  cat "$OUT"
  for f in "${CONFDIR}"/.config.check.json "${SANDBOX}"/stage/*/.config.check.json; do
    [[ -f "$f" ]] && { echo "--- $f ---"; cat "$f"; }
  done
  exit 4
fi

# ═══════════════════════════════════════════════════════════════════════════
head_ '3. 产物落盘'
check 'xray 可执行文件'          test -x "${BIN}/xray"
check 'geoip.dat'                test -f "${DATDIR}/geoip.dat"
check 'geosite.dat'              test -f "${DATDIR}/geosite.dat"
check 'config.json'              test -f "${CONFDIR}/config.json"
check '.deploy-state'            test -f "${CONFDIR}/.deploy-state"
check 'xctl 快捷命令'            test -x "${BIN}/xctl"
check '脚本自副本'               test -f "${CONFDIR}/install-xray.sh"
refute '临时校验文件已清理'      test -f "${CONFDIR}/.config.check.json"

# ═══════════════════════════════════════════════════════════════════════════
head_ '4. 配置内容（用真实内核校验语义）'
CFG="${CONFDIR}/config.json"
j() { jq -r "$1" "$CFG" 2>/dev/null; }

if [[ -f "$CFG" ]]; then
  check 'jq 可解析 JSON' jq -e . "$CFG"

  if "$XRAY_REAL" run -test -config "$CFG" >/dev/null 2>&1; then
    pass 'xray run -test 校验通过'
  else
    fail 'xray run -test 校验失败'
    "$XRAY_REAL" run -test -config "$CFG" 2>&1 | tail -6 | sed 's/^/    /'
  fi

  [[ "$(j '.inbounds[0].port')" == '8443' ]] \
    && pass '端口 = 8443（命令行覆盖生效）' || fail "端口错误：$(j '.inbounds[0].port')"
  [[ "$(j '.inbounds[0].protocol')" == 'vless' ]] \
    && pass '入站协议 = vless' || fail '入站协议错误'
  [[ "$(j '.inbounds[0].streamSettings.security')" == 'reality' ]] \
    && pass 'security = reality' || fail 'security 错误'
  [[ "$(j '.inbounds[0].streamSettings.network')" == 'tcp' ]] \
    && pass 'network = tcp' || fail 'network 错误'
  [[ "$(j '.inbounds[0].streamSettings.realitySettings.target')" == 'www.microsoft.com:443' ]] \
    && pass 'REALITY target = www.microsoft.com:443' || fail "target 错误：$(j '.inbounds[0].streamSettings.realitySettings.target')"
  [[ "$(j '.inbounds[0].streamSettings.realitySettings.serverNames[0]')" == 'www.microsoft.com' ]] \
    && pass 'serverNames 与 target 一致' || fail 'serverNames 错误'
  [[ "$(j '.inbounds[0].settings.clients[0].flow')" == 'xtls-rprx-vision' ]] \
    && pass 'flow = xtls-rprx-vision' || fail 'flow 错误'
  [[ "$(j '.inbounds[0].sniffing.routeOnly')" == 'true' ]] \
    && pass 'sniffing.routeOnly = true' || fail 'sniffing 配置错误'

  DEC="$(j '.inbounds[0].settings.decryption')"
  if [[ "$DEC" == mlkem768x25519plus.* ]]; then
    pass "VLESS Encryption 已启用（${DEC%%\.*}.…）"
    # 结构：握手.外观.票据有效期[.padding…].认证，最少 4 段
    [[ "$(awk -F. '{print NF}' <<<"$DEC")" -ge 4 ]] \
      && pass 'decryption 分段数 ≥4（合法结构）' || fail "decryption 分段异常：$DEC"
    [[ "$(cut -d. -f2 <<<"$DEC")" =~ ^(native|xorpub|random)$ ]] \
      && pass 'decryption 流量外观字段合法' || fail 'decryption 外观字段非法'
    [[ "$(cut -d. -f3 <<<"$DEC")" =~ ^[0-9]+(-[0-9]+)?s$ ]] \
      && pass 'decryption 票据有效期格式合法' || fail "票据字段非法：$(cut -d. -f3 <<<"$DEC")"
  else
    fail "decryption 未启用 VLESS Encryption：$DEC"
  fi

  [[ -n "$(j '.inbounds[0].streamSettings.realitySettings.mldsa65Seed')" ]] \
    && pass 'mldsa65Seed 已写入' || fail 'mldsa65Seed 缺失'
  check 'privateKey 非空' test -n "$(j '.inbounds[0].streamSettings.realitySettings.privateKey')"
  check 'shortIds 非空'   test -n "$(j '.inbounds[0].streamSettings.realitySettings.shortIds[0]')"

  [[ "$(j '.routing.rules | length')" -ge 2 ]] \
    && pass '路由规则已写入（屏蔽 BT + 内网）' || fail '路由规则缺失'
  [[ "$(j '.outbounds | length')" -ge 2 ]] \
    && pass '出站含 direct + block' || fail '出站配置缺失'

  MODE="$(stat -f '%Lp' "$CFG" 2>/dev/null || stat -c '%a' "$CFG")"
  [[ "$MODE" == '600' ]] && pass 'config.json 权限 600' || fail "config.json 权限为 $MODE"

  # 日志级别不应是 debug（生产环境会拖慢性能）
  [[ "$(j '.log.loglevel')" == 'warning' ]] \
    && pass '日志级别 = warning（性能友好）' || fail '日志级别不是 warning'
else
  fail '配置未生成，跳过全部内容校验'
fi

# ═══════════════════════════════════════════════════════════════════════════
head_ '5. 分享链接正确性'
# 输出里带 ANSI 颜色码，先剥掉再匹配
clean() { sed 's/\x1b\[[0-9;]*m//g' | tr -d '\r'; }
LINK_TEXT="$(clean < "$OUT")"
MAIN="$(grep -m1 '^vless://' <<<"$LINK_TEXT" | tr -d ' ')"
if [[ -n "$MAIN" ]]; then
  pass '已输出 vless:// 主链接'
  for p in \
    'security=reality' 'flow=xtls-rprx-vision' 'fp=chrome' \
    'sni=www.microsoft.com' 'spx=%2F' 'type=tcp' 'pbk=' 'sid=' 'encryption='
  do
    grep -q -- "$p" <<<"$MAIN" && pass "链接含 ${p%%=*}" || fail "链接缺少 $p"
  done
  grep -q '8443' <<<"$MAIN" && pass '链接端口 = 8443' || fail '链接端口错误'

  UUID_CFG="$(j '.inbounds[0].settings.clients[0].id')"
  grep -q "$UUID_CFG" <<<"$MAIN" && pass '链接 UUID 与配置一致' || fail '链接 UUID 不一致'

  # pbk 必须由服务端 privateKey 严格推导得出
  PRIV_CFG="$(j '.inbounds[0].streamSettings.realitySettings.privateKey')"
  PUB_OK="$("$XRAY_REAL" x25519 -i "$PRIV_CFG" | sed -n 's/^Password (PublicKey): //p')"
  grep -q "pbk=${PUB_OK}" <<<"$MAIN" \
    && pass '链接 pbk 与服务端私钥严格配对' || fail "pbk 不匹配（应为 ${PUB_OK}）"

  # shortId 必须与配置一致
  SID_CFG="$(j '.inbounds[0].streamSettings.realitySettings.shortIds[0]')"
  grep -q "sid=${SID_CFG}" <<<"$MAIN" && pass '链接 sid 与配置一致' || fail 'sid 不一致'
else
  fail '未输出 vless:// 链接'
fi

# ═══════════════════════════════════════════════════════════════════════════
head_ '6. 服务单元与内核调优'
UNIT="${SYSDIR}/xray.service"
check 'xray.service 已写入'       test -f "$UNIT"
check '10-xray-tuning.conf 已写入' test -f "${SYSDIR}/xray.service.d/10-xray-tuning.conf"
check 'sysctl BBR 文件已写入'      test -f "$SYSCTL"
grep -q "ExecStart=${BIN}/xray run -config ${CONFDIR}/config.json" "$UNIT" \
  && pass 'ExecStart 指向正确配置文件' || fail 'ExecStart 不正确'
grep -q "Environment=XRAY_LOCATION_ASSET=${DATDIR}" "$UNIT" \
  && pass '已声明 XRAY_LOCATION_ASSET（geoip 规则才不会失效）' || fail '缺少 XRAY_LOCATION_ASSET'
grep -q 'Restart=on-failure' "$UNIT" && pass 'Restart=on-failure' || fail '缺少 Restart'
grep -q 'LimitNOFILE=1000000' "$UNIT" && pass 'LimitNOFILE 已放开' || fail 'LimitNOFILE 未设置'
grep -q 'net.ipv4.tcp_congestion_control = bbr' "$SYSCTL" \
  && pass 'sysctl 含 BBR' || fail 'sysctl 缺 BBR'
grep -q 'fs.file-max' "$SYSCTL" && pass 'sysctl 含文件句柄上限' || fail 'sysctl 不完整'
grep -q 'systemctl start xray' "$MOCK_LOG" && pass '已调用 systemctl start xray' || fail '未启动服务'

# ═══════════════════════════════════════════════════════════════════════════
head_ '7. 重复执行（幂等性与配置沿用）'
OUT2="${SANDBOX}/install2.out"
run_installer > "$OUT2" 2>&1
[[ $? -eq 0 ]] && pass '二次执行成功（无参数）' || { fail '二次执行失败'; tail -15 "$OUT2" | sed 's/^/    /'; }
[[ "$(jq -r '.inbounds[0].port' "$CFG")" == '8443' ]] \
  && pass '二次安装沿用原端口 8443（不打断已有客户端）' || fail "二次安装端口异常：$(jq -r '.inbounds[0].port' "$CFG")"
# 二次安装后新链接必须仍然自洽
OUT2_LINK="$(clean < "$OUT2" | grep -m1 '^vless://' | tr -d ' ')"
PRIV2="$(jq -r '.inbounds[0].streamSettings.realitySettings.privateKey' "$CFG")"
PUB2="$("$XRAY_REAL" x25519 -i "$PRIV2" | sed -n 's/^Password (PublicKey): //p')"
grep -q "pbk=${PUB2}" <<<"$OUT2_LINK" && pass '二次安装链接密钥自洽' || fail '二次安装链接密钥不匹配'

head_ '8. --encryption 在旧版内核下的降级保护'
# 机器上已装的二进制比目标版本新，能力探测会合理地「兜住」，所以把已装版本伪装成更旧
OUT_OLD="${SANDBOX}/old.out"
BIN_BAK="${BIN}/xray.bak"
if [[ -f "${BIN}/xray" ]]; then
  mv "${BIN}/xray" "$BIN_BAK"
  write_mock xray '#!/usr/bin/env bash
[[ "${1:-}" == "version" ]] && { echo "Xray 25.1.1 (fake)"; exit 0; }
exit 1'
  LATEST_TAG='v25.1.1' run_installer --encryption > "$OUT_OLD" 2>&1
  mv "$BIN_BAK" "${BIN}/xray"
  if clean < "$OUT_OLD" | grep -q '不支持 VLESS Encryption'; then
    pass '旧版内核下自动跳过 --encryption 并告警'
  else
    fail '缺少旧版降级告警'
    clean < "$OUT_OLD" | head -20 | sed 's/^/    /'
  fi
else
  fail '前置条件缺失：内核文件不存在'
fi

# 不带 --encryption 时，配置里不应出现任何加密字段（确认降级路径干净）
if [[ -f "$CFG" ]]; then
  grep -q 'mlkem768x25519plus' "$CFG" && fail '未启用加密时仍写入 decryption' \
    || pass '未启用加密时配置不含 VLESS Encryption 字段'
fi

head_ '9. --links 仅打印链接'
OUT3="${SANDBOX}/links.out"
run_installer --links > "$OUT3" 2>&1
clean < "$OUT3" | grep -q '^vless://' && pass '--links 输出链接' || fail '--links 无输出'
clean < "$OUT3" | grep -q "$(jq -r '.inbounds[0].settings.clients[0].id' "$CFG")" \
  && pass '--links 与磁盘配置一致' || fail '--links 与配置不一致'

# ═══════════════════════════════════════════════════════════════════════════
head_ '10. --check 健康检查'
OUT5="${SANDBOX}/check.out"
run_installer --check > "$OUT5" 2>&1
[[ $? -eq 0 ]] && pass '--check 退出码 0' || { fail '--check 失败'; tail -15 "$OUT5" | sed 's/^/    /'; }
CHECK_TXT="$(clean < "$OUT5")"
if grep -q '服务状态：运行中' <<<"$CHECK_TXT"; then
  pass '正确识别 systemd 服务为运行中'
else
  fail '服务状态判定错误'
  printf '%s\n' "$CHECK_TXT" | grep -n '服务状态' | sed 's/^/    /'
  printf '%s\n' "$CHECK_TXT" | sed -n '1,12p' | sed 's/^/    | /'
fi
grep -q '内核版本：' <<<"$CHECK_TXT" && pass '报告内核版本' || fail '未报告内核版本'
grep -q '配置校验：通过' <<<"$CHECK_TXT" && pass '配置校验通过' || fail '配置校验未通过'
grep -q '拥塞控制：bbr' <<<"$CHECK_TXT" && pass '报告 BBR 已开启' || fail '未报告 BBR'
grep -q '本机 → ' <<<"$CHECK_TXT" && pass '实测伪装目标延迟' || fail '未实测延迟'
printf '%s\n' "$CHECK_TXT" | grep -qE '[0-9]+ ms' && pass '延迟以毫秒数值给出' || fail '延迟无数值'

# 服务停止时必须给出警告而不是谎报正常
# 注意：变量赋值前缀不会传入 run_installer 内部的 env -i，必须显式 export
export MOCK_SVC_STATE=stopped
CHECK_STOP="$(run_installer --check 2>&1 | clean)"
export MOCK_SVC_STATE=active
grep -q '服务状态：inactive' <<<"$CHECK_STOP" && pass '服务停止时正确告警' \
  || fail '服务停止时未告警'

# ═══════════════════════════════════════════════════════════════════════════
# 卸载必须放在最后：它会删掉内核，后续用例会因此失去验签能力
head_ '11. 卸载流程'
OUT4="${SANDBOX}/uninstall.out"
run_installer --uninstall > "$OUT4" 2>&1
[[ $? -eq 0 ]] && pass '卸载退出码 0' || { fail '卸载失败'; tail -12 "$OUT4" | sed 's/^/    /'; }
check  '内核文件已删除'   test ! -f "${BIN}/xray"
check  'xctl 已删除'      test ! -f "${BIN}/xctl"
check  '服务单元已删除'   test ! -f "$UNIT"
check  '配置目录已保留'   test -f "$CFG"
check  '已提示彻底清除命令' grep -q 'rm -rf' "$OUT4"

# ═══════════════════════════════════════════════════════════════════════════
head_ '测试结果'
printf '  通过：\033[0;32m%d\033[0m   失败：\033[0;31m%d\033[0m\n\n' "$PASS" "$FAIL"
if [[ "$FAIL" -eq 0 ]]; then echo '✅ 全部通过'; exit 0; else echo '❌ 存在失败项'; exit 1; fi
