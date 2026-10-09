defmodule Libremarket.Ui do

  @doc """
  Inicia una compra con las opciones elegidas por el usuario.

  Si el usuario confirma devuelve `{:ok, id_compra}` sin esperar el resultado:
  este llega al proceso que llamo como `{:compra_finalizada, id_compra, resultado}`
  (ver `esperar_resultado/2`). Si no confirma devuelve `:cancelada`.
  """
  def comprar(producto, medio_de_pago, forma_de_entrega) do
    comprar(producto, medio_de_pago, forma_de_entrega, confirmar_compra())
  end

  def comprar(producto, medio_de_pago, forma_de_entrega, true) do
    Libremarket.Compras.Server.comprar(
      producto,
      medio_de_pago,
      forma_de_entrega
    )
  end

  def comprar(_producto, _medio_de_pago, _forma_de_entrega, false) do
    :cancelada
  end

  def confirmar_compra() do
    Enum.random(1..100) <= 80
  end

  @doc """
  Espera el resultado final de una compra iniciada por este proceso. Es opcional:
  da comportamiento sincronico encima de la base asincronica.
  """
  def esperar_resultado(id_compra, timeout \\ 30_000) do
    receive do
      {:compra_finalizada, ^id_compra, resultado} -> resultado
    after
      timeout -> {:error, :sin_respuesta}
    end
  end

  @doc """
  Convierte el resultado de la compra en un mensaje para el usuario.
  """
  def informar_resultado({:ok, id_compra, :producto_enviado}) do
    {:mensaje, "Compra #{id_compra} confirmada"}
  end

  def informar_resultado({:error, :sin_stock}) do
    {:mensaje, "No hay stock disponible"}
  end

  def informar_resultado({:error, :infraccion}) do
    {:mensaje, "La compra fue rechazada por una infraccion"}
  end

  def informar_resultado({:error, :pago_rechazado}) do
    {:mensaje, "El pago fue rechazado"}
  end

  def informar_resultado({:error, :timeout}) do
    {:mensaje, "La compra no pudo completarse: un servicio no respondio a tiempo"}
  end

  def informar_resultado({:error, {:respuesta_inesperada, paso, _respuesta}}) do
    {:mensaje, "La compra fallo: respuesta inesperada de un servicio en el paso #{paso}"}
  end

  def informar_resultado(:cancelada) do
    {:mensaje, "La compra fue cancelada"}
  end

  def informar_resultado(resultado) do
    {:mensaje, "Resultado de compra: #{inspect(resultado)}"}
  end

end

