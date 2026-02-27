#!/bin/bash
cd /mnt/c/WORK_MICS/vpn
KEY=$(awk -F= -v k="VPS1_KEY" '$1==k{sub(/^[^=]*=/,"",$0); gsub(/\r/,""); print; exit}' .env)
echo "KEY=[$KEY]"
echo -n "$KEY" | xxd
echo ""
echo "Testing tilde strip:"
p="$KEY"
echo "p=[$p]"
echo "p#~/=[${p#~/}]"
[[ "$p" == "~/"* ]] && echo "MATCH" || echo "NO MATCH"
[[ "$p" == '~/'* ]] && echo "MATCH2" || echo "NO MATCH2"
