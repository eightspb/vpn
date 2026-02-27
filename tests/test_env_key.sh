#!/bin/bash
cd /mnt/c/WORK_MICS/vpn

read_kv() {
    local file="$1" key="$2"
    awk -F= -v k="$key" '$1==k{sub(/^[^=]*=/,"",$0); gsub(/\r/,""); gsub(/^[ \t'"'"']+|[ \t'"'"']+$/,""); print; exit}' "$file" 2>/dev/null
}

expand_path() {
    local p="${1//\\/\/}"
    if [[ "$p" =~ ^([A-Za-z]):/(.*)$ ]]; then
        p="/mnt/${BASH_REMATCH[1],,}/${BASH_REMATCH[2]}"
    fi
    [[ "$p" == "~/"* ]] && p="${HOME}/${p#'~/'}"
    echo "$p"
}

KEY=$(read_kv .env VPS1_KEY)
echo "RAW KEY=[$KEY]"
EKEY=$(expand_path "$KEY")
echo "EXPANDED=[$EKEY]"
ls -la "$EKEY" 2>&1

echo ""
echo "Testing SSH to VPS1..."
VPS1_IP=$(read_kv .env VPS1_IP)
VPS1_USER=$(read_kv .env VPS1_USER)
echo "VPS1: ${VPS1_USER}@${VPS1_IP} with key $EKEY"
ssh -i "$EKEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes "${VPS1_USER}@${VPS1_IP}" "hostname" 2>&1 && echo "VPS1: OK" || echo "VPS1: FAIL"
