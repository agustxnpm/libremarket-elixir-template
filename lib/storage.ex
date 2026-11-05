defmodule Libremarket.Storage do
  @moduledoc """
  Selecciona el adaptador de persistencia (`:memory` | `:postgres`) segun
  `config :libremarket, :storage_adapter`. Cada servicio elige su modulo
  concreto con `adapter(memory_mod, postgres_mod)`.
  """

  def adapter, do: Application.get_env(:libremarket, :storage_adapter, :memory)

  def postgres?, do: adapter() == :postgres

  def adapter(memory_mod, postgres_mod) do
    if postgres?(), do: postgres_mod, else: memory_mod
  end
end
