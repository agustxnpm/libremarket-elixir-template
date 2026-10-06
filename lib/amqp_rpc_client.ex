defmodule Libremarket.Amqp.RpcClient do
  @moduledoc """
  Cliente RPC sobre AMQP.

  Publica un pedido en la cola de un servicio remoto (`:ventas`, `:pagos`,
  `:envios` o `:infracciones`) y espera la respuesta en una cola exclusiva
  propia, emparejando pedido/respuesta por `correlation_id`.

  El reloj vectorial de este proceso (`:compras`) viaja adentro de cada
  mensaje y se actualiza aca adentro de forma transparente: `Compras.comprar/3`
  llama a `call/3` sin saber que existen relojes vectoriales.
  """

  use GenServer
  use AMQP

  alias Libremarket.VectorClock

  @yo :compras
  @timeout 15_000

  # API del cliente

  def start_link(opts \\ %{}) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Invoca `operacion` con `args` (una lista) en el servicio remoto `servicio`
  y espera el resultado. Ejemplo:

      Libremarket.Amqp.RpcClient.call(:ventas, :reservar_producto, [3])
  """
  def call(servicio, operacion, args \\ []) do
    GenServer.call(__MODULE__, {:rpc, servicio, operacion, args}, @timeout)
  end

  @doc "Devuelve el reloj vectorial actual del cliente (compras)."
  def clock(), do: GenServer.call(__MODULE__, :clock)

  # Callbacks

  @impl true
  def init(_opts) do
    {:ok, channel} = AMQP.Application.get_channel(:channel)

    # Cola de nombre autogenerado, exclusiva de este proceso y que se borra
    # sola si se cae: aca llegan unicamente las respuestas a NUESTROS pedidos.
    {:ok, %{queue: reply_queue}} = Queue.declare(channel, "", exclusive: true, auto_delete: true)
    Basic.consume(channel, reply_queue, nil, no_ack: true)

    estado = %{
      channel: channel,
      reply_queue: reply_queue,
      clock: VectorClock.new(),
      pendientes: %{}
    }

    {:ok, estado}
  end

  @impl true
  def handle_call(:clock, _from, estado), do: {:reply, estado.clock, estado}

  @impl true
  def handle_call({:rpc, servicio, operacion, args}, from, estado) do
    correlation_id = "#{:erlang.unique_integer([:positive, :monotonic])}"

    # Evento de "envio": el reloj propio avanza antes de publicar el mensaje.
    clock = VectorClock.increment(estado.clock, @yo)

    mensaje = :erlang.term_to_binary(%{op: operacion, args: args, clock: clock})

    IO.puts("[compras] ENVIA   #{servicio}.#{operacion} #{inspect(args)} #{VectorClock.format(clock)}")

    Basic.publish(
      estado.channel,
      "",
      Libremarket.Amqp.RpcServer.queue_name(servicio),
      mensaje,
      reply_to: estado.reply_queue,
      correlation_id: correlation_id
    )

    # No respondemos todavia: la respuesta real llega de forma asincronica
    # como {:basic_deliver, ...} y ahi recien hacemos GenServer.reply/2.
    pendientes = Map.put(estado.pendientes, correlation_id, from)
    {:noreply, %{estado | clock: clock, pendientes: pendientes}}
  end

  @impl true
  def handle_info({:basic_consume_ok, _}, estado), do: {:noreply, estado}

  @impl true
  def handle_info({:basic_deliver, payload, meta}, estado) do
    %{result: resultado, clock: reloj_remoto} = :erlang.binary_to_term(payload)

    case Map.pop(estado.pendientes, meta.correlation_id) do
      {nil, _pendientes} ->
        # Respuesta que llego tarde (ya vencio el timeout) o que no es nuestra: se descarta.
        {:noreply, estado}

      {from, pendientes} ->
        # Evento de "recepcion": se funde el reloj recibido con el propio y se avanza.
        clock =
          estado.clock
          |> VectorClock.merge(reloj_remoto)
          |> VectorClock.increment(@yo)

        IO.puts("[compras] RECIBE  respuesta #{inspect(resultado)} reloj remoto=#{VectorClock.format(reloj_remoto)} => #{VectorClock.format(clock)}")

        GenServer.reply(from, resultado)
        {:noreply, %{estado | clock: clock, pendientes: pendientes}}
    end
  end
end
