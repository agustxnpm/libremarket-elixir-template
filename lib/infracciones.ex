defmodule Libremarket.Infracciones do

  def detectar_infraccion() do
    if Enum.random(1..100) <= 30, do: :true, else: :false
  end

end

defmodule Libremarket.Infracciones.Memoria do
  @moduledoc "Adaptador en memoria: `datos` es un mapa id_compra => detectada."

  def init(_opts), do: %{}

  def detectar_infraccion(datos, id_compra) do
    resultado = Libremarket.Infracciones.detectar_infraccion()
    {resultado, Map.put(datos, id_compra, resultado)}
  end

  def listar_infracciones(datos), do: {datos, datos}
end

defmodule Libremarket.Infracciones.Postgres do
  @moduledoc """
  Adaptador PostgreSQL. Idempotente: si el pedido AMQP se re-entrega se devuelve
  la decision ya guardada, sin volver a tirar el azar.
  """
  alias Libremarket.Repo

  def init(_opts), do: nil

  def detectar_infraccion(datos, id_compra) do
    nueva = Libremarket.Infracciones.detectar_infraccion()

    respuesta =
      case Repo.insertar_o_leer(
             "INSERT INTO infracciones (id_compra, detectada) VALUES ($1, $2) ON CONFLICT (id_compra) DO NOTHING RETURNING detectada",
             [id_compra, nueva],
             "SELECT detectada FROM infracciones WHERE id_compra = $1",
             [id_compra]
           ) do
        {:ok, [detectada]} -> detectada
        {:error, :persistencia} = error -> error
      end

    {respuesta, datos}
  end

  def listar_infracciones(datos) do
    case Repo.query("SELECT id_compra, detectada FROM infracciones ORDER BY id_compra DESC LIMIT 1000") do
      {:ok, %{rows: filas}} -> {Map.new(filas, fn [id, d] -> {id, d} end), datos}
      {:error, :persistencia} = error -> {error, datos}
    end
  end
end

defmodule Libremarket.Infracciones.Server do
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

  def detectar_infraccion(pid \\ __MODULE__, id_compra) do
    GenServer.call(pid, {:detectar_infraccion, id_compra})
  end

  def listar_infracciones(pid \\ __MODULE__) do
    GenServer.call(pid, :listar_infracciones)
  end

  @doc """
  Punto de entrada de los pedidos que llegan por AMQP (ver
  `Libremarket.Amqp.RpcServer`).
  """
  def handle_rpc(:detectar_infraccion, [id_compra]), do: detectar_infraccion(id_compra)
  def handle_rpc(:listar_infracciones, []), do: listar_infracciones()

  # Callbacks

  @doc """
  Inicializa el servidor con el adaptador de persistencia configurado
  (ver `Libremarket.Storage`).
  """
  @impl true
  def init(opts) do
    adapter =
      Libremarket.Storage.adapter(Libremarket.Infracciones.Memoria, Libremarket.Infracciones.Postgres)

    {:ok, %{adapter: adapter, datos: adapter.init(opts)}}
  end

  @impl true
  def handle_call({:detectar_infraccion, id_compra}, _from, estado) do
    {respuesta, datos} = estado.adapter.detectar_infraccion(estado.datos, id_compra)
    {:reply, respuesta, %{estado | datos: datos}}
  end

  @impl true
  def handle_call(:listar_infracciones, _from, estado) do
    {respuesta, datos} = estado.adapter.listar_infracciones(estado.datos)
    {:reply, respuesta, %{estado | datos: datos}}
  end
end
