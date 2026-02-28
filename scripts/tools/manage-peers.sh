#!/usr/bin/env bash
# =============================================================================
# manage-peers.sh — массовое управление пирами AmneziaWG
#
# Команды:
#   add       Добавить одного или нескольких пиров
#   list      Показать все пиры на сервере
#   remove    Удалить пира по имени или IP
#   export    Экспортировать конфиг пира (full/split) + QR
#   batch     Массовое создание пиров из CSV/списка
#   info      Показать лимиты и статистику подсети
#
# Использование:
#   bash manage-peers.sh add --name laptop
#   bash manage-peers.sh add --name laptop --type pc --mode split
#   bash manage-peers.sh batch --file devices.csv
#   bash manage-peers.sh batch --prefix dev --count 50
#   bash manage-peers.sh list
#   bash manage-peers.sh remove --name laptop
#   bash manage-peers.sh remove --ip 10.9.0.5
#   bash manage-peers.sh export --name laptop --qr
#   bash manage-peers.sh info
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_ROOT"

source "${PROJECT_ROOT}/lib/common.sh"

# ── Defaults ─────────────────────────────────────────────────────────────────

VPS1_IP="" VPS1_USER="root" VPS1_KEY="" VPS1_PASS=""
TUN_NET="10.9.0"
OUTPUT_DIR="./vpn-output"
PEERS_DB="${OUTPUT_DIR}/peers.json"
SSH_TIMEOUT=30

# ── Load env ─────────────────────────────────────────────────────────────────

load_defaults_from_files

# ── SSH helper ───────────────────────────────────────────────────────────────

_ssh() {
    local cmd="$1"
    local key
    key="$(expand_tilde "$VPS1_KEY")"
    key="$(auto_pick_key_if_missing "$key")"
    key="$(prepare_key_for_ssh "$key")"
    ssh_exec "$VPS1_IP" "$VPS1_USER" "$key" "$VPS1_PASS" "$cmd" "$SSH_TIMEOUT"
}

# ── Server data cache ────────────────────────────────────────────────────────

