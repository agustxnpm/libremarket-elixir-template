defmodule Libremarket.Compras do
  @moduledoc """
  Logica pura de una compra, modelada como una maquina de estados.

  Una compra no se ejecuta de corrido: cada vez que llega la respuesta de un
  servicio remoto se llama a `avanzar/2`, que devuelve el nuevo estado de la
  compra y las acciones a ejecutar (nuevos pedidos RPC, compensaciones), o el
  resultado final. Este modulo no hace I/O ni sabe de AMQP: quien ejecuta las
  acciones es `Libremarket.Compras.Server`, que las envia por
  `Libremarket.Amqp.RpcClient`. Eso permite testear todo el flujo sin broker.

  Flujo (cuando todo sale bien):

      :reservando -> :verificando_infraccion -> [:calculando_costo] ->
      :autorizando_pago -> [:agendando_envio] -> :enviando_producto -> FIN

  Los pasos entre corchetes solo existen cuando la entrega es `:correo`.

  Una accion es `{:rpc, servicio, operacion, args, paso}`. El `paso` es el que
  esta esperando respuesta (o `:liberando` para la compensacion, que no avanza
  ninguna compra).
  """

  @type paso ::
          :reservando
          | :verificando_infraccion
          | :calculando_costo
          | :autorizando_pago
          | :agendando_envio
          | :enviando_producto

  @type accion :: {:rpc, atom(), atom(), [term()], paso() | :liberando}
  @type estado :: %{
          id: integer(),
          producto: term(),
          medio_de_pago: term(),
          entrega: term(),
          paso: paso(),
          solicitante: pid() | nil
        }
  @type resultado_final ::
          {:ok, integer(), :producto_enviado}
          | {:error, :sin_stock | :infraccion | :pago_rechazado | :timeout}
          | {:error, {:respuesta_inesperada, paso(), term()}}

  @doc """
  Arma el estado inicial de una compra y la primera accion: reservar el producto.
  """
  @spec iniciar(integer(), term(), term(), term(), pid() | nil) :: {estado(), [accion()]}
  def iniciar(id, producto, medio_de_pago, entrega, solicitante) do
    estado = %{
      id: id,
      producto: producto,
      medio_de_pago: medio_de_pago,
      entrega: entrega,
      paso: :reservando,
      solicitante: solicitante
    }

    {estado, [{:rpc, :ventas, :reservar_producto, [producto], :reservando}]}
  end

  @doc """
  Aplica la respuesta del paso actual. Devuelve `{:continuar, estado, acciones}`
  si la compra sigue, o `{:finalizar, resultado, acciones}` si termino (las
  acciones restantes son compensaciones).
  """
  @spec avanzar(estado(), term()) ::
          {:continuar, estado(), [accion()]} | {:finalizar, resultado_final(), [accion()]}
  def avanzar(%{paso: :reservando} = estado, :ok),
    do:
      continuar(estado, :infracciones, :detectar_infraccion, [estado.id], :verificando_infraccion)

  def avanzar(%{paso: :reservando}, :sin_stock), do: {:finalizar, {:error, :sin_stock}, []}

  def avanzar(%{paso: :verificando_infraccion} = estado, true),
    do: {:finalizar, {:error, :infraccion}, [liberar(estado)]}

  def avanzar(%{paso: :verificando_infraccion, entrega: :correo} = estado, false),
    do: continuar(estado, :envios, :calcular_costo, [estado.id], :calculando_costo)

  def avanzar(%{paso: :verificando_infraccion} = estado, false),
    do: continuar(estado, :pagos, :autorizar_pago, [estado.id], :autorizando_pago)

  def avanzar(%{paso: :calculando_costo} = estado, _costo),
    do: continuar(estado, :pagos, :autorizar_pago, [estado.id], :autorizando_pago)

  def avanzar(%{paso: :autorizando_pago} = estado, false),
    do: {:finalizar, {:error, :pago_rechazado}, [liberar(estado)]}

  def avanzar(%{paso: :autorizando_pago, entrega: :correo} = estado, true),
    do: continuar(estado, :envios, :agendar_envio, [estado.id], :agendando_envio)

  def avanzar(%{paso: :autorizando_pago} = estado, true), do: enviar_producto(estado)

  def avanzar(%{paso: :agendando_envio} = estado, :agendado), do: enviar_producto(estado)

  def avanzar(%{paso: :enviando_producto} = estado, :enviado),
    do: {:finalizar, {:ok, estado.id, :producto_enviado}, []}

  # Todavia no hay nada reservado: no hay que compensar.
  def avanzar(%{paso: :reservando} = estado, respuesta),
    do: {:finalizar, {:error, {:respuesta_inesperada, estado.paso, respuesta}}, []}

  def avanzar(estado, respuesta),
    do: {:finalizar, {:error, {:respuesta_inesperada, estado.paso, respuesta}}, [liberar(estado)]}

  @doc """
  Finaliza la compra porque el paso actual no obtuvo respuesta a tiempo.

  Si el producto ya estaba reservado se libera, salvo en `:enviando_producto`
  (el envio pudo haberse hecho) y en `:reservando` (no se sabe si Ventas llego
  a reservar).
  """
  @spec timeout(estado()) :: {:finalizar, resultado_final(), [accion()]}
  def timeout(%{paso: paso}) when paso in [:reservando, :enviando_producto],
    do: {:finalizar, {:error, :timeout}, []}

  def timeout(estado), do: {:finalizar, {:error, :timeout}, [liberar(estado)]}

  defp enviar_producto(estado),
    do: continuar(estado, :ventas, :enviar_producto, [estado.producto], :enviando_producto)

  defp continuar(estado, servicio, operacion, args, paso),
    do: {:continuar, %{estado | paso: paso}, [{:rpc, servicio, operacion, args, paso}]}

  defp liberar(estado), do: {:rpc, :ventas, :liberar_producto, [estado.producto], :liberando}
