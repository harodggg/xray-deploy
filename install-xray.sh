#!/usr/bin/env bash
#
# install-xray.sh — Xray-core 一键部署（最新版 / 最快 / 开箱即用配置）
#
#   协议：VLESS + XTLS-Vision + REALITY（可选叠加 VLESS Encryption 后量子加密）
#   产出：systemd 服务 + 完整 config.json + 客户端分享链接 + BBR 加速
#
# 用法（一行）：
#   bash <(curl -fsSL https://raw.githubusercontent.com/harodggg/xray-deploy/main/install-xray.sh)
#
# 常用参数：
#   --port 8443              监听端口（默认 443）
#   --sni www.amazon.com     REALITY 伪装目标域名（默认自动探测，见 README）
#   --encryption             叠加 VLESS Encryption（后量子加密，需 v26.3.27+ 客户端）
#   --xhttp                  改用 XHTTP + REALITY（抗 QoS 更好）
#   --mldsa65                叠加 REALITY 后量子签名（目标站点证书须 >3500 字节）
#   --no-bbr / --no-firewall 关闭内核调优 / 防火墙放行
#   --client-config <文件>   同时生成配套客户端配置
#   --uninstall              完全卸载
#   --links                  仅打印分享链接
#   --check                  健康检查与延迟实测（判断节点快慢用这个）
#   --update                 升级内核到最新版并保留配置
#
# 支持：Debian/Ubuntu、CentOS/RHEL/Rocky/Alma、Fedora、Arch、Alpine(OpenRC)、openSUSE
#

set -Eeuo pipefail
umask 022

# ═══════════════════════════════════════════════════════════════════════════
#  常量
# ═══════════════════════════════════════════════════════════════════════════

readonly SCRIPT_VERSION='1.0.0'
readonly XRAY_REPO='XTLS/Xray-core'

# 路径：默认遵循 FHS，可用环境变量覆盖（便于测试与自定义部署目录）
readonly XRAY_BIN="${XRAY_BIN:-/usr/local/bin/xray}"
readonly XRAY_DAT="${XRAY_DAT:-/usr/local/share/xray}"
readonly XRAY_CONF_DIR="${XRAY_CONF_DIR:-/usr/local/etc/xray}"
readonly XRAY_CONF="${XRAY_CONF_DIR}/config.json"
readonly XRAY_LOG_DIR="${XRAY_LOG_DIR:-/var/log/xray}"
readonly XRAY_STATE="${XRAY_CONF_DIR}/.deploy-state"
readonly SYSCTL_FILE="${SYSCTL_FILE:-/etc/sysctl.d/99-xray-bbr.conf}"
readonly UNIT_FILE="${UNIT_FILE:-/etc/systemd/system/xray.service}"
readonly UNIT_DIR="${UNIT_DIR:-/etc/systemd/system/xray.service.d}"
readonly UNIT_OVERRIDE="${UNIT_DIR}/10-xray-tuning.conf"
readonly HELPER_BIN="${HELPER_BIN:-/usr/local/bin/xctl}"
readonly SELF_COPY="${XRAY_CONF_DIR}/install-xray.sh"
readonly MIN_VER_FOR_VLESSENC='26.3.27'

# 伪装目标候选池。选定依据（均为实测）：
#   - TLS1.3 + HTTP/2，且 REALITY 隧道能真实承载流量
#   - 「链长」为证书链总字节数，>3500 才能叠加 --mldsa65 后量子签名
readonly -a DEFAULT_TARGETS=(
  'www.amazon.com'      # 4287 字节
  'www.samsung.com'     # 4181 字节
  'www.bing.com'        # 3888 字节
  'www.cloudflare.com'  # 3426 字节，不支持 --mldsa65
)
readonly MLDSA_MIN_CHAIN=3500

# spiderX 路径池：真实站点里常见的路径，避免特征化
readonly -a SPIDER_PATHS=(
  '/'
  '/api/v1/'
  '/static/js/'
  '/assets/'
  '/live/'
  '/blog/'
  '/search?q=1'
  '/news/'
)

# ── 运行期全局变量 ──────────────────────────────────────────────────────────
OPT_PORT=''
OPT_SNI=''
OPT_TARGET=''
OPT_ENC=0
OPT_XHTTP=0
OPT_MLDSA=0
OPT_BBR=1
OPT_FIREWALL=1
ACTION='install'
CLIENT_CONF=''

MACHINE=''
PKG_INSTALL=''
PKG_UPDATE=''
INIT_SYS=''
ARCH_RAW=''

CUR_VER=''
NEW_VER=''
UUID=''
PRIV=''
PUB=''
SID=''
SPIDERX=''
VLESS_DEC=''
VLESS_ENC=''
MLDSA_SEED=''
MLDSA_VERIFY=''
SNI=''
TARGET_SNI=''
PORT=''

# ═══════════════════════════════════════════════════════════════════════════
#  输出
# ═══════════════════════════════════════════════════════════════════════════

if [[ -t 1 ]]; then
  C_R=$'\033[0;31m'; C_G=$'\033[0;32m'; C_Y=$'\033[0;33m'
  C_B=$'\033[0;36m'; C_W=$'\033[1;37m'; C_N=$'\033[0m'
else
  C_R=''; C_G=''; C_Y=''; C_B=''; C_W=''; C_N=''
fi

say()  { printf '%s\n' "$*"; }
info() { printf '%s[信息]%s %s\n' "$C_B" "$C_N" "$*"; }
ok()   { printf '%s[成功]%s %s\n' "$C_G" "$C_N" "$*"; }
warn() { printf '%s[警告]%s %s\n' "$C_Y" "$C_N" "$*" >&2; }
die()  { printf '%s[错误]%s %s\n' "$C_R" "$C_N" "$*" >&2; exit 1; }
step() { printf '\n%s▶ %s%s\n' "$C_W" "$*" "$C_N"; }

banner() {
  printf '%s' "$C_B"
  cat <<'EOF'
  ╔═══════════════════════════════════════════════════════════╗
  ║   Xray-core 一键部署 · VLESS + XTLS-Vision + REALITY      ║
  ║   最新版内核 · BBR 加速 · 自动生成客户端链接               ║
  ╚═══════════════════════════════════════════════════════════╝
EOF
  printf '%s\n' "$C_N"
}

# ═══════════════════════════════════════════════════════════════════════════
#  基础工具
# ═══════════════════════════════════════════════════════════════════════════

curl_retry() { curl -fsSL --retry 5 --retry-delay 3 --retry-max-time 90 \
                     --connect-timeout 10 "$@"; }

have() { command -v "$1" >/dev/null 2>&1; }

rand_hex() { # rand_hex <字节数>
  local n="${1:-8}"
  if have openssl; then
    openssl rand -hex "$n"
  else
    od -An -tx1 -N "$n" /dev/urandom | tr -d ' \n'
  fi
}

pick() { # pick <候选...> —— 随机返回其中一个（兼容 bash 3.2，不用 nameref）
  local -a arr=("$@")
  printf '%s' "${arr[RANDOM % ${#arr[@]}]}"
}

