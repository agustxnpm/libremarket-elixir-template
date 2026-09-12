defmodule Libremarket.Supervisor do
  use Supervisor

  @moduledoc """
  Arma el arbol de procesos segun la variable de entorno SERVER_TO_RUN.

  - Si NO esta definida (por ejemplo corriendo `iex -S mix` sin Docker): se
    levantan los cinco servidores de negocio, el `RpcClient` y los cuatro
    `RpcServer`, todo en un unico nodo BEAM. Sirve para probar el flujo
    completo hablando por AMQP consigo mismo, sin containers.
  - Si esta definida (un container por servicio, ver docker-compose.yml): se
    levanta solo lo que ESE container necesita.
      - Container de compras: el `Compras.Server` local + el `RpcClient`
        (porque Compras es quien inicia pedidos hacia los demas).
      - Container de ventas/pagos/envios/infracciones: el servidor de
        negocio local + un `RpcServer` que expone ese servicio por AMQP.

  IMPORTANTE: los servidores de negocio (Ventas.Server, Pagos.Server, etc.)
  se listan como `{Modulo, %{}}` y no como `Modulo` pelado. Si se los deja
  pelados, el Supervisor los arranca como `Modulo.start_link([])` (con una
  lista vacia como argumento), y su estado inicial termina siendo `[]` en vez
  de `%{}`, lo que rompe apenas se hace el primer `Map.put/3` sobre el estado.
  """

  @doc """
  Inicia el supervisor
  """
  def start_link() do
    Supervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  # Que funcion de negocio atiende cada servicio cuando le llega un pedido por AMQP.
  @handlers %{
    ventas: &Libremarket.Ventas.Server.handle_rpc/2,
    pagos: &Libremarket.Pagos.Server.handle_rpc/2,
    envios: &Libremarket.Envios.Server.handle_rpc/2,
    infracciones: &Libremarket.Infracciones.Server.handle_rpc/2
  }

  defp children() do
    case System.get_env("SERVER_TO_RUN") do
      nil -> children_todo_en_uno()
      server_to_run -> children_para(String.to_existing_atom("Elixir." <> server_to_run))
    end
  end

  defp children_todo_en_uno() do
    [
      Libremarket.Amqp.RpcClient,
      {Libremarket.Compras.Server, %{}},
      {Libremarket.Ventas.Server, %{}},
      {Libremarket.Pagos.Server, %{}},
      {Libremarket.Envios.Server, %{}},
      {Libremarket.Infracciones.Server, %{}}
    ] ++ rpc_servers(Map.keys(@handlers))
  end

  defp children_para(Libremarket.Compras.Server) do
    [Libremarket.Amqp.RpcClient, {Libremarket.Compras.Server, %{}}]
  end

  defp children_para(modulo) do
    servicio = servicio_de(modulo)
    [{modulo, %{}}] ++ rpc_servers([servicio])
  end

  defp rpc_servers(servicios) do
    for servicio <- servicios do
      Supervisor.child_spec(
        {Libremarket.Amqp.RpcServer, %{servicio: servicio, handler: @handlers[servicio]}},
        id: {Libremarket.Amqp.RpcServer, servicio}
      )
    end
  end

  defp servicio_de(Libremarket.Ventas.Server), do: :ventas
  defp servicio_de(Libremarket.Pagos.Server), do: :pagos
  defp servicio_de(Libremarket.Envios.Server), do: :envios
  defp servicio_de(Libremarket.Infracciones.Server), do: :infracciones

  @impl true
  def init(_opts) do
    Supervisor.init(children(), strategy: :one_for_one)
  end
end
