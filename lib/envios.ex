defmodule Libremarket.Envios do

  def calcular_costo() do
    Enum.random(1..500)
  end

  def agendar_envio() do
    :agendado
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

  # Callbacks

  @doc """
  Inicializa el estado del servidor
  """
  @impl true
  def init(state) do
    {:ok, state}
  end

  @doc """
  Callback para un call :calcular_costo
  """
  @impl true
  def handle_call({:calcular_costo, id_compra}, _from, state) do
    result = Libremarket.Envios.calcular_costo()
    new_state = Map.put(state, id_compra, result)
    {:reply, result, new_state}
  end

  @impl true
  def handle_call({:agendar_envio, id_compra}, _from, state) do
    result = Libremarket.Envios.agendar_envio()
    new_state = Map.put(state, id_compra, result)
    {:reply, result, new_state}
  end

  @impl true
  def handle_call(:listar_envios, _from, state) do
    {:reply, state, state}
  end

end
