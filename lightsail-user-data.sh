#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive
if ! command -v curl >/dev/null 2>&1; then
    apt-get -o DPkg::Lock::Timeout=300 update
    apt-get -o DPkg::Lock::Timeout=300 install -y ca-certificates curl
fi
curl -fL --retry 5 --connect-timeout 15 --max-time 180 https://raw.githubusercontent.com/SKTTheking/3x-ui/main/lightsail-launch.sh -o /root/lightsail-launch.sh
bash /root/lightsail-launch.sh
