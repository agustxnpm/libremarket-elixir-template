defmodule Libremarket.Repo do
  @moduledoc """
  Wrapper fino sobre `Postgrex` (pool registrado como `Libremarket.Repo`).
  Se conecta a `DATABASE_URL` (siempre el primario) y nunca levanta
  excepciones: toda falla se devuelve como `{:error, :persistencia}`.

  Cada consulta tiene un timeout de 3 s (configurable con
  `config :libremarket, :db_timeout`), menor que el de las llamadas entre
  procesos (5 s): si la base esta lenta, la falla vuelve como
  `{:error, :persistencia}` antes de que se venza el `GenServer.call` que espera.

  SSL: con `?sslmode=require` en la URL la conexion se cifra sin verificar el
  certificado (sirve con el certificado autofirmado que trae PostgreSQL en
  Debian); con `?sslmode=verify-full` ademas se verifica contra las CA del
  sistema y el nombre del host. Sin `sslmode` (o con `disable`) no se usa SSL.
  """

  require Logger

  @pool_size 5
  @db_timeout 3_000

  @doc "Solo se arranca con adaptador :postgres o si DATABASE_URL esta definida."
  def enabled? do
    Libremarket.Storage.postgres?() or database_url() != nil
  end

  def child_spec(_opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, []},
      type: :worker
    }
  end

  def start_link do
    case connection_opts() do
      {:ok, opts} ->
        Postgrex.start_link([name: __MODULE__, pool_size: @pool_size] ++ opts)

      {:error, motivo} ->
        {:error, motivo}
    end
  end

  @spec query(String.t(), list()) :: {:ok, Postgrex.Result.t()} | {:error, :persistencia}
  def query(sql, params \\ []) do
    case Postgrex.query(__MODULE__, sql, params, timeout: db_timeout()) do
      {:ok, %Postgrex.Result{} = result} ->
        {:ok, result}

      {:error, error} ->
        Logger.error("Repo.query fallo: #{Exception.message(error)}")
        {:error, :persistencia}
    end
  catch
    :exit, motivo ->
      Logger.error("Repo.query exit: #{inspect(motivo)}")
      {:error, :persistencia}
  end

  @doc """
  Idempotencia ante re-entrega AMQP: intenta el `INSERT ... ON CONFLICT DO NOTHING
  RETURNING ...`; si la fila ya existia (0 filas) lee la previa con `select_sql`.
  Devuelve `{:ok, fila}` o `{:error, :persistencia}`.
  """
  def insertar_o_leer(insert_sql, params, select_sql, select_params) do
    case query(insert_sql, params) do
      {:ok, %Postgrex.Result{num_rows: 1, rows: [fila]}} ->
        {:ok, fila}

      {:ok, %Postgrex.Result{num_rows: 0}} ->
        case query(select_sql, select_params) do
          {:ok, %Postgrex.Result{rows: [fila]}} -> {:ok, fila}
          _ -> {:error, :persistencia}
        end

      _ ->
        {:error, :persistencia}
    end
  end

  defp database_url do
    case System.get_env("DATABASE_URL") do
      url when url in [nil, ""] -> nil
      url -> url
    end
  end

  # DATABASE_URL: postgres://usuario:clave@host:puerto/base
  defp connection_opts do
    with url when is_binary(url) <- database_url(),
         %URI{scheme: scheme, host: host, path: "/" <> base} = uri
         when scheme in ["postgres", "postgresql"] and is_binary(host) and base != "" <-
           URI.parse(url) do
      {usuario, clave} = credenciales(uri.userinfo)

      opts = [
        hostname: host,
        port: uri.port || 5432,
        database: base,
        username: usuario,
        password: clave
      ]

      case ssl(uri.query) do
        {:ok, nil} -> {:ok, opts}
        {:ok, ssl} -> {:ok, opts ++ [ssl: ssl]}
        :error -> {:error, :database_url_invalida}
      end
    else
      _ -> {:error, :database_url_invalida}
    end
  end

  defp ssl(nil), do: {:ok, nil}

  defp ssl(query) do
    case URI.decode_query(query) |> Map.get("sslmode") do
      modo when modo in [nil, "disable"] -> {:ok, nil}
      "require" -> {:ok, [verify: :verify_none]}
      "verify-full" -> {:ok, true}
      _ -> :error
    end
  end

  defp db_timeout, do: Application.get_env(:libremarket, :db_timeout, @db_timeout)

  defp credenciales(nil), do: {nil, nil}

  defp credenciales(userinfo) do
    case String.split(userinfo, ":", parts: 2) do
      [usuario, clave] -> {URI.decode_www_form(usuario), URI.decode_www_form(clave)}
      [usuario] -> {URI.decode_www_form(usuario), nil}
    end
  end
end
