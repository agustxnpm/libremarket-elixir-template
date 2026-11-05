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
          | {:error, :sin_stock | :infraccion | :pago_rechazado | :timeout | :persistencia}
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
  # Debe ir primero: algunos pasos (p. ej. :calculando_costo) aceptan cualquier respuesta.
  # Un servicio fallo al persistir: resultado final. Se compensa solo si ya hay
  # algo reservado (en :reservando no se sabe, y en :enviando_producto el envio
  # pudo haberse hecho; mismo criterio que timeout/1).
  def avanzar(%{paso: paso}, {:error, :persistencia}) when paso in [:reservando, :enviando_producto],
    do: {:finalizar, {:error, :persistencia}, []}

  def avanzar(estado, {:error, :persistencia}),
    do: {:finalizar, {:error, :persistencia}, [liberar(estado)]}

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

  @doc """
  Texto corto del resultado final, tal como se guarda en `compras.resultado`.
  """
  @spec resultado_a_texto(resultado_final()) :: String.t()
  def resultado_a_texto({:ok, _id, :producto_enviado}), do: "producto_enviado"
  def resultado_a_texto({:error, {:respuesta_inesperada, _paso, _resp}}), do: "respuesta_inesperada"
  def resultado_a_texto({:error, motivo}) when is_atom(motivo), do: Atom.to_string(motivo)

  defp enviar_producto(estado),
    do: continuar(estado, :ventas, :enviar_producto, [estado.producto], :enviando_producto)

  defp continuar(estado, servicio, operacion, args, paso),
    do: {:continuar, %{estado | paso: paso}, [{:rpc, servicio, operacion, args, paso}]}

  defp liberar(estado), do: {:rpc, :ventas, :liberar_producto, [estado.producto], :liberando}
end

defmodule Libremarket.Compras.Memoria do
  @moduledoc """
  Adaptador en memoria (tests y `iex` sin base). `datos` es el proximo id.
  El estado de las compras lo lleva el propio `Compras.Server`.
  """

  def init(_opts), do: 1

  def crear(siguiente_id, _producto, _medio_pago, _entrega), do: {:ok, siguiente_id, siguiente_id + 1}
  def registrar_paso(_datos, _id, _paso), do: :ok
  def registrar_final(_datos, _id, _paso, _resultado), do: :ok
  def interrumpir_en_curso(_datos), do: {:ok, []}
  def obtener(_id), do: :no_encontrada
end