# 版本号比较：ver_gt A B  → A > B
ver_gt() { [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" == "$1" && "$1" != "$2" ]]; }

strip_v() { printf '%s' "${1#v}"; }

# ═══════════════════════════════════════════════════════════════════════════
#  环境检测
# ═══════════════════════════════════════════════════════════════════════════

require_root() {
  [[ "$(id -u)" -eq 0 ]] || die "请以 root 身份运行：sudo -i 后重新执行"
}

detect_init() {
  # 容器/测试环境可强制指定初始化系统（systemd|openrc），跳过运行时探测
  if [[ -n "${XRAY_INIT_OVERRIDE:-}" ]]; then
    INIT_SYS="$XRAY_INIT_OVERRIDE"; return 0
  fi
  if have systemctl && [[ -d /run/systemd/system ]]; then
    INIT_SYS='systemd'
  elif have rc-service || have rc-update; then
    INIT_SYS='openrc'
  else
    die '仅支持 systemd 或 OpenRC（Alpine）的 Linux 发行版'
  fi
}

detect_arch() {
  ARCH_RAW="$(uname -m)"
  case "$ARCH_RAW" in
    x86_64|amd64)        MACHINE='64' ;;
    i386|i686)           MACHINE='32' ;;
    aarch64|arm64|armv8) MACHINE='arm64-v8a' ;;
    armv7l|armv7)        MACHINE='arm32-v7a' ;;
    armv6l)              MACHINE='arm32-v6' ;;
    armv5tel)            MACHINE='arm32-v5' ;;
    mips64)              MACHINE='mips64' ;;
    mips64le)            MACHINE='mips64le' ;;
    mips)                MACHINE='mips32' ;;
    mipsle)              MACHINE='mips32le' ;;
    ppc64)               MACHINE='ppc64' ;;
    ppc64le)             MACHINE='ppc64le' ;;
    riscv64)             MACHINE='riscv64' ;;
    s390x)               MACHINE='s390x' ;;
    *) die "不支持的 CPU 架构：${ARCH_RAW}" ;;
  esac
  info "系统架构：${ARCH_RAW} → Xray-linux-${MACHINE}"
}

detect_pkg() {
  if   have apt-get; then PKG_INSTALL='apt-get install -y --no-install-recommends'; PKG_UPDATE='apt-get update -qq'
  elif have dnf;     then PKG_INSTALL='dnf install -y';                             PKG_UPDATE='dnf makecache -q'
  elif have yum;     then PKG_INSTALL='yum install -y';                             PKG_UPDATE='yum makecache -q'
  elif have zypper;  then PKG_INSTALL='zypper install -y --no-recommends';          PKG_UPDATE='zypper refresh'
  elif have pacman;  then PKG_INSTALL='pacman -Sy --noconfirm';                     PKG_UPDATE='true'
  elif have apk;     then PKG_INSTALL='apk add --no-cache';                          PKG_UPDATE='apk update -q'
  else PKG_INSTALL=''; PKG_UPDATE=''
  fi
}

need_pkg() { # need_pkg <命令> <包名>
  have "$1" && return 0
  [[ -n "$PKG_INSTALL" ]] || die "缺少命令 $1，且无法识别包管理器，请手动安装"
  info "安装依赖：$2"
  $PKG_UPDATE >/dev/null 2>&1 || true
  $PKG_INSTALL "$2" >/dev/null 2>&1 || die "依赖 $2 安装失败，请检查网络"
}

preflight() {
  step '环境检查'
  [[ "$(uname -s)" == 'Linux' ]] || die '本脚本仅支持 Linux'
  detect_init
  detect_arch
  detect_pkg
  need_pkg curl curl
  need_pkg unzip unzip
  ok "初始化系统：${INIT_SYS}｜包管理器：${PKG_INSTALL%% *}"
}

# ═══════════════════════════════════════════════════════════════════════════
#  参数解析
# ═══════════════════════════════════════════════════════════════════════════

