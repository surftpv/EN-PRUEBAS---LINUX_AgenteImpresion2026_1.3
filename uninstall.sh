#!/bin/bash

# ============================================
# Script de Desinstalación - Print Agent
# ============================================

set -e

# Colores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Variables
INSTALL_DIR="/opt/print-agent"
SERVICE_NAME="print-agent"
SERVICE_USER="printagent"
CONFIG_BACKUP_DIR="/root/print-agent-backup-$(date +%Y%m%d_%H%M%S)"

# Función para mostrar ayuda
show_help() {
    echo "Uso: sudo bash uninstall.sh [OPCIÓN]"
    echo ""
    echo "Opciones:"
    echo "  -h, --help          Muestra esta ayuda"
    echo "  -f, --full          Desinstalación completa (elimina TODO incluyendo config)"
    echo "  -k, --keep-config   Desinstala pero conserva la configuración (por defecto)"
    echo "  -p, --purge         Igual que --full, elimina todo rastro"
    echo ""
    echo "Ejemplos:"
    echo "  sudo bash uninstall.sh           # Desinstala conservando config"
    echo "  sudo bash uninstall.sh --full    # Desinstalación completa total"
    echo "  sudo bash uninstall.sh --purge   # Elimina absolutamente todo"
}

# Parsear argumentos
MODE="keep-config"

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        -f|--full|-p|--purge)
            MODE="full"
            shift
            ;;
        -k|--keep-config)
            MODE="keep-config"
            shift
            ;;
        *)
            echo -e "${RED}Opción desconocida: $1${NC}"
            show_help
            exit 1
            ;;
    esac
