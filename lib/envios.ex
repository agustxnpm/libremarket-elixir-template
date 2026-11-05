defmodule Libremarket.Envios do

  def calcular_costo() do
    Enum.random(1..500)
  end

  def agendar_envio() do
    :agendado
  end

end

defmodule Libremarket.Envios.Memoria do
  @moduledoc "Adaptador en memoria: `datos` es un mapa id_compra => ultimo valor calculado."

  def init(_opts), do: %{}

  def calcular_costo(datos, id_compra) do
    resultado = Libremarket.Envios.calcular_costo()
    {resultado, Map.put(datos, id_compra, resultado)}
  end

  def agendar_envio(datos, id_compra) do
    resultado = Libremarket.Envios.agendar_envio()
    {resultado, Map.put(datos, id_compra, resultado)}
  end

  def listar_envios(datos), do: {datos, datos}
end

defmodule Libremarket.Envios.Postgres do
  @moduledoc """
  Adaptador PostgreSQL. Una fila por compra en `envios`: `calcular_costo` la
  crea (`agendado = false`) y `agendar_envio` la marca agendada. Ambas son
  idempotentes ante re-entregas AMQP.
  """
  alias Libremarket.Repo

  def init(_opts), do: nil

  def calcular_costo(datos, id_compra) do
    nuevo = Libremarket.Envios.calcular_costo()

    respuesta =
      case Repo.insertar_o_leer(
             "INSERT INTO envios (id_compra, costo, agendado) VALUES ($1, $2, FALSE) ON CONFLICT (id_compra) DO NOTHING RETURNING costo",
             [id_compra, nuevo],
             "SELECT costo FROM envios WHERE id_compra = $1",
             [id_compra]
           ) do
        {:ok, [costo]} -> costo
        {:error, :persistencia} = error -> error
      end

    {respuesta, datos}
  end

  def agendar_envio(datos, id_compra) do
    sql =
      "INSERT INTO envios (id_compra, costo, agendado) VALUES ($1, 0, TRUE) " <>
        "ON CONFLICT (id_compra) DO UPDATE SET agendado = TRUE RETURNING agendado"

    case Repo.query(sql, [id_compra]) do
      {:ok, %{num_rows: 1}} -> {Libremarket.Envios.agendar_envio(), datos}
      {:error, :persistencia} = error -> {error, datos}
    end
  end

  def listar_envios(datos) do
    case Repo.query("SELECT id_compra, costo, agendado FROM envios ORDER BY id_compra DESC LIMIT 1000") do
      {:ok, %{rows: filas}} ->
        {Map.new(filas, fn [id, costo, agendado] -> {id, %{costo: costo, agendado: agendado}} end), datos}

      {:error, :persistencia} = error ->
        {error, datos}
    end
  end
end

defmodule Libremarket.Envios.Server do
  @moduledoc """
  Envios
  """

  use GenServer

  # API del cliente

  @doc """
  Crea un nuevo servidor de Envios
  """
  def start_link(opts \\ %{}) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def calcular_costo(pid \\ __MODULE__, id_compra) do
    GenServer.call(pid, {:calcular_costo, id_compra})
  end

  def agendar_envio(pid \\ __MODULE__, id_compra) do
    GenServer.call(pid, {:agendar_envio, id_compra})
  end

  def listar_envios(pid \\ __MODULE__) do
    GenServer.call(pid, :listar_envios)
  end

  @doc """
  Punto de entrada de los pedidos que llegan por AMQP (ver
  `Libremarket.Amqp.RpcServer`).
  """
  def handle_rpc(:calcular_costo, [id_compra]), do: calcular_costo(id_compra)
  def handle_rpc(:agendar_envio, [id_compra]), do: agendar_envio(id_compra)
  def handle_rpc(:listar_envios, []), do: listar_envios()

  # Callbacks

  @doc """
  Inicializa el servidor con el adaptador de persistencia configurado
  (ver `Libremarket.Storage`).
  """
  @impl true
  def init(opts) do
    adapter = Libremarket.Storage.adapter(Libremarket.Envios.Memoria, Libremarket.Envios.Postgres)
    {:ok, %{adapter: adapter, datos: adapter.init(opts)}}
  end

  @impl true
  def handle_call({:calcular_costo, id_compra}, _from, estado) do
    {respuesta, datos} = estado.adapter.calcular_costo(estado.datos, id_compra)
    {:reply, respuesta, %{estado | datos: datos}}
  end

  @impl true
  def handle_call({:agendar_envio, id_compra}, _from, estado) do
    {respuesta, datos} = estado.adapter.agendar_envio(estado.datos, id_compra)
    {:reply, respuesta, %{estado | datos: datos}}
  end

  @impl true
  def handle_call(:listar_envios, _from, estado) do
    {respuesta, datos} = estado.adapter.listar_envios(estado.datos)
    {:reply, respuesta, %{estado | datos: datos}}
  end
end
