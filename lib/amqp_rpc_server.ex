defmodule Libremarket.Amqp.RpcServer do
  @moduledoc """
  Lado "servidor" del RPC sobre AMQP.

  Cada servicio (ventas, pagos, envios, infracciones) levanta una instancia de
  este proceso, que:

    1. escucha la cola de pedidos propia del servicio (`queue_name/1`),
    2. delega la operacion pedida en `handler` (la logica de negocio real,
       que vive en el `GenServer` local de ese servicio),
    3. responde publicando en la cola `reply_to` que vino en el pedido,
       usando el mismo `correlation_id`.

  Tambien es el responsable de fundir y avanzar el reloj vectorial del
  servicio en cada pedido que atiende.
  """

  use GenServer
  use AMQP

  alias Libremarket.Amqp.Codec
  alias Libremarket.VectorClock

  def start_link(%{servicio: servicio, handler: handler}) do
    GenServer.start_link(__MODULE__, %{servicio: servicio, handler: handler})
  end

  @doc "Nombre de la cola de pedidos de un servicio (ej: `:ventas` -> \"libremarket.ventas.requests\")."
  def queue_name(servicio), do: "libremarket.#{servicio}.requests"

  @impl true
  def init(%{servicio: servicio, handler: handler}) do
    {:ok, channel} = AMQP.Application.get_channel(:channel)
    queue = queue_name(servicio)

    Queue.declare(channel, queue, durable: true)
    # No tomar mas de 10 pedidos sin confirmar a la vez.
    Basic.qos(channel, prefetch_count: 10)
    Basic.consume(channel, queue)

    estado = %{
      servicio: servicio,
      handler: handler,
      channel: channel,
      clock: VectorClock.new()
    }

    {:ok, estado}
  end

  @impl true
  def handle_info({:basic_consume_ok, _}, estado), do: {:noreply, estado}

  @impl true
  def handle_info({:basic_cancel, _}, estado), do: {:stop, :normal, estado}

  @impl true
  def handle_info({:basic_cancel_ok, _}, estado), do: {:noreply, estado}

  @impl true
  def handle_info({:basic_deliver, payload, meta}, estado) do
    case Codec.decode(payload) do
      {:ok, %{op: operacion, args: args, clock: reloj_remoto}}
      when is_atom(operacion) and is_list(args) and is_map(reloj_remoto) and is_binary(meta.reply_to) ->
        atender(estado, operacion, args, reloj_remoto, meta)

      _ ->
        # Mensaje ilegible o con otra forma: se descarta sin reencolar, para que
        # no vuelva una y otra vez (y sin tirar este proceso).
        IO.puts("[#{estado.servicio}] DESCARTA mensaje invalido (#{byte_size(payload)} bytes)")
        Basic.reject(estado.channel, meta.delivery_tag, requeue: false)
        {:noreply, estado}
    end
  end

  defp atender(estado, operacion, args, reloj_remoto, meta) do
    # Evento de "recepcion": se funde el reloj del pedido con el propio y se avanza.
    clock_recibido =
      estado.clock
      |> VectorClock.merge(reloj_remoto)
      |> VectorClock.increment(estado.servicio)

    IO.puts("[#{estado.servicio}] RECIBE  #{operacion} #{inspect(args)} reloj remoto=#{VectorClock.format(reloj_remoto)} => #{VectorClock.format(clock_recibido)}")
    resultado = ejecutar(estado, operacion, args)

    # Evento de "envio" de la respuesta: se vuelve a avanzar antes de publicar.
    clock_respuesta = VectorClock.increment(clock_recibido, estado.servicio)

    respuesta = Codec.encode(%{result: resultado, clock: clock_respuesta})

    IO.puts("[#{estado.servicio}] RESPONDE #{inspect(resultado)} #{VectorClock.format(clock_respuesta)}")

    Basic.publish(estado.channel, "", meta.reply_to, respuesta, correlation_id: meta.correlation_id)
    Basic.ack(estado.channel, meta.delivery_tag)

    {:noreply, %{estado | clock: clock_respuesta}}
  end

  # Una operacion desconocida o con argumentos que no corresponden no debe tirar
  # el RpcServer: se responde con un error que Compras trata como respuesta inesperada.
  defp ejecutar(estado, operacion, args) do
    estado.handler.(operacion, args)
  rescue
    error in [FunctionClauseError, ArgumentError] ->
      IO.puts("[#{estado.servicio}] ERROR   #{operacion} #{inspect(args)}: #{Exception.message(error)}")
      {:error, :operacion_invalida}
  end
end
