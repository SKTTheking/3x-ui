#!/bin/bash
# Repair VERSION collision in the earlier embedded Lightsail installer.
# Reuse local launch data; preserve its account, password hash and REALITY target.
set -Eeuo pipefail
umask 077
[[ $EUID -eq 0 ]] || { echo 'Run with sudo bash.' >&2; exit 1; }
if [[ -e /etc/x-ui/x-ui.db || -e /usr/local/x-ui ]]; then
    echo 'Existing panel detected. No files changed; inspect it before retrying.' >&2
    exit 1
fi
REPAIR_TMP=$(mktemp -d)
trap 'rm -rf -- "$REPAIR_TMP"' EXIT
export REPAIR_TMP
python3 - <<'PY'
import base64, lzma, os, pathlib, re
source = pathlib.Path('/var/lib/cloud/instance/scripts/part-001').read_text()
match = re.search(r"base64 -d <<'LS_BOOT_XZ' \| xz -dc > \"\$LS_BOOT\"\r?\n(.*?)\r?\nLS_BOOT_XZ", source, re.S)
if not match:
    raise SystemExit('Expected local embedded installer not found; stopped without changes.')
script = lzma.decompress(base64.b64decode(match.group(1))).decode()
changes = {
    'VERSION=v3.7.0\n': 'readonly XUI_RELEASE=v3.7.0\n',
    'export LSX_VERSION="$VERSION"': 'export LSX_VERSION="$XUI_RELEASE"',
    '/releases/download/$VERSION/': '/releases/download/$XUI_RELEASE/',
    '${VERSION#v}': '${XUI_RELEASE#v}',
}
for old, new in changes.items():
    if script.count(old) != 1:
        raise SystemExit('Local installer differs from the known affected version; stopped.')
    script = script.replace(old, new, 1)
port = os.environ.get('REALITY_PORT', '')
if port:
    if not port.isdecimal() or not 1024 <= int(port) <= 65535:
        raise SystemExit('Invalid REALITY_PORT.')
    if script.count("export REALITY_PORT=''\n") != 1:
        raise SystemExit('Cannot safely preserve the selected port; stopped.')
    script = script.replace("export REALITY_PORT=''\n", 'export REALITY_PORT=' + str(int(port)) + '\n', 1)
target = pathlib.Path(os.environ['REPAIR_TMP'])/'launch.sh'
target.write_text(script)
target.chmod(0o600)
print('Local installer repaired. Account and password hash preserved.')
if port: print('REALITY TCP port: ' + port)
PY
bash -n "$REPAIR_TMP/launch.sh"
echo 'Installing; progress is written to /var/lib/lightsail-reality-launch/install.log'
if bash "$REPAIR_TMP/launch.sh"; then
    /usr/local/sbin/lightsail-reality-info
else
    echo 'Installation stopped. Last log lines:' >&2
    tail -n 40 /var/lib/lightsail-reality-launch/install.log >&2
    exit 1
fi
