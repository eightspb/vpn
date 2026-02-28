#!/usr/bin/env python3
"""
generate-split-config.py — генерирует AllowedIPs для WireGuard split tunneling.

Логика: весь публичный интернет через VPN, кроме:
  - российских IP-диапазонов (идут напрямую)
  - RFC1918 и спецназначение (идут напрямую, кроме VPN-сетей)

VPN-сети 10.8.0.0/24 и 10.9.0.0/24 всегда включаются в AllowedIPs,
чтобы DNS (10.8.0.2) и VPN-шлюз (10.9.0.1) были доступны.

Для совместимости с Windows AmneziaVPN мелкие CIDR (/30, /31, /32)
агрегируются до /24, что сокращает количество маршрутов с ~21000 до ~4000.

Использование:
  python3 generate-split-config.py [--ru-list ru.txt] [--output-dir vpn-output]
  python3 generate-split-config.py --print-only

Источник российских IP: https://ipv4.fetus.jp/ru.txt (RIPE NCC данные)
"""

import argparse
import ipaddress
import os
import sys
import urllib.request
from datetime import datetime

RU_LIST_URL = "https://ipv4.fetus.jp/ru.txt"

ALWAYS_EXCLUDE = [
    "0.0.0.0/8",
    "100.64.0.0/10",
    "127.0.0.0/8",
    "169.254.0.0/16",
    "172.16.0.0/12",
    "192.0.0.0/24",
    "192.168.0.0/16",
    "198.18.0.0/15",
    "198.51.100.0/24",
    "203.0.113.0/24",
    "224.0.0.0/4",
    "240.0.0.0/4",
    "255.255.255.255/32",
]

# 10.0.0.0/8 is excluded, but VPN subnets must be routed through the tunnel
VPN_NETS = [
    "10.8.0.0/24",
    "10.9.0.0/24",
]

# Exclude 10.0.0.0/8 minus VPN subnets
TEN_EXCLUDE = [
    "10.0.0.0/13",    # 10.0-7.*
    "10.8.1.0/24",    # 10.8.1.* (keep 10.8.0.*)
    "10.8.2.0/23",
    "10.8.4.0/22",
    "10.8.8.0/21",
    "10.8.16.0/20",
    "10.8.32.0/19",
    "10.8.64.0/18",
    "10.8.128.0/17",
    "10.9.1.0/24",    # 10.9.1.* (keep 10.9.0.*)
    "10.9.2.0/23",
    "10.9.4.0/22",
    "10.9.8.0/21",
    "10.9.16.0/20",
    "10.9.32.0/19",
    "10.9.64.0/18",
    "10.9.128.0/17",
    "10.10.0.0/15",
    "10.12.0.0/14",
    "10.16.0.0/12",
    "10.32.0.0/11",
    "10.64.0.0/10",
    "10.128.0.0/9",
]

MAX_ROUTES = 4000


def load_ru_networks(path=None):
    """Загружает российские IP-диапазоны из файла или URL."""
    lines = []
    if path and os.path.exists(path):
        print(f"[*] Загружаю российские IP из файла: {path}", file=sys.stderr)
        with open(path) as f:
            lines = f.readlines()
    else:
        print(f"[*] Скачиваю российские IP с {RU_LIST_URL} ...", file=sys.stderr)
        req = urllib.request.Request(RU_LIST_URL, headers={"User-Agent": "vpn-split-config/1.0"})
        with urllib.request.urlopen(req, timeout=30) as resp:
            lines = resp.read().decode().splitlines()

    nets = []
    for line in lines:
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        try:
            nets.append(ipaddress.ip_network(line, strict=False))
        except ValueError:
            pass

    print(f"[*] Загружено {len(nets)} российских CIDR-блоков", file=sys.stderr)
    return nets


def subtract_network(nets, exclude_net):
    """Вычитает exclude_net из списка сетей."""
    result = []
    for net in nets:
        if net.overlaps(exclude_net):
            result.extend(net.address_exclude(exclude_net))
        else:
            result.append(net)
    return result


def supernet_reduce(nets, max_routes):
    """Reduce route count by expanding small CIDRs to their /24 supernet.

    Iteratively widens the prefix threshold (/32 -> /31 -> ... -> /17)
    until route count is within max_routes.  Only public non-excluded
    ranges are widened; VPN_NETS are kept intact.
    """
    vpn_set = {ipaddress.ip_network(n) for n in VPN_NETS}
    if len(nets) <= max_routes:
        return nets

    for threshold in range(32, 16, -1):
        expanded = set()
        for n in nets:
            if n in vpn_set or n.prefixlen <= threshold:
                expanded.add(n)
            else:
                expanded.add(n.supernet(new_prefix=threshold))
        collapsed = list(ipaddress.collapse_addresses(sorted(expanded)))
        print(f"[*] Порог /{threshold}: {len(collapsed)} маршрутов", file=sys.stderr)
        if len(collapsed) <= max_routes:
            return collapsed

    return list(ipaddress.collapse_addresses(sorted(expanded)))


