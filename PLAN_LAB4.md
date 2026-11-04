# Plan de migración Lab 2 → Lab 4: persistencia en PostgreSQL con réplica

Objetivo: migrar LibreMarket (Lab 2, servicios Elixir comunicados por AMQP) para que use la infraestructura del Lab 3: HAProxy + Apache/PHP + PostgreSQL con streaming replication (primario/réplica) sobre la red `192.168.56.0/24`.

## 1. Hallazgos del código actual

- **Todo el estado vive en memoria.** Cada `GenServer` guarda su estado en un mapa: [ventas.ex](./lib/ventas.ex), [compras.ex](./lib/compras.ex), [pagos.ex](./lib/pagos.ex), [envios.ex](./lib/envios.ex), [infracciones.ex](./lib/infracciones.ex). El stock se regenera al azar en cada arranque.
- **Los `id_compra` no son persistibles tal como están.** Se generan con `:erlang.unique_integer/1`, que se repite tras reiniciar el nodo. Con una base duradera habría colisiones: el ID debe salir de una secuencia de PostgreSQL.
- **Compras guarda el `pid` del solicitante.** No se puede persistir, así que una compra en vuelo no se puede reanudar tras un reinicio. Se la marca como interrumpida y se compensa.
- **El Lab 3 no se mapea 1:1.** Allá la web escribía y la réplica rechazaba el `INSERT`. Acá la web nunca escribe en la base: los comandos (iniciar una compra) los recibe Compras por HTTP y las escrituras las hacen los servicios Elixir (Nodo 1).
- **Compras no tiene entrada HTTP.** Hoy solo se lo invoca desde `iex` ([ui.ex](./lib/ui.ex), [simulador.ex](./lib/simulador.ex)). Hay que agregarle una API HTTP mínima para que la web inicie compras.

## 2. Arquitectura objetivo

El diagrama original se mantiene, pero se agregan las escrituras de los servicios Elixir hacia el primario y una **API HTTP en Compras** por la que la web inicia compras (opción B). Así HAProxy balancea tráfico real (lecturas y comandos).

El diagrama Mermaid está en [ARQUITECTURA_LAB4.md](./ARQUITECTURA_LAB4.md).

```
Usuario Web ─► HAProxy :80 ─┬─► Apache+PHP (N2) ─┐  lee panel     ┌─► PRIMARIO (N2)
                            └─► Apache+PHP (N3) ─┤  (BD local)    └─► RÉPLICA  (N3)
                                                 │
                                                 └─ POST /compras ─► API HTTP de Compras (N1 :4000)
                                                                          │
Compras ─AMQP─► Ventas / Infracciones / Pagos / Envíos                    │
Servicios Elixir ──lectura/escritura :5432──► PRIMARIO ──WAL streaming──► RÉPLICA
```

### Decisiones de diseño

1. **Los servicios Elixir hablan directo con el primario (puerto 5432).** No pasan por HAProxy, que sigue en capa 7 y solo balancea la web.
2. **Los servicios Elixir también leen del primario.** La réplica es asíncrona y podría devolver datos desactualizados.
3. **La web PHP no escribe en PostgreSQL.** Lee de su base local (panel) y, para iniciar una compra, hace un `POST` a la API HTTP de Compras. Cualquiera de los dos nodos web, incluido el Nodo 3 (réplica), puede iniciar compras. Desaparece el caso "INSERT rechazado en la réplica".
4. **Compras expone una API HTTP mínima** (`plug` + `bandit`, o `plug_cowboy`) en el Nodo 1, puerto `4000`. La web la invoca directo, sin pasar por HAProxy.
   - `POST /compras` con `producto`, `medio_pago`, `entrega`. Valida la entrada y responde `202 {id_compra}` sin esperar el resultado, como ya hace `Compras.Server.comprar/3`.
   - `GET /compras/:id` devuelve el estado (`en_curso` / `finalizada` / `desconocida`) desde la base primaria, para evitar leer datos viejos de la réplica.
5. **Una sola base `libremarket`**, con una tabla por servicio (cada servicio es dueño de sus tablas).
6. **Driver `postgrex`**, sin Ecto: el esquema es chico y se evitan dependencias.
7. **El panel lee de la base local** (primario en N2, réplica en N3), lo que muestra el retraso de replicación. El estado de una compra recién creada se consulta por la API para no depender de ese retraso.

## 3. Fases

### Fase 0: Verificación de infraestructura
- Confirmar que el Lab 3 sigue funcionando: replicación activa y HAProxy balanceando entre N2 y N3.
- Probar conectividad desde un contenedor Docker del Nodo 1 a `192.168.56.11:5432` con `psql`. Por el NAT de Docker, el origen será `192.168.56.10`, cubierto por la regla de `192.168.56.0/24`.
- Confirmar `listen_addresses = '*'` en el primario.
- **Entregable:** checklist de conectividad.

