defmodule Libremarket.RepoTest do
  use ExUnit.Case, async: false

  test "el adaptador por defecto en test es :memory y el Repo esta deshabilitado" do
    assert Libremarket.Storage.adapter() == :memory
    refute Libremarket.Storage.postgres?()
    assert Libremarket.Storage.adapter(:mem, :pg) == :mem
  end

  test "query sin pool levantado devuelve {:error, :persistencia} sin crashear" do
    assert {:error, :persistencia} = Libremarket.Repo.query("SELECT 1")
  end

  test "con una base inalcanzable el pool arranca y query devuelve {:error, :persistencia}" do
    {:ok, _} = Application.ensure_all_started(:postgrex)
    System.put_env("DATABASE_URL", "postgres://u:p%40ss@127.0.0.1:1/libremarket")
    on_exit(fn -> System.delete_env("DATABASE_URL") end)

    assert {:ok, pid} = Libremarket.Repo.start_link()
    assert {:error, :persistencia} = Libremarket.Repo.query("SELECT 1", [])
    Supervisor.stop(pid)
  end

  test "sslmode=require y verify-full arrancan el pool; un sslmode desconocido no" do
    {:ok, _} = Application.ensure_all_started(:postgrex)
    on_exit(fn -> System.delete_env("DATABASE_URL") end)

    for modo <- ["require", "verify-full", "disable"] do
      System.put_env("DATABASE_URL", "postgres://u:p@127.0.0.1:1/libremarket?sslmode=#{modo}")
      assert {:ok, pid} = Libremarket.Repo.start_link()
      Supervisor.stop(pid)
    end

    System.put_env("DATABASE_URL", "postgres://u:p@127.0.0.1:1/libremarket?sslmode=cualquiera")
    assert {:error, :database_url_invalida} = Libremarket.Repo.start_link()
  end

  test "DATABASE_URL invalida no arranca el Repo" do
    System.put_env("DATABASE_URL", "no-es-una-url")
    on_exit(fn -> System.delete_env("DATABASE_URL") end)

    assert {:error, :database_url_invalida} = Libremarket.Repo.start_link()
  end
end
