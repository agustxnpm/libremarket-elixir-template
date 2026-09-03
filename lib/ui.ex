defmodule Libremarket.Ui do

  @doc """
  Inicia una compra con las opciones elegidas por el usuario.
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

  def informar_resultado(:cancelada) do
    {:mensaje, "La compra fue cancelada"}
  end

  def informar_resultado(resultado) do
    {:mensaje, "Resultado de compra: #{inspect(resultado)}"}
  end

end