_SERVER_DATA=""
_fetch_server_data() {
    [[ -n "$_SERVER_DATA" ]] && return
    _SERVER_DATA=$(_ssh '
echo "=PUB="
sudo awg show awg1 public-key
echo "=PORT="
sudo awg show awg1 listen-port
echo "=JUNK="
sudo awk "/^\[Interface\]/{f=1;next} f && /^\[/{exit} f && /^(Jc|Jmin|Jmax|S1|S2|H1|H2|H3|H4)[[:space:]]*=/{print}" /etc/amnezia/amneziawg/awg1.conf
echo "=PEERS="
sudo awg show awg1 allowed-ips
echo "=DUMP="
sudo awg show awg1 dump
echo "=END="
')
}

_get_field() {
    local tag="$1"
    echo "$_SERVER_DATA" | awk "/^=${tag}=/{found=1; next} found && /^=/{exit} found{print}"
}

# ── Peers DB (JSON-like flat file) ───────────────────────────────────────────

_init_db() {
    mkdir -p "$OUTPUT_DIR"
    [[ -f "$PEERS_DB" ]] || echo '[]' > "$PEERS_DB"
}

_db_add() {
    local name="$1" ip="$2" type="$3" pub="$4" priv="$5" created="$6" conf_file="$7"
    _init_db
    local tmp="${PEERS_DB}.tmp"
    if command -v python3 &>/dev/null; then
        python3 -c "
import json, sys
db = json.load(open('$PEERS_DB'))
db.append({
    'name': '$name',
    'ip': '$ip',
    'type': '$type',
    'public_key': '$pub',
    'private_key': '$priv',
    'created': '$created',
    'config_file': '$conf_file'
})
json.dump(db, open('$tmp', 'w'), indent=2, ensure_ascii=False)
"
    else
        # fallback without python — append line-based
        local entry="{\"name\":\"$name\",\"ip\":\"$ip\",\"type\":\"$type\",\"public_key\":\"$pub\",\"private_key\":\"$priv\",\"created\":\"$created\",\"config_file\":\"$conf_file\"}"
        if [[ "$(cat "$PEERS_DB")" == "[]" ]]; then
            echo "[$entry]" > "$tmp"
        else
            sed '$ s/]$/,'"$entry"']/' "$PEERS_DB" > "$tmp"
        fi
    fi
    mv "$tmp" "$PEERS_DB"
}

_db_remove() {
    local field="$1" value="$2"
    [[ -f "$PEERS_DB" ]] || return
    if command -v python3 &>/dev/null; then
        python3 -c "
import json
db = json.load(open('$PEERS_DB'))
db = [p for p in db if p.get('$field') != '$value']
json.dump(db, open('$PEERS_DB', 'w'), indent=2, ensure_ascii=False)
"
    fi
}

_db_find() {
    local field="$1" value="$2"
    [[ -f "$PEERS_DB" ]] || { echo ""; return; }
    if command -v python3 &>/dev/null; then
        python3 -c "
import json
db = json.load(open('$PEERS_DB'))
for p in db:
    if p.get('$field') == '$value':
        for k,v in p.items():
            print(f'{k}={v}')
        break
"
    fi
}

# ── IP allocation ────────────────────────────────────────────────────────────

_get_used_ips() {
    _fetch_server_data
    local peers_block
    peers_block="$(_get_field PEERS)"
    echo "$peers_block" | grep -oE "${TUN_NET//./\\.}\.[0-9]+" | sort -t. -k4 -n | uniq
}

_next_free_ip() {
    local used="$1"
    local i candidate
    for i in $(seq 3 254); do
        candidate="${TUN_NET}.${i}"
        if ! echo "$used" | grep -qF "$candidate"; then
            echo "$candidate"
            return
        fi
    done
    echo ""
}

_count_used_ips() {
    local used="$1"
    echo "$used" | grep -c "${TUN_NET//./\\.}" 2>/dev/null || echo "0"
}

# ── Config generation ────────────────────────────────────────────────────────

_write_config() {
    local file="$1" priv="$2" addr="$3" mtu="$4" allowed="$5"
    local server_pub server_port junk_block dns endpoint

    _fetch_server_data
    server_pub="$(_get_field PUB)"
    server_port="$(_get_field PORT)"
    junk_block="$(_get_field JUNK)"
    dns="10.8.0.2"
    endpoint="${VPS1_IP}:${server_port}"

    {
        echo "[Interface]"
        echo "Address    = ${addr}"
        echo "PrivateKey = ${priv}"
        echo "DNS        = ${dns}"
        echo "MTU        = ${mtu}"
        if [[ -n "$junk_block" ]]; then
            echo ""
            echo "$junk_block"
        fi
        echo ""
        echo "[Peer]"
        echo "PublicKey           = ${server_pub}"
        echo "Endpoint            = ${endpoint}"
        echo "AllowedIPs          = ${allowed}"
        echo "PersistentKeepalive = 25"
    } > "$file"
}

_get_split_allowed() {
    local split_py="${SCRIPT_DIR}/generate-split-config.py"
    if [[ -f "$split_py" ]]; then
        python3 "$split_py" --print-only 2>/dev/null
    else
        echo ""
    fi
}

# ── QR code generation ───────────────────────────────────────────────────────

_show_qr() {
    local conf_file="$1"
    if command -v qrencode &>/dev/null; then
        qrencode -t ANSIUTF8 < "$conf_file"
    elif command -v python3 &>/dev/null; then
        python3 -c "
import sys
try:
    import qrcode
    qr = qrcode.QRCode(error_correction=qrcode.constants.ERROR_CORRECT_L)
    qr.add_data(open('$conf_file').read())
    qr.make(fit=True)
    qr.print_ascii(invert=True)
except ImportError:
    print('Для QR установите: pip install qrcode[pil]')
    print('Или: sudo apt install qrencode')
    sys.exit(1)
"
    else
        warn "Для QR-кодов установите qrencode или python3 qrcode"
        return 1
    fi
}

_save_qr_png() {
    local conf_file="$1" png_file="$2"
    if command -v qrencode &>/dev/null; then
        qrencode -t PNG -o "$png_file" -r "$conf_file" -s 6
    elif command -v python3 &>/dev/null; then
        python3 -c "
import sys
try:
    import qrcode
    qr = qrcode.QRCode(error_correction=qrcode.constants.ERROR_CORRECT_L, box_size=6, border=2)
    qr.add_data(open('$conf_file').read())
    qr.make(fit=True)
    img = qr.make_image(fill_color='black', back_color='white')
    img.save('$png_file')
except ImportError:
    print('Для PNG QR установите: pip install qrcode[pil]')
    sys.exit(1)
"
    else
        warn "Для QR PNG установите qrencode или python3 qrcode[pil]"
        return 1
    fi
}

# ── Command: add ─────────────────────────────────────────────────────────────

cmd_add() {
    local name="" ip="" type="phone" mode="full" show_qr=false save_qr=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name|-n)   name="$2";  shift 2 ;;
            --ip)        ip="$2";    shift 2 ;;
            --type|-t)   type="$2";  shift 2 ;;
            --mode|-m)   mode="$2";  shift 2 ;;
            --qr)        show_qr=true; shift ;;
            --qr-png)    save_qr=true; shift ;;
            --help|-h)   usage_add; return 0 ;;
            *) err "Неизвестный параметр для add: $1" ;;
        esac
    done

    [[ -z "$name" ]] && err "Укажите имя пира: --name <name>"
    [[ -z "$VPS1_IP" ]] && err "VPS1_IP не задан (проверьте .env)"
    [[ -z "$VPS1_KEY" && -z "$VPS1_PASS" ]] && err "Укажите VPS1_KEY или VPS1_PASS"

    local mtu
    case "$type" in
        pc|desktop|laptop|computer) mtu=1360 ;;
        phone|mobile|tablet|ios|android) mtu=1280 ;;
        router|mikrotik|openwrt) mtu=1400 ;;
        *) mtu=1280 ;;
    esac

    mkdir -p "$OUTPUT_DIR"
    _init_db
    _fetch_server_data

    local used_ips
    used_ips="$(_get_used_ips)"

    if [[ -z "$ip" ]]; then
        ip="$(_next_free_ip "$used_ips")"
        [[ -z "$ip" ]] && err "Нет свободных IP в ${TUN_NET}.3-254"
    else
        if echo "$used_ips" | grep -qF "$ip"; then
            err "IP $ip уже занят"
        fi
    fi

    step "Добавление пира: $name ($type, $ip)"

    info "Генерация ключей на сервере..."
    local peer_data
    peer_data=$(_ssh "
PRIV=\$(sudo awg genkey)
PUB=\$(printf '%s' \"\$PRIV\" | sudo awg pubkey)
printf '\n# ${name}\n[Peer]\nPublicKey  = %s\nAllowedIPs = ${ip}/32\n' \"\$PUB\" | sudo tee -a /etc/amnezia/amneziawg/awg1.conf >/dev/null
sudo awg set awg1 peer \"\$PUB\" allowed-ips '${ip}/32' 2>/dev/null || true
printf 'PRIV=%s\nPUB=%s\n' \"\$PRIV\" \"\$PUB\"
")

    local priv pub
    priv="$(echo "$peer_data" | awk -F= '/^PRIV=/{print substr($0,6)}')"
    pub="$(echo "$peer_data" | awk -F= '/^PUB=/{print substr($0,5)}')"

    [[ -z "$priv" || -z "$pub" ]] && err "Не удалось получить ключи с сервера"
    ok "Ключи сгенерированы, pub=$pub"

    # Reset server data cache to pick up new peer
    _SERVER_DATA=""

    local safe_name="${name//[^a-zA-Z0-9_-]/_}"
    local safe_ip="${ip//./_}"
    local conf_file="${OUTPUT_DIR}/peer_${safe_name}_${safe_ip}.conf"

    local allowed="0.0.0.0/0"
    if [[ "$mode" == "split" ]]; then
        info "Генерация split-tunnel AllowedIPs (может занять 30-60 сек)..."
        allowed="$(_get_split_allowed)"
        [[ -z "$allowed" ]] && { warn "Не удалось сгенерировать split AllowedIPs, используем full tunnel"; allowed="0.0.0.0/0"; }
    fi

    _write_config "$conf_file" "$priv" "${ip}/24" "$mtu" "$allowed"
    ok "Конфиг: $conf_file"

    if [[ "$mode" == "both" ]]; then
        local split_file="${OUTPUT_DIR}/peer_${safe_name}_${safe_ip}_split.conf"
        info "Генерация split-tunnel конфига..."
        local split_allowed
        split_allowed="$(_get_split_allowed)"
        if [[ -n "$split_allowed" ]]; then
            _write_config "$split_file" "$priv" "${ip}/24" "$mtu" "$split_allowed"
            ok "Split конфиг: $split_file"
        else
            warn "Не удалось сгенерировать split конфиг"
        fi
    fi

    _db_add "$name" "$ip" "$type" "$pub" "$priv" "$(date +%Y-%m-%d_%H:%M:%S)" "$conf_file"
    ok "Пир добавлен в базу"

    if [[ "$show_qr" == true ]]; then
        echo ""
        info "QR-код для $name:"
        _show_qr "$conf_file"
    fi

    if [[ "$save_qr" == true ]]; then
        local qr_file="${OUTPUT_DIR}/peer_${safe_name}_${safe_ip}.png"
        _save_qr_png "$conf_file" "$qr_file" && ok "QR PNG: $qr_file"
    fi

    echo ""
    ok "Пир $name добавлен успешно"
    echo "  IP:     $ip"
    echo "  Тип:    $type (MTU=$mtu)"
    echo "  Режим:  $mode"
    echo "  Конфиг: $conf_file"
    echo ""
}

# ── Command: batch ───────────────────────────────────────────────────────────

cmd_batch() {
    local file="" prefix="" count=0 type="phone" mode="full" save_qr=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --file|-f)    file="$2";    shift 2 ;;
            --prefix|-p)  prefix="$2";  shift 2 ;;
            --count|-c)   count="$2";   shift 2 ;;
            --type|-t)    type="$2";    shift 2 ;;
            --mode|-m)    mode="$2";    shift 2 ;;
            --qr-png)     save_qr=true; shift ;;
            --help|-h)    usage_batch; return 0 ;;
            *) err "Неизвестный параметр для batch: $1" ;;
        esac
    done

    [[ -z "$file" && -z "$prefix" ]] && err "Укажите --file <csv> или --prefix <name> --count <N>"
    [[ -z "$VPS1_IP" ]] && err "VPS1_IP не задан (проверьте .env)"

    local devices=()

    if [[ -n "$file" ]]; then
        [[ -f "$file" ]] || err "Файл не найден: $file"
        info "Чтение устройств из $file..."
        while IFS=',' read -r dname dtype dmode dip; do
            dname="$(echo "$dname" | tr -d '[:space:]')"
            dtype="$(echo "${dtype:-$type}" | tr -d '[:space:]')"
            dmode="$(echo "${dmode:-$mode}" | tr -d '[:space:]')"
            dip="$(echo "${dip:-}" | tr -d '[:space:]')"
            [[ -z "$dname" || "$dname" == "name" ]] && continue
            devices+=("${dname}|${dtype}|${dmode}|${dip}")
        done < "$file"
    else
        [[ "$count" -gt 0 ]] || err "Укажите --count <N> (количество пиров)"
        info "Генерация $count пиров с префиксом '$prefix'..."
        for i in $(seq 1 "$count"); do
            devices+=("${prefix}-$(printf '%03d' "$i")|${type}|${mode}|")
        done
    fi

    local total=${#devices[@]}
    [[ "$total" -eq 0 ]] && err "Нет устройств для создания"

    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║   Массовое создание пиров: ${total} устройств                      ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    _fetch_server_data
    local used_ips
    used_ips="$(_get_used_ips)"
    local used_count
    used_count="$(_count_used_ips "$used_ips")"
    local available=$((252 - used_count))

    if [[ "$total" -gt "$available" ]]; then
        err "Недостаточно свободных IP: нужно $total, доступно $available (из 252)"
    fi

    info "Свободных IP: $available, создаём: $total"
    echo ""

    local success=0 failed=0
    local batch_report="${OUTPUT_DIR}/batch_$(date +%Y%m%d_%H%M%S).txt"

    {
        echo "# Batch peer creation report"
        echo "# Date: $(date)"
        echo "# Total: $total"
        echo "#"
        echo "# name,ip,type,mode,config_file,status"
    } > "$batch_report"

    for entry in "${devices[@]}"; do
        IFS='|' read -r dname dtype dmode dip <<< "$entry"

        local add_args=(--name "$dname" --type "$dtype" --mode "$dmode")
        [[ -n "$dip" ]] && add_args+=(--ip "$dip")
        [[ "$save_qr" == true ]] && add_args+=(--qr-png)

        echo -e "${CYAN}[$((success + failed + 1))/$total]${NC} Создаю пир: $dname ($dtype, $dmode)..."

        if cmd_add "${add_args[@]}" 2>&1; then
            ((success++))
            echo "$dname,$dip,$dtype,$dmode,,OK" >> "$batch_report"
        else
            ((failed++))
            echo "$dname,$dip,$dtype,$dmode,,FAILED" >> "$batch_report"
            warn "Не удалось создать пир: $dname"
        fi

        # Reset server data cache for next peer
        _SERVER_DATA=""
    done

    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║   Batch завершён                                            ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    ok "Успешно: $success"
    [[ "$failed" -gt 0 ]] && fail "Ошибки: $failed"
    info "Отчёт: $batch_report"
    echo ""
}

