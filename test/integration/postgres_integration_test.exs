defmodule Libremarket.PostgresIntegrationTest do
  @moduledoc """
  Prueba los adaptadores Postgres contra el primario real (`DATABASE_URL`, rol
  `libremarket_app`, esquema `priv/sql/001_schema.sql` ya aplicado). No necesita
  el broker AMQP. Solo corre con `mix test --include integration`.

  Modifica el stock de los productos 1 y 2 y agrega filas con ids altos.
  """
  use ExUnit.Case, async: false

  @moduletag :integration

  alias Libremarket.Amqp.RpcClient
  alias Libremarket.Compras
  alias Libremarket.Repo

  setup do
    url = System.get_env("DATABASE_URL") || flunk("falta DATABASE_URL")
    assert url != ""

    {:ok, _} = Application.ensure_all_started(:postgrex)
    previo = Application.get_env(:libremarket, :storage_adapter)
    Application.put_env(:libremarket, :storage_adapter, :postgres)
    start_supervised!(Repo)

    on_exit(fn -> Application.put_env(:libremarket, :storage_adapter, previo) end)
    :ok
  end

  defp stock(id) do
    {:ok, %{rows: [[stock]]}} = Repo.query("SELECT stock FROM productos WHERE id_producto = $1", [id])
    stock
  end

  defp fijar_stock(id, cantidad),
    do: {:ok, _} = Repo.query("UPDATE productos SET stock = $2 WHERE id_producto = $1", [id, cantidad])

  defp id_unico, do: System.unique_integer([:positive]) + 1_000_000_000

  test "Ventas: la reserva es atomica bajo concurrencia y el stock no baja de cero" do
    start_supervised!({Libremarket.Ventas.Server, %{}})
    fijar_stock(1, 3)

    resultados =
      1..20
      |> Enum.map(fn _ -> Task.async(fn -> Libremarket.Ventas.Server.reservar_producto(1) end) end)
      |> Task.await_many()

    assert Enum.count(resultados, &(&1 == :ok)) == 3
    assert Enum.count(resultados, &(&1 == :sin_stock)) == 17
    assert stock(1) == 0

    assert :ok = Libremarket.Ventas.Server.liberar_producto(1)
    assert stock(1) == 1
    assert %{1 => 1} = Libremarket.Ventas.Server.listar_stock() |> Map.take([1])
  end

  test "Ventas: la semilla no pisa un stock existente al reiniciar" do
    fijar_stock(2, 7)
    start_supervised!({Libremarket.Ventas.Server, %{}})
    assert stock(2) == 7
  end

  test "Infracciones, Pagos y Envios son idempotentes ante re-entregas" do
    start_supervised!({Libremarket.Infracciones.Server, %{}})
    start_supervised!({Libremarket.Pagos.Server, %{}})
    start_supervised!({Libremarket.Envios.Server, %{}})
    id = id_unico()

    infraccion = Libremarket.Infracciones.Server.detectar_infraccion(id)
    assert is_boolean(infraccion)
    for _ <- 1..15, do: assert(Libremarket.Infracciones.Server.detectar_infraccion(id) == infraccion)

    pago = Libremarket.Pagos.Server.autorizar_pago(id)
    assert is_boolean(pago)
    for _ <- 1..15, do: assert(Libremarket.Pagos.Server.autorizar_pago(id) == pago)

    costo = Libremarket.Envios.Server.calcular_costo(id)
    assert costo in 1..500
    for _ <- 1..15, do: assert(Libremarket.Envios.Server.calcular_costo(id) == costo)
    assert :agendado = Libremarket.Envios.Server.agendar_envio(id)
    assert :agendado = Libremarket.Envios.Server.agendar_envio(id)
    assert Libremarket.Envios.Server.calcular_costo(id) == costo

    assert %{^id => %{costo: ^costo, agendado: true}} = Libremarket.Envios.Server.listar_envios()
    assert Map.fetch!(Libremarket.Pagos.Server.listar_pagos(), id) == pago
    assert Map.fetch!(Libremarket.Infracciones.Server.listar_infracciones(), id) == infraccion
  end

  describe "Compras" do
    setup do
      Process.register(self(), RpcClient)
      :ok
    end

    defp pedido(servicio, operacion) do
      assert_receive {:"$gen_cast", {:rpc, ^servicio, ^operacion, args, contexto, _}}
      {args, contexto}
    end

    test "el id sale de la secuencia, cada paso se persiste y se consulta desde la base" do
      start_supervised!({Compras.Server, %{}})

      {:ok, id1} = Compras.Server.comprar(3, :tc, :retira)
      {:ok, id2} = Compras.Server.comprar(4, "td", :correo)
      assert id2 > id1

      assert {:ok, %{estado: "en_curso", paso: "reservando", resultado: nil}} = Compras.Server.consultar(id1)

      {_, ctx} = pedido(:ventas, :reservar_producto)
      GenServer.cast(Compras.Server, {:rpc_reply, ctx, :ok})
      {_, ctx} = pedido(:ventas, :reservar_producto)
      GenServer.cast(Compras.Server, {:rpc_reply, ctx, :sin_stock})

      {[^id1], ctx} = pedido(:infracciones, :detectar_infraccion)
      assert {:ok, %{paso: "verificando_infraccion"}} = Compras.Server.consultar(id1)
      GenServer.cast(Compras.Server, {:rpc_reply, ctx, false})
      {_, ctx} = pedido(:pagos, :autorizar_pago)
      GenServer.cast(Compras.Server, {:rpc_reply, ctx, true})
      {_, ctx} = pedido(:ventas, :enviar_producto)
      GenServer.cast(Compras.Server, {:rpc_reply, ctx, :enviado})

      assert_receive {:compra_finalizada, ^id1, {:ok, ^id1, :producto_enviado}}
      assert_receive {:compra_finalizada, ^id2, {:error, :sin_stock}}

      assert {:ok, %{estado: "finalizada", resultado: "producto_enviado", paso: "enviando_producto"}} =
               Compras.Server.consultar(id1)

      assert {:ok, %{estado: "finalizada", resultado: "sin_stock"}} = Compras.Server.consultar(id2)
      assert Compras.Server.consultar(2_000_000_000) == :no_encontrada
    end

    test "al reiniciar, las compras en_curso quedan interrumpidas y se libera el stock reservado" do
      insertar = fn producto, paso ->
        {:ok, %{rows: [[id]]}} =
          Repo.query(
            "INSERT INTO compras (id_producto, medio_pago, entrega, paso, estado) VALUES ($1, 'tc', 'correo', $2, 'en_curso') RETURNING id_compra",
            [producto, paso]
          )

        id
      end

      reservada = insertar.(5, "autorizando_pago")
      sin_reserva = insertar.(6, "reservando")
      en_envio = insertar.(7, "enviando_producto")

      start_supervised!({Compras.Server, %{}})

      assert {[5], {^reservada, :liberando}} = pedido(:ventas, :liberar_producto)
      refute_receive {:"$gen_cast", {:rpc, :ventas, :liberar_producto, [6], _, _}}, 100
      # En :enviando_producto el envio pudo haberse hecho: no se devuelve el stock.
      refute_receive {:"$gen_cast", {:rpc, :ventas, :liberar_producto, [7], _, _}}, 100

      for id <- [reservada, sin_reserva, en_envio] do
        assert {:ok, %{estado: "interrumpida"}} = Compras.Server.consultar(id)
      end

      {:ok, %{rows: [[finalizada]]}} =
        Repo.query("SELECT finalizada_at IS NOT NULL FROM compras WHERE id_compra = $1", [reservada])

      assert finalizada
    end
  end
end