usage() {
  sed -n '3,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 0
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --port)       PORT="${2:-}"; shift 2 ;;
      --sni)        SNI="${2:-}";  TARGET_SNI="${2:-}"; shift 2 ;;
      --target)     TARGET_SNI="${2:-}"; shift 2 ;;
      --encryption) OPT_ENC=1; shift ;;
      --xhttp)      OPT_XHTTP=1; shift ;;
      --mldsa65)    OPT_MLDSA=1; shift ;;
      --no-bbr)     OPT_BBR=0; shift ;;
      --no-firewall) OPT_FIREWALL=0; shift ;;
      --uninstall)  ACTION='uninstall'; shift ;;
      --client-config) CLIENT_CONF="${2:-}"; [[ -n "$CLIENT_CONF" ]] || die '--client-config 需要指定文件路径'; shift 2 ;;
      --links)      ACTION='links'; shift ;;
      --check)      ACTION='check'; shift ;;
      --update)     ACTION='update'; shift ;;
      -h|--help)    usage ;;
      *) die "未知参数：$1（用 --help 查看用法）" ;;
    esac
  done
  if [[ -n "$PORT" ]]; then
    [[ "$PORT" =~ ^[0-9]+$ ]] || die "--port 必须是数字，例如 --port 8443"
    if [[ "$PORT" -lt 1 || "$PORT" -gt 65535 ]]; then
      die "--port 取值范围 1-65535，收到：${PORT}"
    fi
    if [[ "$PORT" -lt 1024 && "$(id -u)" -ne 0 ]]; then
      die "端口 ${PORT} 属于特权端口，需要 root 权限"
    fi
  fi
  if [[ -n "$TARGET_SNI" ]]; then
    # 允许域名或 IP；拒绝把 URL / 带端口 / 带路径的值误传进来
    if [[ "$TARGET_SNI" == *'://'* || "$TARGET_SNI" == */* || "$TARGET_SNI" == *:* ]]; then
      die "--sni 只接受域名或 IP（不要带协议、路径或端口），例如 --sni www.amazon.com"
    fi
    [[ "$TARGET_SNI" =~ ^[A-Za-z0-9._-]+$ ]] || die "--sni 含非法字符：${TARGET_SNI}"
  fi
  if [[ -n "$CLIENT_CONF" ]]; then
    local cdir; cdir="$(dirname "$CLIENT_CONF")"
    [[ -d "$cdir" ]] || die "--client-config 的目录不存在：${cdir}"
  fi
}

# ═══════════════════════════════════════════════════════════════════════════
#  版本处理
# ═══════════════════════════════════════════════════════════════════════════

current_version() {
  if [[ -x "$XRAY_BIN" ]]; then
    "$XRAY_BIN" version 2>/dev/null | head -n1 | awk '{print $2}'
  fi
}

latest_version() {
  # 允许手动指定（测试或锁定版本）
  if [[ -n "${XRAY_LATEST_TAG:-}" ]]; then printf '%s' "$XRAY_LATEST_TAG"; return 0; fi
  local api="https://api.github.com/repos/${XRAY_REPO}/releases/latest" tag
  tag="$(curl_retry -H 'Accept: application/vnd.github+json' "$api" \
          | grep -m1 '"tag_name"' | cut -d'"' -f4)" || true
  if [[ -z "$tag" ]]; then
    # API 限流时回退到 releases/latest 的 302 跳转
    tag="$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
            "https://github.com/${XRAY_REPO}/releases/latest" 2>/dev/null | sed 's#.*/tag/##')" || true
  fi
  [[ -n "$tag" && "$tag" != *'/releases/latest'* ]] || die '无法获取 Xray 最新版本号，请检查网络'
  printf '%s' "$tag"
}

# ═══════════════════════════════════════════════════════════════════════════
#  下载安装内核
# ═══════════════════════════════════════════════════════════════════════════

install_core() { # install_core <版本tag>
  local ver="$1" url tmp zip sha_expect sha_real
  url="${XRAY_DL_BASE:-https://github.com/${XRAY_REPO}/releases/download}/${ver}/Xray-linux-${MACHINE}.zip"
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN
  zip="${tmp}/xray.zip"

  step "下载 Xray ${ver}（${MACHINE}）"
  info "$url"
  curl_retry -o "$zip" "$url" || die '内核下载失败：请检查网络，或使用 --proxy/v2ray 类中转后重试'

  # SHA256 校验（官方 .dgst 文件）
  if curl_retry -o "${zip}.dgst" "${url}.dgst" 2>/dev/null; then
    sha_expect="$(awk -F'= ' '/256=/{print $2}' "${zip}.dgst" | tr -d ' \r\n')"
    if have sha256sum; then sha_real="$(sha256sum "$zip" | awk '{print $1}')"
    else sha_real="$(shasum -a 256 "$zip" | awk '{print $1}')"; fi
    if [[ -n "$sha_expect" && "$sha_expect" != "$sha_real" ]]; then
      die "SHA256 校验失败（期望 ${sha_expect:0:16}… 实际 ${sha_real:0:16}…）"
    fi
    ok 'SHA256 校验通过'
  else
    warn '未取到官方校验文件，跳过 SHA256 校验'
  fi

  unzip -oq "$zip" -d "$tmp" || die '解压失败：安装包可能已损坏'
  [[ -f "${tmp}/xray" ]] || die '压缩包中未找到 xray 可执行文件'

  install -m 0755 "${tmp}/xray" "$XRAY_BIN"
  install -d -m 0755 "$XRAY_DAT"
  [[ -f "${tmp}/geoip.dat"   ]] && install -m 0644 "${tmp}/geoip.dat"   "$XRAY_DAT/"
  [[ -f "${tmp}/geosite.dat" ]] && install -m 0644 "${tmp}/geosite.dat" "$XRAY_DAT/"
  ok "已安装到 ${XRAY_BIN}"
}

# ═══════════════════════════════════════════════════════════════════════════
#  密钥与配置生成
# ═══════════════════════════════════════════════════════════════════════════

# 在下载之前先确定内核是否支持 VLESS Encryption，避免白下载一个不支持该特性的版本
check_encryption_support() {
  # XHTTP 模式下 Vision 流控依赖 VLESS Encryption，自动启用
  if [[ "$OPT_XHTTP" -eq 1 && "$OPT_ENC" -eq 0 ]]; then
    OPT_ENC=1
    info '--xhttp 需要 VLESS Encryption 配合 Vision 流控，已自动启用'
  fi
  [[ "$OPT_ENC" -eq 1 ]] || return 0
  local ver; ver="$(strip_v "$NEW_VER")"
  if ver_gt "$ver" "26.3.26"; then
    return 0
  fi
  # 容错：内核已装但版本探测失败时，直接问二进制自己认不认这个子命令
  if [[ -x "$XRAY_BIN" ]] && "$XRAY_BIN" help vlessenc >/dev/null 2>&1; then
    return 0
  fi
  warn "内核 ${NEW_VER} 不支持 VLESS Encryption（需 ≥ v${MIN_VER_FOR_VLESSENC}），已自动跳过 --encryption"
  OPT_ENC=0
}

gen_credentials() {
  step '生成密钥与凭据'

  UUID="$("$XRAY_BIN" uuid)"
  info "UUID：${UUID}"

  # xray x25519 输出形如：
  #   PrivateKey: <base64url>
  #   Password (PublicKey): <base64url>
  #   Hash32: <base64url>
  local out
  out="$("$XRAY_BIN" x25519)"
  PRIV="$(printf '%s\n' "$out" | sed -n 's/^PrivateKey: //p' | head -n1)"
  PUB="$(printf '%s\n' "$out"  | sed -n 's/^Password (PublicKey): //p' | head -n1)"
  [[ -n "$PRIV" && -n "$PUB" ]] || die 'X25519 密钥生成失败'
  ok 'REALITY X25519 密钥对已生成'

  SID="$(rand_hex 8)"
  SPIDERX="$(pick "${SPIDER_PATHS[@]}")"
  info "shortId：${SID}"

  # ── 可选的 VLESS Encryption（后量子）──────────────────────────────────
  VLESS_DEC='none'
  if [[ "$OPT_ENC" -eq 1 ]]; then
    # 版本能力已在 check_encryption_support 里提前校验过
    local vout
    vout="$("$XRAY_BIN" vlessenc)"
    VLESS_DEC="$(printf '%s\n' "$vout" | grep -A2 'ML-KEM-768' | sed -n 's/.*"decryption": "\([^"]*\)".*/\1/p' | head -n1)"
    VLESS_ENC="$(printf '%s\n' "$vout" | grep -A2 'ML-KEM-768' | sed -n 's/.*"encryption": "\([^"]*\)".*/\1/p' | head -n1)"
    if [[ -z "$VLESS_DEC" ]]; then
      warn '未能解析 vlessenc 输出，已自动跳过 --encryption'
      OPT_ENC=0; VLESS_DEC='none'
    else
      ok 'VLESS Encryption（ML-KEM-768 后量子）已启用'
    fi
  fi

  # ── 可选的 REALITY 后量子签名 ─────────────────────────────────────────
  if [[ "$OPT_MLDSA" -eq 1 ]]; then
    local mout
    mout="$("$XRAY_BIN" mldsa65 2>/dev/null || true)"
    MLDSA_SEED="$(printf '%s\n' "$mout"   | sed -n 's/^Seed: //p'   | head -n1)"
    MLDSA_VERIFY="$(printf '%s\n' "$mout" | sed -n 's/^Verify: //p' | head -n1)"
    if [[ -z "$MLDSA_SEED" ]]; then
      warn 'mldsa65 密钥生成失败（内核版本过旧？），已跳过'
      OPT_MLDSA=0
    else
      ok 'REALITY 后量子签名（ML-DSA-65）已启用'
    fi
  fi
}

# 空闲端口探测（避免与既有服务冲突）
free_port() {
  if have python3; then
    python3 -c 'import socket
s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()' 2>/dev/null && return 0
  fi
  local p
  for p in 20000 21001 22002 23003 24004 25005; do
    if ! (echo > "/dev/tcp/127.0.0.1/$p") 2>/dev/null; then printf '%s' "$p"; return 0; fi
  done
  return 1
}

wait_tcp() { # wait_tcp <端口> <秒数>
  local port="$1" limit="${2:-6}" i=0
  while [[ "$i" -lt $((limit * 10)) ]]; do
    if (echo > "/dev/tcp/127.0.0.1/${port}") 2>/dev/null; then return 0; fi
    sleep 0.1; i=$((i + 1))
  done
  return 1
}

# 端到端自检：临时起一套 REALITY 服务端+客户端，确认该目标站点真的能承载隧道。
# 这一步能排除「TLS1.3/h2 都正常、但 REALITY 握手失败」的目标（实测确实存在）。
reality_probe() { # reality_probe <目标域名>
  local target="$1"
  local sp lp uuid priv pub sid rdir
  sp="$(free_port)" || return 1
  lp="$(free_port)" || return 1
  [[ "$sp" != "$lp" ]] || return 1

  uuid="$("$XRAY_BIN" uuid 2>/dev/null)" || return 1
  local keys
  keys="$("$XRAY_BIN" x25519 2>/dev/null)" || return 1
  priv="$(printf '%s\n' "$keys" | sed -n 's/^PrivateKey: //p')"
  pub="$(printf '%s\n' "$keys" | sed -n 's/^Password (PublicKey): //p')"
  sid="$(rand_hex 8)"
  [[ -n "$priv" && -n "$pub" ]] || return 1

  rdir="$(mktemp -d)"
  cat > "${rdir}/s.json" <<EOF
{ "log": { "loglevel": "error" },
  "inbounds": [{ "listen": "127.0.0.1", "port": ${lp}, "protocol": "vless",
    "settings": { "clients": [{ "id": "${uuid}", "flow": "xtls-rprx-vision" }],
                  "decryption": "none", "fallbacks": [] },
    "streamSettings": { "network": "tcp", "security": "reality",
      "realitySettings": { "show": false, "target": "${target}:443", "xver": 0,
        "serverNames": [ "${target}" ], "privateKey": "${priv}", "shortIds": [ "${sid}" ] } } }],
  "outbounds": [{ "protocol": "freedom" }] }
EOF
  cat > "${rdir}/c.json" <<EOF
{ "log": { "loglevel": "error" },
  "inbounds": [{ "listen": "127.0.0.1", "port": ${sp}, "protocol": "socks",
                 "settings": { "udp": false, "auth": "noauth" } }],
  "outbounds": [{ "tag": "proxy", "protocol": "vless",
    "settings": { "address": "127.0.0.1", "port": ${lp}, "id": "${uuid}",
                  "encryption": "none", "flow": "xtls-rprx-vision" },
    "streamSettings": { "network": "tcp", "security": "reality",
      "realitySettings": { "fingerprint": "chrome", "serverName": "${target}",
        "publicKey": "${pub}", "shortId": "${sid}", "spiderX": "/" } } }] }
EOF

  XRAY_LOCATION_ASSET="$XRAY_DAT" "$XRAY_BIN" run -config "${rdir}/s.json" \
      > "${rdir}/s.log" 2>&1 &
  local spid=$!
  XRAY_LOCATION_ASSET="$XRAY_DAT" "$XRAY_BIN" run -config "${rdir}/c.json" \
      > "${rdir}/c.log" 2>&1 &
  local cpid=$!

  local rc=1
  if wait_tcp "$sp" 6; then
    # 只验证握手是否被打通：拿得到任何 HTTP 响应头即视为隧道可用
    if curl -sS -o /dev/null -m 20 -w '%{http_code}' \
         --socks5-hostname "127.0.0.1:${sp}" "https://${target}/" 2>/dev/null | grep -qE '^[1-5][0-9][0-9]$'; then
      rc=0
    fi
  fi

  kill "$spid" "$cpid" 2>/dev/null
  wait "$spid" "$cpid" 2>/dev/null
  rm -rf "$rdir"
  return $rc
}

# 探测目标站点的证书链总长度（REALITY 的 dest 需要 TLS1.3 + h2）
cert_chain_len() {
  local host="$1" out
  out="$("$XRAY_BIN" tls ping "$host" 2>&1 || true)"
  printf '%s\n' "$out" | sed -n "s/.*Certificate chain's total length: *\([0-9]*\).*/\1/p" | head -n1
}

choose_target() {
  step '选择 REALITY 伪装目标'
  local t len
  if [[ -n "$TARGET_SNI" ]]; then
    SNI="$TARGET_SNI"
    len="$(cert_chain_len "$SNI")"
    if [[ -n "$len" ]]; then
      info "使用指定目标：${SNI}（证书链 ${len} 字节）"
    else
      warn "使用指定目标：${SNI}（未能探测证书链长度）"
    fi
    if reality_probe "$SNI"; then
      ok '该目标 REALITY 隧道自检通过'
    else
      warn "该目标 REALITY 隧道自检未通过，节点可能无法连接；建议换 --sni（如 www.amazon.com）"
    fi
    return 0
  fi
  # 逐个实测：证书链长度 + REALITY 隧道可用性
  local fallback='' fallback_len=''
  for t in "${DEFAULT_TARGETS[@]}"; do
    len="$(cert_chain_len "$t")"
    if [[ -z "$len" ]]; then
      info "跳过 ${t}（无法探测 TLS 信息）"
      continue
    fi
    if [[ "$len" -gt "$MLDSA_MIN_CHAIN" ]] && reality_probe "$t"; then
      SNI="$t"
      ok "自动选定伪装目标：${SNI}（证书链 ${len} 字节，隧道自检通过，支持 --mldsa65）"
      return 0
    fi
    if [[ -z "$fallback" ]]; then fallback="$t"; fallback_len="$len"; fi
  done
  # 没有「链长够大」的可用目标时，退而求其次选一个隧道可用的
  for t in "${DEFAULT_TARGETS[@]}"; do
    if reality_probe "$t"; then
      SNI="$t"
      warn "已选定 ${SNI}（隧道自检通过，但证书链 ≤${MLDSA_MIN_CHAIN} 字节，无法配合 --mldsa65）"
      return 0
    fi
  done
  if [[ -n "$fallback" ]]; then
    SNI="$fallback"
    warn "隧道自检均未通过，仍选用 ${SNI}（${fallback_len} 字节）；如节点不通请改用 --sni 指定其他目标"
  else
    SNI="${DEFAULT_TARGETS[0]}"
    warn "全部探测失败，使用默认目标：${SNI}"
  fi
}

# validate_fragment <名字> <对象内容>
# 内容不带花括号，函数内部会补上并追加一个哨兵键，再做严格 JSON 解析。
# 追加哨兵键意味着「最后一项必须带逗号」——这正是最容易写出非法 JSON 的地方。
validate_fragment() {
  local name="$1" body="$2" tmp="${XRAY_CONF_DIR}/.frag.check.json"
  printf '{%s\n"_sentinel_": 0}' "$body" > "$tmp" 2>/dev/null || return 0

  if have jq; then
    if jq -e . "$tmp" >/dev/null 2>&1; then rm -f "$tmp"; return 0; fi
  else
    # 无 jq 时借内核的 JSON 解析器：它只报语法错，不会因字段名陌生而误判
    if ! XRAY_LOCATION_ASSET="$XRAY_DAT" "$XRAY_BIN" run -test -config "$tmp" 2>&1 \
         | grep -q 'failed to decode config'; then
      rm -f "$tmp"; return 0
    fi
  fi

  say '' >&2
  XRAY_LOCATION_ASSET="$XRAY_DAT" "$XRAY_BIN" run -test -config "$tmp" 2>&1 | tail -n 3 >&2 || true
  rm -f "$tmp"
  die "内部错误：配置片段 ${name} 不是合法 JSON，已中止（这是脚本 Bug，请反馈）"
}

# ML-DSA-65 会显著增大 REALITY 临时证书，因此要求目标站点证书链 >3500 字节：
# 否则伪装特征不一致，且实测会导致隧道建不起来（客户端 TLS 握手失败）
check_mldsa65_feasibility() {
  [[ "$OPT_MLDSA" -eq 1 ]] || return 0
  local len; len="$(cert_chain_len "$SNI")"
  if [[ -z "$len" ]]; then
    warn "无法探测 ${SNI} 的证书链长度，跳过 --mldsa65 的可行性检查"
    return 0
  fi
  if [[ "$len" -gt "$MLDSA_MIN_CHAIN" ]]; then
    info "目标 ${SNI} 证书链 ${len} 字节，满足 --mldsa65 要求"
    return 0
  fi
  if [[ "${MLDSA_FORCE:-0}" == '1' ]]; then
    warn "目标 ${SNI} 证书链仅 ${len} 字节（建议 >${MLDSA_MIN_CHAIN}），因设置 MLDSA_FORCE=1 继续"
    return 0
  fi
  warn "目标 ${SNI} 证书链仅 ${len} 字节，不足以承载 ML-DSA-65 签名（需 >${MLDSA_MIN_CHAIN} 字节）"
  warn '继续使用会导致客户端 TLS 握手失败，已自动关闭 --mldsa65'
  warn "可用 --sni www.amazon.com（4287 字节）或 www.samsung.com（4181 字节），或设 MLDSA_FORCE=1 强制启用"
  OPT_MLDSA=0
}

write_config() {
  step '写入服务端配置'
  install -d -m 0755 "$XRAY_CONF_DIR"
  install -d -m 0755 "$XRAY_LOG_DIR"

  local network='tcp' security='reality' flow='xtls-rprx-vision'
  if [[ "$OPT_XHTTP" -eq 1 ]]; then
    network='xhttp'
    # XHTTP 下 Vision 依赖 VLESS Encryption 顶替传输层 TLS，必须同时启用
    [[ "$OPT_ENC" -eq 1 ]] || die '内部错误：XHTTP 模式必须先启用 VLESS Encryption'
  fi

  # VLESS Encryption 与 XTLS Vision 可叠加；XHTTP 下 Vision 依赖 VLESS Encryption
  # 注意：内核禁止 fallbacks 与 decryption 同时出现，所以启用加密时不写 fallbacks
  # 每个可选片段都自带尾随逗号，为空时不留悬空逗号（这是最容易写出非法 JSON 的地方）
  local dec_json enc_json fallbacks_line
  if [[ "$OPT_ENC" -eq 1 ]]; then
    dec_json="\"decryption\": \"${VLESS_DEC}\","
    enc_json="\"encryption\": \"${VLESS_ENC}\","
    fallbacks_line=''                       # 禁止与 decryption 同时出现
  else
    dec_json='"decryption": "none",'
    enc_json=''
    fallbacks_line='"fallbacks": [],'
  fi

  local mldsa_json=''
  [[ "$OPT_MLDSA" -eq 1 ]] && mldsa_json="\"mldsa65Seed\": \"${MLDSA_SEED}\","

  local xhttp_json=''
  if [[ "$OPT_XHTTP" -eq 1 ]]; then
    XHTTP_PATH="/$(rand_hex 6)"
    xhttp_json='"xhttpSettings": { "path": "'"${XHTTP_PATH}"'", "mode": "auto" },'
  else
    XHTTP_PATH=''
  fi

  # 每个含可选片段的块都校验一次：能精确指出是哪个字段写坏了
  # 注意：这些片段是「对象内容」（不含最外层花括号），用哨兵键逼出尾随逗号问题
  validate_fragment 'settings'        "\
        \"clients\": [
          { \"id\": \"${UUID}\", \"flow\": \"${flow}\", \"email\": \"default\" }
        ],
        ${dec_json}
        ${enc_json}
        ${fallbacks_line}
        \"_\": 0,"
  validate_fragment 'realitySettings' "\
          \"show\": false,
          \"target\": \"${SNI}:443\",
          \"xver\": 0,
          \"serverNames\": [ \"${SNI}\" ],
          \"privateKey\": \"${PRIV}\",
          \"shortIds\": [ \"${SID}\" ],
          ${mldsa_json}
          \"_\": 0,"
  validate_fragment 'streamSettings'  "\
        \"network\": \"${network}\",
        \"security\": \"${security}\",
        ${xhttp_json}
        \"_\": 0,"

  # 语法校验：通过才落盘，避免把服务搞挂
  # 注意 1：Xray v26 依据文件扩展名识别配置格式，临时文件必须保留 .json 后缀
  # 注意 2：geoip.dat/geosite.dat 通过 XRAY_LOCATION_ASSET 指定，否则内核会去
  #         可执行文件同级目录盲目查找（官方安装脚本即把 dat 放在 /usr/local/bin）
  local tmp="${XRAY_CONF_DIR}/.config.check.json"
  cat > "$tmp" <<EOF
{
  "log": {
    "loglevel": "warning",
    "access": "${XRAY_LOG_DIR}/access.log",
    "error": "${XRAY_LOG_DIR}/error.log"
  },
  "dns": {
    "servers": [
      { "address": "https://1.1.1.1/dns-query", "skipFallback": true },
      { "address": "https://8.8.8.8/dns-query", "skipFallback": true },
      "localhost"
    ],
    "queryStrategy": "UseIPv4"
  },
  "inbounds": [
    {
      "tag": "vless-in",
      "listen": "0.0.0.0",
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": "${flow}",
            "email": "default"
          }
        ],
        ${dec_json}
        ${enc_json}
        ${fallbacks_line}
        "_": 0
      },
      "streamSettings": {
        "network": "${network}",
        "security": "${security}",
        ${xhttp_json}
        "realitySettings": {
          "show": false,
          "target": "${SNI}:443",
          "xver": 0,
          "serverNames": [ "${SNI}" ],
          "privateKey": "${PRIV}",
          "shortIds": [ "${SID}" ],
          ${mldsa_json}
          "limitFallbackUpload":   { "afterBytes": 0, "bytesPerSec": 0, "burstBytesPerSec": 0 },
          "limitFallbackDownload": { "afterBytes": 0, "bytesPerSec": 0, "burstBytesPerSec": 0 }
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [ "http", "tls", "quic" ],
        "routeOnly": true
      }
    }
  ],
  "outbounds": [
    { "tag": "direct", "protocol": "freedom", "settings": { "domainStrategy": "UseIPv4v6" } },
    { "tag": "block",  "protocol": "blackhole" }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      { "type": "field", "protocol": [ "bittorrent" ], "outboundTag": "block" },
      { "type": "field", "ip": [ "geoip:private" ], "outboundTag": "block" }
    ]
  },
  "policy": {
    "levels": {
      "0": { "handshake": 3, "connIdle": 180, "uplinkOnly": 1, "downlinkOnly": 1 }
    }
  }
}
EOF

  # 语法校验：通过才落盘，避免把服务搞挂
  if ! XRAY_LOCATION_ASSET="$XRAY_DAT" "$XRAY_BIN" run -test -config "$tmp" >/dev/null 2>&1; then
    say ''
    XRAY_LOCATION_ASSET="$XRAY_DAT" "$XRAY_BIN" run -test -config "$tmp" 2>&1 | tail -n 20 >&2 || true
    rm -f "$tmp"
    die '配置校验未通过，已放弃写入（原配置未被修改）'
  fi

  install -m 0600 "$tmp" "$XRAY_CONF"
  rm -f "$tmp"
  chown 0:0 "$XRAY_CONF" 2>/dev/null || true
  ok "配置已写入 ${XRAY_CONF}（权限 0600）"
}

save_state() {
  local NETWORK_JSON='tcp'
  [[ "$OPT_XHTTP" -eq 1 ]] && NETWORK_JSON='xhttp'
  install -d -m 0755 "$XRAY_CONF_DIR"
  cat > "$XRAY_STATE" <<EOF
# 由 install-xray.sh 生成，供 xctl 与重装/升级使用（请勿手改）
PORT='${PORT}'
SNI='${SNI}'
UUID='${UUID}'
PRIV='${PRIV}'
PUB='${PUB}'
SHORT_ID='${SID}'
SPIDER_X='${SPIDERX}'
VLESS_DECRYPTION='${VLESS_DEC}'
VLESS_ENCRYPTION='${VLESS_ENC}'
MLDSA65_VERIFY='${MLDSA_VERIFY}'
NETWORK='${NETWORK_JSON}'
XHTTP_PATH='${XHTTP_PATH:-}'
INSTALLED_VERSION='${NEW_VER}'
EOF
  chmod 0600 "$XRAY_STATE"
}

load_state() {
  # 只读取白名单字段：状态文件里若混入与脚本同名的变量（如 SCRIPT_VERSION），
  # 直接 source 会因 readonly 冲突而中断部署
  local line key val
  if [[ -f "$XRAY_STATE" ]]; then
    while IFS= read -r line; do
      key="${line%%=*}"
      val="${line#*=}"
      case "$key" in
        PORT|SNI|UUID|PRIV|PUB|SHORT_ID|SPIDER_X|\
        VLESS_DECRYPTION|VLESS_ENCRYPTION|MLDSA65_VERIFY|\
        NETWORK|XHTTP_PATH|INSTALLED_VERSION)
          # 去掉单引号包裹（状态文件里是 shell 字面量写法）
          val="${val#\'}"; val="${val%\'}"
          printf -v "$key" '%s' "$val"
          ;;
      esac
    done < "$XRAY_STATE"
  fi
  PORT="${PORT:-443}"
  SNI="${SNI:-www.cloudflare.com}"
  NETWORK="${NETWORK:-tcp}"
}

# ═══════════════════════════════════════════════════════════════════════════
#  服务与系统调优
# ═══════════════════════════════════════════════════════════════════════════

install_service() {
  step '配置系统服务'

  if [[ "$INIT_SYS" == 'systemd' ]]; then
    # 显式声明 dat 资源目录：内核找不到 asset 时会导致含 geoip 的路由规则整体失效
    cat > "$UNIT_FILE" <<EOF
[Unit]
Description=Xray Service
Documentation=https://github.com/XTLS/Xray-core
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
Environment=XRAY_LOCATION_ASSET=${XRAY_DAT}
ExecStart=${XRAY_BIN} run -config ${XRAY_CONF}
Restart=on-failure
RestartSec=2
RestartPreventExitStatus=23
LimitNPROC=1000000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF

    install -d -m 0755 "$UNIT_DIR"
    cat > "$UNIT_OVERRIDE" <<'EOF'
# 性能相关调优，由 install-xray.sh 生成
[Service]
LimitNOFILE=1048576
LimitNPROC=1048576
Environment=GOMAXPROCS=0
EOF

    chmod 0644 "$UNIT_FILE" "$UNIT_OVERRIDE"
    systemctl daemon-reload
    ok 'systemd 服务已安装（xray.service）'
  else
    install -d -m 0755 /etc/conf.d
    cat > /etc/conf.d/xray <<EOF
# Xray OpenRC 配置 —— 由 install-xray.sh 生成
export XRAY_LOCATION_ASSET="${XRAY_DAT}"
EOF
    cat > /etc/init.d/xray <<EOF
#!/sbin/openrc-run
name="xray"
description="Xray Service"
command="${XRAY_BIN}"
command_args="run -config ${XRAY_CONF}"
command_background=true
pidfile="/run/xray.pid"
output_log="${XRAY_LOG_DIR}/openrc.log"
error_log="${XRAY_LOG_DIR}/openrc.log"
respawn_delay=2
respawn_max=0

depend() { need net; after firewall; }
EOF
    chmod 0755 /etc/init.d/xray
    rc-update add xray default >/dev/null 2>&1 || true
    ok 'OpenRC 服务已安装（/etc/init.d/xray）'
  fi
}

svc_start() {
  if [[ "$INIT_SYS" == 'systemd' ]]; then systemctl start xray
  else rc-service xray start; fi
}
svc_stop() {
  if [[ "$INIT_SYS" == 'systemd' ]]; then systemctl stop xray 2>/dev/null || true
  else rc-service xray stop 2>/dev/null || true; fi
}
svc_restart() {
  if [[ "$INIT_SYS" == 'systemd' ]]; then systemctl restart xray
  else rc-service xray restart; fi
}
svc_enable() {
  if [[ "$INIT_SYS" == 'systemd' ]]; then systemctl enable xray >/dev/null 2>&1 || true
  else rc-update add xray default >/dev/null 2>&1 || true; fi
}
svc_active() {
  if [[ "$INIT_SYS" == 'systemd' ]]; then systemctl is-active --quiet xray
  else rc-service xray status >/dev/null 2>&1; fi
}

tune_kernel() {
  [[ "$OPT_BBR" -eq 1 ]] || { info '已跳过 BBR 内核调优'; return 0; }
  step '开启 BBR 与 TCP 加速'

  modprobe tcp_bbr 2>/dev/null || true
  # 把模块写进开机加载（部分云主机内核未内置）
  local MODULES_DIR="${MODULES_LOAD_DIR:-/etc/modules-load.d}"
  if install -d -m 0755 "$MODULES_DIR" 2>/dev/null; then
    printf 'tcp_bbr\n' > "${MODULES_DIR}/xray-bbr.conf" 2>/dev/null || true
  fi

  local cc_ok=0
  if sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
    cc_ok=1
  fi
  if [[ "$cc_ok" -eq 0 ]]; then
    warn '当前内核不支持 BBR（需 ≥ 4.9），已跳过拥塞控制调优，仅应用缓冲区优化'
  fi

  install -d -m 0755 "$(dirname "$SYSCTL_FILE")" 2>/dev/null || true
  cat > "$SYSCTL_FILE" <<EOF
# Xray 性能调优 —— 由 install-xray.sh 生成
$([[ "$cc_ok" -eq 1 ]] && cat <<'INNER'
# ── 拥塞控制：BBR ──
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
INNER
)
# ── 缓冲区：高带宽高延迟链路（BBR 需要较大发送缓冲）──
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.ipv4.tcp_rmem = 4096 1048576 67108864
net.ipv4.tcp_wmem = 4096 1048576 67108864
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192

# ── 连接队列与并发 ──
net.core.somaxconn = 32768
net.core.netdev_max_backlog = 32768
net.ipv4.tcp_max_syn_backlog = 32768
net.ipv4.tcp_max_tw_buckets = 262144

# ── 快速回收 / 复用 ──
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fastopen = 3

# ── 空闲长连接保活（代理场景很关键）──
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5

# ── 端口范围 ──
net.ipv4.ip_local_port_range = 10240 65000

# ── 文件句柄 ──
fs.file-max = 1000000
EOF

  sysctl --system >/dev/null 2>&1 || sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1 || true

  local cc now
  cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '未知')"
  now="$(sysctl -n net.core.default_qdisc 2>/dev/null || echo '未知')"
  ok "拥塞控制：${cc}｜队列算法：${now}"
}

