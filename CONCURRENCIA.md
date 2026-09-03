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

## Resultados observables

- En una venta exitosa, el stock queda reducido en una unidad y se envia o agenda el producto segun la entrega.
- Ante un pago rechazado, el stock se libera y vuelve al valor anterior a la compra.
- Ante falta de stock, no se descuenta ninguna unidad.
- Con varias compras concurrentes, el total de reservas exitosas no puede superar el stock disponible al comenzar la simulacion.