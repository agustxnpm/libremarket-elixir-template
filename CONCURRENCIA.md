# Concurrencia y simulaciones

## Simulaciones

El modulo `Simulador` permite ejecutar compras de dos formas:

- `Simulador.simular_compras_secuencial(10)`: inicia una compra y espera su resultado antes de iniciar la siguiente.
- `Simulador.simular_compras_async(10)`: crea una tarea por compra y espera todos los resultados con `Task.await_many/2`. Como `Compras.Server` no se bloquea mientras una compra espera respuestas remotas, las compras realmente quedan en vuelo al mismo tiempo.

Cada compra selecciona aleatoriamente un producto y un medio de pago. La UI simula un 80% de confirmaciones del cliente. El simulador elige correo en el 70% de los casos. Los resultados posibles son una compra exitosa, `:cancelada`, una infraccion, un pago rechazado, falta de stock o un timeout (`{:error, :timeout}`) si un servicio no responde.

## Analisis de concurrencia

Cada servidor es un proceso independiente y procesa sus mensajes en orden.

En particular, dos compras concurrentes que reservan el mismo producto no modifican el mapa de stock al mismo tiempo. `Ventas.Server` atiende una reserva, actualiza su estado y luego atiende la siguiente. La segunda reserva observa el stock ya actualizado y devuelve `:sin_stock` cuando no quedan unidades.

La reserva y la autorizacion del pago no forman una transaccion distribuida. Si una compra falla despues de reservar, `Compras` envia a Ventas un pedido `liberar_producto` como compensacion. Esto se aplica a una infraccion, a un pago rechazado, a una respuesta inesperada y a un timeout (salvo en `:reservando`, donde no se sabe si Ventas llego a reservar, y en `:enviando_producto`, donde el envio pudo haberse hecho). Si un servidor falla entre dos operaciones, no existe rollback automatico.

`Compras.Server` nunca espera una respuesta remota dentro de un callback: `comprar/3` responde `{:ok, id_compra}` enseguida y cada respuesta AMQP llega despues como un mensaje que hace avanzar esa compra (ver "Patron RPC sobre AMQP"). Por eso `Task.async/1` en el simulador produce concurrencia efectiva dentro de Compras, y no solo en las tareas del cliente.

## Estructuras de datos por servidor

Cada `GenServer` mantiene su propio estado, aislado del resto de los procesos:

- `Ventas.Server`: un mapa `%{id_producto => cantidad}` con el stock disponible, inicializado aleatoriamente por `Ventas.stock_inicial/0`. Se actualiza en cada reserva o liberacion.
- `Pagos.Server`: un mapa `%{id_compra => resultado}` donde `resultado` es un booleano que indica si el pago fue autorizado. Se agrega una entrada por cada compra procesada.
- `Envios.Server`: un mapa `%{id_compra => resultado}` con el costo calculado o el estado de agendamiento del envio.
- `Infracciones.Server`: un mapa `%{id_compra => resultado}` con el booleano que indica si se detecto una infraccion.
- `Compras.Server`: un mapa `%{en_curso: %{id_compra => compra}, finalizadas: %{id_compra => resultado}}`. Cada compra en curso guarda su `paso` actual (por ejemplo `:autorizando_pago`) y el proceso que la inicio. `finalizadas` crece sin limite; es aceptable para este trabajo practico.

Al ser mapas propios de cada proceso, no hay memoria compartida entre servidores: toda lectura o escritura pasa por un mensaje, lo que evita condiciones de carrera sobre estos datos.

## Resultados observables

- En una venta exitosa, el stock queda reducido en una unidad y se envia o agenda el producto segun la entrega.
- Ante un pago rechazado, el stock se libera y vuelve al valor anterior a la compra.
- Ante falta de stock, no se descuenta ninguna unidad.
- Con varias compras concurrentes, el total de reservas exitosas no puede superar el stock disponible al comenzar la simulacion.
## Comunicacion distribuida y relojes vectoriales (Lab 2)

A partir del Laboratorio 2, cada servicio corre en su propio contenedor
Docker (`compras`, `ventas`, `pagos`, `envios`, `infracciones`) y ya no
comparte nodo BEAM con los demas. La comunicacion entre servicios pasa a ser
por paso de mensajes usando AMQP (LavinMQ en CloudAMQP como broker), en lugar
de llamadas directas a un `GenServer` remoto.

### Patron RPC sobre AMQP, 100% asincronico

