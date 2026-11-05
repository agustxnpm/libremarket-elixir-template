defmodule Libremarket.Pagos do

  def autorizar_pago() do
    Enum.random(0 .. 100) > 30
  end

end

defmodule Libremarket.Pagos.Memoria do
  @moduledoc "Adaptador en memoria: `datos` es un mapa id_compra => autorizado."

  def init(_opts), do: %{}

  def autorizar_pago(datos, id_compra) do
    resultado = Libremarket.Pagos.autorizar_pago()
    {resultado, Map.put(datos, id_compra, resultado)}
  end

  def listar_pagos(datos), do: {datos, datos}
end

defmodule Libremarket.Pagos.Postgres do
  @moduledoc """
  Adaptador PostgreSQL. Idempotente: ante una re-entrega se devuelve la
  autorizacion ya guardada, sin volver a tirar el azar.
  """
  alias Libremarket.Repo

  def init(_opts), do: nil

  def autorizar_pago(datos, id_compra) do
    nuevo = Libremarket.Pagos.autorizar_pago()

    respuesta =
      case Repo.insertar_o_leer(
             "INSERT INTO pagos (id_compra, autorizado) VALUES ($1, $2) ON CONFLICT (id_compra) DO NOTHING RETURNING autorizado",
             [id_compra, nuevo],
             "SELECT autorizado FROM pagos WHERE id_compra = $1",
             [id_compra]
           ) do
        {:ok, [autorizado]} -> autorizado
        {:error, :persistencia} = error -> error
      end

    {respuesta, datos}
  end

  def listar_pagos(datos) do
    case Repo.query("SELECT id_compra, autorizado FROM pagos ORDER BY id_compra DESC LIMIT 1000") do
      {:ok, %{rows: filas}} -> {Map.new(filas, fn [id, a] -> {id, a} end), datos}
      {:error, :persistencia} = error -> {error, datos}
    end
  end
end

defmodule Libremarket.Pagos.Server do
  @moduledoc """
  Pagos
  """

  use GenServer

  # API del cliente

  @doc """
  Crea un nuevo servidor de Pagos
  """
  def start_link(opts \\ %{}) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def autorizar_pago(pid \\ __MODULE__, id_compra) do
    GenServer.call(pid, {:autorizar_pago, id_compra})
  end

 def listar_pagos(pid \\ __MODULE__) do
    GenServer.call(pid, :listar_pagos)
  end

  @doc """
  Punto de entrada de los pedidos que llegan por AMQP (ver
  `Libremarket.Amqp.RpcServer`).
  """
  def handle_rpc(:autorizar_pago, [id_compra]), do: autorizar_pago(id_compra)
  def handle_rpc(:listar_pagos, []), do: listar_pagos()

  # Callbacks

  @doc """
  Inicializa el servidor con el adaptador de persistencia configurado
  (ver `Libremarket.Storage`).
  """
  @impl true
  def init(opts) do
    adapter = Libremarket.Storage.adapter(Libremarket.Pagos.Memoria, Libremarket.Pagos.Postgres)
    {:ok, %{adapter: adapter, datos: adapter.init(opts)}}
  end

  @impl true
  def handle_call({:autorizar_pago, id_compra}, _from, estado) do
    {respuesta, datos} = estado.adapter.autorizar_pago(estado.datos, id_compra)
    {:reply, respuesta, %{estado | datos: datos}}
  end

  @impl true
  def handle_call(:listar_pagos, _from, estado) do
    {respuesta, datos} = estado.adapter.listar_pagos(estado.datos)
    {:reply, respuesta, %{estado | datos: datos}}
  end
end