defmodule Libremarket.Compras.Postgres do
  @moduledoc """
  Adaptador PostgreSQL. El `id_compra` sale de la secuencia de la tabla
  `compras`. El `pid` del solicitante nunca se persiste. Las fallas se
  devuelven como `{:error, :persistencia}`; nunca lanzan.
  """
  alias Libremarket.Compras
  alias Libremarket.Repo

  def init(_opts), do: nil

  def crear(datos, producto, medio_pago, entrega) do
    sql =
      "INSERT INTO compras (id_producto, medio_pago, entrega, paso, estado) " <>
        "VALUES ($1, $2, $3, 'reservando', 'en_curso') RETURNING id_compra"

    case Repo.query(sql, [producto, to_string(medio_pago), to_string(entrega)]) do
      {:ok, %{rows: [[id_compra]]}} -> {:ok, id_compra, datos}
      {:error, :persistencia} = error -> error
    end
  end

  def registrar_paso(_datos, id_compra, paso), do: actualizar(id_compra, paso, "en_curso", nil, nil)

  def registrar_final(_datos, id_compra, paso, resultado) do
    actualizar(id_compra, paso, "finalizada", Compras.resultado_a_texto(resultado), DateTime.utc_now())
  end

  defp actualizar(id_compra, paso, estado, resultado, finalizada_at) do
    sql =
      "UPDATE compras SET paso = $2, estado = $3, resultado = $4, finalizada_at = $5 WHERE id_compra = $1"

    case Repo.query(sql, [id_compra, to_string(paso), estado, resultado, finalizada_at]) do
      {:ok, _} -> :ok
      {:error, :persistencia} = error -> error
    end
  end

  @doc """
  Marca como `interrumpida` toda compra que quedo `en_curso` (el proceso que
  la llevaba murio) y devuelve `{:ok, [%{id:, producto:, paso:}]}`.
  """
  def interrumpir_en_curso(_datos) do
    sql =
      "UPDATE compras SET estado = 'interrumpida', finalizada_at = NOW() " <>
        "WHERE estado = 'en_curso' RETURNING id_compra, id_producto, paso"

    case Repo.query(sql) do
      {:ok, %{rows: filas}} ->
        {:ok, for([id, producto, paso] <- filas, do: %{id: id, producto: producto, paso: paso})}

      {:error, :persistencia} = error ->
        error
    end
  end

  def obtener(id_compra) do
    sql = "SELECT id_compra, estado, paso, resultado FROM compras WHERE id_compra = $1"

    case Repo.query(sql, [id_compra]) do
      {:ok, %{rows: [[id, estado, paso, resultado]]}} ->
        {:ok, %{id_compra: id, estado: estado, paso: paso, resultado: resultado}}

      {:ok, %{rows: []}} ->
        :no_encontrada

      {:error, :persistencia} = error ->
        error
    end
  end
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
  Inicia una compra y devuelve `{:ok, id_compra}` sin esperar el resultado
  (o `{:error, :persistencia}` si no se pudo registrar la compra).
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
  o `:desconocida`. Con Postgres, lo que no esta en memoria (por ejemplo tras un
  reinicio) se lee de la base: `{:interrumpida, paso}` o `{:finalizada, resultado_en_texto}`.
  """
  def estado_compra(pid \\ __MODULE__, id_compra) do
    GenServer.call(pid, {:estado_compra, id_compra})
  end

  @doc """
  Consulta para la API HTTP: `{:ok, %{id_compra:, estado:, paso:, resultado:}}`,
  `:no_encontrada` o `{:error, :persistencia}`. Con Postgres lee directo del
  primario (sin pasar por el GenServer); en memoria traduce `estado_compra/1`.
  """
  def consultar(id_compra) do
    if Libremarket.Storage.postgres?() do
      Libremarket.Compras.Postgres.obtener(id_compra)
    else
      case estado_compra(id_compra) do
        {:en_curso, paso} ->
          {:ok, %{id_compra: id_compra, estado: "en_curso", paso: to_string(paso), resultado: nil}}

        {:finalizada, resultado} ->
          {:ok,
           %{
             id_compra: id_compra,
             estado: "finalizada",
             paso: nil,
             resultado: Compras.resultado_a_texto(resultado)
           }}

        :desconocida ->
          :no_encontrada
      end
    end
  catch
    :exit, _ -> {:error, :persistencia}
  end

  # Callbacks

  @doc """
  Inicializa el estado del servidor
  """
  @impl true
  def init(opts) do
    adapter = Libremarket.Storage.adapter(Libremarket.Compras.Memoria, Libremarket.Compras.Postgres)

    estado = %{en_curso: %{}, finalizadas: %{}, adapter: adapter, datos: adapter.init(opts)}
    {:ok, estado, {:continue, :recuperar}}
  end

  # Las compras que quedaron `en_curso` pertenecen a un proceso que murio (el pid
  # del solicitante no se persiste): se marcan `interrumpida` y, si ya habian
  # superado la reserva, se libera el stock.
  @impl true
  def handle_continue(:recuperar, estado) do
    case estado.adapter.interrumpir_en_curso(estado.datos) do
      {:ok, interrumpidas} ->
        for %{id: id, producto: producto, paso: paso} <- interrumpidas do
          IO.puts("[compras ##{id}] INTERRUMPIDA al reiniciar (paso=#{paso})")

          if paso != "reservando" do
            RpcClient.request(:ventas, :liberar_producto, [producto], {id, :liberando})
          end
        end

      {:error, :persistencia} ->
        IO.puts("[compras] no se pudieron recuperar las compras en curso")
    end

    {:noreply, estado}
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
    case estado.adapter.crear(estado.datos, id_producto, medio_de_pago, forma_de_entrega) do
      {:ok, id_compra, datos} ->
        {compra, acciones} =
          Compras.iniciar(id_compra, id_producto, medio_de_pago, forma_de_entrega, solicitante)

        ejecutar_acciones(id_compra, acciones)

        estado = put_in(%{estado | datos: datos}, [:en_curso, id_compra], compra)
        {:reply, {:ok, id_compra}, estado}

      {:error, :persistencia} ->
        {:reply, {:error, :persistencia}, estado}
    end
  end

  @impl true
  def handle_call({:estado_compra, id_compra}, _from, estado) do
    respuesta =
      case estado do
        %{en_curso: %{^id_compra => %{paso: paso}}} -> {:en_curso, paso}
        %{finalizadas: %{^id_compra => resultado}} -> {:finalizada, resultado}
        _ -> desde_la_base(estado.adapter, id_compra)
      end

    {:reply, respuesta, estado}
  end

  defp desde_la_base(adapter, id_compra) do
    case adapter.obtener(id_compra) do
      {:ok, %{estado: "en_curso", paso: paso}} -> {:en_curso, paso}
      {:ok, %{estado: "interrumpida", paso: paso}} -> {:interrumpida, paso}
      {:ok, %{estado: "finalizada", resultado: resultado}} -> {:finalizada, resultado}
      _ -> :desconocida
    end
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
            estado.adapter.registrar_paso(estado.datos, id_compra, compra.paso)
            ejecutar_acciones(id_compra, acciones)
            {:noreply, put_in(estado, [:en_curso, id_compra], compra)}

          {:finalizar, resultado, acciones} ->
            estado.adapter.registrar_final(estado.datos, id_compra, compra.paso, resultado)
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
