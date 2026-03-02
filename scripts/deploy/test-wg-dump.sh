#!/usr/bin/env bash
set +e
for IFACE in awg1 awg0 wg1 wg0; do
  DUMP=$(sudo -n awg show "$IFACE" dump 2>/dev/null || sudo -n wg show "$IFACE" dump 2>/dev/null || awg show "$IFACE" dump 2>/dev/null || wg show "$IFACE" dump 2>/dev/null || true)
  [ -n "$DUMP" ] && printf '%s\n' "$DUMP"
done
true
rc=$?
echo "RC=$rc"
