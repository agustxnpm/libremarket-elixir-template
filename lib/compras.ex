defmodule Libremarket.Compras do
  @moduledoc """
  Orquesta el flujo de una compra hablando con los demas servicios por AMQP
  (a traves de `Libremarket.Amqp.RpcClient`), en lugar de llamarlos
  directamente como GenServers locales. Esto es lo que permite que cada
  servicio corra en su propio contenedor: ya no hace falta que esten en el
  mismo nodo BEAM, alcanza con que todos puedan llegar al broker (LavinMQ/
  CloudAMQP).

  El reloj vectorial de cada mensaje lo maneja el `RpcClient` de forma
  transparente; este modulo no necesita saber que existe.
  """

  alias Libremarket.Amqp.RpcClient

  def comprar(id_producto, _medio_de_pago, forma_de_entrega) do
    id_compra = :erlang.unique_integer([:positive])

    case RpcClient.call(:ventas, :reservar_producto, [id_producto]) do
      :sin_stock ->
        {:error, :sin_stock}

      :ok ->
        case RpcClient.call(:infracciones, :detectar_infraccion, [id_compra]) do
          true ->
            RpcClient.call(:ventas, :liberar_producto, [id_producto])
            {:error, :infraccion}

          false ->
            if forma_de_entrega == :correo do
              RpcClient.call(:envios, :calcular_costo, [id_compra])
            end

            case RpcClient.call(:pagos, :autorizar_pago, [id_compra]) do
              true ->
                finalizar_compra(id_compra, id_producto, forma_de_entrega)

              false ->
                RpcClient.call(:ventas, :liberar_producto, [id_producto])
                {:error, :pago_rechazado}
            end
        end
    end
  end

  def finalizar_compra(id_compra, id_producto, :correo) do
    :agendado = RpcClient.call(:envios, :agendar_envio, [id_compra])
    :enviado = RpcClient.call(:ventas, :enviar_producto, [id_producto])
    {:ok, id_compra, :producto_enviado}
  end

  def finalizar_compra(id_compra, id_producto, :retira) do
    :enviado = RpcClient.call(:ventas, :enviar_producto, [id_producto])
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