open_firewall() {
  [[ "$OPT_FIREWALL" -eq 1 ]] || { info '已跳过防火墙放行'; return 0; }
  step '放行防火墙端口'

  # 云厂商安全组需在控制台单独放行，这里只处理主机防火墙
  if have ufw && ufw status 2>/dev/null | grep -q 'Status: active'; then
    ufw allow "${PORT}/tcp" >/dev/null 2>&1 && ok "ufw 已放行 ${PORT}/tcp"
  elif have firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="${PORT}/tcp" >/dev/null 2>&1
    firewall-cmd --reload >/dev/null 2>&1 && ok "firewalld 已放行 ${PORT}/tcp"
  elif have iptables; then
    if ! iptables -C INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null; then
      iptables -I INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null && \
        ok "iptables 已放行 ${PORT}/tcp（注意：重启后可能失效，建议持久化）"
    else
      info "iptables 规则已存在"
    fi
    if have netfilter-persistent; then netfilter-persistent save >/dev/null 2>&1 || true
    elif [[ -d /etc/iptables ]]; then iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    fi
  else
    info '未检测到启用的主机防火墙，跳过'
  fi
  warn '若为云服务器，请务必在控制台【安全组】中放行该 TCP 端口'
}

install_helper() {
  [[ -f "$SELF_COPY" ]] || return 0
  cat > "$HELPER_BIN" <<EOF
#!/usr/bin/env bash
# xctl —— Xray 部署管理快捷命令（由 install-xray.sh 生成）
exec bash '${SELF_COPY}' "\$@"
EOF
  chmod 0755 "$HELPER_BIN"
  ok '已安装快捷命令：xctl'
}

