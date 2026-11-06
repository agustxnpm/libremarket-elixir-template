defmodule Libremarket.Amqp.Codec do
  @moduledoc """
  Serializacion de los mensajes RPC que viajan por AMQP.

  Los mensajes llegan desde el broker, asi que no se confia en su contenido:
  `decode/1` usa `:erlang.binary_to_term/2` con la opcion `:safe`, que rechaza
  todo binario que cree atomos nuevos (la tabla de atomos es finita y nunca se
  libera) o referencias a funciones. Un mensaje mal formado devuelve
  `{:error, :mensaje_invalido}` en vez de tirar el proceso que lo consume.

  Con `:safe` los atomos del mensaje ya tienen que existir en la VM. Como los
  modulos se cargan bajo demanda, un contenedor podria no tener cargado el
  modulo que define alguno de ellos (por ejemplo, el de ventas nunca carga
  Compras). Por eso este modulo los declara en `atomos_conocidos/0`: al cargarse
  `Codec` (antes del primer `decode/1`) todos quedan creados.
  """

  @doc "Serializa un termino para publicarlo."
  @spec encode(term()) :: binary()
  def encode(termino), do: :erlang.term_to_binary(termino)

  @doc "Deserializa un mensaje recibido sin crear atomos nuevos."
  @spec decode(binary()) :: {:ok, term()} | {:error, :mensaje_invalido}
  def decode(payload) when is_binary(payload) do
    {:ok, :erlang.binary_to_term(payload, [:safe])}
  rescue
    ArgumentError -> {:error, :mensaje_invalido}
  end

  def decode(_payload), do: {:error, :mensaje_invalido}

  @doc """
  Atomos que pueden aparecer en un mensaje: claves, servicios (relojes
  vectoriales), operaciones y respuestas. Si se agrega una operacion o una
  respuesta nueva, hay que sumarla aca.
  """
  def atomos_conocidos do
    [
      # claves de los mensajes
      :op,
      :args,
      :clock,
      :result,
      # servicios
      :compras,
      :ventas,
      :pagos,
      :envios,
      :infracciones,
      # operaciones
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
      :listar_pagos,
      # respuestas
      :ok,
      :error,
      :sin_stock,
      :enviado,
      :agendado,
      :persistencia,
      :operacion_invalida
    ]
  end
end
