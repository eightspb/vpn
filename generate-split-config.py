#!/usr/bin/env python3
"""
generate-split-config.py — генерирует AllowedIPs для WireGuard split tunneling.

Логика: весь публичный интернет через VPN, кроме:
  - российских IP-диапазонов (идут напрямую)
  - RFC1918 и спецназначение (идут напрямую)

Использование:
  python3 generate-split-config.py [--ru-list ru.txt] [--output-dir vpn-output]

Источник российских IP: https://ipv4.fetus.jp/ru.txt (RIPE NCC данные)
"""

import argparse
import ipaddress
import os
import sys
import urllib.request
from datetime import datetime

RU_LIST_URL = "https://ipv4.fetus.jp/ru.txt"

# RFC1918 и специальные диапазоны, которые всегда идут напрямую
ALWAYS_EXCLUDE = [
    "0.0.0.0/8",        # "This" network
    "10.0.0.0/8",       # RFC1918 private
    "100.64.0.0/10",    # Shared address space (CGNAT)
    "127.0.0.0/8",      # Loopback
    "169.254.0.0/16",   # Link-local
    "172.16.0.0/12",    # RFC1918 private
    "192.0.0.0/24",     # IETF Protocol Assignments
    "192.168.0.0/16",   # RFC1918 private
    "198.18.0.0/15",    # Benchmarking
    "198.51.100.0/24",  # Documentation
    "203.0.113.0/24",   # Documentation
    "224.0.0.0/4",      # Multicast
    "240.0.0.0/4",      # Reserved
    "255.255.255.255/32",
]


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


def compute_allowed_ips(ru_nets):
    """Вычисляет список AllowedIPs = всё IPv4 минус RU минус RFC1918."""
    exclude_all = [ipaddress.ip_network(n) for n in ALWAYS_EXCLUDE] + ru_nets

    remaining = [ipaddress.ip_network("0.0.0.0/0")]
    total = len(exclude_all)
    for i, ex in enumerate(exclude_all):
        remaining = subtract_network(remaining, ex)
        if (i + 1) % 500 == 0:
            print(f"[*] Обработано {i+1}/{total} исключений, осталось {len(remaining)} блоков...", file=sys.stderr)

    remaining.sort()
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
            # пропускаем старую строку AllowedIPs
        elif stripped.startswith("# Split tunneling") or stripped.startswith("# Весь трафик"):
            pass  # убираем старые комментарии про split
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

    # Обновляем client-split.conf и phone-split.conf
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