self_copy() {
  local src="${BASH_SOURCE[0]}"
  [[ -f "$src" ]] || return 0
  install -d -m 0755 "$XRAY_CONF_DIR"
  if [[ "$(readlink -f "$src" 2>/dev/null || printf '%s' "$src")" != "$SELF_COPY" ]]; then
    install -m 0700 "$src" "$SELF_COPY"
  fi
}

# ═══════════════════════════════════════════════════════════════════════════
#  分享链接
# ═══════════════════════════════════════════════════════════════════════════

server_ip() {
  local ip
  ip="$(curl -fsSL --connect-timeout 5 https://api.ipify.org 2>/dev/null || true)"
  [[ -z "$ip" ]] && ip="$(curl -fsSL --connect-timeout 5 https://ifconfig.me 2>/dev/null || true)"
  [[ -z "$ip" ]] && ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')"
  printf '%s' "${ip:-<你的服务器IP>}"
}

# 生成与本服务端严格配套的客户端配置（可选产物，方便本机/路由器直接使用）
write_client_config() {
  local out="$1"
  load_state
  PUB="${PUB:-$("$XRAY_BIN" x25519 -i "$PRIV" 2>/dev/null | sed -n 's/^Password (PublicKey): //p' | head -n1)}"

  local enc_line='' dec_line='' xhttp_line=''
  if [[ -n "${VLESS_ENCRYPTION:-}" && "${VLESS_DECRYPTION:-none}" != 'none' ]]; then
    enc_line="\"encryption\": \"${VLESS_ENCRYPTION}\","
    dec_line="\"decryption\": \"${VLESS_DECRYPTION}\","
  else
    # 未启用 VLESS Encryption 时必须显式写 "none"，缺了内核会拒绝启动
    enc_line='"encryption": "none",'
  fi
  if [[ "${NETWORK:-tcp}" == 'xhttp' ]]; then
    xhttp_line='"xhttpSettings": { "path": "'"${XHTTP_PATH:-/}"'", "mode": "auto" },'
  fi
  local mldsa_line=''
  [[ -n "${MLDSA65_VERIFY:-}" ]] && mldsa_line="\"mldsa65Verify\": \"${MLDSA65_VERIFY}\","

  local tmp="${out}.tmp"
  cat > "$tmp" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "socks-in",
      "listen": "127.0.0.1",
      "port": 10808,
      "protocol": "socks",
      "settings": { "udp": true, "auth": "noauth" },
      "sniffing": {
        "enabled": true,
        "destOverride": [ "http", "tls", "quic" ],
        "routeOnly": true
      }
    },
    {
      "tag": "http-in",
      "listen": "127.0.0.1",
      "port": 10809,
      "protocol": "http"
    }
  ],
  "outbounds": [
    {
      "tag": "proxy",
      "protocol": "vless",
      "settings": {
        "address": "SERVER_ADDRESS",
        "port": ${PORT},
        "id": "${UUID}",
        ${enc_line}
        ${dec_line}
        "flow": "xtls-rprx-vision"
      },
      "streamSettings": {
        "network": "${NETWORK:-tcp}",
        "security": "reality",
        ${xhttp_line}
        "realitySettings": {
          "fingerprint": "chrome",
          "serverName": "${SNI}",
          "publicKey": "${PUB}",
          "shortId": "${SHORT_ID}",
          ${mldsa_line}
          "spiderX": "${SPIDER_X:-/}"
        }
      }
    },
    { "tag": "direct", "protocol": "freedom", "settings": { "domainStrategy": "UseIPv4v6" } },
    { "tag": "block",  "protocol": "blackhole" }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      { "type": "field", "protocol": [ "bittorrent" ], "outboundTag": "block" },
      { "type": "field", "ip": [ "geoip:cn" ], "outboundTag": "direct" },
      { "type": "field", "domain": [ "geosite:cn" ], "outboundTag": "direct" }
    ]
  }
}
EOF
  install -m 0600 "$tmp" "$out"
  rm -f "$tmp"
  ok "客户端配置已生成：${out}"
  warn '记得把里面的 SERVER_ADDRESS 替换为你的服务器地址'
}

