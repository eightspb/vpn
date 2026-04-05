import paramiko
cmd=(
"for IFACE in awg1 awg0 wg1 wg0; do "
"DUMP=$(sudo -n awg show \"$IFACE\" dump 2>/dev/null || "
"sudo -n wg show \"$IFACE\" dump 2>/dev/null || "
"awg show \"$IFACE\" dump 2>/dev/null || "
"wg show \"$IFACE\" dump 2>/dev/null || true); "
"[ -n \"$DUMP\" ] && printf '%s\\n' \"$DUMP\"; "
"done; true"
)
client=paramiko.SSHClient()
client.load_system_host_keys()
client.set_missing_host_key_policy(paramiko.RejectPolicy())
client.connect(hostname='89.169.172.51', username='slava', key_filename='/opt/vpn/.ssh/ssh-key-1772056840349', timeout=30, banner_timeout=30)
stdin, stdout, stderr = client.exec_command(cmd, timeout=30)
out=stdout.read().decode('utf-8','replace')
err=stderr.read().decode('utf-8','replace')
code=stdout.channel.recv_exit_status()
print('EXIT',code)
print('ERR',err[:300].replace('\n','|'))
print('OUT_HEAD',out[:300].replace('\n','|'))
client.close()
