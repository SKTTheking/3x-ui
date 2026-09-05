# Lightsail 一键安装：3x-ui + VLESS/REALITY + BBR

适用于全新 AWS Lightsail Ubuntu 22.04/24.04、Debian 12/13 实例，支持 amd64/arm64。无需 Docker。协议是 **VLESS + TCP + REALITY + xtls-rprx-vision**。

使用已有的 `SKTTheking/3x-ui` 官方 Fork，新增独立安装入口；保留原仓库内容。面板来自 **MHSanaei/3x-ui v3.7.0 正式发布包**，Xray 内核单独固定为 **v26.6.27**；两份下载分别验证固定 SHA-256，避免跟随 main/dev 自动变化。Xray 使用[官方 v26.6.27 发布包](https://github.com/XTLS/Xray-core/releases/tag/v26.6.27)（上游标记为 Pre-release），这是用户在现有客户端上实测能用的版本，不代表对所有客户端的兼容保证。

## 创建实例时自动安装，登录 SSH 自动显示节点

在 Lightsail 创建实例页面选择全新 Ubuntu 24.04，展开 **添加启动脚本 / Add launch script**，粘贴下面整段，再创建实例：

```bash
#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive
if ! command -v curl >/dev/null 2>&1; then
    apt-get -o DPkg::Lock::Timeout=300 update
    apt-get -o DPkg::Lock::Timeout=300 install -y ca-certificates curl
fi
curl -fL --retry 5 --connect-timeout 15 --max-time 180 https://raw.githubusercontent.com/SKTTheking/3x-ui/main/lightsail-launch.sh -o /root/lightsail-launch.sh
bash /root/lightsail-launch.sh
```

也可查看完整的 [`lightsail-user-data.sh`](lightsail-user-data.sh)，复制其文件内容。

创建后先保留 SSH 规则。安装在后台运行，不需要先打开 SSH，也不需要保持浏览器开启。安装完成后登录 SSH，查看随机节点端口，再单独放行该 TCP 端口；面板仍为 TCP 54321，限制管理 IP。不要为随机端口直接开放全部端口。

安装成功后，使用 Lightsail 自带的浏览器 SSH 连接：终端会自动显示 `vless://` 节点链接，以及面板地址和账号密码。过早连接时会显示“正在自动安装”；等待后重新连接即可。安装失败则显示失败提示及日志查看命令，不输出成功节点。

自动显示适用于 root 或拥有现成免密 sudo 权限的默认 Ubuntu 管理员；脚本不添加 sudo 权限，也不会把密码放进所有用户可读的登录公告。只有带终端的 SSH 登录会显示信息，不影响 scp/sftp 或非交互 SSH 命令。若修改了登录 shell 或 sudo 权限，可手动运行 `sudo lightsail-reality-info`。

安装日志：`sudo tail -n 60 /var/lib/lightsail-reality-launch/install.log`。如果连登录提示都没出现，先用 `sudo tail -n 60 /var/log/cloud-init-output.log` 查看最初下载启动脚本时是否失败。

启动脚本在创建实例的首次启动时安装；之后重启由 systemd 启动已安装的面板，不重新生成密钥。通过面板手动修改配置后，登录输出仍是保存的安装信息。

## 已创建实例：手动安装

1. 在 Lightsail 建立全新 Ubuntu 24.04 实例，建议先绑定静态 IPv4。
2. 打开实例的 **Networking / 联网 → IPv4 防火墙**，保留 SSH 原规则，添加：

   | 协议 | 端口 | 用途 | 来源 |
   | --- | --- | --- | --- |
   | TCP | 安装后显示的随机端口 | REALITY 节点 | 需要使用节点的客户端；也可所有 IPv4 |
   | TCP | 54321 | HTTPS 面板 | 仅你的管理公网 IPv4 |

3. 在实例 SSH 终端运行：

   ```bash
   curl -fL --retry 3 https://raw.githubusercontent.com/SKTTheking/3x-ui/main/lightsail-reality.sh -o lightsail-reality.sh && sudo bash lightsail-reality.sh
   ```

4. 完成后会显示面板网址、随机账号、随机密码、证书指纹和 `vless://` 导入链接。把节点链接导入支持 REALITY 的新版 v2rayN/客户端。

面板自动使用自签 HTTPS 证书，浏览器第一次提示“不受信任”属预期；核对终端显示的地址和 SHA-256 证书指纹后访问。证书只服务面板，与 REALITY 使用的目标站是两套不同配置。

## 自动完成的工作

- 安装依赖，等待 apt/dpkg 锁，校验操作系统、架构和端口占用。默认从 20000–49999 选择一个空闲节点端口，排除面板端口；首次安装后固定，重启不会换端口。
- 从实例内检测目标域名 **`mirrors-package-mc.aki-game.net:443`** 的证书、TLS 1.3 和 HTTP/2；不满足就停止，不偷偷切换域名。这只是必要条件检查，不是对目标站长期可用性的保证。
- 通过 AWS IMDSv2 获取公网 IPv4，失败后使用 AWS 公网 IP 查询服务。
- 下载固定 v3.7.0 面板发布包及 Xray **v26.6.27** 发布包，分别校验 SHA-256；在首次启动前替换内核并核对版本，下载或校验失败就停止，不回退使用面板捆绑的较新内核。
- 面板路径固定为 `/`，直接访问 `https://公网IP:54321/`；默认生成随机账号、密码、UUID、X25519 密钥及 short ID；可通过实例环境变量预设面板账号和密码，公共脚本不包含个人凭据。
- 利用官方 CLI 初始化账号，通过本机 HTTPS API 建立一个无限流量/无到期时间的节点；关闭未使用的订阅监听。
- 验证入站创建、Xray 配置、监听进程及最终重启后的 HTTPS 页面；撤销初始化 API 令牌。
- 内核支持时启用 BBR、将默认队列设为 fq，并写入持久化 sysctl 文件；不升级内核、不重启机器，不强制替换现有网卡队列。BBR 的提速效果取决于网络，不能保证提升，也不能解决 IP 被封。
- 对正在运行的 UFW/firewalld 添加相关端口规则，不清空其他规则；不更改 SSH 密码或 SSH 登录设置。

Lightsail 云防火墙与服务器自身防火墙是两层；脚本没有你的 AWS 管理凭据，**不会自动更改 Lightsail 控制台规则**。IPv4/IPv6 云规则独立，本脚本的导入链接使用 IPv4。

## 可选参数

```bash
sudo env PANEL_PORT=54321 REALITY_PORT=443 SERVER_IP=你的公网IPv4 ADMIN_CIDR=你的管理IPv4/32 bash lightsail-reality.sh
```

- `REALITY_PORT` 不填就随机，显式设置时固定为指定端口。随机端口不能防止完整端口扫描；REALITY 使用非 443 端口也不保证比 443 更稳定。
- `PANEL_USERNAME` 与 `PANEL_PASSWORD` 可一起传入，或用 `PANEL_PASSWORD_HASH` 传入 bcrypt 哈希以避免把明文密码放进启动脚本；密码和哈希二选一。不要把个人凭据或密码哈希提交到公开 GitHub。使用哈希时，登录提示只显示“使用你预设的面板密码”。
- 默认不用传参数；`SERVER_IP` 用于自动识别失败或出口与静态 IP 不一致时。
- `ADMIN_CIDR` 仅限制脚本添加的本机防火墙面板规则；原有的宽泛放行规则仍然有效，需要自行检查。云防火墙仍需设置。
- 需要换目标域名时，在首次安装前使用 `sudo env TARGET_SNI=新的域名 bash lightsail-reality.sh`。
- 此次固定内核的依据：用户报告服务端 v26.7.28 无法连接，降为 v26.6.27 后恢复；其 v2rayN 日志显示客户端内核为 25.5.16。不要只看 v2rayN 界面版本。安装脚本不会自动升级 Xray；手动升级面板或内核可能改变此组合。

## 查看信息与排查

```bash
sudo cat /etc/x-ui/lightsail-reality/access.txt
sudo systemctl status x-ui --no-pager
sudo journalctl -u x-ui -n 50 --no-pager
sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc
```

`access.txt` 含账号密码与节点链接，请勿公开。文件位于服务器本地且仅 root 可读。通过面板手动更改后，该文件不会自动更新。

发现已有 `/etc/x-ui` 或其他安装痕迹时，脚本拒绝覆盖。成功后重复运行只显示之前的信息，不重新生成节点。安装中途失败则停止服务、保留配置用于诊断；不会擅自删除数据库，也不自动覆盖失败现场。

## 仓库隐私

当前仓库是公开 Fork，不能直接单独改为私有。可在 GitHub Settings → General → Danger Zone 中先 Leave fork network，再 Change visibility → Private。离开 Fork 网络不可逆，会影响关联元数据，请阅读 GitHub 的确认说明。

改成私有后，本文的匿名 GitHub 下载命令会失效；已有服务器不受影响。需要继续无人值守安装时，可使用内嵌安装程序的独立启动脚本，无需把 GitHub 令牌放进实例。仓库私有只能隐藏代码，不能阻止别人扫描服务器 IP；面板入口仍应限制管理 IP。

## 验证范围

已用正式 amd64 发布程序验证：嵌入 Python 与 Bash 语法、实际 HTTPS API 初始化和入站创建、重复创建保护、Xray 配置解析及监听、初始化令牌撤销、面板重启与 HTTPS 页面，以及 VLESS + REALITY + Vision 客户端/服务端通过本地 TLS 目标站完成 HTTP 请求往返。往返测试只在隔离测试配置里放行指定回环地址，没有更改安装脚本的默认出站规则。

这些验证在隔离环境中运行，没有使用你的 AWS 实例。真实 Lightsail 的 apt/systemd、防火墙、内核 BBR、指定目标站及客户端公网连通，需要在实例运行安装后确认。arm64 发布包哈希已从官方发布元数据固定，但未执行 arm64 二进制测试。

启动脚本补充验证：Bash/POSIX shell 语法、安装中/失败/成功提示、非管理员无法直接读取凭据、非交互 SSH 无输出，以及交互终端通过现有免密 sudo 调用显示程序。尚未在真实 Lightsail cloud-init 中完成整机部署验证。

随机端口与预设密码补充验证：随机端口范围和显式端口覆盖、数据库内账号及 bcrypt 哈希、实际 HTTPS 登录成功、重启及 REALITY 本地请求往返。个性化独立启动文件不提交到此公开仓库。

## 上游与依据

- [3x-ui v3.7.0 正式发布](https://github.com/MHSanaei/3x-ui/releases/tag/v3.7.0)
- [3x-ui 官方安装说明](https://github.com/MHSanaei/3x-ui/wiki/Installation)
- [REALITY 官方说明](https://github.com/XTLS/REALITY)
- [GitHub 脱离 Fork 网络](https://docs.github.com/en/pull-requests/how-tos/work-with-forks/detaching-a-fork)
- [GitHub 更改可见性](https://docs.github.com/repositories/managing-your-repositorys-settings-and-features/managing-repository-settings/setting-repository-visibility)
- [AWS Lightsail 防火墙设置](https://docs.aws.amazon.com/lightsail/latest/userguide/amazon-lightsail-editing-firewall-rules.html)
- [AWS Lightsail 启动脚本说明](https://docs.aws.amazon.com/lightsail/latest/userguide/lightsail-how-to-configure-server-additional-data-shell-script.html)
- [AWS Lightsail IP 地址说明](https://docs.aws.amazon.com/lightsail/latest/userguide/understanding-public-ip-and-private-ip-addresses-in-amazon-lightsail.html)

本脚本沿用仓库 GPL-3.0 许可。手动从面板或 `x-ui` 菜单升级将脱离此处已验证的版本组合；升级前备份 `/etc/x-ui`。

内核固定与面板路径更新：新安装默认 Xray v26.6.27，面板根路径 `/`；已部署服务器不被远程修改。个性化独立启动文件需要重新下载，旧文件中的内嵌代码不会自动更新。

本次补充验证：实际 v26.6.27 amd64 内核与 3x-ui v3.7.0 完成根路径 HTTPS/API 初始化、预设密码哈希保留、重复入站保护、令牌撤销及重启检查；使用官方 Xray v25.5.16 Linux 客户端与 v26.6.27 服务端完成 REALITY/Vision 本地 HTTP 请求往返。用户另已报告其 Windows v2rayN 使用降级后的服务器恢复连接。未重新创建 AWS 实例验证整段启动流程。
