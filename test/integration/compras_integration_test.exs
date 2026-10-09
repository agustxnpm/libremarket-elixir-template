defmodule Libremarket.ComprasIntegrationTest do
  @moduledoc """
  Prueba el flujo asincronico completo contra el broker AMQP configurado
  (`CLOUDAMQP_URL`). Levanta todos los servicios en este mismo nodo, asi que
  conviene que no haya otros contenedores de libremarket consumiendo las mismas
  colas. Solo corre con `mix test --include integration`.
  """
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag timeout: 60_000

  alias Libremarket.Compras.Server
  alias Libremarket.Ventas

  @cantidad 20

  setup_all do
    System.delete_env("SERVER_TO_RUN")
    {:ok, _} = Application.ensure_all_started(:libremarket)
    on_exit(fn -> Application.stop(:libremarket) end)
    :ok
  end

  defp lanzar_compras(cantidad) do
    for n <- 1..cantidad do
      entrega = if rem(n, 3) == 0, do: :retira, else: :correo
      {:ok, id} = Server.comprar(rem(n, 10) + 1, :tc, entrega)
      id
    end
  end

  defp recolectar(ids, timeout \\ 25_000) do
    Map.new(ids, fn id ->
      assert_receive {:compra_finalizada, ^id, resultado}, timeout
      {id, resultado}
    end)
  end

  defp total(stock), do: stock |> Map.values() |> Enum.sum()

  defp esperar_sin_mensajes(pid, intentos \\ 50) do
    {:message_queue_len, pendientes} = Process.info(pid, :message_queue_len)

    if pendientes > 0 and intentos > 0 do
      Process.sleep(100)
      esperar_sin_mensajes(pid, intentos - 1)
    end
  end

  # Las compensaciones se publican despues de avisar el resultado: se espera a que impacten.
  defp esperar_stock(condicion, intentos \\ 100) do
    stock = Ventas.Server.listar_stock()

    cond do
      condicion.(stock) ->
        stock

      intentos == 0 ->
        flunk("el stock no llego al valor esperado: #{inspect(stock)}")

      true ->
        Process.sleep(100)
        esperar_stock(condicion, intentos - 1)
    end
  end

  test "comprar/3 retorna enseguida y la compra termina por eventos" do
    stock_inicial = Ventas.Server.listar_stock()

    {micros, {:ok, id}} = :timer.tc(fn -> Server.comprar(1, :tc, :correo) end)

    assert micros < 500_000
    refute Server.estado_compra(id) == :desconocida

    assert_receive {:compra_finalizada, ^id, resultado}, 25_000
    assert Server.estado_compra(id) == {:finalizada, resultado}

    # Se espera la compensacion (si la hubo) para no ensuciar a los demas tests.
    enviadas = if match?({:ok, _, :producto_enviado}, resultado), do: 1, else: 0
    esperar_stock(&(total(&1) == total(stock_inicial) - enviadas))
  end

  test "varias compras concurrentes terminan y el stock queda coherente" do
    stock_inicial = Ventas.Server.listar_stock()

    resultados = @cantidad |> lanzar_compras() |> recolectar()

    assert map_size(resultados) == @cantidad

    for {id, resultado} <- resultados do
      assert match?({:ok, ^id, :producto_enviado}, resultado) or
               resultado in [
                 {:error, :sin_stock},
                 {:error, :infraccion},
                 {:error, :pago_rechazado}
               ]
    end

    enviadas = Enum.count(resultados, fn {_id, r} -> match?({:ok, _, :producto_enviado}, r) end)
    esperado = total(stock_inicial) - enviadas

    stock_final = esperar_stock(&(total(&1) == esperado))
    assert Enum.all?(Map.values(stock_final), &(&1 >= 0))
  end

  describe "con el servicio de pagos caido" do
    # Se suspende el RpcServer de pagos en vez de pararlo: los pedidos le siguen
    # llegando pero nunca contesta, igual que un servicio caido.
    setup do
      {_id, pagos, _tipo, _modulos} =
        Libremarket.Supervisor
        |> Supervisor.which_children()
        |> List.keyfind({Libremarket.Amqp.RpcServer, :pagos}, 0)

      Application.put_env(:libremarket, :rpc_timeout, 1_000)
      :ok = :sys.suspend(pagos)

      on_exit(fn ->
        Application.delete_env(:libremarket, :rpc_timeout)
        # Al reanudar, pagos procesa los pedidos acumulados (sus respuestas se descartan).
        :ok = :sys.resume(pagos)
        esperar_sin_mensajes(pagos)
        Process.sleep(300)
      end)

      :ok
    end

    test "las compras que llegan al pago terminan en timeout y liberan el producto" do
      stock_inicial = Ventas.Server.listar_stock()

      resultados = @cantidad |> lanzar_compras() |> recolectar() |> Map.values()

      refute Enum.any?(resultados, &match?({:ok, _, _}, &1))
      assert {:error, :timeout} in resultados

      assert Enum.all?(
               resultados,
               &(&1 in [{:error, :timeout}, {:error, :sin_stock}, {:error, :infraccion}])
             )

      assert esperar_stock(&(&1 == stock_inicial)) == stock_inicial
    end
  end
end
