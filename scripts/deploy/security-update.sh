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

echo "[security-update] apt index update"
apt-get -qq update

echo "[security-update] finish interrupted dpkg state"
dpkg --force-confdef --force-confold --configure -a

echo "[security-update] upgrade packages"
apt-get "${APT_OPTS[@]}" upgrade

echo "[security-update] dist-upgrade packages"
apt-get "${APT_OPTS[@]}" dist-upgrade

echo "[security-update] cleanup unused packages"
apt-get -y autoremove --purge
apt-get -y autoclean

if [[ -f /var/run/reboot-required ]]; then
  echo "[security-update] reboot required"
else
  echo "[security-update] reboot not required"
fi

echo "[security-update] done"
