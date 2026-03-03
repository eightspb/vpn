#!/usr/bin/env bash
set -euo pipefail
d="$(mktemp -d)"
cat > "$d/ssh" <<'EOF'
#!/usr/bin/env bash
exec ssh.exe "$@"
EOF
cat > "$d/scp" <<'EOF'
#!/usr/bin/env bash
exec scp.exe "$@"
EOF
chmod +x "$d/ssh" "$d/scp"
export PATH="$d:$PATH"
bash scripts/deploy/deploy.sh --with-proxy
