defmodule Libremarket.Compras.HttpApiTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Libremarket.Compras.HttpApi

  @token "token-de-prueba"

  setup do
    System.put_env("API_TOKEN", @token)
    parent = self()

    Application.put_env(:libremarket, :compras_api,
      comprar: fn producto, medio, entrega ->
        send(parent, {:comprar, producto, medio, entrega})
        {:ok, 42}
      end,
      consultar: fn
        42 -> {:ok, %{id_compra: 42, estado: "finalizada", paso: "enviando_producto", resultado: "producto_enviado"}}
        500 -> {:error, :persistencia}
        _ -> :no_encontrada
      end,
      health: fn -> true end
    )

    on_exit(fn ->
      System.delete_env("API_TOKEN")
      Application.delete_env(:libremarket, :compras_api)
    end)
  end

  defp llamar(metodo, ruta, params \\ nil, token \\ @token) do
    conn = conn(metodo, ruta, params)
    conn = if token, do: put_req_header(conn, "x-api-token", token), else: conn
    HttpApi.call(conn, HttpApi.init([]))
  end

  defp json(conn), do: Jason.decode!(conn.resp_body)

  @valido %{"producto" => "3", "medio_pago" => "tc", "entrega" => "correo"}

  describe "GET /health" do
    test "es publico y responde 200" do
      conn = llamar(:get, "/health", nil, nil)
      assert conn.status == 200
      assert json(conn) == %{"status" => "ok"}
    end

    test "responde 503 si la base falla" do
      Application.put_env(:libremarket, :compras_api, health: fn -> false end)
      assert llamar(:get, "/health", nil, nil).status == 503
    end
  end

  describe "autenticacion" do
    test "POST /compras sin token o con token incorrecto -> 401" do
      for token <- [nil, "otro"] do
        conn = llamar(:post, "/compras", @valido, token)
        assert conn.status == 401
        assert json(conn) == %{"error" => "unauthorized"}
      end

      refute_received {:comprar, _, _, _}
    end

    test "GET /compras/:id sin token -> 401" do
      assert llamar(:get, "/compras/42", nil, nil).status == 401
    end

    test "sin API_TOKEN configurada se rechaza todo" do
      System.delete_env("API_TOKEN")
      assert llamar(:post, "/compras", @valido, "").status == 401
    end
  end

  describe "POST /compras" do
    test "crea la compra y responde 202 con el id (form-urlencoded)" do
      conn = llamar(:post, "/compras", @valido)
      assert conn.status == 202
      assert json(conn) == %{"id_compra" => 42}
      assert_received {:comprar, 3, :tc, :correo}
    end

    test "acepta JSON" do
      conn =
        conn(:post, "/compras", Jason.encode!(%{producto: 10, medio_pago: "efectivo", entrega: "retira"}))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-api-token", @token)
        |> then(&HttpApi.call(&1, HttpApi.init([])))

      assert conn.status == 202
      assert_received {:comprar, 10, :efectivo, :retira}
    end

    test "entrada invalida -> 400 sin invocar a Compras" do
      invalidos = [
        %{@valido | "producto" => "0"},
        %{@valido | "producto" => "11"},
        %{@valido | "producto" => "abc"},
        %{@valido | "medio_pago" => "bitcoin"},
        %{@valido | "entrega" => "dron"},
        Map.delete(@valido, "entrega"),
        %{}
      ]

      for params <- invalidos do
        conn = llamar(:post, "/compras", params)
        assert conn.status == 400
        assert json(conn) == %{"error" => "invalid_input"}
      end

      refute_received {:comprar, _, _, _}
    end

    test "si Compras no puede persistir -> 503" do
      Application.put_env(:libremarket, :compras_api, comprar: fn _, _, _ -> {:error, :persistencia} end)
      assert llamar(:post, "/compras", @valido).status == 503
    end

    test "si Compras no esta disponible -> 503 sin caer" do
      Application.put_env(:libremarket, :compras_api, comprar: fn _, _, _ -> exit(:noproc) end)
      assert llamar(:post, "/compras", @valido).status == 503
    end
  end

  describe "GET /compras/:id" do
    test "devuelve el estado" do
      conn = llamar(:get, "/compras/42")
      assert conn.status == 200

      assert json(conn) == %{
               "id_compra" => 42,
               "estado" => "finalizada",
               "paso" => "enviando_producto",
               "resultado" => "producto_enviado"
             }
    end

    test "inexistente o id invalido -> 404" do
      assert llamar(:get, "/compras/7").status == 404
      assert llamar(:get, "/compras/abc").status == 404
    end

    test "falla de persistencia -> 503" do
      assert llamar(:get, "/compras/500").status == 503
    end
  end

  test "ruta desconocida -> 404" do
    assert llamar(:get, "/nada", nil, nil).status == 404
  end
end