done

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Desinstalador de Print Agent         ${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# Verificar que se ejecuta como root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error: Este script debe ejecutarse como root${NC}"
    echo "Uso: sudo bash uninstall.sh"
    exit 1
fi

# Confirmación del usuario
echo -e "${YELLOW}⚠️  ATENCIÓN: Esto detendrá y eliminará el servicio Print Agent${NC}"
if [ "$MODE" == "full" ]; then
    echo -e "${RED}🔴 MODO COMPLETO: Se eliminará TODO incluyendo configuraciones${NC}"
else
    echo -e "${BLUE}🔵 MODO ESTÁNDAR: Se conservará la configuración en: $CONFIG_BACKUP_DIR${NC}"
fi
echo ""
read -p "¿Estás seguro? Escribe 'SI' para continuar: " CONFIRM

if [ "$CONFIRM" != "SI" ]; then
    echo -e "${YELLOW}Operación cancelada por el usuario${NC}"
    exit 0
fi

echo ""
echo -e "${YELLOW}[1/7] Deteniendo servicio...${NC}"

# Detener y deshabilitar el servicio
if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
    systemctl stop "$SERVICE_NAME"
    echo "✓ Servicio detenido"
else
    echo "ℹ️  El servicio no estaba en ejecución"
fi

if systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
    systemctl disable "$SERVICE_NAME"
    echo "✓ Servicio deshabilitado"
else
    echo "ℹ️  El servicio no estaba habilitado"
fi

echo -e "${YELLOW}[2/7] Eliminando archivos de servicio systemd...${NC}"

# Eliminar archivo de servicio
if [ -f "/etc/systemd/system/${SERVICE_NAME}.service" ]; then
    rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
    echo "✓ Archivo de servicio eliminado"
fi

# Recargar systemd
systemctl daemon-reload
systemctl reset-failed 2>/dev/null || true
echo "✓ systemd recargado"

echo -e "${YELLOW}[3/7] Gestionando archivos de instalación...${NC}"

if [ -d "$INSTALL_DIR" ]; then
    if [ "$MODE" == "keep-config" ]; then
        # Modo estándar: hacer backup de la configuración
        echo "📦 Haciendo backup de la configuración..."
        mkdir -p "$CONFIG_BACKUP_DIR"
        
        if [ -d "$INSTALL_DIR/config" ]; then
            cp -r "$INSTALL_DIR/config" "$CONFIG_BACKUP_DIR/"
            echo "✓ Configuración respaldada en: $CONFIG_BACKUP_DIR/config"
        fi
        
        # Guardar también un resumen
        cat > "$CONFIG_BACKUP_DIR/README.txt" << EOF
Backup de Print Agent
Fecha: $(date)
Origen: $INSTALL_DIR

Archivos respaldados:
- config/: Configuración del servicio

Para restaurar:
sudo mkdir -p $INSTALL_DIR/config
sudo cp -r $CONFIG_BACKUP_DIR/config/* $INSTALL_DIR/config/
EOF
    fi
    
    # Eliminar directorio de instalación
    rm -rf "$INSTALL_DIR"
    echo "✓ Directorio $INSTALL_DIR eliminado"
else
    echo "ℹ️  El directorio $INSTALL_DIR no existe"
fi

echo -e "${YELLOW}[4/7] Eliminando usuario del servicio...${NC}"

if id "$SERVICE_USER" &>/dev/null; then
    # Matar procesos del usuario si quedan
    pkill -u "$SERVICE_USER" 2>/dev/null || true
    
    # Eliminar usuario
    userdel "$SERVICE_USER" 2>/dev/null || userdel -r "$SERVICE_USER" 2>/dev/null || true
    echo "✓ Usuario $SERVICE_USER eliminado"
else
    echo "ℹ️  El usuario $SERVICE_USER no existe"
fi

echo -e "${YELLOW}[5/7] Limpiando logs y caché...${NC}"

# Limpiar logs de journalctl
journalctl --rotate 2>/dev/null || true
journalctl --vacuum-time=1s --unit="$SERVICE_NAME" 2>/dev/null || true
echo "✓ Logs del servicio limpiados"

# Limpiar logs antiguos si existen
if [ -d "/var/log/print-agent" ]; then
    rm -rf "/var/log/print-agent"
    echo "✓ Logs antiguos eliminados"
fi

echo -e "${YELLOW}[6/7] Verificando procesos residuales...${NC}"

# Matar cualquier proceso Python relacionado con print_agent
PIDS=$(pgrep -f "print_agent.py" 2>/dev/null || true)
if [ -n "$PIDS" ]; then
    echo "⚠️  Encontrados procesos residuales, terminando..."
    kill -9 $PIDS 2>/dev/null || true
    echo "✓ Procesos terminados"
else
    echo "✓ No hay procesos residuales"
fi

echo -e "${YELLOW}[7/7] Verificación final...${NC}"

# Verificar que todo se eliminó
ERRORS=0

if [ -d "$INSTALL_DIR" ]; then
    echo -e "${RED}✗ $INSTALL_DIR aún existe${NC}"
    ERRORS=$((ERRORS + 1))
else
    echo -e "${GREEN}✓ $INSTALL_DIR eliminado${NC}"
fi

if [ -f "/etc/systemd/system/${SERVICE_NAME}.service" ]; then
    echo -e "${RED}✗ Archivo de servicio aún existe${NC}"
    ERRORS=$((ERRORS + 1))
else
    echo -e "${GREEN}✓ Archivo de servicio eliminado${NC}"
fi

if id "$SERVICE_USER" &>/dev/null; then
    echo -e "${RED}✗ Usuario $SERVICE_USER aún existe${NC}"
    ERRORS=$((ERRORS + 1))
else
    echo -e "${GREEN}✓ Usuario eliminado${NC}"
fi

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Desinstalación completada!            ${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

if [ "$MODE" == "keep-config" ]; then
    echo -e "📦 ${BLUE}Configuración respaldada en:${NC}"
    echo -e "   ${YELLOW}$CONFIG_BACKUP_DIR${NC}"
    echo ""
    echo "Para eliminar también el backup:"
    echo -e "   ${YELLOW}sudo rm -rf $CONFIG_BACKUP_DIR${NC}"
else
    echo -e "🔴 ${RED}Modo completo: Todos los datos han sido eliminados${NC}"
fi

echo ""
echo "Resumen de acciones realizadas:"
echo "  ✓ Servicio detenido y deshabilitado"
echo "  ✓ Archivos de instalación eliminados"
echo "  ✓ Usuario del servicio eliminado"
echo "  ✓ Logs limpiados"
echo "  ✓ Procesos terminados"

if [ $ERRORS -gt 0 ]; then
    echo ""
    echo -e "${YELLOW}⚠️  Advertencia: $ERRORS elemento(s) no pudieron ser eliminados${NC}"
    echo "Puede que necesites eliminarlos manualmente"
    exit 1
else
    echo ""
    echo -e "${GREEN}✅ Limpieza completa exitosa${NC}"
    exit 0
fi
