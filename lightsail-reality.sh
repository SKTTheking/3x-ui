#!/usr/bin/env bash
# Lightsail: pinned 3x-ui + VLESS/REALITY + kernel BBR. GPL-3.0-or-later.
set -Eeuo pipefail
umask 077
export LC_ALL=C
readonly XUI_RELEASE=v3.7.0
readonly XRAY_RELEASE=v26.6.27
export LSX_VERSION="$XUI_RELEASE"
export LSX_XRAY_VERSION="$XRAY_RELEASE"
export LSX_PANEL_DIR=/usr/local/x-ui
export LSX_STATE_DIR=/etc/x-ui/lightsail-reality
export XUI_DB_FOLDER=/etc/x-ui
export XUI_BIN_FOLDER=/usr/local/x-ui/bin
export TARGET_SNI="${TARGET_SNI:-mirrors-package-mc.aki-game.net}"
export REALITY_PORT="${REALITY_PORT:-}"
export PANEL_PORT="${PANEL_PORT:-54321}"
export PANEL_USERNAME="${PANEL_USERNAME:-}"
export PANEL_PASSWORD="${PANEL_PASSWORD:-}"
export PANEL_PASSWORD_HASH="${PANEL_PASSWORD_HASH:-}"
export SERVER_IP="${SERVER_IP:-}"
export ADMIN_CIDR="${ADMIN_CIDR:-}"
die() {
    echo "错误：$*" >&2
    if [[ "${CHANGED:-0}" == 1 ]]; then
        systemctl stop x-ui >/dev/null 2>&1 || true
        echo '配置已保留在 /etc/x-ui，请保留报错信息排查。' >&2
    fi
    exit 1
}
[[ $EUID -eq 0 ]] || die '请使用 sudo bash lightsail-reality.sh 运行。'
command -v flock >/dev/null || die '系统缺少 flock，请先安装 util-linux。'
exec 9>/run/lock/lightsail-reality.lock
flock -n 9 || die '另一个安装程序正在运行。'
if [[ -f "$LSX_STATE_DIR/complete" ]]; then
    echo '已安装；不会更改现有节点或密码。之前保存的安装信息：'
    cat "$LSX_STATE_DIR/access.txt"
    systemctl is-active x-ui || die '服务未运行，请查看 journalctl -u x-ui -n 50。'
    exit 0
fi
for p in /usr/local/x-ui /etc/x-ui /usr/bin/x-ui /etc/systemd/system/x-ui.service /etc/default/x-ui; do
    [[ ! -e "$p" ]] || die "发现已有文件 $p；为保护配置已停止。本脚本用于全新实例。"
done
[[ -d /run/systemd/system ]] || die '需要以 systemd 启动的 Ubuntu/Debian 实例。'
# shellcheck disable=SC1091
source /etc/os-release
case "$ID:$VERSION_ID" in
    ubuntu:22.04|ubuntu:24.04|debian:12|debian:13) ;;
    *) die '支持 Ubuntu 22.04/24.04、Debian 12/13；建议使用 Lightsail Ubuntu 24.04。' ;;
esac
case "$(uname -m)" in
    x86_64)
        ARCH=amd64; SHA=0f8dd7baef3458f6591574e24814f322cf7f5e1e27f0a594683745e50be84ec5
        XRAY_ASSET=64; XRAY_SHA=b3e5902d06d6282fe53cfa2fc426058b9aeaa429b2c812e20887cd47f26d08bf ;;
    aarch64|arm64)
        ARCH=arm64; SHA=3caf1db1e8b10bb1fa1324c945522690bcf01c533ee75b377268f1c01a3ce896
        XRAY_ASSET=arm64-v8a; XRAY_SHA=13a251379bea366c2cf10363ad71e75734193d401f26f518bf0c25e5c8f8c931 ;;
    *) die '仅支持 amd64 和 arm64。' ;;