def compute_allowed_ips(ru_nets):
    """Вычисляет список AllowedIPs = всё IPv4 минус RU минус RFC1918 + VPN-сети."""
    exclude_all = (
        [ipaddress.ip_network(n) for n in ALWAYS_EXCLUDE]
        + [ipaddress.ip_network(n) for n in TEN_EXCLUDE]
        + ru_nets
    )

    remaining = [ipaddress.ip_network("0.0.0.0/0")]
    total = len(exclude_all)
    for i, ex in enumerate(exclude_all):
        remaining = subtract_network(remaining, ex)
        if (i + 1) % 500 == 0:
            print(f"[*] Обработано {i+1}/{total} исключений, осталось {len(remaining)} блоков...", file=sys.stderr)

    remaining.sort()
    print(f"[*] До агрегации: {len(remaining)} CIDR-блоков", file=sys.stderr)

    remaining = supernet_reduce(remaining, MAX_ROUTES)
    print(f"[*] После агрегации: {len(remaining)} CIDR-блоков (лимит {MAX_ROUTES})", file=sys.stderr)

    has_dns = any(ipaddress.ip_address("10.8.0.2") in n for n in remaining)
    has_gw = any(ipaddress.ip_address("10.9.0.1") in n for n in remaining)
    if not has_dns or not has_gw:
        print("[!] ВНИМАНИЕ: VPN-сети не найдены в результате, добавляю принудительно", file=sys.stderr)
        for vn in VPN_NETS:
            remaining.append(ipaddress.ip_network(vn))
        remaining = list(ipaddress.collapse_addresses(sorted(remaining)))

    print(f"[*] Итого AllowedIPs: {len(remaining)} CIDR-блоков", file=sys.stderr)
    return remaining


def patch_conf(template_path, output_path, allowed_ips_str, label):
    """Создаёт новый конфиг с обновлёнными AllowedIPs."""
    with open(template_path) as f:
        content = f.read()

    lines = content.splitlines()
    new_lines = []
    replaced = False
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("AllowedIPs"):
            if not replaced:
                new_lines.append(f"# Split tunneling: RU-сайты напрямую, остальное через VPN (сгенерировано {datetime.utcnow().strftime('%Y-%m-%d')})")
                new_lines.append(f"AllowedIPs = {allowed_ips_str}")
                replaced = True
        elif stripped.startswith("# Split tunneling") or stripped.startswith("# Весь трафик"):
            pass
        else:
            new_lines.append(line)

    with open(output_path, "w") as f:
        f.write("\n".join(new_lines) + "\n")

    print(f"[+] Записан {label}: {output_path}", file=sys.stderr)


def main():
    parser = argparse.ArgumentParser(description="Генератор split tunneling конфигов для WireGuard")
    parser.add_argument("--ru-list", default=None, help="Путь к файлу с российскими IP (иначе скачивается)")
    parser.add_argument("--output-dir", default="vpn-output", help="Директория для конфигов")
    parser.add_argument("--print-only", action="store_true", help="Только вывести AllowedIPs, не писать файлы")
    args = parser.parse_args()

    ru_nets = load_ru_networks(args.ru_list)
    allowed = compute_allowed_ips(ru_nets)
    allowed_str = ", ".join(str(n) for n in allowed)

    if args.print_only:
        print(allowed_str)
        return

    output_dir = args.output_dir
    os.makedirs(output_dir, exist_ok=True)

    for src_name, dst_name, label in [
        ("client.conf", "client-split.conf", "client-split"),
        ("phone.conf", "phone-split.conf", "phone-split"),
    ]:
        src = os.path.join(output_dir, src_name)
        dst = os.path.join(output_dir, dst_name)
        if os.path.exists(src):
            patch_conf(src, dst, allowed_str, label)
        else:
            print(f"[!] Не найден исходный конфиг: {src}", file=sys.stderr)

    print(f"\n[+] Готово. Конфиги с split tunneling (RU напрямую) сохранены в {output_dir}/", file=sys.stderr)
    print(f"    Всего AllowedIPs блоков: {len(allowed)}", file=sys.stderr)


if __name__ == "__main__":
    main()
