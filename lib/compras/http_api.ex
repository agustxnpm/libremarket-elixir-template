defmodule Libremarket.Compras.HttpApi do
  @moduledoc """
  API HTTP minima de Compras (Bandit + Plug), pensada para que la web PHP inicie
  y consulte compras.

    * `GET  /health`        publico; `200 {"status":"ok"}` o `503` si falla la base.
    * `POST /compras`       `producto` (1..10), `medio_pago`, `entrega` -> `202 {"id_compra": N}`.
    * `GET  /compras/:id`   `200 {"id_compra","estado","paso","resultado"}` o `404`.

  `POST` y `GET /compras/:id` exigen el header `x-api-token` igual a la variable
  de entorno `API_TOKEN` (comparacion en tiempo constante); si falta o no
  coincide -> `401 {"error":"unauthorized"}`. Sin `API_TOKEN` configurada todo
  pedido protegido se rechaza.

  Para tests, `config :libremarket, :compras_api, comprar: fun, consultar: fun, health: fun`
  reemplaza las dependencias.
  """

  use Plug.Router

  @medios_de_pago %{
    "efectivo" => :efectivo,
    "transferencia" => :transferencia,
    "td" => :td,
    "tc" => :tc
  }
  @entregas %{"correo" => :correo, "retira" => :retira}

  plug(:match)
  plug(Plug.Parsers, parsers: [:urlencoded, :json], json_decoder: Jason, pass: ["*/*"])
  plug(:dispatch)

  get "/health" do
    if dependencia(:health).() do
      responder(conn, 200, %{status: "ok"})
    else
      responder(conn, 503, %{status: "unavailable"})
    end
  end

  post "/compras" do
    con_token(conn, fn ->
      case validar(conn.params) do
        {:ok, producto, medio_pago, entrega} ->
          case iniciar_compra(producto, medio_pago, entrega) do
            {:ok, id_compra} -> responder(conn, 202, %{id_compra: id_compra})
            {:error, _} -> responder(conn, 503, %{error: "service_unavailable"})
          end

        :error ->
          responder(conn, 400, %{error: "invalid_input"})
      end
    end)
  end

  get "/compras/:id" do
    con_token(conn, fn ->
      case Integer.parse(id) do
        {id_compra, ""} -> consultar_compra(conn, id_compra)
        _ -> responder(conn, 404, %{error: "not_found"})
      end
    end)
  end

  match _ do
    responder(conn, 404, %{error: "not_found"})
  end

  defp consultar_compra(conn, id_compra) do
    case dependencia(:consultar).(id_compra) do
      {:ok, compra} -> responder(conn, 200, compra)
      :no_encontrada -> responder(conn, 404, %{error: "not_found"})
      {:error, _} -> responder(conn, 503, %{error: "service_unavailable"})
    end
  end

  defp iniciar_compra(producto, medio_pago, entrega) do
    dependencia(:comprar).(producto, medio_pago, entrega)
  catch
    :exit, _ -> {:error, :no_disponible}
  end

  defp con_token(conn, accion) do
    if token_valido?(conn), do: accion.(), else: responder(conn, 401, %{error: "unauthorized"})
  end

  defp token_valido?(conn) do
    esperado = System.get_env("API_TOKEN")

    case get_req_header(conn, "x-api-token") do
      [recibido | _] when is_binary(esperado) and esperado != "" ->
        Plug.Crypto.secure_compare(recibido, esperado)

      _ ->
        false
    end
  end

  defp validar(params) do
    with {:ok, producto} <- producto(params["producto"]),
         {:ok, medio_pago} <- Map.fetch(@medios_de_pago, params["medio_pago"]),
         {:ok, entrega} <- Map.fetch(@entregas, params["entrega"]) do
      {:ok, producto, medio_pago, entrega}
    else
      _ -> :error
    end
  end

  defp producto(valor) when is_integer(valor) and valor in 1..10, do: {:ok, valor}

  defp producto(valor) when is_binary(valor) do
    case Integer.parse(valor) do
      {n, ""} when n in 1..10 -> {:ok, n}
      _ -> :error
    end
  end

  defp producto(_), do: :error

  defp responder(conn, status, cuerpo) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(cuerpo))
  end

  defp dependencia(nombre) do
    config = Application.get_env(:libremarket, :compras_api, [])
    Keyword.get_lazy(config, nombre, fn -> por_defecto(nombre) end)
  end

  defp por_defecto(:comprar), do: &Libremarket.Compras.Server.comprar/3
  defp por_defecto(:consultar), do: &Libremarket.Compras.Server.consultar/1
  defp por_defecto(:health), do: &base_disponible?/0

  # Sin adaptador Postgres no hay base que verificar.
  defp base_disponible? do
    not Libremarket.Storage.postgres?() or
      match?({:ok, _}, Libremarket.Repo.query("SELECT 1"))
  end
end
