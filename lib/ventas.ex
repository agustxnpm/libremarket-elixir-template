defmodule Libremarket.Ventas do
  @doc """
  Genera el stock inicial: al menos 10 productos,
  con stock aleatorio entre 1 y 10 unidades cada uno.
  """
  def stock_inicial() do
    for id_producto <- 1..10, into: %{} do
      {id_producto, :rand.uniform(10)}
    end
  end

  @doc """
  Intenta reservar una unidad del producto.
  Devuelve {:ok, nuevo_stock} o {:sin_stock, stock}.
  """
  def reservar_producto(stock, id_producto) do
    case Map.get(stock, id_producto, 0) do
      cantidad when cantidad > 0 ->
        {:ok, Map.update!(stock, id_producto, &(&1 - 1))}

      _ ->
        {:sin_stock, stock}
    end
  end

  @doc """
  Libera (devuelve) una unidad del producto al stock.
  """
  def liberar_producto(stock, id_producto) do
    Map.update(stock, id_producto, 1, &(&1 + 1))
  end
end

defmodule Libremarket.Ventas.Memoria do
  @moduledoc """
  Adaptador en memoria (tests y `iex` sin base). Cada funcion recibe los datos
  del adaptador y devuelve `{respuesta, datos}`.
  """
  alias Libremarket.Ventas

  def init(_opts), do: Ventas.stock_inicial()
  def reservar_producto(stock, id_producto), do: Ventas.reservar_producto(stock, id_producto)
  def liberar_producto(stock, id_producto), do: {:ok, Ventas.liberar_producto(stock, id_producto)}
  def listar_stock(stock), do: {stock, stock}
end

defmodule Libremarket.Ventas.Postgres do
  @moduledoc """
  Adaptador PostgreSQL: el stock vive en la tabla `productos` y las operaciones
  son atomicas en SQL. Nunca lanza: las fallas se devuelven como `{:error, :persistencia}`.
  """
  require Logger

  alias Libremarket.Repo

  # Misma semilla que priv/sql/001_schema.sql (productos 1..10 con 10 unidades).
  @stock_semilla 10

  # Semilla solo si la tabla esta vacia, asi el stock sobrevive a reinicios.
  def init(_opts) do
    case Repo.query("SELECT COUNT(*) FROM productos") do
      {:ok, %{rows: [[0]]}} ->
        for id <- 1..10 do
          Repo.query(
            "INSERT INTO productos (id_producto, stock) VALUES ($1, $2) ON CONFLICT DO NOTHING",
            [id, @stock_semilla]
          )
        end

      {:ok, _} ->
        :ok

      {:error, :persistencia} ->
        Logger.error("Ventas: no se pudo verificar la semilla de productos")
    end

    nil
  end

  def reservar_producto(datos, id_producto) do
    sql =
      "UPDATE productos SET stock = stock - 1 WHERE id_producto = $1 AND stock > 0 RETURNING stock"

    case Repo.query(sql, [id_producto]) do
      {:ok, %{num_rows: 1}} -> {:ok, datos}
      {:ok, %{num_rows: 0}} -> {:sin_stock, datos}
      {:error, :persistencia} -> {{:error, :persistencia}, datos}
    end
  end

  def liberar_producto(datos, id_producto) do
    case Repo.query("UPDATE productos SET stock = stock + 1 WHERE id_producto = $1", [id_producto]) do
      {:ok, _} -> {:ok, datos}
      {:error, :persistencia} -> {{:error, :persistencia}, datos}
    end
  end

  def listar_stock(datos) do
    case Repo.query("SELECT id_producto, stock FROM productos ORDER BY id_producto") do
      {:ok, %{rows: filas}} -> {Map.new(filas, fn [id, stock] -> {id, stock} end), datos}
      {:error, :persistencia} -> {{:error, :persistencia}, datos}
    end
  end
end

defmodule Libremarket.Ventas.Server do
  @moduledoc """
  Ventas
  """
  use GenServer

  # API del cliente
  @doc """
  Crea un nuevo servidor de Ventas
  """
  def start_link(opts \\ %{}) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def reservar_producto(pid \\ __MODULE__, id_producto) do
    GenServer.call(pid, {:reservar_producto, id_producto})
  end

  def liberar_producto(pid \\ __MODULE__, id_producto) do
    GenServer.call(pid, {:liberar_producto, id_producto})
  end

  def enviar_producto(pid \\ __MODULE__, id_producto) do
    GenServer.call(pid, {:enviar_producto, id_producto})
  end

  def listar_stock(pid \\ __MODULE__) do
    GenServer.call(pid, :listar_stock)
  end

  @doc """
  Punto de entrada de los pedidos que llegan por AMQP (ver
  `Libremarket.Amqp.RpcServer`). Traduce la operacion pedida en una llamada
  local sobre este mismo GenServer.
  """
  def handle_rpc(:reservar_producto, [id_producto]), do: reservar_producto(id_producto)
  def handle_rpc(:liberar_producto, [id_producto]), do: liberar_producto(id_producto)
  def handle_rpc(:enviar_producto, [id_producto]), do: enviar_producto(id_producto)
  def handle_rpc(:listar_stock, []), do: listar_stock()

  # Callbacks
  @doc """
  Inicializa el servidor con el adaptador de persistencia configurado
  (ver `Libremarket.Storage`).
  """
  @impl true
  def init(opts) do
    adapter = Libremarket.Storage.adapter(Libremarket.Ventas.Memoria, Libremarket.Ventas.Postgres)
    {:ok, %{adapter: adapter, datos: adapter.init(opts)}}
  end

  @impl true
  def handle_call({:reservar_producto, id_producto}, _from, estado) do
    {respuesta, datos} = estado.adapter.reservar_producto(estado.datos, id_producto)
    {:reply, respuesta, %{estado | datos: datos}}
  end

  @impl true
  def handle_call({:liberar_producto, id_producto}, _from, estado) do
    {respuesta, datos} = estado.adapter.liberar_producto(estado.datos, id_producto)
    {:reply, respuesta, %{estado | datos: datos}}
  end

  @impl true
  def handle_call({:enviar_producto, _id_producto}, _from, estado) do
    {:reply, :enviado, estado}
  end

  @impl true
  def handle_call(:listar_stock, _from, estado) do
    {respuesta, datos} = estado.adapter.listar_stock(estado.datos)
    {:reply, respuesta, %{estado | datos: datos}}
  end
end
