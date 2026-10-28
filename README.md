# xray-install.sh

在 Debian / Ubuntu VPS 上一键部署 Xray（VLESS），并生成客户端链接和二维码。

| 模式 | 协议 | 端口 | 适用场景 |
|---|---|---|---|
| 1 | VLESS + TCP + REALITY | 443 | 直连 VPS IP |
| 2 | VLESS + WS + TLS | 443 | 经 Cloudflare 中转 |
| 3（默认） | 同时部署以上两种 | REALITY 443，WS 8443 | 两条线路都要 |

## 运行要求

- Debian / Ubuntu，使用 systemd
- root 权限（sudo）
- 443 端口（模式 3 还有 8443）没有被 nginx 等其他服务占用。脚本发现端口被占用会直接退出，不会停掉其他服务。

## 部署前准备

### Cloudflare 设置（模式 2、3）

1. 域名已接入 Cloudflare。
2. 添加 DNS 记录：A 记录指向 VPS 的 IPv4，代理状态选“已代理”（橙色云朵）。
3. SSL/TLS → 概述：加密模式选 **完全（严格）/ Full (strict)**。
4. 网络（Network）里的 WebSockets 保持开启（默认就是开启的）。
5. 创建源服务器证书：SSL/TLS → 源服务器（Origin Server）→ 创建证书，格式选 PEM。私钥只在创建时显示一次，要当场保存。
6. 在 VPS 上新建证书和私钥文件，把 Cloudflare 页面上的内容分别粘贴进去，开头的 `-----BEGIN ...-----` 和结尾的 `-----END ...-----` 两行也要包括：

```bash
sudo nano /root/cf-origin.pem   # 粘贴源证书
sudo nano /root/cf-origin.key   # 粘贴私钥
```

在 nano 里粘贴后按 `Ctrl+O`、回车保存，再按 `Ctrl+X` 退出。以后要修改，用同样的命令打开编辑。

7. 设置权限，私钥只允许 root 读写：

```bash
sudo chmod 644 /root/cf-origin.pem
sudo chmod 600 /root/cf-origin.key
```

### 放行端口

VPS 防火墙**和**服务商后台的安全组都要放行：

| 模式 | 需要放行的 TCP 端口 |
|---|---|
| 1 | 443 |
| 2 | 443 |
| 3 | 443、8443 |

ufw 示例。ufw 没有启用就不用设置；如果打算新启用 ufw，先放行 SSH，否则会断开连接：

```bash
sudo ufw allow OpenSSH
sudo ufw allow 443/tcp
sudo ufw allow 8443/tcp   # 仅模式 3
```

脚本不会修改防火墙，也不会改 Cloudflare 的设置。

## 使用

### 交互式安装

先下载再运行：

```bash
curl -fsSL https://raw.githubusercontent.com/anUniqueName/vps-setup/main/xray-install.sh -o xray-install.sh
sudo bash xray-install.sh
```

不要用 `curl ... | sudo bash` 管道方式运行。

脚本会依次询问以下内容（方括号里是默认值，直接回车即采用）：

1. 部署模式 [3]
2. 已有 Xray 配置时，输入 `REPLACE` 确认替换
3. Cloudflare 域名（模式 2、3）
4. 证书路径 [/root/cf-origin.pem]、私钥路径 [/root/cf-origin.key]（模式 2、3）
5. WebSocket 路径 [随机生成]（模式 2、3）
6. REALITY 目标网站 [www.apple.com]（模式 1、3）
7. 节点备注 [主机名-月日]
8. REALITY 链接使用的公网 IPv4 [自动检测]（模式 1、3）
9. 是否开启 BBR [N]

### 无人值守安装

用环境变量提前给出答案；加上 `YES=1`，其余问题全部使用默认值：

```bash
# 模式 3（默认），证书在默认路径
sudo env YES=1 DOMAIN=node1.example.com REMARK=node1 bash xray-install.sh

# 只部署 REALITY 直连
sudo env YES=1 MODE=1 bash xray-install.sh

# 只部署 Cloudflare 线路，证书放在其他位置，开启 BBR
sudo env YES=1 MODE=2 DOMAIN=node1.example.com \
  CERT_SOURCE=/etc/ssl/cf.pem KEY_SOURCE=/etc/ssl/cf.key BBR=y bash xray-install.sh
```