esac
export LSX_ARCH="$ARCH"
TEMP_DIR=$(mktemp -d)
CHANGED=0
cleanup() { rm -rf -- "$TEMP_DIR"; }
trap cleanup EXIT
failed() {
    trap - ERR
    if [[ "$CHANGED" == 1 ]]; then
        systemctl stop x-ui >/dev/null 2>&1 || true
        echo '安装未完成，服务已停止，配置保留在 /etc/x-ui。请保留报错信息排查，不要直接删库。' >&2
    fi
    echo "安装失败（第 $1 行）。没有报告安装成功。" >&2
    exit 1
}
trap 'failed "$LINENO"' ERR
echo '[1/6] 安装依赖（等待 apt 锁最多 5 分钟）'
export DEBIAN_FRONTEND=noninteractive
apt-get -o DPkg::Lock::Timeout=300 -o Acquire::Retries=3 update
apt-get -o DPkg::Lock::Timeout=300 -o Acquire::Retries=3 install -y --no-install-recommends ca-certificates curl python3 openssl tar iproute2 kmod util-linux

echo '[2/6] 检测端口、公网 IP 和 REALITY 目标站'
REALITY_PORT=$(python3 - <<'PY_PORT'
import os, secrets, socket
requested = os.environ.get('REALITY_PORT', '')
if requested:
    if not requested.isdecimal() or not 1 <= int(requested) <= 65535:
        raise SystemExit('REALITY_PORT 必须是合法端口。')
    print(int(requested))
else:
    for port in secrets.SystemRandom().sample(range(20000, 50000), 100):
        if str(port) == os.environ['PANEL_PORT']: continue
        with socket.socket() as sock:
            try: sock.bind(('0.0.0.0', port))
            except OSError: continue
            print(port)
            break
    else: raise SystemExit('未找到空闲随机端口。')
PY_PORT
)
export REALITY_PORT
echo "本次节点 TCP 端口：$REALITY_PORT（请在 Lightsail 云防火墙放行此端口）"
python3 - <<'PY_PREFLIGHT'
import ipaddress, os, re, socket, ssl
username, password = os.environ['PANEL_USERNAME'], os.environ['PANEL_PASSWORD']
password_hash = os.environ['PANEL_PASSWORD_HASH']
if password and password_hash:
    raise SystemExit('PANEL_PASSWORD 与 PANEL_PASSWORD_HASH 只能设置一个。')
if bool(username) != bool(password or password_hash):
    raise SystemExit('自定义账号需同时设置密码或 bcrypt 密码哈希。')
if password_hash and not re.fullmatch(r'\$2[aby]\$(?:0[4-9]|1[0-6])\$[./A-Za-z0-9]{53}', password_hash):
    raise SystemExit('PANEL_PASSWORD_HASH 必须是有效的 bcrypt 哈希。')
if username and not re.fullmatch(r'[A-Za-z0-9_.-]{3,64}', username):
    raise SystemExit('面板用户名需为 3–64 位字母、数字、下划线、点或短横线。')
if password and (not 12 <= len(password) <= 128 or any(ord(c) < 32 or ord(c) == 127 for c in password)):
    raise SystemExit('面板密码需为 12–128 个字符且不含控制字符。')
ports = [os.environ['REALITY_PORT'], os.environ['PANEL_PORT']]
if any(not p.isdecimal() or not 1024 <= int(p) <= 65535 and p != '443' for p in ports):
    raise SystemExit('端口应为 1024–65535 或 443。')
if len(set(map(int, ports))) != 2:
    raise SystemExit('面板与节点端口不能相同。')
for p in ports:
    with socket.socket() as s:
        try: s.bind(('0.0.0.0', int(p)))
        except OSError: raise SystemExit(f'端口 {p} 已被占用，安装已停止。')
host = os.environ['TARGET_SNI']
if len(host) > 253 or not re.fullmatch(r'(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}', host):
    raise SystemExit('TARGET_SNI 必须是合法域名。')