# ── Command: list ────────────────────────────────────────────────────────────

cmd_list() {
    local verbose=false
    [[ "${1:-}" == "--verbose" || "${1:-}" == "-v" ]] && verbose=true
    [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && { usage_list; return 0; }

    [[ -z "$VPS1_IP" ]] && err "VPS1_IP не задан (проверьте .env)"

    _fetch_server_data

    local peers_block dump_block
    peers_block="$(_get_field PEERS)"
    dump_block="$(_get_field DUMP)"

    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║   Пиры на VPS1 (${VPS1_IP})                                ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    printf "  ${BOLD}%-20s %-16s %-15s %-12s${NC}\n" "PUBLIC KEY" "IP" "HANDSHAKE" "TRAFFIC"
    printf "  %-20s %-16s %-15s %-12s\n" "────────────────────" "────────────────" "───────────────" "────────────"

    local count=0
    while IFS=$'\t' read -r pub_key allowed_ips; do
        [[ -z "$pub_key" || "$pub_key" == "(none)" ]] && continue
        local ip
        ip="$(echo "$allowed_ips" | grep -oE '10\.9\.0\.[0-9]+' | head -1)"
        [[ -z "$ip" ]] && ip="$allowed_ips"

        local handshake="never" rx="0" tx="0"
        local dump_line
        dump_line="$(echo "$dump_block" | grep "^${pub_key}" || true)"
        if [[ -n "$dump_line" ]]; then
            local hs_epoch
            hs_epoch="$(echo "$dump_line" | awk '{print $5}')"
            if [[ -n "$hs_epoch" && "$hs_epoch" != "0" ]]; then
                local now
                now="$(date +%s)"
                local diff=$((now - hs_epoch))
                if [[ "$diff" -lt 60 ]]; then
                    handshake="${diff}s ago"
                elif [[ "$diff" -lt 3600 ]]; then
                    handshake="$((diff / 60))m ago"
                elif [[ "$diff" -lt 86400 ]]; then
                    handshake="$((diff / 3600))h ago"
                else
                    handshake="$((diff / 86400))d ago"
                fi
            fi
            rx="$(echo "$dump_line" | awk '{printf "%.1f MB", $6/1048576}')"
            tx="$(echo "$dump_line" | awk '{printf "%.1f MB", $7/1048576}')"
        fi

        local short_pub="${pub_key:0:12}..."

        # Try to find name from local DB
        local db_name=""
        if [[ -f "$PEERS_DB" ]] && command -v python3 &>/dev/null; then
            db_name="$(python3 -c "
import json
db = json.load(open('$PEERS_DB'))
for p in db:
    if p.get('public_key','')[:20] == '${pub_key:0:20}':
        print(p.get('name','')); break
" 2>/dev/null || true)"
        fi

        local display_name="${db_name:-$short_pub}"
        if [[ "$handshake" != "never" && "$handshake" != *"d ago"* && "$handshake" != *"h ago"* ]]; then
            printf "  ${GREEN}%-20s${NC} %-16s %-15s %s↓ %s↑\n" "$display_name" "$ip" "$handshake" "$rx" "$tx"
        else
            printf "  %-20s %-16s %-15s %s↓ %s↑\n" "$display_name" "$ip" "$handshake" "$rx" "$tx"
        fi

        if [[ "$verbose" == true ]]; then
            echo "    PubKey: $pub_key"
        fi

        ((count++))
    done <<< "$peers_block"

    echo ""
    local used_ips
    used_ips="$(_get_used_ips)"
    local used_count
    used_count="$(_count_used_ips "$used_ips")"
    local available=$((252 - used_count))

    info "Всего пиров: $count"
    info "Занято IP: $used_count / 252"
    info "Свободно: $available"
    echo ""
}

# ── Command: remove ──────────────────────────────────────────────────────────

cmd_remove() {
    local name="" ip="" force=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name|-n)  name="$2";  shift 2 ;;
            --ip)       ip="$2";    shift 2 ;;
            --force|-f) force=true; shift ;;
            --help|-h)  usage_remove; return 0 ;;
            *) err "Неизвестный параметр для remove: $1" ;;
        esac
    done

    [[ -z "$name" && -z "$ip" ]] && err "Укажите --name <name> или --ip <ip>"
    [[ -z "$VPS1_IP" ]] && err "VPS1_IP не задан"

    _fetch_server_data

    local pub_key=""

    if [[ -n "$name" ]]; then
        local db_entry
        db_entry="$(_db_find name "$name")"
        if [[ -n "$db_entry" ]]; then
            pub_key="$(echo "$db_entry" | awk -F= '/^public_key=/{print substr($0,12)}')"
            ip="$(echo "$db_entry" | awk -F= '/^ip=/{print substr($0,4)}')"
        fi
    fi

    if [[ -z "$pub_key" && -n "$ip" ]]; then
        local peers_block
        peers_block="$(_get_field PEERS)"
        pub_key="$(echo "$peers_block" | grep "$ip" | awk '{print $1}')"
    fi

    [[ -z "$pub_key" ]] && err "Пир не найден: name=$name ip=$ip"

    if [[ "$force" != true ]]; then
        echo -e "${YELLOW}Удалить пир?${NC}"
        echo "  Имя: ${name:-unknown}"
        echo "  IP:  ${ip:-unknown}"
        echo "  Key: ${pub_key:0:20}..."
        echo ""
        read -rp "Подтвердите (y/N): " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Отменено."; return 0; }
    fi

    step "Удаление пира: ${name:-$ip}"

    info "Удаление с сервера..."
    _ssh "sudo awg set awg1 peer '${pub_key}' remove 2>/dev/null || true"

    _ssh "sudo python3 -c \"
