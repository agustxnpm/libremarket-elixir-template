defmodule Libremarket.Amqp.RpcClient do
  @moduledoc """
  Cliente RPC sobre AMQP.

  Publica un pedido en la cola de un servicio remoto (`:ventas`, `:pagos`,
  `:envios` o `:infracciones`) y recibe la respuesta en una cola exclusiva
  propia, emparejando pedido/respuesta por `correlation_id`.

  Es 100% asincronico: `request/5` no espera nada. Por cada pedido se guarda un
  `contexto` opaco (el cliente no lo interpreta) y, cuando llega la respuesta,
  se le entrega al proceso `responder_a` como
  `{:rpc_reply, contexto, resultado}`. Si no llega en `@timeout` ms, se le
  entrega `{:rpc_timeout, contexto}`.

  El reloj vectorial de este proceso (`:compras`) viaja adentro de cada
  mensaje y se actualiza aca adentro de forma transparente, sin que quien
  hace el pedido sepa que existen relojes vectoriales.
  """

  use GenServer
  use AMQP

  alias Libremarket.VectorClock

  @yo :compras
  # Tiempo maximo de espera de una respuesta (ms); se puede cambiar con
  # `config :libremarket, rpc_timeout: ms`.
  @timeout 15_000

  # API del cliente

  def start_link(opts \\ %{}) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Pide `operacion` con `args` (una lista) al servicio remoto `servicio` y
  retorna enseguida. Mas tarde, `responder_a` recibe por `cast`
  `{:rpc_reply, contexto, resultado}` o, si el servicio no contesta a tiempo,
  `{:rpc_timeout, contexto}`. Ejemplo:

      Libremarket.Amqp.RpcClient.request(:ventas, :reservar_producto, [3], {id_compra, :reservando})
  """
  def request(servicio, operacion, args, contexto, responder_a \\ Libremarket.Compras.Server) do
    GenServer.cast(__MODULE__, {:rpc, servicio, operacion, args, contexto, responder_a})
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
  def handle_cast({:rpc, servicio, operacion, args, contexto, responder_a}, estado) do
    correlation_id = "#{:erlang.unique_integer([:positive, :monotonic])}"

    # Evento de "envio": el reloj propio avanza antes de publicar el mensaje.
    clock = VectorClock.increment(estado.clock, @yo)

    mensaje = :erlang.term_to_binary(%{op: operacion, args: args, clock: clock})

    IO.puts("[compras #{etiqueta(contexto, correlation_id)}] ENVIA   #{servicio}.#{operacion} #{inspect(args, charlists: :as_lists)} #{VectorClock.format(clock)}")

    Basic.publish(
      estado.channel,
      "",
      Libremarket.Amqp.RpcServer.queue_name(servicio),
      mensaje,
      reply_to: estado.reply_queue,
      correlation_id: correlation_id
    )

    # No se espera la respuesta: llega como {:basic_deliver, ...} y, si no
    # llega, como {:rpc_timeout, ...}. En ambos casos se avisa a `responder_a`.
    timer = Process.send_after(self(), {:rpc_timeout, correlation_id}, timeout())

    pendiente = %{
      contexto: contexto,
      responder_a: responder_a,
      timer: timer,
      servicio: servicio,
      operacion: operacion
    }

    {:noreply, %{estado | clock: clock, pendientes: Map.put(estado.pendientes, correlation_id, pendiente)}}
  end

  @impl true
  def handle_info({:basic_consume_ok, _}, estado), do: {:noreply, estado}

  @impl true
  def handle_info({:basic_deliver, payload, meta}, estado) do
    %{result: resultado, clock: reloj_remoto} = :erlang.binary_to_term(payload)

    case Map.pop(estado.pendientes, meta.correlation_id) do
      {nil, _pendientes} ->
        # Respuesta que llego tarde (ya vencio el timeout) o que no es nuestra: se descarta.
        IO.puts("[compras cid=#{meta.correlation_id}] DESCARTA respuesta tardia o ajena #{inspect(resultado)}")
        {:noreply, estado}

      {pendiente, pendientes} ->
        Process.cancel_timer(pendiente.timer)

        # Evento de "recepcion": se funde el reloj recibido con el propio y se avanza.
        clock =
          estado.clock
          |> VectorClock.merge(reloj_remoto)
          |> VectorClock.increment(@yo)

        IO.puts("[compras #{etiqueta(pendiente.contexto, meta.correlation_id)}] RECIBE  respuesta #{inspect(resultado)} reloj remoto=#{VectorClock.format(reloj_remoto)} => #{VectorClock.format(clock)}")

        GenServer.cast(pendiente.responder_a, {:rpc_reply, pendiente.contexto, resultado})
        {:noreply, %{estado | clock: clock, pendientes: pendientes}}
    end
  end

  @impl true
  def handle_info({:rpc_timeout, correlation_id}, estado) do
    case Map.pop(estado.pendientes, correlation_id) do
      # La respuesta ya llego (el timeout quedo en la cola de mensajes): no hay nada que hacer.
      {nil, _pendientes} ->
        {:noreply, estado}

      {pendiente, pendientes} ->
        # No hubo evento de recepcion: el reloj no se toca.
        IO.puts("[compras #{etiqueta(pendiente.contexto, correlation_id)}] TIMEOUT #{pendiente.servicio}.#{pendiente.operacion} sin respuesta tras #{timeout()} ms")

        GenServer.cast(pendiente.responder_a, {:rpc_timeout, pendiente.contexto})
        {:noreply, %{estado | pendientes: pendientes}}
    end
  end

  defp timeout(), do: Application.get_env(:libremarket, :rpc_timeout, @timeout)

  # Etiqueta de los logs para poder separar compras intercaladas: el contexto
  # que usa Compras es {id_compra, paso}; con cualquier otro se usa el correlation_id.
  defp etiqueta({id_compra, _paso}, _correlation_id), do: "##{id_compra}"
  defp etiqueta(_contexto, correlation_id), do: "cid=#{correlation_id}"
end