if os.environ['ADMIN_CIDR']:
    net = ipaddress.ip_network(os.environ['ADMIN_CIDR'], strict=False)
    if net.version != 4: raise SystemExit('ADMIN_CIDR 请填写管理员 IPv4/CIDR。')
ctx = ssl.create_default_context()
ctx.minimum_version = ctx.maximum_version = ssl.TLSVersion.TLSv1_3
ctx.set_alpn_protocols(['h2'])
try:
    with socket.create_connection((host, 443), timeout=15) as raw:
        with ctx.wrap_socket(raw, server_hostname=host) as conn:
            if conn.selected_alpn_protocol() != 'h2':
                raise RuntimeError('目标站没有协商 HTTP/2')
            print(f'目标站证书、TLS 1.3、HTTP/2 检查通过：{host}')
except Exception as exc:
    raise SystemExit(f'指定目标站检查失败：{exc}。未安装面板；请检查服务器网络或更换 TARGET_SNI。')
PY_PREFLIGHT
if [[ -z "$SERVER_IP" ]]; then
    IMDS_TOKEN=$(curl --noproxy '*' -fsS --connect-timeout 2 --max-time 4 -X PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' http://169.254.169.254/latest/api/token 2>/dev/null || true)
    if [[ -n "$IMDS_TOKEN" ]]; then
        SERVER_IP=$(curl --noproxy '*' -fsS --connect-timeout 2 --max-time 4 -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || true)
    fi
    unset IMDS_TOKEN
    if [[ -z "$SERVER_IP" ]]; then
        SERVER_IP=$(curl -4fsS --connect-timeout 5 --max-time 15 https://checkip.amazonaws.com 2>/dev/null || true)
    fi
fi
export SERVER_IP
python3 - <<'PY_IP'
import ipaddress, os
try:
    addr = ipaddress.ip_address(os.environ['SERVER_IP'].strip())
    if addr.version != 4 or not addr.is_global: raise ValueError()
except ValueError:
    raise SystemExit('无法确认公网 IPv4，请用 sudo env SERVER_IP=你的公网IP bash lightsail-reality.sh。')
PY_IP
SERVER_IP="${SERVER_IP//[[:space:]]/}"
echo "[3/6] 下载面板 $XUI_RELEASE 和 Xray $XRAY_RELEASE，验证 SHA-256"
curl -fL --retry 3 --connect-timeout 15 --max-time 600 \
    "https://github.com/MHSanaei/3x-ui/releases/download/$XUI_RELEASE/x-ui-linux-$ARCH.tar.gz" -o "$TEMP_DIR/release.tar.gz"
printf '%s  %s\n' "$SHA" "$TEMP_DIR/release.tar.gz" | sha256sum -c -
tar --no-same-owner -xzf "$TEMP_DIR/release.tar.gz" -C "$TEMP_DIR"
[[ "$("$TEMP_DIR/x-ui/x-ui" -v)" == "${XUI_RELEASE#v}" ]] || die '面板版本不匹配。'
[[ -x "$TEMP_DIR/x-ui/bin/xray-linux-$ARCH" && -f "$TEMP_DIR/x-ui/x-ui.sh" ]] || die '安装包缺少必要文件。'
# Pin the core separately; do not use the newer binary bundled with the panel.
curl -fL --retry 3 --connect-timeout 15 --max-time 600 \
    "https://github.com/XTLS/Xray-core/releases/download/$XRAY_RELEASE/Xray-linux-$XRAY_ASSET.zip" -o "$TEMP_DIR/xray.zip"
printf '%s  %s\n' "$XRAY_SHA" "$TEMP_DIR/xray.zip" | sha256sum -c -
python3 - "$TEMP_DIR" "$ARCH" <<'PY_XRAY'
import pathlib, sys, zipfile
temp = pathlib.Path(sys.argv[1])
binary = temp / 'x-ui' / 'bin' / ('xray-linux-' + sys.argv[2])
with zipfile.ZipFile(temp / 'xray.zip') as archive:
    binary.write_bytes(archive.read('xray'))
binary.chmod(0o755)
PY_XRAY
XRAY_ACTUAL=$("$TEMP_DIR/x-ui/bin/xray-linux-$ARCH" version)
[[ "$XRAY_ACTUAL" == "Xray ${XRAY_RELEASE#v} "* ]] || die 'Xray 版本不匹配。'
CHANGED=1
install -d -m 700 "$LSX_STATE_DIR"
mv "$TEMP_DIR/x-ui" "$LSX_PANEL_DIR"
chmod 700 "$LSX_PANEL_DIR"
install -m 755 "$LSX_PANEL_DIR/x-ui.sh" /usr/bin/x-ui

echo '[4/6] 生成账号、HTTPS 证书和 REALITY 配置'
python3 - <<'PY_SETUP'
import json, os, pathlib, re, secrets, sqlite3, subprocess, uuid
root = pathlib.Path(os.environ['LSX_PANEL_DIR'])
state = pathlib.Path(os.environ['LSX_STATE_DIR'])
dbdir = pathlib.Path(os.environ['XUI_DB_FOLDER'])
def run(args):
    p = subprocess.run(list(map(str, args)), cwd=root, capture_output=True, text=True, timeout=90)
    if p.returncode: raise RuntimeError(f'{pathlib.Path(str(args[0])).name} 执行失败，退出码 {p.returncode}')
    return p.stdout
def save(name, obj):
    path = state / name
    path.write_text(json.dumps(obj, indent=2))
    path.chmod(0o600)
keys = {}
for line in run([root/'bin'/('xray-linux-' + os.environ['LSX_ARCH']), 'x25519']).splitlines():
    if ':' in line:
        k, v = line.split(':', 1); keys[k.strip().lower()] = v.strip()
private = next((v for k, v in keys.items() if 'private' in k), '')
public = next((v for k, v in keys.items() if 'public' in k or 'password' in k), '')
if not all(re.fullmatch(r'[A-Za-z0-9_-]{43}', v) for v in [private, public]):
    raise RuntimeError('无法解析 Xray X25519 密钥。')
c = dict(username=os.environ.get('PANEL_USERNAME') or 'ls_' + secrets.token_hex(4),
         password=os.environ.get('PANEL_PASSWORD') or secrets.token_urlsafe(24),
         base_path='/', uuid=str(uuid.uuid4()),
         short_id=secrets.token_hex(8), private_key=private, public_key=public,
         server_ip=os.environ['SERVER_IP'], sni=os.environ['TARGET_SNI'],
         panel_port=int(os.environ['PANEL_PORT']), port=int(os.environ['REALITY_PORT']),
         version=os.environ['LSX_VERSION'], xray_version=os.environ['LSX_XRAY_VERSION'])
password_hash = os.environ.get('PANEL_PASSWORD_HASH', '')
initial_password = c['password']
if password_hash:
    c['password'] = '（使用你预设的面板密码）'
save('credentials.json', c)
cert, key = state/'panel.crt', state/'panel.key'
run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-sha256', '-nodes', '-days', '3650',
     '-keyout', key, '-out', cert, '-subj', '/CN=Lightsail-3x-ui',
     '-addext', 'subjectAltName=IP:' + c['server_ip'] + ',IP:127.0.0.1'])
