#!/bin/bash
# uninstall-quick.sh - Versión rápida sin confirmaciones (¡Cuidado!)

if [ "$EUID" -ne 0 ]; then echo "Necesitas ser root"; exit 1; fi

echo "Desinstalando Print Agent..."

# Detener y eliminar servicio
systemctl stop print-agent 2>/dev/null || true
systemctl disable print-agent 2>/dev/null || true
rm -f /etc/systemd/system/print-agent.service
systemctl daemon-reload

# Backup rápido de config
mkdir -p /root/print-agent-backup-quick 2>/dev/null || true
cp -r /opt/print-agent/config /root/print-agent-backup-quick/ 2>/dev/null || true

# Eliminar todo
rm -rf /opt/print-agent
userdel printagent 2>/dev/null || true
pkill -f print_agent.py 2>/dev/null || true

echo "✓ Desinstalado. Config backup: /root/print-agent-backup-quick/"
