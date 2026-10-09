defmodule Libremarket.Compras.ServerTest do
  # No usa broker: el proceso del test se registra con el nombre del RpcClient
  # y hace de cliente falso. Recibe los pedidos que el servidor publicaria y
  # contesta enviando al servidor los mismos casts que mandaria el RpcClient.
  use ExUnit.Case, async: false

  alias Libremarket.Amqp.RpcClient
  alias Libremarket.Compras.Server

  setup do
    Process.register(self(), RpcClient)
    start_supervised!({Server, %{}})
    :ok
  end

  defp responder(contexto, resultado),
    do: GenServer.cast(Server, {:rpc_reply, contexto, resultado})

  defp pedido(servicio, operacion) do
    assert_receive {:"$gen_cast", {:rpc, ^servicio, ^operacion, args, contexto, Server}}
    {args, contexto}
  end

  test "comprar/3 devuelve {:ok, id} y deja la compra en curso esperando la reserva" do
    assert {:ok, id} = Server.comprar(3, :tc, :correo)

    assert {[3], {^id, :reservando}} = pedido(:ventas, :reservar_producto)
    assert Server.estado_compra(id) == {:en_curso, :reservando}
  end

  test "estado_compra/1 de un id inexistente es :desconocida" do
    assert Server.estado_compra(123_456) == :desconocida
  end

  test "una compra exitosa por correo avanza paso a paso y avisa al solicitante" do
    {:ok, id} = Server.comprar(3, :tc, :correo)

    {[3], ctx} = pedido(:ventas, :reservar_producto)
    responder(ctx, :ok)

    {[^id], ctx} = pedido(:infracciones, :detectar_infraccion)
    assert ctx == {id, :verificando_infraccion}
    responder(ctx, false)

    {[^id], ctx} = pedido(:envios, :calcular_costo)
    responder(ctx, 120)

    {[^id], ctx} = pedido(:pagos, :autorizar_pago)
    responder(ctx, true)

    {[^id], ctx} = pedido(:envios, :agendar_envio)
    responder(ctx, :agendado)

    {[3], ctx} = pedido(:ventas, :enviar_producto)
    assert Server.estado_compra(id) == {:en_curso, :enviando_producto}
    responder(ctx, :enviado)

    assert_receive {:compra_finalizada, ^id, {:ok, ^id, :producto_enviado}}
    assert Server.estado_compra(id) == {:finalizada, {:ok, id, :producto_enviado}}
  end

  test "sin stock finaliza sin publicar mas pedidos" do
    {:ok, id} = Server.comprar(3, :tc, :retira)

    {_, ctx} = pedido(:ventas, :reservar_producto)
    responder(ctx, :sin_stock)

    assert_receive {:compra_finalizada, ^id, {:error, :sin_stock}}
    refute_receive {:"$gen_cast", {:rpc, _, _, _, _, _}}, 50
  end

  test "una infraccion finaliza y publica la compensacion con contexto :liberando" do
    {:ok, id} = Server.comprar(3, :tc, :retira)

    {_, ctx} = pedido(:ventas, :reservar_producto)
    responder(ctx, :ok)
    {_, ctx} = pedido(:infracciones, :detectar_infraccion)
    responder(ctx, true)

    assert_receive {:compra_finalizada, ^id, {:error, :infraccion}}
    assert {[3], {^id, :liberando}} = pedido(:ventas, :liberar_producto)

    # La respuesta de la compensacion no cambia el estado de la compra.
    responder({id, :liberando}, :ok)
    assert Server.estado_compra(id) == {:finalizada, {:error, :infraccion}}
  end

  test "varias compras conviven: el servidor atiende nuevas mientras otras esperan" do
    {:ok, id1} = Server.comprar(1, :tc, :retira)
    {:ok, id2} = Server.comprar(2, :td, :retira)
    {:ok, id3} = Server.comprar(3, :tc, :correo)

    assert Enum.uniq([id1, id2, id3]) |> length() == 3

    for {id, producto} <- [{id1, 1}, {id2, 2}, {id3, 3}] do
      assert {[^producto], {^id, :reservando}} = pedido(:ventas, :reservar_producto)
      assert Server.estado_compra(id) == {:en_curso, :reservando}
    end

    # Las respuestas llegan en otro orden y cada compra avanza por su cuenta.
    responder({id2, :reservando}, :sin_stock)
    responder({id3, :reservando}, :ok)

    assert_receive {:compra_finalizada, ^id2, {:error, :sin_stock}}
    assert {[^id3], {^id3, :verificando_infraccion}} = pedido(:infracciones, :detectar_infraccion)
    assert Server.estado_compra(id1) == {:en_curso, :reservando}
    assert Server.estado_compra(id3) == {:en_curso, :verificando_infraccion}
  end

  test "una respuesta que no corresponde al paso actual se ignora" do
    {:ok, id} = Server.comprar(3, :tc, :retira)
    {_, _} = pedido(:ventas, :reservar_producto)

    responder({id, :autorizando_pago}, true)

    assert Server.estado_compra(id) == {:en_curso, :reservando}
    refute_receive {:"$gen_cast", {:rpc, _, _, _, _, _}}, 50
  end

  test "una respuesta duplicada o de una compra terminada se ignora" do
    {:ok, id} = Server.comprar(3, :tc, :retira)
    {_, ctx} = pedido(:ventas, :reservar_producto)
    responder(ctx, :sin_stock)
    assert_receive {:compra_finalizada, ^id, {:error, :sin_stock}}

    responder(ctx, :ok)

    assert Server.estado_compra(id) == {:finalizada, {:error, :sin_stock}}
    refute_receive {:"$gen_cast", {:rpc, _, _, _, _, _}}, 50
    refute_receive {:compra_finalizada, _, _}, 50
  end

  test "un timeout en el pago finaliza con {:error, :timeout} y libera el producto" do
    {:ok, id} = Server.comprar(3, :tc, :retira)
    {_, ctx} = pedido(:ventas, :reservar_producto)
    responder(ctx, :ok)
    {_, ctx} = pedido(:infracciones, :detectar_infraccion)
    responder(ctx, false)
    {_, ctx} = pedido(:pagos, :autorizar_pago)

    GenServer.cast(Server, {:rpc_timeout, ctx})

    assert_receive {:compra_finalizada, ^id, {:error, :timeout}}
    assert {[3], {^id, :liberando}} = pedido(:ventas, :liberar_producto)
  end

  test "un timeout de un paso ya superado se ignora" do
    {:ok, id} = Server.comprar(3, :tc, :retira)
    {_, ctx} = pedido(:ventas, :reservar_producto)
    responder(ctx, :ok)
    {_, _} = pedido(:infracciones, :detectar_infraccion)

    GenServer.cast(Server, {:rpc_timeout, ctx})

    assert Server.estado_compra(id) == {:en_curso, :verificando_infraccion}
    refute_receive {:compra_finalizada, _, _}, 50
  end
end