run([root/'x-ui', 'setting', '-username', c['username'], '-password', initial_password,
     '-port', c['panel_port'], '-webBasePath', c['base_path'], '-listenIP', '0.0.0.0',
     '-webCert', cert, '-webCertKey', key])
db = dbdir/'x-ui.db'
if not db.is_file(): raise RuntimeError('面板未建立数据库。')
with sqlite3.connect(db) as conn:
    if password_hash:
        conn.execute('UPDATE users SET password=? WHERE id=(SELECT id FROM users ORDER BY id LIMIT 1)', (password_hash,))
        if conn.execute('SELECT password FROM users ORDER BY id LIMIT 1').fetchone()[0] != password_hash:
            raise RuntimeError('预设密码哈希未正确保存。')
    # Disable unused subscription listeners; use official CLI for credentials.
    for k in ['subEnable', 'subJsonEnable', 'subClashEnable']:
        conn.execute('DELETE FROM settings WHERE key=?', (k,))
        conn.execute('INSERT INTO settings (key,value) VALUES (?,?)', (k, 'false'))
    actual = dict(conn.execute('SELECT key,value FROM settings'))
    for k, v in dict(webPort=str(c['panel_port']), webBasePath=c['base_path'],
                     webListen='0.0.0.0', webCertFile=str(cert), webKeyFile=str(key)).items():
        if actual.get(k) != v: raise RuntimeError('面板设置未正确保存：' + k)
