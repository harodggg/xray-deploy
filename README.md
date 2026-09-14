# Xray 一键部署（Linux · 最新版 · 最快 · 开箱即用配置）

一条命令在 Linux VPS 上部署 **Xray-core 最新版**，自动生成加密强度、性能与隐蔽性都到位的服务端配置，
并直接输出**可复制的客户端分享链接**。

- 内核版本：部署时自动拉取 **官方最新 release**（本文档编写时为 `v26.3.27`）
- 协议栈：**VLESS + XTLS-Vision + REALITY**，可选叠加后量子能力
- 速度：自动开启 **BBR + fq**，并调优 TCP 缓冲区 / 连接队列 / 长连接保活
- 配置：自动生成 UUID、X25519 密钥对、shortId，**生成前用内核自身校验语法**，校验不通过绝不落盘
- 安全：配置与密钥 `0600`，日志 `warning` 级，默认屏蔽 BT 与内网探测

---

## 一、快速开始

### 1. 一键链接

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/harodggg/xray-deploy/main/install-xray.sh)
```

> 仓库需为 **Public**，`raw.githubusercontent.com` 才能取到脚本。
> 若使用私有仓库，请参考文末「发布到自己的仓库」中的自建分发方式。

### 2. 另一种等价写法（先下载再执行，便于审查）

```bash
curl -fsSL -o install-xray.sh https://raw.githubusercontent.com/harodggg/xray-deploy/main/install-xray.sh
less install-xray.sh          # 建议先看一眼
sudo bash install-xray.sh
```

### 3. 部署完成后你会拿到

```
【主链接 · VLESS + Vision + REALITY】
vless://<uuid>@<你的IP>:443?type=tcp&security=reality&sni=www.amazon.com&fp=chrome&pbk=<公钥>&sid=<shortId>&spx=%2F&flow=xtls-rprx-vision#Xray-<你的IP>

【手动填写参数（任何客户端通用）】
  地址(Address)   : 1.2.3.4
  端口(Port)      : 443
  用户ID(UUID)    : xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
  流控(Flow)      : xtls-rprx-vision
  传输(Network)   : tcp
  安全(Security)  : reality
  SNI/serverName  : www.amazon.com
  指纹(Fingerprint): chrome
  公钥(PublicKey) : xxxxxxxx
  ShortId         : xxxxxxxx
  spiderX         : /
```

复制主链接导入客户端即可：**v2rayN / v2rayNG / Nekoray / Shadowrocket / sing-box / Xray 内核客户端**均支持。

---

## 二、参数

| 参数 | 说明 |
| --- | --- |
| `--port <端口>` | 监听端口，默认 `443`。非 443 端口隐蔽性下降，内核也会提示 |
| `--sni <域名>` | REALITY 伪装目标，默认自动探测（见下） |
| `--encryption` | 叠加 **VLESS Encryption**（ML-KEM-768 后量子加密），需客户端内核 ≥ v26.3.27 |
| `--xhttp` | 改用 **XHTTP + REALITY**（抗 QoS 更稳，会自动启用 `--encryption`） |
| `--mldsa65` | 叠加 **REALITY 后量子签名**（ML-DSA-65），要求目标证书链 > 3500 字节 |
| `--client-config <文件>` | 同时生成配套客户端配置（含国内直连分流规则） |
| `--no-bbr` | 不做内核调优 |
| `--no-firewall` | 不自动放行防火墙端口 |
| `--links` | 只打印分享链接（重装/换客户端时用） |
| `--update` | 升级内核到最新版，保留现有配置与端口 |
| `--uninstall` | 卸载（保留配置与密钥，避免误删） |
| `--help` | 查看用法 |

### 常用组合

```bash
# 默认：最省心，兼容性最好
sudo bash install-xray.sh

# 极致隐蔽（推荐）：换端口 + 后量子加密 + 后量子签名
sudo bash install-xray.sh --port 8443 --sni www.amazon.com --encryption --mldsa65

# 抗 QoS 场景
sudo bash install-xray.sh --xhttp

# 同时产出客户端配置，直接丢给路由器/本机用
sudo bash install-xray.sh --client-config /root/client.json
```

---

## 三、REALITY 伪装目标怎么选

REALITY 会借用目标站点的 TLS 外观。目标必须同时满足：

1. 支持 **TLS 1.3 + HTTP/2**；
2. **真实能被 REALITY 借用** —— 这一点光看 TLS 信息判断不出来；
3. 若要用 `--mldsa65`，**证书链总长度 > 3500 字节**（后量子签名会让临时证书变长）。

脚本在选目标时会**真实起一套临时隧道做连通性自检**，只有自检通过才会选用，
不通过会自动换下一个候选，因此不会出现「配置写好了却连不上」。

实测结论（本文档编写时）：

| 目标 | 证书链 | 隧道自检 | 可配 `--mldsa65` |
| --- | --- | --- | --- |
| `www.amazon.com` | 4287 | ✅ | ✅ |
| `www.samsung.com` | 4181 | ✅ | ✅ |
| `www.bing.com` | 3888 | ✅ | ✅ |
| `www.cloudflare.com` | 3426 | ✅ | ❌ 链太短 |
| `www.apple.com` | 3231 | ✅ | ❌ 链太短 |
| `www.microsoft.com` | 5879 | ❌ | — |

> `www.microsoft.com` 的 TLS 信息看起来完全合格（TLS1.3、h2、链长 5879），
> 但实测 REALITY 握手无法承载流量 —— 所以**不要仅凭 TLS 信息选目标**。

你也可以自己探测：

```bash
/usr/local/bin/xray tls ping www.example.com     # 看 TLS 版本、链长、后量子支持

