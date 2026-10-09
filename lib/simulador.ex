defmodule Simulador do

  def simular_compra() do
    envio = if Enum.random(1..100) <= 70, do: :correo, else: :retira
    pago = Enum.random([:efectivo, :transferencia, :td, :tc])

    resultado =
      case Libremarket.Ui.comprar(:rand.uniform(10), pago, envio) do
        {:ok, id_compra} -> Libremarket.Ui.esperar_resultado(id_compra)
        :cancelada -> :cancelada
      end

    # Con compras concurrentes el reloj incluye eventos de otras compras en vuelo.
    IO.puts("[simulador] resultado=#{inspect(resultado)} reloj compras (al terminar esta compra)=#{Libremarket.VectorClock.format(Libremarket.Amqp.RpcClient.clock())}")
    resultado
  end

  def simular_compras_secuencial(cantidad \\ 1) do
    for _n <- 1 .. cantidad do
      simular_compra()
    end
  end

  def simular_compras_async(cantidad \\ 1) do
    compras = for _n <- 1 .. cantidad do
      Task.async(fn -> simular_compra() end)
    end
    # Mayor que el timeout de Ui.esperar_resultado/2 (30 s) para no cortar antes.
    Task.await_many(compras, 60_000)
  end

end
