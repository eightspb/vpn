#!/usr/bin/env bash
set -euo pipefail
curl -k -s -c /tmp/admin.cookies -H "Content-Type: application/json" -d '{"username":"admin","password":"My-secure-admin-password"}' https://127.0.0.1:8443/api/auth/login
echo
curl -k -s -b /tmp/admin.cookies https://127.0.0.1:8443/api/monitoring/peers | head -c 600
echo
