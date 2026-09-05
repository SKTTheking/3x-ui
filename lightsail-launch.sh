#!/usr/bin/env bash
# Run once from Lightsail launch script / cloud-init user data.
set -Eeuo pipefail
umask 077
[[ $EUID -eq 0 ]] || { echo '请以 root 运行启动脚本。' >&2; exit 1; }
install -d -m 700 /var/lib/lightsail-reality-launch
exec 8>/var/lib/lightsail-reality-launch/lock
flock -n 8 || exit 0
exec >>/var/lib/lightsail-reality-launch/install.log 2>&1
LAUNCH_TMP=''
finish() {
    local rc=$?
    trap - EXIT
    [[ -z "$LAUNCH_TMP" ]] || rm -f -- "$LAUNCH_TMP"
    if [[ $rc -eq 0 ]]; then
        printf 'done\n' > /var/lib/lightsail-reality-launch/status
    else
        printf 'failed\n' > /var/lib/lightsail-reality-launch/status
        echo "启动安装失败，退出码：$rc。配置和日志已保留。"
    fi
    exit "$rc"
}
trap finish EXIT
printf 'installing\n' > /var/lib/lightsail-reality-launch/status

# Reads secrets only with the administrator's existing sudo authority.
# No sudoers rule is added and no credential is put into a public MOTD.
cat > /usr/local/sbin/lightsail-reality-info <<'INFO'
#!/bin/sh
if [ "$(id -u)" != 0 ]; then
    echo '请运行 sudo lightsail-reality-info 查看节点。'
    exit 1
fi
if [ -f /etc/x-ui/lightsail-reality/complete ]; then
    printf '\n=== Lightsail REALITY 节点与面板 ===\n'
    cat /etc/x-ui/lightsail-reality/access.txt
    if ! systemctl is-active --quiet x-ui; then
        echo '注意：面板服务当前未运行。请用 sudo systemctl status x-ui 查看。'
    fi
elif [ "$(cat /var/lib/lightsail-reality-launch/status 2>/dev/null)" = failed ]; then
    printf '\nREALITY 自动安装失败，没有可用节点输出。\n'
    echo '查看原因：sudo tail -n 60 /var/lib/lightsail-reality-launch/install.log'
elif [ "$(cat /var/lib/lightsail-reality-launch/status 2>/dev/null)" = done ]; then
    echo '未找到安装完成标记；请查看安装日志。'
else
    printf '\nREALITY 正在自动安装，完成后重新连接 SSH 就会显示节点。\n'
    echo '查看进度：sudo tail -n 30 /var/lib/lightsail-reality-launch/install.log'
fi
INFO
chmod 755 /usr/local/sbin/lightsail-reality-info

cat > /etc/profile.d/99-lightsail-reality.sh <<'PROFILE'
# Only interactive SSH logins; keep scp/sftp and command output untouched.
if [ -n "${SSH_CONNECTION:-}" ] && [ -t 1 ]; then
    if [ "$(id -u)" = 0 ]; then
        /usr/local/sbin/lightsail-reality-info || :
    elif command -v sudo >/dev/null 2>&1; then
        sudo -n /usr/local/sbin/lightsail-reality-info 2>/dev/null ||
            echo '查看 REALITY 节点：sudo lightsail-reality-info'
    fi
fi
PROFILE
chmod 644 /etc/profile.d/99-lightsail-reality.sh

echo '开始通过 Lightsail 启动脚本安装 3x-ui + REALITY + BBR。'
export DEBIAN_FRONTEND=noninteractive
if ! command -v curl >/dev/null 2>&1; then
    apt-get -o DPkg::Lock::Timeout=300 -o Acquire::Retries=3 update
    apt-get -o DPkg::Lock::Timeout=300 -o Acquire::Retries=3 install -y ca-certificates curl
fi
LAUNCH_TMP=$(mktemp /var/lib/lightsail-reality-launch/installer.XXXXXX)
curl -fL --retry 5 --retry-delay 3 --connect-timeout 15 --max-time 180 \
    https://raw.githubusercontent.com/SKTTheking/3x-ui/main/lightsail-reality.sh -o "$LAUNCH_TMP"
bash "$LAUNCH_TMP"
test -f /etc/x-ui/lightsail-reality/complete
echo '自动安装已完成。下一次交互式 SSH 登录将显示节点。'