token_output = run([root/'x-ui', 'setting', '-getApiToken'])
token = re.search(r'^apiToken:\s*(\S+)\s*$', token_output, re.M)
if not token: raise RuntimeError('无法生成初始化 API 令牌。')
(state/'bootstrap-token').write_text(token.group(1))
for p in [db, cert, key, state/'bootstrap-token']: p.chmod(0o600)
inbound = dict(remark='Lightsail-REALITY', enable=True, listen='0.0.0.0', port=c['port'],
               protocol='vless', up=0, down=0, total=0, expiryTime=0,
               settings=json.dumps(dict(decryption='none', clients=[dict(id=c['uuid'],
                   flow='xtls-rprx-vision', email='lightsail-' + secrets.token_hex(4),
                   limitIp=0, totalGB=0, expiryTime=0, enable=True, tgId=0,
                   subId=secrets.token_hex(8), reset=0)])),
               streamSettings=json.dumps(dict(network='tcp', security='reality',
                   realitySettings=dict(show=False, xver=0, target=c['sni'] + ':443',
                       serverNames=[c['sni']], privateKey=c['private_key'],
                       shortIds=[c['short_id']], settings=dict(publicKey=c['public_key'],
                           fingerprint='chrome', serverName=c['sni'], spiderX='/')))),
               sniffing=json.dumps(dict(enabled=True, destOverride=['http','tls','quic'], routeOnly=True)))
save('inbound.json', inbound)
print('面板与节点配置已生成；密钥未写入公共仓库。')
PY_SETUP
unset PANEL_USERNAME PANEL_PASSWORD PANEL_PASSWORD_HASH
cat > /etc/systemd/system/x-ui.service <<'UNIT'
[Unit]
Description=3x-ui Lightsail REALITY
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=180
StartLimitBurst=10
[Service]
Type=simple
WorkingDirectory=/usr/local/x-ui
Environment=XUI_DB_FOLDER=/etc/x-ui
Environment=XUI_BIN_FOLDER=/usr/local/x-ui/bin
UMask=0077
ExecStart=/usr/local/x-ui/x-ui
ExecReload=/bin/kill -USR1 $MAINPID
Restart=on-failure
RestartSec=5
LimitNOFILE=65535
[Install]
WantedBy=multi-user.target
UNIT
chmod 644 /etc/systemd/system/x-ui.service
systemctl daemon-reload
systemctl enable --now x-ui
python3 - <<'PY_PROVISION'
import json, os, pathlib, socket, ssl, subprocess, time, urllib.parse, urllib.request
state = pathlib.Path(os.environ['LSX_STATE_DIR'])
root = pathlib.Path(os.environ['LSX_PANEL_DIR'])
c = json.loads((state/'credentials.json').read_text())
base = f"https://127.0.0.1:{c['panel_port']}{c['base_path']}panel/api/"
ctx = ssl.create_default_context(cafile=str(state/'panel.crt'))
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), urllib.request.HTTPSHandler(context=ctx))
token = (state/'bootstrap-token').read_text().strip()
def api(path, data=None):
    body = None if data is None else json.dumps(data).encode()
    req = urllib.request.Request(base + path, data=body,
        headers={'Authorization':'Bearer ' + token, 'Content-Type':'application/json'})
    with opener.open(req, timeout=10) as r: result = json.load(r)
    if result.get('success') is not True:
        raise RuntimeError('面板 API 返回失败：' + str(result.get('msg', '')))
    return result.get('obj')