### Fase 1: Base de datos (Nodo 2; se replica sola al Nodo 3)
- Crear la base `libremarket` y los roles:
  - `libremarket_app`: SELECT/INSERT/UPDATE (usado por Elixir).
  - Rol de solo SELECT para la web (reutilizar o ajustar `webuser`).
- Agregar en `pg_hba.conf` una regla para `libremarket_app` desde `192.168.56.10/32`.
- Crear el esquema en un script versionado `priv/sql/001_schema.sql`:

| Tabla | Columnas |
|---|---|
| `productos` | `id_producto PK`, `stock CHECK (stock >= 0)`; semilla de 10 productos |
| `compras` | `id_compra BIGSERIAL PK`, `id_producto`, `medio_pago`, `entrega`, `paso`, `estado`, `resultado`, `creada_at`, `finalizada_at` |
| `pagos` | `id_compra PK`, `autorizado`, `ts` |
| `envios` | `id_compra PK`, `costo`, `agendado`, `ts` |
| `infracciones` | `id_compra PK`, `detectada`, `ts` |
| `eventos` (opcional) | `id`, `id_compra`, `servicio`, `evento`, `reloj jsonb`, `ts` (persistir relojes vectoriales) |

- **Validación:** `INSERT` en el primario y `SELECT` en la réplica mostrando el mismo dato.

### Fase 2: Capa de acceso a datos en Elixir
- Agregar `{:postgrex, "~> 0.19"}` en [mix.exs](./mix.exs).
- Crear `Libremarket.Repo`: wrapper fino con pool de Postgrex que lee `DATABASE_URL` del entorno (igual que `CLOUDAMQP_URL`).
- Incluirlo en el árbol de [supervisor.ex](./lib/supervisor.ex) para los 5 servicios.
- Definir un comportamiento de persistencia por servicio, con un adaptador Postgres y uno en memoria, para que los tests actuales (`mix test --no-start`) sigan sin base.
- Manejo de errores: una falla de la base no debe tumbar el `GenServer`; devolver `{:error, :persistencia}` y que Compras lo trate como resultado final, con compensación si corresponde.
- **Entregable:** `Repo` operando desde `iex` contra el primario.

### Fase 3: Migración de servicios (uno por vez, validando cada uno)
1. **Ventas** (el más crítico). Operaciones atómicas en SQL:
   - Reservar: `UPDATE productos SET stock = stock - 1 WHERE id_producto = $1 AND stock > 0 RETURNING stock`.
   - Liberar: `UPDATE productos SET stock = stock + 1 WHERE id_producto = $1`.
   - Listar: `SELECT`.
   - La semilla se carga solo si la tabla está vacía, así el stock sobrevive a reinicios.
2. **Infracciones, Pagos y Envíos.** Cada decisión se guarda con `INSERT ... ON CONFLICT (id_compra) DO NOTHING`, lo que vuelve idempotente la re-entrega de mensajes AMQP.
3. **Compras.**
   - `id_compra` desde la secuencia.
   - Persistir cada transición de `paso` y el resultado final. `Compras.avanzar/2` sigue siendo lógica pura y no se toca.
   - Al arrancar, las compras `en_curso` pasan a `interrumpida` y se libera el stock reservado.
   - `estado_compra/1` consulta la base.
4. **API HTTP de Compras** (solo en el contenedor de Compras).
   - Agregar `{:plug, "~> 1.16"}` y `{:bandit, "~> 1.5"}` en [mix.exs](./mix.exs) y arrancar el servidor HTTP bajo el supervisor de Compras en [supervisor.ex](./lib/supervisor.ex), en el puerto `4000` (configurable por `HTTP_PORT`).
   - `POST /compras`: valida `producto` (1..10), `medio_pago` (`efectivo|transferencia|td|tc`) y `entrega` (`correo|retira`) contra una lista permitida, llama a `Compras.Server.comprar/3` y responde `202 {"id_compra": N}`. Entrada inválida: `400`.
   - `GET /compras/:id`: responde con el estado leído de la base primaria (`en_curso`, `finalizada` con resultado, o `404`).
   - `GET /health`: para chequeo desde la web.
   - El proceso que atiende el `POST` es el "solicitante" y muere al responder, por lo que el mensaje `{:compra_finalizada, ...}` se pierde. No afecta: el resultado queda persistido y se consulta por `GET`.
   - Acceso restringido: token compartido en el header `X-Api-Token` (variable `API_TOKEN`, no versionada) y regla de firewall que solo permita el puerto 4000 desde `192.168.56.11` y `192.168.56.12`.
- **Validación:** `mix test` en verde (incluye tests de la API con `Plug.Test`, sin broker) y test de integración (`--include integration`) contra el primario. `curl -X POST` a la API crea una compra visible en la base.

