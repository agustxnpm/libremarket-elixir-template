defmodule Libremarket.VectorClockTest do
  use ExUnit.Case, async: true

  alias Libremarket.VectorClock

  @servicios [:compras, :ventas, :pagos, :envios, :infracciones]

  test "new/0 devuelve todos los servicios en cero" do
    clock = VectorClock.new()

    assert Map.keys(clock) |> Enum.sort() == Enum.sort(@servicios)
    assert Enum.all?(Map.values(clock), &(&1 == 0))
  end

  test "increment/2 suma uno solo al componente indicado" do
    clock = VectorClock.new() |> VectorClock.increment(:pagos)

    assert clock.pagos == 1
    assert Enum.all?(@servicios -- [:pagos], &(clock[&1] == 0))
    assert VectorClock.increment(clock, :pagos).pagos == 2
  end

  test "merge/2 toma el maximo componente a componente" do
    a = %{compras: 3, ventas: 1, pagos: 0, envios: 5, infracciones: 2}
    b = %{compras: 1, ventas: 4, pagos: 0, envios: 2, infracciones: 2}

    assert VectorClock.merge(a, b) == %{
             compras: 3,
             ventas: 4,
             pagos: 0,
             envios: 5,
             infracciones: 2
           }
  end

  test "merge/2 es conmutativo" do
    a = %{compras: 3, ventas: 1, pagos: 7, envios: 0, infracciones: 2}
    b = %{compras: 1, ventas: 4, pagos: 0, envios: 2, infracciones: 9}

    assert VectorClock.merge(a, b) == VectorClock.merge(b, a)
  end

  test "format/1 respeta el orden fijo" do
    clock = %{infracciones: 5, envios: 4, pagos: 3, ventas: 2, compras: 1}

    assert VectorClock.format(clock) == "[compras=1 ventas=2 pagos=3 envios=4 infracciones=5]"
  end
end