for attempt in range(45):
    try:
        existing = api('inbounds/list')
        break
    except Exception:
        if attempt == 44: raise RuntimeError('面板 API 未就绪，请查看 x-ui 服务日志。')
        time.sleep(1)
payload = json.loads((state/'inbound.json').read_text())
matching = [i for i in existing if i.get('port') == c['port']]
if matching:
    settings = matching[0]['settings']
    if isinstance(settings, str): settings = json.loads(settings)
    clients = settings.get('clients', [])
    if not any(x.get('id') == c['uuid'] for x in clients):
        raise RuntimeError('端口已有不同节点，拒绝覆盖。')
else:
    created = api('inbounds/add', payload)
    if not created or not created.get('id'): raise RuntimeError('未获得入站 ID。')
api('server/restartXrayService', {})
for attempt in range(45):
    try:
        with socket.create_connection(('127.0.0.1', c['port']), timeout=1): pass
        config = root/'bin/config.json'
        if not config.is_file(): raise RuntimeError('Xray 配置尚未生成')
        test = subprocess.run([str(root/'bin'/('xray-linux-' + os.environ['LSX_ARCH'])),
            'run', '-test', '-config', str(config)], cwd=root, capture_output=True, timeout=30)
        if test.returncode: raise RuntimeError('Xray 配置校验未通过')
        listeners = subprocess.check_output(['ss', '-H', '-ltnp', 'sport', '=', ':' + str(c['port'])], text=True, stderr=subprocess.DEVNULL)
        if 'xray-linux-' not in listeners:
            raise RuntimeError('节点端口并非由 Xray 监听')
        break
    except Exception:
        if attempt == 44: raise RuntimeError('Xray 启动或配置检查失败，请查看服务日志。')
        time.sleep(1)
query = urllib.parse.urlencode(dict(encryption='none', security='reality', sni=c['sni'],
    fp='chrome', pbk=c['public_key'], sid=c['short_id'], type='tcp', flow='xtls-rprx-vision', spx='/'))
link = f"vless://{c['uuid']}@{c['server_ip']}:{c['port']}?{query}#Lightsail-REALITY"
fingerprint = subprocess.check_output(['openssl','x509','-in',str(state/'panel.crt'),
    '-noout','-fingerprint','-sha256'], text=True).strip()
text = f"""3x-ui {c['version']} + Xray {c['xray_version']} + VLESS/REALITY
面板：https://{c['server_ip']}:{c['panel_port']}{c['base_path']}
用户名：{c['username']}
密码：{c['password']}
面板使用自签 HTTPS 证书；首次浏览器会提示证书不受信任。
核对地址及证书指纹：{fingerprint}

节点链接（复制到 v2rayN / 支持 REALITY 的客户端导入）：
{link}

Lightsail 控制台 → 实例 → 联网/Networking → IPv4 防火墙：
放行 TCP {c['port']}（节点）；TCP {c['panel_port']}（面板，只允许你的管理 IP）。
保留原来的 SSH 规则。本脚本不修改 AWS 控制台防火墙。
绑定静态 IPv4 可避免停机再开机后节点地址变化。

查看信息：sudo cat /etc/x-ui/lightsail-reality/access.txt
重启面板：sudo systemctl restart x-ui
查看日志：sudo journalctl -u x-ui -n 50 --no-pager
检查 BBR：sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc
本机配置/API/监听检查已通过；客户端实际连通还取决于云防火墙和网络。
"""
(state/'access.txt').write_text(text)
(state/'access.txt').chmod(0o600)
print('面板 API、入站创建、Xray 配置与运行状态检查通过。')
PY_PROVISION

