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

  # Callbacks
  @doc """
  Inicializa el estado del servidor con stock aleatorio
  """
  @impl true
  def init(_opts) do
    {:ok, Libremarket.Ventas.stock_inicial()}
  end

  @doc """
  Callback para un call :reservar_producto
  """
  @impl true
  def handle_call({:reservar_producto, id_producto}, _from, stock) do
    case Libremarket.Ventas.reservar_producto(stock, id_producto) do
      {:ok, nuevo_stock} -> {:reply, :ok, nuevo_stock}
      {:sin_stock, stock} -> {:reply, :sin_stock, stock}
    end
  end

  @impl true
  def handle_call({:liberar_producto, id_producto}, _from, stock) do
    nuevo_stock = Libremarket.Ventas.liberar_producto(stock, id_producto)
    {:reply, :ok, nuevo_stock}
  end

  @impl true
  def handle_call({:enviar_producto, _id_producto}, _from, stock) do
    {:reply, :enviado, stock}
  end

  @impl true
  def handle_call(:listar_stock, _from, stock) do
    {:reply, stock, stock}
  end
end