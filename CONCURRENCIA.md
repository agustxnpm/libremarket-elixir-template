# Concurrencia y simulaciones

## Simulaciones

El modulo `Simulador` permite ejecutar compras de dos formas:

- `Simulador.simular_compras_secuencial(10)`: ejecuta una compra y espera su resultado antes de iniciar la siguiente.
- `Simulador.simular_compras_async(10)`: crea una tarea por compra y espera todos los resultados con `Task.await_many/1`.

Cada compra selecciona aleatoriamente un producto y un medio de pago. La UI simula un 80% de confirmaciones del cliente. El simulador elige correo en el 70% de los casos. Los resultados posibles son una compra exitosa, `:cancelada`, una infraccion, un pago rechazado o falta de stock.

## Analisis de concurrencia

Cada servidor es un proceso independiente. Las operaciones se envian con `GenServer.call/2`, por lo que el cliente espera una respuesta, pero cada servidor procesa sus mensajes en orden.

En particular, dos compras concurrentes que reservan el mismo producto no modifican el mapa de stock al mismo tiempo. `Ventas.Server` atiende una reserva, actualiza su estado y luego atiende la siguiente. La segunda reserva observa el stock ya actualizado y devuelve `:sin_stock` cuando no quedan unidades.

La reserva y la autorizacion del pago no forman una transaccion distribuida. Si una compra falla despues de reservar, `Compras` debe llamar a `Ventas.Server.liberar_producto/1`. Esto se aplica a una infraccion y a un pago rechazado. Si un servidor falla entre dos operaciones, no existe rollback automatico.

El uso de `Task.async/1` permite observar solicitudes concurrentes, pero no elimina la coordinacion: cada llamada a un `GenServer` sigue siendo sincronica para la tarea que la realiza.

## Estructuras de datos por servidor

Cada `GenServer` mantiene su propio estado, aislado del resto de los procesos:

- `Ventas.Server`: un mapa `%{id_producto => cantidad}` con el stock disponible, inicializado aleatoriamente por `Ventas.stock_inicial/0`. Se actualiza en cada reserva o liberacion.
- `Pagos.Server`: un mapa `%{id_compra => resultado}` donde `resultado` es un booleano que indica si el pago fue autorizado. Se agrega una entrada por cada compra procesada.
- `Envios.Server`: un mapa `%{id_compra => resultado}` con el costo calculado o el estado de agendamiento del envio.
- `Infracciones.Server`: un mapa `%{id_compra => resultado}` con el booleano que indica si se detecto una infraccion.
- `Compras.Server`: no acumula estado propio; su unico rol es delegar cada `handle_call` en las funciones del modulo `Compras`, que a su vez coordina al resto de los servidores.

Al ser mapas propios de cada proceso, no hay memoria compartida entre servidores: toda lectura o escritura pasa por un mensaje (`GenServer.call/2`), lo que evita condiciones de carrera sobre estos datos.

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

### Patron RPC sobre AMQP

`Compras` necesita el resultado de cada paso antes de decidir el siguiente
(reservar antes de chequear infraccion, etc.), por lo que se implemento un
patron de **RPC sobre AMQP**:

- Cada servicio remoto (ventas/pagos/envios/infracciones) tiene su propia
  cola de pedidos (`Libremarket.Amqp.RpcServer`, cola
  `libremarket.<servicio>.requests`).
- El contenedor de `compras` tiene un `Libremarket.Amqp.RpcClient`: publica
  el pedido con una cola de respuesta exclusiva propia (`reply_to`) y un
  `correlation_id` unico, y espera esa respuesta puntual.
- `Compras.comprar/3` llama a `RpcClient.call(:ventas, :reservar_producto, [id])`
  en vez de `Libremarket.Ventas.Server.reservar_producto(id)`: la logica de
  negocio no cambio, solo el transporte.

### Relojes vectoriales

Cada mensaje (pedido y respuesta) lleva adjunto el reloj vectorial de quien
lo envia (`Libremarket.VectorClock`, un mapa `%{servicio => contador}`):

- Al enviar un mensaje, el emisor incrementa su propio contador.
- Al recibir un mensaje, el receptor funde (maximo componente a componente)
  su reloj con el recibido, y despues incrementa su propio contador.

Esto queda encapsulado en `RpcClient`/`RpcServer`: ni `Compras` ni
`Ventas`/`Pagos`/`Envios`/`Infracciones` necesitan saber que existen relojes
vectoriales.
