defmodule Libremarket.Compras do

  def comprar(id_producto, _medio_de_pago, forma_de_entrega) do
    id_compra = :erlang.unique_integer([:positive])

    case Libremarket.Ventas.Server.reservar_producto(id_producto) do
      :sin_stock ->
        {:error, :sin_stock}

      :ok ->
        case Libremarket.Infracciones.Server.detectar_infraccion(id_compra) do
          :true ->
            Libremarket.Ventas.Server.liberar_producto(id_producto)
            {:error, :infraccion}

          :false ->
            if forma_de_entrega == :correo do
              Libremarket.Envios.Server.calcular_costo(id_compra)
            end

            case Libremarket.Pagos.Server.autorizar_pago(id_compra) do
              true ->
                finalizar_compra(id_compra, id_producto, forma_de_entrega)

              false ->
                Libremarket.Ventas.Server.liberar_producto(id_producto)
                {:error, :pago_rechazado}
            end
        end
    end
  end

  def finalizar_compra(id_compra, id_producto, :correo) do
    :agendado = Libremarket.Envios.Server.agendar_envio(id_compra)
    :enviado = Libremarket.Ventas.Server.enviar_producto(id_producto)
    {:ok, id_compra, :producto_enviado}
  end

  def finalizar_compra(id_compra, id_producto, :retira) do
    :enviado = Libremarket.Ventas.Server.enviar_producto(id_producto)
    {:ok, id_compra, :producto_enviado}
  end

  def finalizar_compra(id_compra, id_producto, _forma_de_entrega) do
    finalizar_compra(id_compra, id_producto, :retira)
  end

end

defmodule Libremarket.Compras.Server do
  @moduledoc """
  Compras
  """

  use GenServer

  # API del cliente

  @doc """
  Crea un nuevo servidor de Compras
  """
  def start_link(opts \\ %{}) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def comprar(
      pid \\ __MODULE__,
      id_producto,
      medio_de_pago,
      forma_de_entrega
    ) do
    GenServer.call(
      pid,
      {:comprar, id_producto, medio_de_pago, forma_de_entrega}
    )
  end

  # Callbacks

  @doc """
  Inicializa el estado del servidor
  """
  @impl true
  def init(state) do
    {:ok, state}
  end

  @doc """
  Callback para un call :comprar
  """
  @impl true
  def handle_call({:comprar, id_producto, medio_de_pago, forma_de_entrega}, _from, state) do
    result = Libremarket.Compras.comprar(id_producto, medio_de_pago, forma_de_entrega)
    {:reply, result, state}
  end

end