`Compras` necesita el resultado de cada paso antes de decidir el siguiente
(reservar antes de chequear infraccion, etc.), pero **ningun proceso queda
bloqueado esperando una respuesta**: cada compra avanza por eventos, cuando
llega un mensaje. Se implemento como un **RPC sobre AMQP orientado a eventos**:

- Cada servicio remoto (ventas/pagos/envios/infracciones) tiene su propia
  cola de pedidos (`Libremarket.Amqp.RpcServer`, cola
  `libremarket.<servicio>.requests`).
- El contenedor de `compras` tiene un `Libremarket.Amqp.RpcClient`.
  `RpcClient.request/5` publica el pedido con una cola de respuesta exclusiva
  propia (`reply_to`) y un `correlation_id` unico, guarda un `contexto` opaco
  (`{id_compra, paso}`) y **retorna enseguida**.
- Cuando llega la respuesta, `RpcClient` actualiza el reloj vectorial y se la
  entrega a `Compras.Server` con `GenServer.cast(..., {:rpc_reply, contexto, resultado})`.
- Cada pedido programa un `Process.send_after/3` (15 s por defecto, configurable con
  `config :libremarket, rpc_timeout: ms`). Si vence antes de la respuesta, el
  cliente avisa `{:rpc_timeout, contexto}` sin tocar el reloj (no hubo recepcion).
  Las respuestas tardias se descartan por `correlation_id`.

Cada compra es una **maquina de estados** que vive en el estado de
`Compras.Server` (`en_curso`):

```text
:reservando -> :verificando_infraccion -> [:calculando_costo] ->
:autorizando_pago -> [:agendando_envio] -> :enviando_producto -> FIN
```

(los pasos entre corchetes solo aplican a entregas por correo). Las
transiciones son funciones puras en `Libremarket.Compras` (`iniciar/5`,
`avanzar/2`, `timeout/1`): devuelven el nuevo estado y las acciones a ejecutar
(siguiente pedido RPC o compensacion `liberar_producto`), por lo que se
testean sin broker. Una respuesta que no corresponde al paso actual (tardia o
repetida) se ignora.

Desde afuera:

- `Compras.Server.comprar/3` (y `Ui.comprar/3`) devuelve `{:ok, id_compra}` sin
  esperar el resultado.
- Al terminar, el proceso que inicio la compra recibe
  `{:compra_finalizada, id_compra, resultado}`; `Ui.esperar_resultado/2` lo
  espera si se quiere un comportamiento sincronico.
- `Compras.Server.estado_compra/1` informa `{:en_curso, paso}`,
  `{:finalizada, resultado}` o `:desconocida`.
- Los logs del cliente llevan el `id_compra` (`[compras #3590] ENVIA ...`) para
  separar compras intercaladas.

### Relojes vectoriales

Cada mensaje (pedido y respuesta) lleva adjunto el reloj vectorial de quien
lo envia (`Libremarket.VectorClock`, un mapa `%{servicio => contador}`):

- Al enviar un mensaje, el emisor incrementa su propio contador.
- Al recibir un mensaje, el receptor funde (maximo componente a componente)
  su reloj con el recibido, y despues incrementa su propio contador.

Esto queda encapsulado en `RpcClient`/`RpcServer`: ni `Compras` ni
`Ventas`/`Pagos`/`Envios`/`Infracciones` necesitan saber que existen relojes
vectoriales.

Con compras concurrentes hay un unico reloj en `RpcClient` (se modifica solo
dentro de ese proceso, por lo que las actualizaciones estan serializadas). Los
vectores incorporan eventos de otras compras en vuelo: reflejan la causalidad
entre **mensajes**, no entre compras. Para mostrar el recorrido de una sola
compra conviene usar `Simulador.simular_compras_secuencial/1`; para mostrar
concurrencia, `Simulador.simular_compras_async/1`.

## Pruebas

- `mix test` corre los tests sin broker (`VectorClock`, transiciones puras de
  `Compras` y `Compras.Server` con un `RpcClient` falso). Los tests no levantan
  la aplicacion (`test --no-start`, ver `mix.exs`).
- `mix test --include integration` agrega los tests contra el broker
  configurado en `CLOUDAMQP_URL` (compras concurrentes, stock coherente y
  timeout con pagos "caido"). Levantan todos los servicios en un solo nodo,
  asi que no deben estar corriendo los contenedores de libremarket. Con Docker:

  ```sh
  docker run --rm -v "$(pwd)":/app -w /app --env-file .env \
    -e MIX_HOME=/app/mix_home -e HEX_HOME=/app/hex_home \
    elixir:otp-27-alpine mix test --include integration
  ```
