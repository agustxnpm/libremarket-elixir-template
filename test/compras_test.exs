defmodule Libremarket.ComprasTest do
  use ExUnit.Case, async: true

  alias Libremarket.Compras

  @id 10
  @producto 3
  @liberar {:rpc, :ventas, :liberar_producto, [@producto], :liberando}

  defp en_paso(paso, entrega \\ :correo) do
    %{
      id: @id,
      producto: @producto,
      medio_de_pago: :tc,
      entrega: entrega,
      paso: paso,
      solicitante: nil
    }
  end

  # Recorre una compra aplicando las respuestas en orden y devuelve los pedidos
  # RPC emitidos (incluido el inicial) y el resultado final.
  defp recorrer(entrega, respuestas) do
    {estado, acciones} = Compras.iniciar(@id, @producto, :tc, entrega, self())
    recorrer(estado, respuestas, acciones)
  end

  defp recorrer(estado, [respuesta | resto], pedidos) do
    case Compras.avanzar(estado, respuesta) do
      {:continuar, estado, acciones} -> recorrer(estado, resto, pedidos ++ acciones)
      {:finalizar, resultado, acciones} -> {pedidos ++ acciones, resultado, resto}
    end
  end

  describe "iniciar/5" do
    test "arranca en :reservando y pide reservar el producto" do
      {estado, acciones} = Compras.iniciar(@id, @producto, :tc, :correo, self())

      assert estado == %{
               id: @id,
               producto: @producto,
               medio_de_pago: :tc,
               entrega: :correo,
               paso: :reservando,
               solicitante: self()
             }

      assert acciones == [{:rpc, :ventas, :reservar_producto, [@producto], :reservando}]
    end
  end

  describe "avanzar/2 - flujo exitoso" do
    test "entrega por correo recorre los 6 pasos" do
      {pedidos, resultado, sobrantes} =
        recorrer(:correo, [:ok, false, 250, true, :agendado, :enviado])

      assert pedidos == [
               {:rpc, :ventas, :reservar_producto, [@producto], :reservando},
               {:rpc, :infracciones, :detectar_infraccion, [@id], :verificando_infraccion},
               {:rpc, :envios, :calcular_costo, [@id], :calculando_costo},
               {:rpc, :pagos, :autorizar_pago, [@id], :autorizando_pago},
               {:rpc, :envios, :agendar_envio, [@id], :agendando_envio},
               {:rpc, :ventas, :enviar_producto, [@producto], :enviando_producto}
             ]

      assert resultado == {:ok, @id, :producto_enviado}
      assert sobrantes == []
    end

    test "entrega con retiro omite el costo y el agendado" do
      {pedidos, resultado, _} = recorrer(:retira, [:ok, false, true, :enviado])

      assert pedidos == [
               {:rpc, :ventas, :reservar_producto, [@producto], :reservando},
               {:rpc, :infracciones, :detectar_infraccion, [@id], :verificando_infraccion},
               {:rpc, :pagos, :autorizar_pago, [@id], :autorizando_pago},
               {:rpc, :ventas, :enviar_producto, [@producto], :enviando_producto}
             ]

      assert resultado == {:ok, @id, :producto_enviado}
    end

    test "cualquier entrega distinta de :correo se trata como retiro" do
      {pedidos, resultado, _} = recorrer(:otra, [:ok, false, true, :enviado])

      refute Enum.any?(pedidos, &match?({:rpc, :envios, _, _, _}, &1))
      assert resultado == {:ok, @id, :producto_enviado}
    end

    test "el estado guarda el paso que espera respuesta" do
      {estado, _} = Compras.iniciar(@id, @producto, :tc, :correo, self())

      {:continuar, estado, _} = Compras.avanzar(estado, :ok)
      assert estado.paso == :verificando_infraccion

      {:continuar, estado, _} = Compras.avanzar(estado, false)
      assert estado.paso == :calculando_costo

      {:continuar, estado, _} = Compras.avanzar(estado, 99)
      assert estado.paso == :autorizando_pago
    end
  end

  describe "avanzar/2 - finales con error" do
    test "sin stock finaliza sin compensar" do
      assert {:finalizar, {:error, :sin_stock}, []} =
               Compras.avanzar(en_paso(:reservando), :sin_stock)
    end

    test "infraccion finaliza y libera el producto" do
      assert {:finalizar, {:error, :infraccion}, [@liberar]} =
               Compras.avanzar(en_paso(:verificando_infraccion), true)
    end

    test "pago rechazado finaliza y libera el producto" do
      assert {:finalizar, {:error, :pago_rechazado}, [@liberar]} =
               Compras.avanzar(en_paso(:autorizando_pago), false)
    end

    test "el recorrido completo de un pago rechazado emite la compensacion al final" do
      {pedidos, resultado, _} = recorrer(:correo, [:ok, false, 100, false])

      assert resultado == {:error, :pago_rechazado}
      assert List.last(pedidos) == @liberar
    end
  end

  describe "avanzar/2 - respuesta inesperada" do
    test "en :reservando no compensa porque no hay nada reservado" do
      assert {:finalizar, {:error, {:respuesta_inesperada, :reservando, :raro}}, []} =
               Compras.avanzar(en_paso(:reservando), :raro)
    end

    for paso <- [
          :verificando_infraccion,
          :autorizando_pago,
          :agendando_envio,
          :enviando_producto
        ] do
      test "en #{paso} finaliza con error y libera el producto" do
        assert {:finalizar, {:error, {:respuesta_inesperada, unquote(paso), :raro}}, [@liberar]} =
                 Compras.avanzar(en_paso(unquote(paso)), :raro)
      end
    end

    test "agendar_envio con un valor distinto de :agendado ya no provoca un MatchError" do
      assert {:finalizar, {:error, {:respuesta_inesperada, :agendando_envio, :error}}, [@liberar]} =
               Compras.avanzar(en_paso(:agendando_envio), :error)
    end
  end

  describe "timeout/1" do
    test "en :reservando finaliza sin compensar (no se sabe si se reservo)" do
      assert {:finalizar, {:error, :timeout}, []} = Compras.timeout(en_paso(:reservando))
    end

    test "en :enviando_producto finaliza sin liberar (el envio pudo haberse hecho)" do
      assert {:finalizar, {:error, :timeout}, []} = Compras.timeout(en_paso(:enviando_producto))
    end

    for paso <- [:verificando_infraccion, :calculando_costo, :autorizando_pago, :agendando_envio] do
      test "en #{paso} finaliza y libera el producto" do
        assert {:finalizar, {:error, :timeout}, [@liberar]} =
                 Compras.timeout(en_paso(unquote(paso)))
      end
    end
  end
end
