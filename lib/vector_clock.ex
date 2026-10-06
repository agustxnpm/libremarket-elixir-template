defmodule Libremarket.VectorClock do
  @moduledoc """
  Relojes vectoriales para el sistema distribuido de Libremarket.

  Cada proceso (compras, ventas, pagos, envios, infracciones) mantiene un mapa
  `%{servicio => contador}`. Las reglas que implementa este modulo son las
  clasicas de relojes vectoriales:

    * Evento local o de envio de un mensaje: el proceso incrementa su propio
      contador (`increment/2`).
    * Evento de recepcion de un mensaje: el proceso funde su reloj con el que
      llego adjunto al mensaje, tomando el maximo componente a componente
      (`merge/2`), y luego incrementa su propio contador.

  Este modulo no sabe nada de AMQP ni de Compras/Ventas/etc: solo maneja los
  mapas. Quien arma y desarma los mensajes es `Libremarket.Amqp.RpcClient` y
  `Libremarket.Amqp.RpcServer`.
  """

  @servicios [:compras, :ventas, :pagos, :envios, :infracciones]

  @doc "Crea un reloj nuevo, con el contador de cada servicio en cero."
  def new() do
    for servicio <- @servicios, into: %{}, do: {servicio, 0}
  end

  @doc "Incrementa en uno el contador propio de `servicio`."
  def increment(clock, servicio) do
    Map.update(clock, servicio, 1, &(&1 + 1))
  end

  @doc """
  Funde dos relojes tomando, para cada servicio, el maximo de ambos
  contadores. Es la operacion que corresponde a "recibir" el reloj de otro
  proceso.
  """
  def merge(clock_a, clock_b) do
    Map.merge(clock_a, clock_b, fn _servicio, a, b -> max(a, b) end)
  end

  @doc "Texto compacto del reloj en orden fijo, ej: `[compras=3 ventas=2 pagos=0 envios=0 infracciones=1]`."
  def format(clock) do
    contenido = Enum.map_join(@servicios, " ", fn s -> "#{s}=#{Map.get(clock, s, 0)}" end)
    "[#{contenido}]"
  end
end
