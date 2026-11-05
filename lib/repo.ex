defmodule Libremarket.Repo do
  @moduledoc """
  Wrapper fino sobre `Postgrex` (pool registrado como `Libremarket.Repo`).
  Se conecta a `DATABASE_URL` (siempre el primario) y nunca levanta
  excepciones: toda falla se devuelve como `{:error, :persistencia}`.
  """

  require Logger

  @pool_size 5

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
    case Postgrex.query(__MODULE__, sql, params) do
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

      {:ok,
       [hostname: host, port: uri.port || 5432, database: base, username: usuario, password: clave]}
    else
      _ -> {:error, :database_url_invalida}
    end
  end

  defp credenciales(nil), do: {nil, nil}

  defp credenciales(userinfo) do
    case String.split(userinfo, ":", parts: 2) do
      [usuario, clave] -> {URI.decode_www_form(usuario), URI.decode_www_form(clave)}
      [usuario] -> {URI.decode_www_form(usuario), nil}
    end
  end
end