end

defmodule Libremarket.Compras.Server do
  @moduledoc """
  Compras

  Mantiene las compras en vuelo (`en_curso`) y las ya terminadas
  (`finalizadas`). Ninguna compra bloquea al servidor: `comprar/3` registra la
  compra, publica el primer pedido y responde `{:ok, id_compra}` enseguida; cada
  respuesta remota llega despues como un `cast` que hace avanzar la compra
  (ver `Libremarket.Compras.avanzar/2`). Asi pueden convivir varias compras.

  Al terminar una compra se le envia al proceso que la inicio el mensaje
  `{:compra_finalizada, id_compra, resultado}`.
  """

  use GenServer

  alias Libremarket.Amqp.RpcClient
  alias Libremarket.Compras

  # API del cliente

  @doc """
  Crea un nuevo servidor de Compras
  """
  def start_link(opts \\ %{}) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Inicia una compra y devuelve `{:ok, id_compra}` sin esperar el resultado.
  El resultado llega al proceso que llamo como `{:compra_finalizada, id_compra, resultado}`.
  """
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

  @doc """
  Consulta el estado de una compra: `{:en_curso, paso}`, `{:finalizada, resultado}`
  o `:desconocida`.
  """
  def estado_compra(pid \\ __MODULE__, id_compra) do
    GenServer.call(pid, {:estado_compra, id_compra})
  end

  # Callbacks

  @doc """
  Inicializa el estado del servidor
  """
  @impl true
  def init(_opts) do
    {:ok, %{en_curso: %{}, finalizadas: %{}}}
  end

  @doc """
  Callback para un call :comprar
  """
  @impl true
  def handle_call(
        {:comprar, id_producto, medio_de_pago, forma_de_entrega},
        {solicitante, _tag},
        estado
      ) do
    id_compra = :erlang.unique_integer([:positive])

    {compra, acciones} =
      Compras.iniciar(id_compra, id_producto, medio_de_pago, forma_de_entrega, solicitante)

    ejecutar_acciones(id_compra, acciones)

    {:reply, {:ok, id_compra}, put_in(estado, [:en_curso, id_compra], compra)}
  end

  @impl true
  def handle_call({:estado_compra, id_compra}, _from, estado) do
    respuesta =
      case estado do
        %{en_curso: %{^id_compra => %{paso: paso}}} -> {:en_curso, paso}
        %{finalizadas: %{^id_compra => resultado}} -> {:finalizada, resultado}
        _ -> :desconocida
      end

    {:reply, respuesta, estado}
  end

  # Respuesta a una compensacion: solo se registra, no avanza ninguna compra.
  @impl true
  def handle_cast({:rpc_reply, {id_compra, :liberando}, resultado}, estado) do
    IO.puts("[compras ##{id_compra}] LIBERA  producto liberado, respuesta #{inspect(resultado)}")
    {:noreply, estado}
  end

  def handle_cast({:rpc_reply, {id_compra, paso}, resultado}, estado) do
    procesar(estado, id_compra, paso, &Compras.avanzar(&1, resultado))
  end

  def handle_cast({:rpc_timeout, {id_compra, :liberando}}, estado) do
    IO.puts("[compras ##{id_compra}] LIBERA  sin confirmacion: ventas no respondio a tiempo")
    {:noreply, estado}
  end

  def handle_cast({:rpc_timeout, {id_compra, paso}}, estado) do
    procesar(estado, id_compra, paso, &Compras.timeout/1)
  end

  # Aplica `transicion` a la compra solo si sigue esperando ese `paso`; una
  # respuesta tardia o repetida (compra ya avanzada o terminada) se ignora.
  defp procesar(estado, id_compra, paso, transicion) do
    case estado.en_curso do
      %{^id_compra => %{paso: ^paso} = compra} ->
        case transicion.(compra) do
          {:continuar, compra, acciones} ->
            ejecutar_acciones(id_compra, acciones)
            {:noreply, put_in(estado, [:en_curso, id_compra], compra)}

          {:finalizar, resultado, acciones} ->
            ejecutar_acciones(id_compra, acciones)
            {:noreply, finalizar(estado, compra, resultado)}
        end

      _ ->
        IO.puts(
          "[compras ##{id_compra}] IGNORA  mensaje fuera de paso o de una compra terminada (paso=#{paso})"
        )

        {:noreply, estado}
    end
  end

  defp finalizar(estado, compra, resultado) do
    IO.puts("[compras ##{compra.id}] FINALIZA #{inspect(resultado)}")
    send(compra.solicitante, {:compra_finalizada, compra.id, resultado})

    %{
      estado
      | en_curso: Map.delete(estado.en_curso, compra.id),
        finalizadas: Map.put(estado.finalizadas, compra.id, resultado)
    }
  end

  defp ejecutar_acciones(id_compra, acciones) do
    for {:rpc, servicio, operacion, args, paso} <- acciones do
      RpcClient.request(servicio, operacion, args, {id_compra, paso})
    end
  end
end
