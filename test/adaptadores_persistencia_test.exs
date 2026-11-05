defmodule Libremarket.AdaptadoresPersistenciaTest do
  @moduledoc """
  Con el adaptador :postgres pero sin base disponible, ningun servicio debe
  caerse: todo se resuelve como `{:error, :persistencia}`.
  """
  use ExUnit.Case, async: false

  alias Libremarket.Amqp.RpcClient

  setup do
    Application.put_env(:libremarket, :storage_adapter, :postgres)
    on_exit(fn -> Application.put_env(:libremarket, :storage_adapter, :memory) end)
    :ok
  end

  test "Ventas responde {:error, :persistencia} y sigue vivo" do
    pid = start_supervised!({Libremarket.Ventas.Server, %{}})

    assert {:error, :persistencia} = Libremarket.Ventas.Server.reservar_producto(1)
    assert {:error, :persistencia} = Libremarket.Ventas.Server.liberar_producto(1)
    assert {:error, :persistencia} = Libremarket.Ventas.Server.listar_stock()
    assert Process.alive?(pid)
  end

  test "Infracciones, Pagos y Envios responden {:error, :persistencia} y siguen vivos" do
    pids = [
      start_supervised!({Libremarket.Infracciones.Server, %{}}),
      start_supervised!({Libremarket.Pagos.Server, %{}}),
      start_supervised!({Libremarket.Envios.Server, %{}})
    ]

    assert {:error, :persistencia} = Libremarket.Infracciones.Server.detectar_infraccion(1)
    assert {:error, :persistencia} = Libremarket.Pagos.Server.autorizar_pago(1)
    assert {:error, :persistencia} = Libremarket.Envios.Server.calcular_costo(1)
    assert {:error, :persistencia} = Libremarket.Envios.Server.agendar_envio(1)
    assert Enum.all?(pids, &Process.alive?/1)
  end

  test "Compras no crea la compra si no puede persistirla y sigue vivo" do
    Process.register(self(), RpcClient)
    pid = start_supervised!({Libremarket.Compras.Server, %{}})

    assert {:error, :persistencia} = Libremarket.Compras.Server.comprar(3, :tc, :correo)
    assert Libremarket.Compras.Server.estado_compra(1) == :desconocida
    assert Libremarket.Compras.Server.consultar(1) == {:error, :persistencia}
    assert Process.alive?(pid)
    refute_receive {:"$gen_cast", {:rpc, _, _, _, _, _}}, 50
  end
end