# ── 健康检查 ────────────────────────────────────────────────────────────────
# 回答「这个节点快不快、稳不稳」：先看本机状态，再实测到伪装目标的往返延迟
# 与握手耗时，最后给出口径明确的结论。
svc_info() {
  # 注意：systemctl is-active 的 stdout 只是给人看的文本，判定依据是退出码
  if [[ "$INIT_SYS" == 'systemd' ]]; then
    if systemctl is-active --quiet xray 2>/dev/null; then printf 'active'; else printf 'inactive'; fi
  else
    if rc-service xray status >/dev/null 2>&1; then printf 'active'; else printf 'inactive'; fi
  fi
}

tcp_ping() { # tcp_ping <host> <port> —— 用 curl 的建连耗时近似 RTT
  local host="$1" port="$2" i best='' cur
  for i in 1 2 3 4 5; do
    cur="$(curl -sS -o /dev/null -m 8 -w '%{time_connect}' \
            "telnet://${host}:${port}" 2>/dev/null || true)"
    [[ -z "$cur" ]] && continue
    if [[ -z "$best" ]] || awk -v a="$cur" -v b="$best" 'BEGIN{exit !(a<b)}'; then best="$cur"; fi
  done
  [[ -n "$best" ]] && awk -v v="$best" 'BEGIN{printf "%.0f", v*1000}'
}

