#!/bin/bash
# Restringe el puerto de la API de Compras (4000) a los nodos web (N2 y N3).
# Ejecutar en el Nodo 1 con sudo:  sudo ./deploy/firewall_nodo1.sh
#
# Docker publica los puertos saltandose las reglas INPUT de ufw, por eso las
# reglas van en la cadena DOCKER-USER (se evalua antes que las de Docker).
# Es idempotente. Las reglas se pierden al reiniciar la VM: volver a ejecutarlo
# despues de que Docker arranque.
set -euo pipefail

PUERTO="${HTTP_PORT:-4000}"
PERMITIDOS=("192.168.56.11" "192.168.56.12")

iptables -N DOCKER-USER 2>/dev/null || true

# Borra reglas propias previas para poder re-ejecutar sin duplicar.
limpiar() {
  while iptables -C DOCKER-USER "$@" 2>/dev/null; do
    iptables -D DOCKER-USER "$@"
  done
}

limpiar -p tcp -m conntrack --ctorigdstport "$PUERTO" -j DROP
limpiar -p tcp -m conntrack --ctorigdstport "$PUERTO" --ctstate RELATED,ESTABLISHED -j ACCEPT
for ip in "${PERMITIDOS[@]}"; do
  limpiar -p tcp -s "$ip" -m conntrack --ctorigdstport "$PUERTO" -j ACCEPT
done

# Primero el DROP y despues los ACCEPT: con -I cada regla queda arriba de la anterior.
iptables -I DOCKER-USER -p tcp -m conntrack --ctorigdstport "$PUERTO" -j DROP
for ip in "${PERMITIDOS[@]}"; do
  iptables -I DOCKER-USER -p tcp -s "$ip" -m conntrack --ctorigdstport "$PUERTO" -j ACCEPT
done
# Las respuestas del contenedor tambien llevan ctorigdstport 4000 (conntrack es por conexion)
# y su origen es el contenedor, no N2/N3: sin esta regla el DROP las descarta y el cliente
# queda en timeout. Debe quedar primera.
iptables -I DOCKER-USER -p tcp -m conntrack --ctorigdstport "$PUERTO" --ctstate RELATED,ESTABLISHED -j ACCEPT

echo "Reglas activas en DOCKER-USER:"
iptables -S DOCKER-USER