lines = open('/etc/amnezia/amneziawg/awg1.conf').read().split('\\n')
new_lines, skip = [], False
for line in lines:
    if '${pub_key}' in line:
        while new_lines and (new_lines[-1].startswith('#') or new_lines[-1].strip() == '' or new_lines[-1].strip() == '[Peer]'):
            removed = new_lines.pop()
            if removed.strip() == '[Peer]': break
        skip = True; continue
    if skip:
        if line.startswith('AllowedIPs'): continue
        if line.strip() == '': skip = False; continue
        skip = False
    new_lines.append(line)
open('/etc/amnezia/amneziawg/awg1.conf','w').write('\\n'.join(new_lines))
\" 2>/dev/null || true"

    ok "Пир удалён с сервера"

    if [[ -n "$name" ]]; then
        _db_remove name "$name"
        ok "Пир удалён из базы"
    elif [[ -n "$ip" ]]; then
        _db_remove ip "$ip"
        ok "Пир удалён из базы"
    fi

    echo ""
}

# ── Command: export ──────────────────────────────────────────────────────────

cmd_export() {
    local name="" ip="" mode="full" show_qr=false save_qr=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name|-n)  name="$2";  shift 2 ;;
            --ip)       ip="$2";    shift 2 ;;
            --mode|-m)  mode="$2";  shift 2 ;;
            --qr)       show_qr=true; shift ;;
            --qr-png)   save_qr=true; shift ;;
            --help|-h)  usage_export; return 0 ;;
            *) err "Неизвестный параметр для export: $1" ;;
        esac
    done

    [[ -z "$name" && -z "$ip" ]] && err "Укажите --name <name> или --ip <ip>"

    local db_entry=""
    if [[ -n "$name" ]]; then
        db_entry="$(_db_find name "$name")"
    elif [[ -n "$ip" ]]; then
        db_entry="$(_db_find ip "$ip")"
    fi

    [[ -z "$db_entry" ]] && err "Пир не найден в базе: name=$name ip=$ip"

    local priv conf_file peer_ip peer_type
    priv="$(echo "$db_entry" | awk -F= '/^private_key=/{print substr($0,13)}')"
    conf_file="$(echo "$db_entry" | awk -F= '/^config_file=/{print substr($0,13)}')"
    peer_ip="$(echo "$db_entry" | awk -F= '/^ip=/{print substr($0,4)}')"
    peer_type="$(echo "$db_entry" | awk -F= '/^type=/{print substr($0,6)}')"
    name="$(echo "$db_entry" | awk -F= '/^name=/{print substr($0,6)}')"

    [[ -z "$priv" ]] && err "Приватный ключ не найден в базе для $name"

    _fetch_server_data

    local mtu
    case "$peer_type" in
        pc|desktop|laptop|computer) mtu=1360 ;;
        router|mikrotik|openwrt) mtu=1400 ;;
        *) mtu=1280 ;;
    esac

    local safe_name="${name//[^a-zA-Z0-9_-]/_}"
    local safe_ip="${peer_ip//./_}"

    if [[ "$mode" == "split" ]]; then
        local split_file="${OUTPUT_DIR}/peer_${safe_name}_${safe_ip}_split.conf"
        info "Генерация split-tunnel конфига для $name..."
        local split_allowed
        split_allowed="$(_get_split_allowed)"
        [[ -z "$split_allowed" ]] && err "Не удалось сгенерировать split AllowedIPs"
        _write_config "$split_file" "$priv" "${peer_ip}/24" "$mtu" "$split_allowed"
        conf_file="$split_file"
        ok "Split конфиг: $split_file"
    elif [[ ! -f "$conf_file" ]]; then
        info "Пересоздание конфига для $name..."
        _write_config "$conf_file" "$priv" "${peer_ip}/24" "$mtu" "0.0.0.0/0"
        ok "Конфиг пересоздан: $conf_file"
    else
        ok "Конфиг: $conf_file"
    fi

    if [[ "$show_qr" == true ]]; then
        echo ""
        info "QR-код для $name:"
        _show_qr "$conf_file"
    fi

    if [[ "$save_qr" == true ]]; then
        local qr_file="${conf_file%.conf}.png"
        _save_qr_png "$conf_file" "$qr_file" && ok "QR PNG: $qr_file"
    fi

    echo ""
}