do_check() {
  banner
  detect_init
  detect_pkg
  load_state
  step '节点健康检查'

  # 1. 本机状态
  local st; st="$(svc_info)"
  if [[ "$st" == 'active' ]]; then ok "服务状态：运行中"
  else warn "服务状态：${st:-未知}（可执行 systemctl restart xray）"; fi

  if [[ -x "$XRAY_BIN" ]]; then
    ok "内核版本：$("$XRAY_BIN" version 2>/dev/null | head -n1 | awk '{print $2}')"
  else
    warn "内核文件缺失：${XRAY_BIN}"; fi

  if [[ -f "$XRAY_CONF" ]]; then
    if XRAY_LOCATION_ASSET="$XRAY_DAT" "$XRAY_BIN" run -test -config "$XRAY_CONF" >/dev/null 2>&1; then
      ok '配置校验：通过'
    else
      warn '配置校验：未通过（执行 xray run -test -config '"$XRAY_CONF"' 查看详情）'
    fi
  else
    warn "配置文件缺失：${XRAY_CONF}"; fi

  local listening=0
  if have ss && ss -lnt 2>/dev/null | grep -q ":${PORT} "; then listening=1
  elif have netstat && netstat -lnt 2>/dev/null | grep -q ":${PORT} "; then listening=1
  elif (echo > "/dev/tcp/127.0.0.1/${PORT}") 2>/dev/null; then listening=1; fi
  if [[ "$listening" -eq 1 ]]; then ok "监听端口 ${PORT}：正常"
  else warn "监听端口 ${PORT}：未监听"; fi

  printf '  端口        : %s\n' "$PORT"
  printf '  伪装目标    : %s\n' "$SNI"
  printf '  传输 / 流控 : %s / xtls-rprx-vision\n' "${NETWORK:-tcp}"
  if [[ "${VLESS_DECRYPTION:-none}" != 'none' && -n "${VLESS_DECRYPTION:-}" ]]; then
    printf '  VLESS 加密  : 已启用（后量子）\n'
  else
    printf '  VLESS 加密  : 未启用\n'
  fi

  # 2. 到伪装目标的延迟（决定首包与握手快慢）
  step '延迟实测'
  local t
  t="$(tcp_ping "$SNI" 443)"
  if [[ -n "$t" ]]; then
    ok "本机 → ${SNI}  TCP 建连：${t} ms"
    if   [[ "$t" -lt 30 ]]; then say '  评价：极佳（同区域机房）'
    elif [[ "$t" -lt 80 ]]; then say '  评价：良好'
    elif [[ "$t" -lt 150 ]]; then say '  评价：一般，握手会偏慢'
    else say '  评价：偏高，建议换离你更近的机房'; fi
  else
    warn "无法连通 ${SNI}:443 —— 伪装目标不可达会导致客户端握手失败，建议更换 --sni"
  fi

  # 3. BBR 与队列算法（决定吞吐上限，尤其跨洋高延迟链路）
  step '内核加速状态'
  local cc qd
  cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '读取失败')"
  qd="$(sysctl -n net.core.default_qdisc 2>/dev/null || echo '读取失败')"
  if [[ "$cc" == 'bbr' ]]; then ok "拥塞控制：bbr"
  else warn "拥塞控制：${cc}（建议开启 BBR：xctl 重跑部署或手工 sysctl）"; fi
  if [[ "$qd" == 'fq' || "$qd" == 'fq_codel' || "$qd" == 'cake' ]]; then ok "队列算法：${qd}"
  else warn "队列算法：${qd}（BBR 建议配 fq）"; fi

  # 4. 服务端出口带宽参考（下载 10MB 测速）
  step '出口带宽参考'
  local dl
  dl="$(curl -sS -o /dev/null -m 25 -w '%{speed_download}' \
        'https://speed.cloudflare.com/__down?bytes=10485760' 2>/dev/null || true)"
  if [[ -n "$dl" ]] && awk -v v="$dl" 'BEGIN{exit !(v>0)}'; then
    awk -v v="$dl" 'BEGIN{printf "  本机下载速度：%.1f MB/s（%.0f Mbps）\n", v/1048576, v*8/1000000}'
    say '  说明：这是机房到测速点的速度，客户端实际速度还取决于你与机房之间的线路'
  else
    warn '测速失败（可能出网受限），跳过'
  fi

  say ''
  say '如需更换更快的伪装目标：'
  say "  bash ${SELF_COPY} --sni <更快的目标域名>"
  say ''
}

