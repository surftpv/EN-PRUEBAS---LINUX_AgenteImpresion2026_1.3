# LINUX_AgenteImpresion2026_1.3

Instalar como sudo ./install.sh (darle permisos Ejecutable como un programa)

AL FINALIZAR:
Instalación completada con éxito!     
========================================

📁 Directorio de instalación: /opt/print-agent

⚙️  Archivo de configuración:  /opt/print-agent/config/config.json

📋 Logs del servicio:         journalctl -u print-agent -f

Próximos pasos:
  1. Edita la configuración:
     sudo nano /opt/print-agent/config/config.json

  2. Inicia el servicio:
     sudo systemctl start print-agent

  3. Verifica el estado:
     sudo systemctl status print-agent

  4. Ver logs en tiempo real:
     sudo journalctl -u print-agent -f



-------------------------------------------------------------
Para el cajón:
Copiar el archivo "cajon.py" en carpeta: /opt/print-agent/

En Ubuntu
1. Ir a:    Ajustes -> Teclado -> Atajos del teclado -> Ver y personalizar atajos: Atajo personalizado
   
3. Rellenar con los siguientes datos:
   
    Nombre:  Abrir Cajón
    Comando: python3 /opt/print-agent/cajon.py  (o la ruta donde se encuentre el archivo cajon.py una vez se haya configurado con la ip de la impresora conectada al cajón)
    Atajo: F3