# ── Command: info ────────────────────────────────────────────────────────────

cmd_info() {
    [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && { usage_info; return 0; }
    [[ -z "$VPS1_IP" ]] && err "VPS1_IP не задан (проверьте .env)"

    _fetch_server_data

    local used_ips
    used_ips="$(_get_used_ips)"
    local used_count
    used_count="$(_count_used_ips "$used_ips")"
    local available=$((252 - used_count))

    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║   Информация о VPN-подсети                                  ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "  Подсеть:          ${TUN_NET}.0/24"
    echo "  Шлюз (VPS1):      ${TUN_NET}.1"
    echo "  Первый клиент:    ${TUN_NET}.2"
    echo "  Диапазон пиров:   ${TUN_NET}.3 — ${TUN_NET}.254"
    echo ""
    echo "  Занято IP:        $used_count / 252"
    echo "  Свободно:         $available"
    echo "  Макс. устройств:  252 (с текущей подсетью /24)"
    echo ""

    if [[ "$available" -lt 50 ]]; then
        warn "Осталось менее 50 свободных IP!"
        echo ""
        echo "  Для расширения до 65534 устройств:"
        echo "  1. Изменить подсеть на ${TUN_NET%.*}.0.0/16"
        echo "  2. Обновить Address в awg1.conf на VPS1"
        echo "  3. Обновить AllowedIPs всех клиентов"
        echo ""
    fi

    if [[ -f "$PEERS_DB" ]] && command -v python3 &>/dev/null; then
        local db_count
        db_count="$(python3 -c "import json; print(len(json.load(open('$PEERS_DB'))))" 2>/dev/null || echo 0)"
        echo "  Пиров в локальной базе: $db_count"
        echo "  База: $PEERS_DB"
    fi

    echo ""
    info "Занятые IP:"
    echo "$used_ips" | while IFS= read -r line; do
        [[ -n "$line" ]] && echo "    $line"
    done
    echo ""
}

# ── Usage ────────────────────────────────────────────────────────────────────

usage_main() {
    cat <<'EOF'
manage-peers.sh — массовое управление пирами AmneziaWG

Использование:
  bash manage-peers.sh <команда> [опции]

Команды:
  add       Добавить пира
  batch     Массовое создание пиров
  list      Показать все пиры на сервере
  remove    Удалить пира
  export    Экспортировать конфиг / QR-код
  info      Лимиты и статистика подсети
  help      Эта справка

Общие опции (из .env или CLI):
  --vps1-ip IP        IP VPS1
  --vps1-user USER    SSH-пользователь VPS1
  --vps1-key PATH     SSH-ключ VPS1
  --vps1-pass PASS    SSH-пароль VPS1
  --output-dir DIR    Директория для конфигов (default: ./vpn-output)

Примеры:
  bash manage-peers.sh add --name laptop --type pc
  bash manage-peers.sh add --name phone2 --type phone --qr
  bash manage-peers.sh batch --prefix user --count 100 --type phone
  bash manage-peers.sh batch --file devices.csv
  bash manage-peers.sh list
  bash manage-peers.sh remove --name laptop
  bash manage-peers.sh export --name phone2 --qr
  bash manage-peers.sh info
EOF
}

usage_add() {
    cat <<'EOF'
manage-peers.sh add — добавить нового пира

Опции:
  --name, -n NAME     Имя устройства (обязательно)
  --ip IP             IP-адрес (default: автоопределение)
  --type, -t TYPE     Тип устройства:
                        pc, desktop, laptop, computer  (MTU=1360)
                        phone, mobile, tablet, ios, android  (MTU=1280)
                        router, mikrotik, openwrt  (MTU=1400)
  --mode, -m MODE     Режим туннеля:
                        full   — весь трафик через VPN (default)
                        split  — RU напрямую, остальное через VPN
                        both   — создать оба конфига
  --qr                Показать QR-код в терминале
  --qr-png            Сохранить QR-код как PNG

Примеры:
  bash manage-peers.sh add --name laptop --type pc --mode both
  bash manage-peers.sh add --name iphone --type phone --qr
  bash manage-peers.sh add --name router-home --type router --ip 10.9.0.100
EOF
}

usage_batch() {
    cat <<'EOF'
manage-peers.sh batch — массовое создание пиров

Режим 1: Из CSV-файла
  --file, -f FILE     CSV-файл (name,type,mode,ip)
                      type, mode, ip — опциональны

Режим 2: По шаблону
  --prefix, -p NAME   Префикс имени (например: user → user-001, user-002, ...)
  --count, -c N       Количество пиров

Общие опции:
  --type, -t TYPE     Тип по умолчанию (default: phone)
  --mode, -m MODE     Режим по умолчанию (default: full)
  --qr-png            Сохранить QR-коды как PNG

Формат CSV:
  name,type,mode,ip
  laptop,pc,full,
  phone-anna,phone,split,
  router-office,router,full,10.9.0.100

Примеры:
  bash manage-peers.sh batch --prefix employee --count 50 --type phone
  bash manage-peers.sh batch --file devices.csv --qr-png
  bash manage-peers.sh batch --prefix dev --count 10 --type pc --mode both
EOF
}

usage_list() {
    cat <<'EOF'
manage-peers.sh list — показать все пиры на сервере

Опции:
  --verbose, -v    Показать полные публичные ключи

Примеры:
  bash manage-peers.sh list
  bash manage-peers.sh list --verbose
EOF
}

usage_remove() {
    cat <<'EOF'
manage-peers.sh remove — удалить пира

Опции:
  --name, -n NAME    Удалить по имени
  --ip IP            Удалить по IP
  --force, -f        Без подтверждения

Примеры:
  bash manage-peers.sh remove --name laptop
  bash manage-peers.sh remove --ip 10.9.0.5 --force
EOF
}

usage_export() {
    cat <<'EOF'
manage-peers.sh export — экспортировать конфиг / QR-код

Опции:
  --name, -n NAME    Имя пира
  --ip IP            IP пира
  --mode, -m MODE    full (default) или split
  --qr               Показать QR в терминале
  --qr-png           Сохранить QR как PNG

Примеры:
  bash manage-peers.sh export --name laptop --qr
  bash manage-peers.sh export --name phone --mode split --qr-png
EOF
}

usage_info() {
    cat <<'EOF'
manage-peers.sh info — лимиты и статистика подсети

Показывает:
  - Текущую подсеть и диапазон IP
  - Занятые и свободные адреса
  - Максимальное количество устройств
  - Рекомендации по расширению
EOF
}

# ── Global args parsing ──────────────────────────────────────────────────────

GLOBAL_ARGS=()
COMMAND=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --vps1-ip)     VPS1_IP="$2";     shift 2 ;;
        --vps1-user)   VPS1_USER="$2";   shift 2 ;;
        --vps1-key)    VPS1_KEY="$2";    shift 2 ;;
        --vps1-pass)   VPS1_PASS="$2";   shift 2 ;;
        --output-dir)  OUTPUT_DIR="$2";  shift 2 ;;
        --tun-net)     TUN_NET="$2";     shift 2 ;;
        add|batch|list|remove|export|info|help)
            COMMAND="$1"; shift
            GLOBAL_ARGS=("$@")
            break
            ;;
        --help|-h) usage_main; exit 0 ;;
        *)
            if [[ -z "$COMMAND" ]]; then
                COMMAND="$1"; shift
                GLOBAL_ARGS=("$@")
                break
            fi
            ;;
    esac
done

[[ -z "$COMMAND" ]] && { usage_main; exit 0; }

trap cleanup_temp_keys EXIT

case "$COMMAND" in
    add)     cmd_add    "${GLOBAL_ARGS[@]+"${GLOBAL_ARGS[@]}"}" ;;
    batch)   cmd_batch  "${GLOBAL_ARGS[@]+"${GLOBAL_ARGS[@]}"}" ;;
    list)    cmd_list   "${GLOBAL_ARGS[@]+"${GLOBAL_ARGS[@]}"}" ;;
    remove)  cmd_remove "${GLOBAL_ARGS[@]+"${GLOBAL_ARGS[@]}"}" ;;
    export)  cmd_export "${GLOBAL_ARGS[@]+"${GLOBAL_ARGS[@]}"}" ;;
    info)    cmd_info   "${GLOBAL_ARGS[@]+"${GLOBAL_ARGS[@]}"}" ;;
    help)    usage_main ;;
    *) err "Неизвестная команда: $COMMAND. Используйте: add, batch, list, remove, export, info" ;;
esac