print_links() {
  load_state
  PUB="${PUB:-$( "$XRAY_BIN" x25519 -i "$PRIV" 2>/dev/null | sed -n 's/^Password (PublicKey): //p' | head -n1)}"
  local ip enc_param='' flow='xtls-rprx-vision'
  ip="$(server_ip)"

  [[ "$VLESS_DECRYPTION" != 'none' && -n "$VLESS_DECRYPTION" ]] && enc_param="&encryption=${VLESS_ENCRYPTION}"

  local base="vless://${UUID}@${ip}:${PORT}"
  local common="type=${NETWORK}&security=reality&sni=${SNI}&fp=chrome&pbk=${PUB}&sid=${SHORT_ID}&spx=%2F&flow=${flow}"

  step '客户端分享链接（复制即用）'
  say ''
  say "${C_W}【主链接 · VLESS + Vision + REALITY】${C_N}"
  say "${C_G}${base}?${common}${enc_param}#Xray-${ip}${C_N}"
  say ''
  say "${C_W}【备用 · 关闭 XTLS 流控（客户端不兼容时使用）】${C_N}"
  say "${C_Y}${base}?type=${NETWORK}&security=reality&sni=${SNI}&fp=chrome&pbk=${PUB}&sid=${SHORT_ID}&spx=%2F#Xray-${ip}-noflow${C_N}"
  say ''
  say "${C_W}【手动填写参数（任何客户端通用）】${C_N}"
  printf '  地址(Address)   : %s\n' "$ip"
  printf '  端口(Port)      : %s\n' "$PORT"
  printf '  用户ID(UUID)    : %s\n' "$UUID"
  printf '  流控(Flow)      : %s\n' "$flow"
  printf '  传输(Network)   : %s\n' "$NETWORK"
  printf '  安全(Security)  : reality\n'
  printf '  SNI / serverName: %s\n' "$SNI"
  printf '  指纹(Fingerprint): chrome\n'
  printf '  公钥(PublicKey) : %s\n' "$PUB"
  printf '  ShortId         : %s\n' "$SID"
  printf '  spiderX         : /\n'
  if [[ "$VLESS_DECRYPTION" != 'none' && -n "$VLESS_DECRYPTION" ]]; then
    printf '  Encryption      : %s\n' "$VLESS_ENCRYPTION"
    printf '  Decryption      : %s\n' "$VLESS_DECRYPTION"
    say ''
    say "  ${C_Y}注意：本节点启用了 VLESS Encryption，客户端 Xray 内核需 ≥ v${MIN_VER_FOR_VLESSENC}${C_N}"
  fi
  if [[ -n "${MLDSA65_VERIFY:-}" ]]; then
    printf '  mldsa65Verify   : %s\n' "$MLDSA65_VERIFY"
  fi
  say ''
}

# ═══════════════════════════════════════════════════════════════════════════
#  动作
# ═══════════════════════════════════════════════════════════════════════════

do_install() {
  banner
  preflight
  parse_defaults

  NEW_VER="v$(strip_v "$(latest_version)")"
  CUR_VER="$(current_version)"
  if [[ -n "$CUR_VER" ]]; then
    info "当前已安装版本：${CUR_VER}"
  fi
  check_encryption_support

  install_core "$NEW_VER"
  choose_target
  check_mldsa65_feasibility
  gen_credentials
  write_config
  save_state
  self_copy
  install_helper
  install_service
  tune_kernel
  open_firewall

  # 可选产物：配套客户端配置
  [[ -n "$CLIENT_CONF" ]] && write_client_config "$CLIENT_CONF"

  step '启动服务'
  svc_stop
  svc_enable
  svc_start
  sleep 2

  if svc_active; then
    ok "Xray ${NEW_VER} 正在运行"
  else
    warn '服务未能启动，最近日志：'
    if [[ "$INIT_SYS" == 'systemd' ]]; then
      journalctl -u xray -n 25 --no-pager 2>/dev/null | sed 's/^/    /' || true
    else
      tail -n 25 "${XRAY_LOG_DIR}/openrc.log" 2>/dev/null | sed 's/^/    /' || true
    fi
    die '启动失败，请把以上日志反馈给我'
  fi

  print_links
  step '部署完成'
  say "  配置文件：${XRAY_CONF}"
  say "  服务管理：systemctl {status|restart|stop} xray     （Alpine: rc-service xray status）"
  say "  实时日志：journalctl -u xray -f"
  say "  查看链接：xctl --links"
  say "  升级内核：xctl --update"
  say "  完全卸载：xctl --uninstall"
  say ''
}

parse_defaults() {
  # 已部署过则沿用原端口/凭据，避免升级时把已有客户端打断
  if [[ -f "$XRAY_STATE" ]]; then
    local old_port="${PORT}"
    load_state
    [[ -n "$old_port" ]] && PORT="$old_port"
    info "检测到既有部署，沿用端口 ${PORT}"
  fi
  PORT="${PORT:-443}"
}

do_update() {
  banner
  preflight
  load_state
  NEW_VER="v$(strip_v "$(latest_version)")"
  CUR_VER="$(current_version)"
  info "当前版本：${CUR_VER:-未安装} → 目标版本：${NEW_VER}"
  if [[ "$CUR_VER" == "$NEW_VER" ]]; then
    ok '已是最新版本，无需升级'
    exit 0
  fi
  install_core "$NEW_VER"
  "$XRAY_BIN" run -test -config "$XRAY_CONF" >/dev/null 2>&1 || die '现有配置在新内核下校验失败，请先检查配置'
  svc_restart
  sleep 2
  svc_active && ok "已升级到 ${NEW_VER} 并重启服务" || die '升级后服务启动失败'
  sed -i "s/^INSTALLED_VERSION=.*/INSTALLED_VERSION='${NEW_VER}'/" "$XRAY_STATE" 2>/dev/null || true
}

do_uninstall() {
  banner
  require_root
  detect_init
  step '卸载 Xray'
  svc_stop
  if [[ "$INIT_SYS" == 'systemd' ]]; then
    systemctl disable xray >/dev/null 2>&1 || true
  else
    rc-update del xray default >/dev/null 2>&1 || true
  fi
  rm -f "$UNIT_FILE" "$HELPER_BIN" /etc/init.d/xray
  rm -f /etc/conf.d/xray
  rm -rf "$UNIT_DIR"
  rm -f "$SYSCTL_FILE"
  rm -rf "$XRAY_DAT"
  rm -f "$XRAY_BIN"
  [[ "$INIT_SYS" == 'systemd' ]] && systemctl daemon-reload
  say ''
  warn '以下内容已保留（含私钥与配置），如需彻底清除请手动删除：'
  say "  配置与密钥：${XRAY_CONF_DIR}"
  say "  日志目录  ：${XRAY_LOG_DIR}"
  say ''
  info '如需一并删除，执行：'
  say "  rm -rf ${XRAY_CONF_DIR} ${XRAY_LOG_DIR}"
  ok '卸载完成'
}

# ═══════════════════════════════════════════════════════════════════════════
#  入口
# ═══════════════════════════════════════════════════════════════════════════

main() {
  parse_args "$@"
  case "$ACTION" in
    install)   require_root; do_install ;;
    update)    require_root; do_update ;;
    uninstall) require_root; do_uninstall ;;
    links)     require_root; print_links ;;
    check)     require_root; do_check ;;
    *)         die "未知动作：${ACTION}" ;;
  esac
}

# 仅在直接执行时运行；被 source 时只加载函数（便于测试与二次封装）
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