注意：设置 `YES=1` 后，如果机器上已有 Xray 配置，脚本会**直接替换**，不再要求输入 REPLACE（旧配置仍会备份）。

没有终端的环境（如 cloud-init）也能运行，但没有默认值的项（模式 2、3 的 `DOMAIN`）必须提前给出，否则脚本会报错退出，并提示缺少哪个变量。

| 变量 | 含义 | 默认值 |
|---|---|---|
| `MODE` | 部署模式：1 / 2 / 3 | 3 |
| `DOMAIN` | Cloudflare 上的域名（模式 2、3） | 无，必填 |
| `CERT_SOURCE` | 源服务器证书路径 | `/root/cf-origin.pem` |
| `KEY_SOURCE` | 源服务器私钥路径 | `/root/cf-origin.key` |
| `WS_PATH` | WebSocket 路径，以 `/` 开头，只能包含字母、数字、`/`、`_`、`-` | 随机 24 位十六进制 |
| `REALITY_SNI` | REALITY 目标网站（模式 1、3），同时作为客户端的 SNI。自定义时选支持 TLS 1.3 和 HTTP/2 的网站，只填域名 | `www.apple.com` |
| `REMARK` | 节点备注，显示在客户端的节点名称里 | `主机名-月日` |
| `SERVER_IP` | REALITY 链接里使用的公网 IPv4 | 通过 api.ipify.org 自动检测 |
| `BBR` | 设为 `y` 开启 BBR | `N` |
| `YES` | 设为 `1` 时其余问题全部用默认值 | 不设置 |

## 安装完成后

- 客户端链接和二维码会打印在屏幕上，同时保存在 `/root/xray-client.XXXXXXXX/`：
  - `reality.txt` / `reality.png`：REALITY 直连链接（直接连 VPS IP，不经过 Cloudflare）
  - `ws-cf.txt` / `ws-cf.png`：Cloudflare 线路链接
- 查看状态：`systemctl status xray`
- 查看日志：`journalctl -u xray -n 50 --no-pager`

脚本只检查本机 Xray 是否启动成功，没有验证经过 Cloudflare 的完整链路，请用客户端实际测试一下。

## 重新运行与回滚

- 每次运行都会生成新的 UUID 并**整体替换** Xray 配置，旧的客户端链接全部失效，自定义的路由规则也会被覆盖。
- 替换前会把旧配置备份到 `/usr/local/etc/xray/config.backup.XXXXXXXX`。
- 新配置启动失败时，脚本会自动恢复旧配置。
- 手动回滚：

```bash
sudo cp /usr/local/etc/xray/config.backup.XXXXXXXX /usr/local/etc/xray/config.json
sudo systemctl restart xray
```

- 机器上已经装有 Xray 时，脚本直接使用现有版本，不会升级。需要升级时运行官方脚本：

```bash
sudo bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
```

## 常见问题

| 报错或现象 | 原因与处理 |
|---|---|
| `Port 443 is used by another service` | 端口被 nginx 等其他服务占用。脚本不会停掉其他服务，需要自己处理端口冲突。 |
| `Certificate does not cover hostname` | 证书里不包含这个域名。通配符只覆盖一级子域名，`*.example.com` 不包含 `a.b.example.com`。 |
| `Certificate and private key do not match` | 证书和私钥不是同一次创建的。 |
| `Certificate is invalid or expired` | 证书已过期，或文件不是 PEM 格式。 |
| `Custom Xray service command detected` | xray.service 不是官方安装脚本的默认写法（比如用了 `-confdir`），脚本不处理这种情况，需要手动配置。 |
| `Config check failed ... Candidate retained at ...` | 新配置没有通过 Xray 的检查，线上配置没有改动。根据上面 Xray 输出的报错排查。 |

安装失败后，`/usr/local/etc/xray/` 下可能留有 `config.new.*` 文件和 `tls.*` 目录，不影响使用。可以删除所有 `config.new.*`，以及当前 `config.json` 没有用到的 `tls.*` 目录：

```bash
grep -o 'tls\.[A-Za-z0-9]*' /usr/local/etc/xray/config.json   # 查看正在使用的 tls 目录
```