# 换目标后重新出链接（重跑部署，会沿用原端口与其余配置）：
sudo bash install-xray.sh --sni www.example.com
```

> 想重新打印**当前**链接而不改任何东西，用 `xctl --links`（只读，不会重装）。

---

## 四、日常运维

安装时会装一个快捷命令 `xctl`：

```bash
xctl --links                # 重新打印分享链接
xctl --update               # 升级内核（保留配置与端口）
xctl --port 8443 --encryption   # 重新部署（会沿用原端口，除非显式指定）
xctl --uninstall            # 卸载

systemctl status xray       # 服务状态
systemctl restart xray      # 重启
journalctl -u xray -f       # 实时日志
tail -f /var/log/xray/error.log

/usr/local/bin/xray run -test -config /usr/local/etc/xray/config.json   # 校验配置
```

### 文件位置

| 路径 | 内容 |
| --- | --- |
| `/usr/local/bin/xray` | 内核二进制 |
| `/usr/local/etc/xray/config.json` | 服务端配置（`0600`，含私钥） |
| `/usr/local/etc/xray/.deploy-state` | 部署状态（端口、UUID、公钥、shortId 等，`0600`） |
| `/usr/local/etc/xray/install-xray.sh` | 脚本自副本（供 `xctl` 使用，`0700`） |
| `/usr/local/share/xray/` | `geoip.dat` / `geosite.dat` |
| `/var/log/xray/` | 日志 |
| `/etc/sysctl.d/99-xray-bbr.conf` | BBR / TCP 调优 |

---

## 五、客户端配置

`--client-config <文件>` 会产出一份**与服务端严格配套**的客户端配置：

- 本地 SOCKS5 `127.0.0.1:10808`、HTTP `127.0.0.1:10809`
- 需要把里面的 `SERVER_ADDRESS` 替换为你的服务器地址
- 已内置国内直连分流（`geoip:cn` / `geosite:cn` 走直连）
- 启用加密时会自动带上 `encryption` / `decryption` / `mldsa65Verify`，
  与服务端参数严格配对（这三项只要错一个字节就连不上）

```bash
sudo bash install-xray.sh --client-config /root/client.json
sed -i 's/SERVER_ADDRESS/你的服务器IP/' /root/client.json
xray run -config /root/client.json        # 本机即可用
```

---

## 六、安全提醒

1. **云厂商安全组**需要单独在控制台放行端口，脚本只能处理主机防火墙。
2. `--encryption` 要求客户端内核 ≥ v26.3.27；老客户端会连不上，
   不确定客户端版本时先用默认模式。
3. 默认关闭 BT 与内网访问，避免被当作扫描跳板；如需放行请改 `config.json` 的 `routing`。
4. 私钥在 `config.json` 与 `.deploy-state` 中，均为 `0600`，请勿公开。

---

## 七、支持的平台

| 项目 | 支持范围 |
| --- | --- |
| 发行版 | Debian / Ubuntu、CentOS / RHEL / Rocky / Alma、Fedora、Arch、openSUSE、Alpine |
| 初始化系统 | systemd、OpenRC |
| 架构 | x86_64、i386、arm64、armv7/v6/v5、mips(le)、mips64(le)、ppc64(le)、riscv64、s390x |
| 依赖 | `curl`、`unzip`（脚本自动安装） |

---

## 八、开发与验证

```bash
# 单元/集成测试：沙箱内跑完整安装流程，逐项校验产物（71 项断言）
bash tests/run-tests.sh /path/to/xray

# 端到端测试：真起服务端+客户端，通过隧道实际抓取网页
bash tests/e2e-proxy.sh /path/to/xray

# 四种模式都验一遍
for m in plain enc xhttp full; do E2E_MODE=$m bash tests/e2e-proxy.sh /path/to/xray; done
```

测试用**真实 xray 内核**校验配置语义、密钥配对与链接参数，
并用真实隧道验证「真能上网」，而不是只做文本比对。测试沙箱通过环境变量
（`XRAY_BIN` / `XRAY_CONF_DIR` / `XRAY_INIT_OVERRIDE` 等）重定向所有路径，
不会污染宿主机。

---

## 九、发布到自己的仓库（拿到属于你的一键链接）

```bash
cd xray-deploy
git init && git add . && git commit -m 'feat: xray one-click deploy'
git branch -M main
git remote add origin git@github.com:<你的用户名>/xray-deploy.git
git push -u origin main
```

推送后即可使用：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/<你的用户名>/xray-deploy/main/install-xray.sh)
```

### 不想建仓库？用 Gist

```bash
# 需要 GitHub CLI
gh gist create install-xray.sh --public
# 然后：
bash <(curl -fsSL https://gist.githubusercontent.com/<用户名>/<gist-id>/raw/install-xray.sh)
```

### 自建分发（适合内网/批量部署）

```bash
# 在已部署的服务器上，脚本自副本就在配置目录里
cp /usr/local/etc/xray/install-xray.sh /var/www/html/
# 之后即可用 http://<你的服务器>/install-xray.sh 分发
```
