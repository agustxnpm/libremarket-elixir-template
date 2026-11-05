# Despliegue de LibreMarket Lab 4 en las máquinas virtuales

Guía paso a paso para pasar el proyecto del repo local a las VMs, más los problemas que aparecieron durante el despliegue y cómo se resolvieron.

## Topología

| Nodo | IP | Qué corre |
|---|---|---|
| Nodo 1 | `192.168.56.10` | Docker Compose con los 5 servicios Elixir (`compras`, `ventas`, `pagos`, `envios`, `infracciones`) + HAProxy (`:80`). La API HTTP de Compras escucha en `:4000`. |
| Nodo 2 | `192.168.56.11` | Apache + PHP + PostgreSQL **primario** (`:5432`) |
| Nodo 3 | `192.168.56.12` | Apache + PHP + PostgreSQL **réplica** (`:5432`) |

Reglas de datos: los servicios Elixir leen y escriben **solo en el primario** (`DATABASE_URL`). La web PHP **nunca escribe**: lee su base local e inicia compras por la API HTTP de Compras.

En los comandos, reemplazá `USUARIO1`, `USUARIO2` y `USUARIO3` por los usuarios SSH de cada nodo.

---

## Paso 0 – Prerrequisitos

**Nodo 1: Docker y permisos.** El usuario debe poder usar Docker sin `sudo`:

```bash
sudo usermod -aG docker $USER
```