### Fase 4: Web PHP y HAProxy (depende de la Fase 1 y de la API de la Fase 3)
- En N2 y N3, `php-pgsql` conectando a `127.0.0.1:5432` con el rol de solo lectura (cada nodo consulta su propia base, como en el Lab 3).
- Páginas de lectura: stock actual, últimas compras con estado, totales por resultado, y pie con hostname y rol (`pg_is_in_recovery()`).
- Formulario "Comprar" (producto, medio de pago, entrega): el PHP hace `POST` a `http://192.168.56.10:4000/compras` con `API_TOKEN` (cURL, timeout corto) y redirige a `compra.php?id=N`.
- `compra.php?id=N` consulta `GET /compras/N` en la API cada pocos segundos hasta que la compra finaliza, y muestra el resultado (`Ui.informar_resultado`). Si la API no responde, muestra un mensaje controlado (sin HTTP 500).
- Consultas con sentencias preparadas y salida escapada con `htmlspecialchars`.
- Agregar `health.php` (`SELECT 1`) y en `haproxy.cfg` usar `option httpchk GET /health.php`, para que un nodo con la base caída salga de la rotación.
- **Validación:**
  - Al recargar `http://192.168.56.10` se alterna N2/N3.
  - Una compra iniciada desde el Nodo 3 (réplica) se completa correctamente.
  - El panel muestra la compra en ambos nodos (con retraso mínimo de replicación).

### Fase 5: Despliegue en Nodo 1
- Agregar `DATABASE_URL` y `API_TOKEN` al entorno de los servicios en [docker-compose.yml](./docker-compose.yml), tomados de un `.env` no versionado (verificar que esté en `.gitignore`).
- Publicar el puerto `4000` solo en el servicio `compras` (`ports: "4000:4000"`).
- Reintento de conexión (o `depends_on`) por si el primario no está listo.
- Los scripts `libremarket.sh start|stop` no cambian.
- **Entregable:** `./libremarket.sh start` levanta los 5 servicios conectados a la base y la API de Compras accesible desde N2 y N3.

### Fase 6: Pruebas de extremo a extremo y de fallas
- `Simulador.simular_compras_async(50)` y verificar:
  - Stock nunca negativo bajo concurrencia.
  - Stock inicial menos compras exitosas coincide con el stock final.
  - La web muestra los mismos resultados en ambos nodos.
- Repetir con compras iniciadas desde la web (`POST /compras` vía HAProxy, varias en paralelo con `curl` o `ab`) y comprobar que se reparten entre N2 y N3.
- Escenarios de falla:

| Escenario | Resultado esperado |
|---|---|
| Apagar Apache en N3 | HAProxy lo descarta sin cortes; las compras siguen entrando por N2 |
| Apagar la API de Compras | La web muestra un mensaje controlado (sin HTTP 500); el panel sigue funcionando |
| `POST` sin `API_TOKEN` o con datos inválidos | La API responde `401` / `400` |
| Apagar la réplica | El sistema sigue funcionando |
| Apagar el primario | Las compras fallan de forma controlada; los procesos no se caen |
| Reiniciar el contenedor `ventas` | El stock se conserva |
| Reiniciar `compras` con una compra en vuelo | Queda `interrumpida` y se libera el stock |

- **Entregable:** evidencia para la bitácora (capturas y salidas de `psql`).

### Fase 7: Documentación
- Actualizar [README.md](./README.md) y [CONCURRENCIA.md](./CONCURRENCIA.md): arquitectura nueva, atomicidad por SQL en lugar de por `GenServer`, y limitaciones.
- Documentar la API HTTP de Compras (endpoints, token y restricciones de red).
- Reemplazar el diagrama por [ARQUITECTURA_LAB4.md](./ARQUITECTURA_LAB4.md).

## 4. Orden y dependencias

```
F0 → F1 → F2 → F3 (Ventas → Infracciones/Pagos/Envíos → Compras → API HTTP) ─┐
              F1 → F4 (páginas de lectura, en paralelo a F3) ────────────────┤
                                       F4 (formulario de compra) necesita la API de F3 ┘→ F5 → F6 → F7
```

## 5. Riesgos y limitaciones

- **Sin failover automático.** Si cae el primario, la réplica no se promueve sola. Queda fuera de alcance y se documenta; promover a mano con `pg_ctl promote` puede servir de demo extra.
- **Retraso de replicación.** La web puede mostrar datos levemente viejos; es el comportamiento esperado de una réplica asíncrona y se menciona en el informe.
- **Mensajes AMQP duplicados.** Cubiertos por la idempotencia de la Fase 3.
- **Credenciales.** Nunca se versionan; van en `.env` y en variables de entorno (`DATABASE_URL`, `API_TOKEN`).
- **Compras es punto único de entrada.** Si cae el contenedor de Compras, la web no puede iniciar compras (el panel de lectura sigue andando). Se mitiga con `restart: unless-stopped` en docker-compose.
- **API expuesta en la red.** Se protege con token compartido, validación estricta de entrada y firewall limitado a N2 y N3.
