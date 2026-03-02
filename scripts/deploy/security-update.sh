#!/bin/bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export UCF_FORCE_CONFFOLD=1

APT_OPTS=(
  -y
  -o Dpkg::Options::="--force-confdef"
  -o Dpkg::Options::="--force-confold"
)

# Retry apt-get update to handle transient DNS failures (cloud-init network delays)
_apt_update() {
    local i
    for i in 1 2 3; do
        apt-get -qq update 2>/dev/null && return 0
        if [[ $i -lt 3 ]]; then
            echo "[security-update] apt update failed (attempt $i/3, DNS?), retrying in 20s..."
            sleep 20
        fi
    done
    echo "[security-update] WARNING: apt update failed after 3 attempts — upgrading with cached lists" >&2
}

echo "[security-update] apt index update"
_apt_update

echo "[security-update] finish interrupted dpkg state"
dpkg --force-confdef --force-confold --configure -a

echo "[security-update] upgrade packages"
apt-get "${APT_OPTS[@]}" upgrade || \
    echo "[security-update] WARNING: upgrade incomplete (DNS down? packages pending next run)" >&2

echo "[security-update] dist-upgrade packages"
apt-get "${APT_OPTS[@]}" dist-upgrade || \
    echo "[security-update] WARNING: dist-upgrade incomplete (DNS down? packages pending next run)" >&2

echo "[security-update] cleanup unused packages"
apt-get -y autoremove --purge
apt-get -y autoclean

if [[ -f /var/run/reboot-required ]]; then
  echo "[security-update] reboot required"
else
  echo "[security-update] reboot not required"
fi

echo "[security-update] done"