echo '[5/6] 启用内核 BBR + fq，配置现有系统防火墙'
BBR_STATUS='内核不支持 BBR，保留原拥塞控制'
modprobe tcp_bbr 2>/dev/null || true
if [[ " $(sysctl -n net.ipv4.tcp_available_congestion_control) " == *' bbr '* ]]; then
    cat > /etc/sysctl.d/99-lightsail-reality-bbr.conf <<'BBR'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
BBR
    chmod 644 /etc/sysctl.d/99-lightsail-reality-bbr.conf
    sysctl -p /etc/sysctl.d/99-lightsail-reality-bbr.conf
    [[ "$(sysctl -n net.ipv4.tcp_congestion_control)" == bbr ]] || die 'BBR 未生效。'
    [[ "$(sysctl -n net.core.default_qdisc)" == fq ]] || die 'fq 未生效。'
    BBR_STATUS='BBR 已启用，默认队列为 fq（不会强制替换现有网卡队列）'
fi
if command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then
    ufw allow "$REALITY_PORT/tcp"
    if [[ -n "$ADMIN_CIDR" ]]; then
        ufw allow from "$ADMIN_CIDR" to any port "$PANEL_PORT" proto tcp
    else
        ufw allow "$PANEL_PORT/tcp"
    fi
fi
if command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="$REALITY_PORT/tcp"
    firewall-cmd --add-port="$REALITY_PORT/tcp"
    if [[ -n "$ADMIN_CIDR" ]]; then
        RULE="rule family=ipv4 source address=$ADMIN_CIDR port port=$PANEL_PORT protocol=tcp accept"
        firewall-cmd --permanent --add-rich-rule="$RULE"
        firewall-cmd --add-rich-rule="$RULE"
    else
        firewall-cmd --permanent --add-port="$PANEL_PORT/tcp"
        firewall-cmd --add-port="$PANEL_PORT/tcp"
    fi
fi
# Remove the temporary administrative API token while the database is offline.
# This is a fresh installation, so all tokens here were created by this script.
systemctl stop x-ui
python3 - <<'PY_REVOKE'
import os, pathlib, sqlite3
with sqlite3.connect(pathlib.Path(os.environ['XUI_DB_FOLDER'])/'x-ui.db') as db:
    db.execute('DELETE FROM api_tokens')
(pathlib.Path(os.environ['LSX_STATE_DIR'])/'bootstrap-token').unlink()
PY_REVOKE
systemctl start x-ui
python3 - <<'PY_FINAL_CHECK'
import json, os, pathlib, socket, ssl, time, urllib.request
state = pathlib.Path(os.environ['LSX_STATE_DIR'])
c = json.loads((state/'credentials.json').read_text())
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}),
    urllib.request.HTTPSHandler(context=ssl.create_default_context(cafile=str(state/'panel.crt'))))
for attempt in range(45):
    try:
        with socket.create_connection(('127.0.0.1', c['port']), timeout=1): pass
        with opener.open(f"https://127.0.0.1:{c['panel_port']}{c['base_path']}", timeout=3) as r:
            if r.status != 200: raise RuntimeError('面板页面异常')
        break
    except Exception:
        if attempt == 44: raise RuntimeError('最终重启检查未通过')
        time.sleep(1)
PY_FINAL_CHECK
systemctl is-active --quiet x-ui
printf '\nBBR 状态：%s\n' "$BBR_STATUS" >> "$LSX_STATE_DIR/access.txt"
touch "$LSX_STATE_DIR/complete"
CHANGED=0
echo '[6/6] 安装完成'
cat "$LSX_STATE_DIR/access.txt"
