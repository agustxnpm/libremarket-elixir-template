defmodule Libremarket.Amqp.CodecTest do
  use ExUnit.Case, async: true

  alias Libremarket.Amqp.Codec

  test "un pedido codificado se decodifica igual" do
    mensaje = %{op: :reservar_producto, args: [3], clock: %{compras: 1, ventas: 0}}
    assert Codec.decode(Codec.encode(mensaje)) == {:ok, mensaje}
  end

  test "rechaza un binario que crearia un atomo nuevo" do
    nombre = "atomo_que_no_existe_#{System.unique_integer([:positive])}"
    # Formato externo de un atomo (SMALL_ATOM_UTF8_EXT), armado a mano para no crearlo.
    payload = <<131, 119, byte_size(nombre), nombre::binary>>

    assert Codec.decode(payload) == {:error, :mensaje_invalido}
    assert_raise ArgumentError, fn -> String.to_existing_atom(nombre) end
  end

  test "rechaza basura y valores que no son binarios" do
    assert Codec.decode(<<1, 2, 3>>) == {:error, :mensaje_invalido}
    assert Codec.decode(nil) == {:error, :mensaje_invalido}
  end

  test "todas las operaciones que atienden los servicios estan entre los atomos conocidos" do
    conocidos = MapSet.new(Codec.atomos_conocidos())

    operaciones = [
      :reservar_producto,
      :liberar_producto,
      :enviar_producto,
      :listar_stock,
      :detectar_infraccion,
      :listar_infracciones,
      :calcular_costo,
      :agendar_envio,
      :listar_envios,
      :autorizar_pago,
      :listar_pagos
    ]

    assert Enum.all?(operaciones, &MapSet.member?(conocidos, &1))
  end
end
