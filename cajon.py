#!/usr/bin/env python3
import socket

def abrir_cajon(ip, puerto=9100):
    # Comandos ESC/POS comunes
    comandos = [
        b'\x1b\x70\x00\x3c\xf0',
    ]
    
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(5)
        sock.connect((ip, puerto))
        sock.send(comandos[0])  # Probar primer comando
        sock.close()
        print("✅ Cajón abierto correctamente")
        return True
    except Exception as e:
        print(f"❌ Error: {e}")
        return False

# Uso
if __name__ == "__main__":
    abrir_cajon("192.168.1.24")
