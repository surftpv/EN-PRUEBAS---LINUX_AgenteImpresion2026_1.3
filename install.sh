#!/bin/bash

# ============================================
# Script de Instalación - Print Agent Service
# ============================================

set -e

# Colores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Variables configurables
INSTALL_DIR="/opt/print-agent"
SERVICE_NAME="print-agent"
SERVICE_USER="printagent"
VENV_DIR="$INSTALL_DIR/venv"
CONFIG_DIR="$INSTALL_DIR/config"
LOGS_DIR="$INSTALL_DIR/logs"

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Instalador de Print Agent Service   ${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# Verificar que se ejecuta como root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error: Este script debe ejecutarse como root${NC}"
    echo "Uso: sudo bash install.sh"
    exit 1
fi

# Verificar sistema operativo
if ! command -v apt-get &> /dev/null; then
    echo -e "${RED}Error: Este script está diseñado para sistemas Debian/Ubuntu${NC}"
    exit 1
fi

echo -e "${YELLOW}[1/8] Actualizando paquetes del sistema...${NC}"
apt-get update -qq

echo -e "${YELLOW}[2/8] Instalando dependencias del sistema...${NC}"
apt-get install -y -qq python3 python3-venv python3-pip \
    libjpeg-dev zlib1g-dev libfreetype6-dev \
    liblcms2-dev libopenjp2-7-dev libtiff5-dev \
    libwebp-dev tcl8.6-dev tk8.6-dev python3-tk \
    libcups2-dev cups-bsd cups-client \
    gcc python3-dev libffi-dev

echo -e "${YELLOW}[3/8] Creando usuario del servicio...${NC}"
if ! id "$SERVICE_USER" &>/dev/null; then
    useradd --system --no-create-home --shell /bin/false "$SERVICE_USER"
    echo "Usuario $SERVICE_USER creado"
else
    echo "Usuario $SERVICE_USER ya existe"
fi

echo -e "${YELLOW}[4/8] Creando directorios de instalación...${NC}"
mkdir -p "$INSTALL_DIR" "$CONFIG_DIR" "$LOGS_DIR"
chown -R "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR"
chmod 750 "$INSTALL_DIR"
chmod 755 "$CONFIG_DIR"

echo -e "${YELLOW}[5/8] Creando entorno virtual Python...${NC}"
python3 -m venv "$VENV_DIR"
source "$VENV_DIR/bin/activate"

echo -e "${YELLOW}[6/8] Instalando dependencias Python...${NC}"
pip install --quiet --upgrade pip setuptools wheel

# Instalar dependencias paso a paso para mejor diagnóstico
echo "  → Instalando requests..."
pip install --quiet requests

echo "  → Instalando Pillow..."
pip install --quiet Pillow

echo "  → Instalando python-escpos..."
pip install --quiet python-escpos

deactivate

# Crear archivo de configuración si no existe
CONFIG_FILE="$CONFIG_DIR/config.json"
if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${YELLOW}[7/8] Creando archivo de configuración...${NC}"
    cat > "$CONFIG_FILE" << 'EOF'
{
    "odoo_url": "https://demo.surftpv.app/",
    "api_key": "TU_API_KEY_AQUI",
    "printer_ips": [
        "192.168.1.23",
        "192.168.1.24"
    ],
    "poll_interval": 5,
    "log_level": "INFO"
}
EOF
    chown "$SERVICE_USER:$SERVICE_USER" "$CONFIG_FILE"
    chmod 640 "$CONFIG_FILE"
    echo -e "${GREEN}✓ Archivo de configuración creado: $CONFIG_FILE${NC}"
else
    echo -e "${YELLOW}[7/8] Archivo de configuración ya existe, preservando...${NC}"
fi

# Crear el script Python principal
echo -e "${YELLOW}[8/8] Instalando script principal...${NC}"
cat > "$INSTALL_DIR/print_agent.py" << 'EOF'
#!/usr/bin/env python3
"""
Print Agent - Servicio de impresión para Odoo POS
Lee configuración desde archivo JSON externo
"""

import requests
import base64
from escpos.printer import Network
from time import sleep
from PIL import Image
from io import BytesIO
import threading
import signal
import sys
import logging
import json
import os

# ============================================
# CONFIGURACIÓN DESDE ARCHIVO EXTERNO
# ============================================

CONFIG_PATH = os.environ.get(
    'PRINT_AGENT_CONFIG',
    '/opt/print-agent/config/config.json'
)

def load_config():
    """Carga la configuración desde archivo JSON."""
    try:
        with open(CONFIG_PATH, 'r') as f:
            return json.load(f)
    except FileNotFoundError:
        print(f"Error: No se encontró el archivo de configuración: {CONFIG_PATH}")
        sys.exit(1)
    except json.JSONDecodeError as e:
        print(f"Error: El archivo de configuración no es válido JSON: {e}")
        sys.exit(1)

# Cargar configuración
config = load_config()

# Configurar logging
log_level = getattr(logging, config.get('log_level', 'INFO').upper(), logging.INFO)
logging.basicConfig(
    level=log_level,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[
        logging.StreamHandler(sys.stdout)
    ]
)
_logger = logging.getLogger(__name__)


class PrintAgent:
    def __init__(self, odoo_url, api_key, printer_ips, poll_interval=5):
        """
        :param odoo_url: Base URL of the Odoo server
        :param api_key:  API key for authentication
        :param printer_ips: List of printer IP addresses
        :param poll_interval: Seconds between polling cycles
        """
        self.odoo_url = odoo_url.rstrip('/')
        self.headers = {'Authorization': f'Bearer {api_key}'}
        self.printer_ips = printer_ips
        self.poll_interval = poll_interval
        self._stop_event = threading.Event()
        self.threads = []

    def start(self):
        """Start polling threads for each configured printer."""
        _logger.info("Starting PrintAgent for printers: %s", self.printer_ips)
        
        # Handle graceful shutdown
        signal.signal(signal.SIGINT, self._signal_handler)
        signal.signal(signal.SIGTERM, self._signal_handler)

        for ip in self.printer_ips:
            _logger.info("Starting thread for printer: %s", ip)
            t = threading.Thread(target=self._poll_printer, args=(ip,), daemon=True)
            t.start()
            self.threads.append(t)

        # Wait for threads to finish
        try:
            for t in self.threads:
                t.join()
        except Exception as e:
            _logger.error("Error en threads: %s", e)

    def _signal_handler(self, signum, frame):
        _logger.info("Shutdown signal received (%s). Stopping threads...", signum)
        self._stop_event.set()

    def _poll_printer(self, printer_ip):
        """Continuously fetch jobs for a given printer IP."""
        _logger.info("Thread started for printer %s", printer_ip)
        
        while not self._stop_event.is_set():
            try:
                resp = requests.get(
                    f"{self.odoo_url}/pos_print_agent/jobs",
                    json={"printer_ip": printer_ip},
                    headers=self.headers,
                    timeout=10
                )
                resp.raise_for_status()
                jobs = resp.json().get('result', [])

                for job in jobs:
                    job_id = job.get('id')
                    img_data = job.get('data')
                    try:
                        self._print_receipt(img_data, printer_ip)
                        self._confirm_job(job_id)
                    except Exception as e:
                        _logger.error("Failed to print job %s on %s: %s", job_id, printer_ip, e)
                        
            except requests.exceptions.RequestException as e:
                _logger.error("Network error polling jobs for %s: %s", printer_ip, e)
            except Exception as e:
                _logger.error("Error polling jobs for %s: %s", printer_ip, e)

            sleep(self.poll_interval)

        _logger.info("Thread exiting for printer %s", printer_ip)

    def _print_receipt(self, img_data, printer_ip):
        """Decode the base64 image, split if needed, and send to printer."""
        try:
            im = Image.open(BytesIO(base64.b64decode(img_data)))
        except Exception as e:
            _logger.error("Error decoding image data: %s", e)
            raise

        slices = self._imgcrop(im)
        
        try:
            printer = Network(printer_ip)

            for slice_img in slices:
                printer.image(slice_img)

            # BEEP para notificar impresión
            try:
                printer._raw(b'\x1b\x42\x02\x05')
            except Exception as e:
                _logger.warning("Error en el BEEP en %s: %s", printer_ip, e)

            # FEED para sacar papel en blanco
            try:
                printer._raw(b'\x1b\x64\x02')
            except Exception as e:
                _logger.warning("Error en el FEED Extra en %s: %s", printer_ip, e)

            printer.cut()
            printer.close()
            _logger.info("Printed receipt on %s", printer_ip)
            
        except Exception as e:
            _logger.error("Printer connection error %s: %s", printer_ip, e)
            raise

    def _imgcrop(self, im):
        """Split tall images into chunks for ESC/POS printers."""
        ret = []
        w, h = im.size
        max_height = 800  # adjust as per printer buffer capability
        sleep(0.5)
        y_slices = (h + max_height - 1) // max_height
        slice_h = h // y_slices if y_slices > 0 else h

        for i in range(y_slices):
            top = i * slice_h
            bottom = h if i == y_slices - 1 else (top + slice_h)
            ret.append(im.crop((0, top, w, bottom)))
        return ret

    def _confirm_job(self, job_id):
        """Mark the job as done in Odoo."""
        try:
            resp = requests.post(
                f"{self.odoo_url}/pos_print_agent/jobs/{job_id}",
                json={"status": "done"},
                headers=self.headers,
                timeout=5
            )
            resp.raise_for_status()
            _logger.info("Confirmed job %s", job_id)
        except Exception as e:
            _logger.error("Error confirming job %s: %s", job_id, e)


def main():
    """Punto de entrada principal."""
    _logger.info("=" * 50)
    _logger.info("Print Agent Service Starting")
    _logger.info("Config file: %s", CONFIG_PATH)
    _logger.info("=" * 50)
    
    # Validar configuración
    required_keys = ['odoo_url', 'api_key', 'printer_ips']
    for key in required_keys:
        if key not in config:
            _logger.error("Configuración incompleta: falta '%s'", key)
            sys.exit(1)
    
    agent = PrintAgent(
        odoo_url=config['odoo_url'],
        api_key=config['api_key'],
        printer_ips=config['printer_ips'],
        poll_interval=config.get('poll_interval', 5)
    )
    
    try:
        agent.start()
    except Exception as e:
        _logger.critical("Error fatal: %s", e)
        sys.exit(1)


if __name__ == "__main__":
    main()
EOF

chown "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR/print_agent.py"
chmod 750 "$INSTALL_DIR/print_agent.py"

# Crear archivo de servicio systemd
echo -e "${YELLOW}Creando servicio systemd...${NC}"
cat > "/etc/systemd/system/${SERVICE_NAME}.service" << EOF
[Unit]
Description=Print Agent Service - Odoo POS Printer
Documentation=https://github.com/surftpv/print-agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_USER

# Directorio de trabajo
WorkingDirectory=$INSTALL_DIR

# Entorno virtual
Environment="PATH=$VENV_DIR/bin:/usr/local/bin:/usr/bin:/bin"
Environment="PRINT_AGENT_CONFIG=$CONFIG_FILE"
Environment="PYTHONUNBUFFERED=1"

# Comando de inicio
ExecStart=$VENV_DIR/bin/python $INSTALL_DIR/print_agent.py

# Reinicio automático
Restart=on-failure
RestartSec=10
StartLimitInterval=60s
StartLimitBurst=3

# Seguridad
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$LOGS_DIR

# Logs
StandardOutput=journal
StandardError=journal
SyslogIdentifier=print-agent

[Install]
WantedBy=multi-user.target
EOF

# Recargar systemd y habilitar servicio
systemctl daemon-reload
systemctl enable "$SERVICE_NAME.service"

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Instalación completada con éxito!     ${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "📁 Directorio de instalación: ${YELLOW}$INSTALL_DIR${NC}"
echo -e "⚙️  Archivo de configuración:  ${YELLOW}$CONFIG_FILE${NC}"
echo -e "📋 Logs del servicio:         ${YELLOW}journalctl -u $SERVICE_NAME -f${NC}"
echo ""
echo -e "${YELLOW}Próximos pasos:${NC}"
echo "  1. Edita la configuración:"
echo -e "     ${YELLOW}sudo nano $CONFIG_FILE${NC}"
echo ""
echo "  2. Inicia el servicio:"
echo -e "     ${YELLOW}sudo systemctl start $SERVICE_NAME${NC}"
echo ""
echo "  3. Verifica el estado:"
echo -e "     ${YELLOW}sudo systemctl status $SERVICE_NAME${NC}"
echo ""
echo "  4. Ver logs en tiempo real:"
echo -e "     ${YELLOW}sudo journalctl -u $SERVICE_NAME -f${NC}"
echo ""
echo -e "${RED}IMPORTANTE: Edita el archivo de configuración antes de iniciar el servicio${NC}"