Cerrá la sesión SSH y volvé a entrar para que el grupo se aplique (ver [problema 1](#1-comando-newgrp-command-not-found)).

**Nodo 2: base y roles (Fase 1).** Verificá desde el Nodo 2:

```bash
sudo -u postgres psql -d libremarket -tc "SELECT count(*) FROM productos;"   # debe dar 10
sudo -u postgres psql -tc "SHOW listen_addresses;"                           # debe incluir '*'
sudo grep libremarket_app $(sudo -u postgres psql -tAc "SHOW hba_file;")     # regla para 192.168.56.10/32
```

Si falta algo, aplicá [`priv/sql/001_schema.sql`](./priv/sql/001_schema.sql) con roles `libremarket_app` y `webuser` creados, y agregá en `pg_hba.conf`:

```text
host    libremarket    libremarket_app    192.168.56.10/32    scram-sha-256
```

Después: `sudo systemctl reload postgresql`.

**Archivo `.env` local.** Debe tener (no se versiona):

```text
CLOUDAMQP_URL=...
API_TOKEN=<token aleatorio, por ejemplo openssl rand -hex 24>
HTTP_PORT=4000
DATABASE_URL=postgres://libremarket_app:PASSWORD@192.168.56.11:5432/libremarket
```

Si la contraseña tiene `@`, `:` o `/`, escribila en formato URL (por ejemplo `@` como `%40`).

---

## Paso 1 – Copiar el proyecto al Nodo 1

Desde la carpeta del proyecto, en tu máquina local:

```bash
cd /home/agustxnpm/Documentos/SistemasDistribuidos/libremarket-elixir-template
ssh USUARIO1@192.168.56.10 'mkdir -p ~/libremarket'
tar --exclude=.git --exclude=.env -czf - . | ssh USUARIO1@192.168.56.10 'tar -xzf - -C ~/libremarket'
scp .env USUARIO1@192.168.56.10:~/libremarket/.env
ssh USUARIO1@192.168.56.10 'chmod 600 ~/libremarket/.env'
```

El `.env` se copia aparte porque contiene credenciales y no viaja con el resto.

## Paso 2 – Compilar en el Nodo 1

**Siempre desde `~/libremarket`** (ver [problema 2](#2-mix-no-encontraba-el-proyecto-could-not-find-a-mixproject)):

```bash
ssh USUARIO1@192.168.56.10
cd ~/libremarket
docker run --rm -v "$PWD":/app -w /app -u "$(id -u):$(id -g)" \
  -e MIX_HOME=/app/mix_home -e HEX_HOME=/app/hex_home \
  elixir:otp-27-alpine sh -c "mix local.hex --force && mix local.rebar --force && mix deps.get && mix compile"
```

Debe terminar sin errores.

## Paso 3 – Restringir el puerto 4000 (Nodo 1)

```bash
cd ~/libremarket
sudo ./deploy/firewall_nodo1.sh
```

El script ([`deploy/firewall_nodo1.sh`](./deploy/firewall_nodo1.sh)) deja en la cadena `DOCKER-USER`, de arriba hacia abajo:

1. `ACCEPT` de paquetes `RELATED,ESTABLISHED` del puerto 4000 (las respuestas).
2. `ACCEPT` desde `192.168.56.11` y `192.168.56.12`.
3. `DROP` del resto del tráfico hacia el puerto 4000.

Se usa `DOCKER-USER` y no `ufw` porque Docker publica los puertos saltándose las reglas de `ufw`. Las reglas se pierden al reiniciar la VM: volvé a ejecutar el script con Docker ya iniciado. Detalles del porqué en el [problema 5](#5-cuelgue-de-curl-y-código-http-000-hacia-la-api-elixir-4000).

## Paso 4 – Levantar los servicios (Nodo 1)

```bash
cd ~/libremarket
./libremarket.sh start
docker ps --format '{{.Names}}\t{{.Status}}\t{{.Ports}}'
./libremarket.sh logs compras
```

Deben estar los 5 contenedores. Solo `compras` publica `0.0.0.0:4000->4000/tcp`. En los logs de `compras` buscá `Running Libremarket.Compras.HttpApi ... at 0.0.0.0:4000`.

## Paso 5 – Probar la API desde el Nodo 1

```bash
TOKEN=$(grep ^API_TOKEN ~/libremarket/.env | cut -d= -f2)
curl -s -w ' [%{http_code}]\n' http://localhost:4000/health
curl -s -w ' [%{http_code}]\n' -X POST http://localhost:4000/compras \
  -H "X-Api-Token: $TOKEN" -d 'producto=3&medio_pago=tc&entrega=correo'
```

Esperado: `{"status":"ok"} [200]` y `{"id_compra":N} [202]`.

## Paso 6 – Instalar la web en los Nodos 2 y 3

Repetí este bloque una vez por nodo (`192.168.56.11` con `USUARIO2`, luego `192.168.56.12` con `USUARIO3`). Se ejecuta desde tu máquina local. Usa `ssh -t` y un único `sudo bash -c` (ver [problema 3](#3-error-de-tty-en-ssh-sudo-a-terminal-is-required-to-authenticate)), y completa las credenciales sin editar a mano (ver [problema 4](#4-automatización-de-credenciales-en-configphp)).

```bash
cd /home/agustxnpm/Documentos/SistemasDistribuidos/libremarket-elixir-template

# Token tomado del Nodo 1 y contraseña de webuser
TOKEN=$(ssh USUARIO1@192.168.56.10 "grep ^API_TOKEN ~/libremarket/.env | cut -d= -f2")
WEBPASS='contraseña_de_webuser'

NODO=192.168.56.11; USR=USUARIO2     # luego repetir con 192.168.56.12 y USUARIO3
scp web/index.php web/comprar.php web/compra.php web/health.php web/lib.php web/config.php.example $USR@$NODO:/tmp/
ssh -t $USR@$NODO "sudo bash -c '
  [ -f /var/www/html/index.php.lab3.bak ] || cp /var/www/html/index.php /var/www/html/index.php.lab3.bak
  apt-get install -y php-pgsql php-curl
  cp /tmp/index.php /tmp/comprar.php /tmp/compra.php /tmp/health.php /tmp/lib.php /var/www/html/
  cp /tmp/config.php.example /var/www/html/config.php
  sed -i \"s|CAMBIAR_POR_API_TOKEN|$TOKEN|; s|webpass|$WEBPASS|\" /var/www/html/config.php
  systemctl restart apache2
'"
```

Notas:

- Si la contraseña de `webuser` contiene `|` o `&`, `sed` falla: editá `/var/www/html/config.php` a mano.
- La contraseña no se puede leer de PostgreSQL (se guarda hasheada); hay que conocerla. Si no la sabés, reseteala en el Nodo 2 con `\password webuser` (se replica sola al Nodo 3).
- `api_url` ya apunta a `http://192.168.56.10:4000`.
- Se conserva el `index.php` del Lab 3 como `index.php.lab3.bak`.

## Paso 7 – Verificar los Nodos 2 y 3

En cada nodo web:

```bash
TOKEN='pegá_tu_API_TOKEN'
curl -s -w ' [%{http_code}]\n' http://localhost/health.php                 # OK [200]
curl -s -w ' [%{http_code}]\n' http://192.168.56.10:4000/health            # {"status":"ok"} [200]
curl -s -w ' [%{http_code}]\n' -X POST http://192.168.56.10:4000/compras \
  -H "X-Api-Token: $TOKEN" -d 'producto=3&medio_pago=tc&entrega=correo'    # 202
```

Si el segundo o tercer `curl` se queda sin responder, mirá el [problema 5](#5-cuelgue-de-curl-y-código-http-000-hacia-la-api-elixir-4000).

## Paso 8 – HAProxy (Nodo 1)

Editá `/etc/haproxy/haproxy.cfg` manteniendo la separación estricta entre `frontend` y `backend` (ver [problema 6](#6-configuración-corrupta-de-haproxy-balance-ignored-because-frontend-http_front-has-no-backend-capability)). Estructura esperada (ajustá los pesos a los que ya tenías):

```text
frontend http_front
    bind *:80
    default_backend web_nodes

backend web_nodes
    balance roundrobin
    option httpchk GET /health.php
    http-check expect status 200
    server nodo2 192.168.56.11:80 check inter 3s fall 2 rise 2 weight 3
    server nodo3 192.168.56.12:80 check inter 3s fall 2 rise 2 weight 1
```

Validá **antes** de recargar:

```bash
sudo haproxy -c -f /etc/haproxy/haproxy.cfg && sudo systemctl reload haproxy
```

Para ver el estado de los servidores (ver [problema 7](#7-herramienta-socat-ausente-en-nodo-1)):

```bash
sudo apt-get install -y socat
echo "show servers state" | sudo socat stdio /run/haproxy/admin.sock
```

## Paso 9 – Prueba final

1. Abrí `http://192.168.56.10` y recargá varias veces: "Atendido por" debe alternar entre `nodo-2` y `nodo-3`.
2. Elegí producto, pago y entrega, y tocá **Comprar**. Te redirige a `compra.php?id=N` y la compra termina con un resultado.
3. En el panel, la compra aparece en la lista y el stock baja si terminó bien.
4. Desde una máquina que **no** sea N2 ni N3, `curl -m 3 http://192.168.56.10:4000/health` debe fallar por timeout.
5. En el Nodo 2, verificá la base (ver [problema 8](#8-error-de-sql-column-id-does-not-exist) por los nombres de columnas):

```bash
sudo -u postgres psql -d libremarket -c \
  "SELECT id_compra, id_producto, medio_pago, entrega, paso, estado, resultado, creada_at FROM compras ORDER BY id_compra DESC LIMIT 5;"
```

Para detener o reiniciar los servicios (por ejemplo tras cambiar el `.env`): `./libremarket.sh stop && ./libremarket.sh start`.

---

# Problemas encontrados y soluciones

## 1. Comando `newgrp: command not found`

- **Síntoma:** al agregar el usuario al grupo Docker en el Nodo 1 (`sudo usermod -aG docker $USER`), la shell devolvió error al intentar refrescar el grupo.
- **Causa:** la imagen base del sistema operativo es mínima y no incluye el paquete de utilidades de cuentas donde viene `newgrp`.
- **Solución:** reabrir la sesión por SSH o ejecutar `su - $USER` para cargar el grupo sin depender del binario faltante.

## 2. Mix no encontraba el proyecto (`Could not find a Mix.Project`)

- **Síntoma:** Docker descargó la imagen de Elixir pero falló inmediatamente con `(Mix) Could not find a Mix.Project`.
- **Causa:** el contenedor se ejecutó montando `$PWD` estando parado en el directorio home (`~`) en lugar de estar dentro de `~/libremarket`.
- **Solución:** navegar a la carpeta del proyecto (`cd ~/libremarket`) antes de montar el volumen en Docker.

## 3. Error de TTY en SSH (`sudo: a terminal is required to authenticate`)

- **Síntoma:** al copiar los archivos PHP por `scp` y correr el provisioning remoto por `ssh` en los Nodos 2 y 3, `sudo` abortó con ese error.
- **Causa:** por defecto, `ssh` no asigna un pseudoterminal interactivo si se le pasa un comando inline, lo que impide que `sudo` pida la contraseña del usuario.
- **Solución:** agregar el flag `-t` a SSH (`ssh -t ...`) y encapsular todos los comandos bajo un único `sudo bash -c "..."`, de modo que la contraseña se pida una sola vez.

## 4. Automatización de credenciales en `config.php`

- **Síntoma:** se quería evitar la edición manual con `nano` en cada nodo para configurar la contraseña de `webuser` y el `API_TOKEN`.
- **Causa/duda:** la contraseña de PostgreSQL no se puede leer en texto plano desde la base (viene hasheada), y surgieron dudas sobre el entrecomillado y cómo obtener el token dinámicamente.
- **Solución:**
  - Se extrajo el token directamente desde el Nodo 1 con `grep`/`cut` sobre el `.env`.
  - Se usó `sed` dentro de cada nodo para inyectar tanto la contraseña como el token de forma no interactiva (ver Paso 6).

## 5. Cuelgue de curl y código HTTP `[000]` hacia la API Elixir (:4000)

- **Síntoma:** desde el Nodo 3, `curl http://192.168.56.10:4000/health` arrojaba `Connection timed out` y código `[000]`.
- **Causa:** el contenedor corría y escuchaba bien localmente, pero los paquetes entrantes desde la interfaz física `enp0s8` del Nodo 1 eran descartados (`DROP`) en la cadena `DOCKER-USER` / `FORWARD` de `iptables`. Faltaba contemplar los paquetes de respuesta ya establecidos y el cambio de puerto que genera el DNAT de Docker: en `DOCKER-USER` el paquete ya fue traducido, por lo que hay que filtrar con `--ctorigdstport 4000` (puerto original) y no solo con `--dport`. Además, la conexión completa (incluidas las respuestas del contenedor) queda marcada con ese puerto de origen, así que un `DROP` genérico las descartaba.
- **Solución:** reglas prioritarias en `DOCKER-USER` en el Nodo 1:
  1. Aceptar paquetes con estado `RELATED,ESTABLISHED`.
  2. Permitir el tráfico entrante desde los nodos web usando `--ctorigdstport 4000`.
  3. Descartar el resto del tráfico hacia ese puerto.

  En una primera versión se permitió toda la subred `192.168.56.0/24`. El script [`deploy/firewall_nodo1.sh`](./deploy/firewall_nodo1.sh) aplica estas reglas de forma idempotente y limita el acceso a `192.168.56.11` y `192.168.56.12`; si necesitás toda la subred, cambiá la lista `PERMITIDOS` a `("192.168.56.0/24")`.

## 6. Configuración corrupta de HAProxy (`'balance' ignored because frontend 'http_front' has no backend capability`)

- **Síntoma:** al automatizar el cambio de HAProxy para incorporar el healthcheck contra `/health.php`, HAProxy falló la validación sintáctica (`haproxy -c`) y se negó a recargar.
- **Causa:** el script de reemplazo no encontró la cabecera esperada y concatenó las directivas del backend dentro del bloque `frontend http_front`.
- **Solución:** se reescribió `/etc/haproxy/haproxy.cfg` de forma limpia y completa, respetando la separación estricta entre `frontend` y `backend`, y manteniendo la opción `httpchk GET /health.php`, el código `200` y los pesos originales (`weight 3` y `weight 1`). Conviene hacer una copia antes (`sudo cp /etc/haproxy/haproxy.cfg /etc/haproxy/haproxy.cfg.bak`) y validar siempre con `haproxy -c` antes de recargar.

## 7. Herramienta `socat` ausente en Nodo 1

- **Síntoma:** `sudo: 'socat': command not found` al intentar consultar el socket administrativo `/run/haproxy/admin.sock`.
- **Causa:** paquete no instalado en la máquina virtual.
- **Solución:** `sudo apt-get install -y socat` para inspeccionar el estado `UP` y los pesos del balanceador.

## 8. Error de SQL: `ERROR: column "id" does not exist`

- **Síntoma:** al consultar la tabla de compras en PostgreSQL (Nodo 2), la base devolvió que la columna `id` no existía.
- **Causa:** discrepancia con el esquema real definido en [`priv/sql/001_schema.sql`](./priv/sql/001_schema.sql).
- **Solución:** se inspeccionó la tabla con `\d compras` y se corrigió la consulta usando las columnas reales: `id_compra`, `id_producto`, `medio_pago`, `entrega`, `paso`, `estado`, `resultado`, `creada_at` (y `finalizada_at`).

## 9. Preguntas frecuentes

**¿Por qué `compra.php` dice "Atendido por nodo-2" si compré desde el nodo-3?**
Con `balance roundrobin`, HAProxy reparte cada petición HTTP por separado. Una compra genera varias peticiones seguidas (panel, `POST comprar.php`, redirección a `compra.php`) y se alternan entre los nodos. No es un error: `compra.php` consulta la API de Compras, no la base local, por lo que muestra el mismo resultado desde cualquier nodo. Si se quisiera fijar cada navegador a un nodo, se puede agregar `cookie NODO insert indirect nocache` en el backend y `cookie n2` / `cookie n3` en cada `server`, a costa de ocultar el balanceo.
