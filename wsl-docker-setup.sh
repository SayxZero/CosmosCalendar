#!/bin/sh
# Docker Engine in the WSL distribution that builds the Linux packages
# (build-linux.ps1). Run once as root from Windows:
#
#   wsl -d Ubuntu-26.04 -u root sh /mnt/d/Prog/Calendar/wsl-docker-setup.sh [DNS...]
#   wsl --terminate Ubuntu-26.04
#
# The second line restarts the distribution: systemd then starts dockerd, and
# the user of the distribution is in the group docker. Docker comes from the
# archive of Ubuntu (docker.io, docker-buildx) - open source, no licence to
# accept, no Docker Desktop.
#
# DNS - servers for the distribution instead of the DNS proxy of Windows on
# the WSL gateway, which a VPN on the Windows side can leave mute: names then
# resolve neither for apt nor in the containers (ISSUES.md). For example
# "8.8.8.8 8.8.4.4", the servers of the network card of Windows.
set -eu

if [ $# -gt 0 ]; then
    if ! grep -qs '^generateResolvConf *= *false' /etc/wsl.conf; then
        printf '\n[network]\ngenerateResolvConf=false\n' >> /etc/wsl.conf
    fi
    rm -f /etc/resolv.conf
    for server in "$@"; do
        echo "nameserver $server"
    done > /etc/resolv.conf
fi

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends docker.io docker-buildx

# dockerd is a systemd service; the Ubuntu image of WSL turns systemd on
# itself, an older one may not.
if ! grep -qs '^systemd *= *true' /etc/wsl.conf; then
    printf '\n[boot]\nsystemd=true\n' >> /etc/wsl.conf
fi

# The user made on the first start of the distribution (uid 1000) runs docker
# without sudo; build-linux.ps1 calls it as that user.
user=$(getent passwd 1000 | cut -d: -f1)
if [ -n "$user" ]; then
    usermod -aG docker "$user"
fi
echo "Docker установлен. Перезапуск дистрибутива: wsl --terminate <имя>"
