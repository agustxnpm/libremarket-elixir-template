import Config

# Configuración para la conexión AMQP, se carga desde variable de entorno CLOUDAMQP_URL
# Adaptador de persistencia: :postgres si hay DATABASE_URL, :memory si no.
# En test siempre :memory (los tests de integracion lo pisan con Application.put_env/3).
storage_adapter =
  if config_env() != :test and System.get_env("DATABASE_URL") not in [nil, ""],
    do: :postgres,
    else: :memory

config :libremarket, storage_adapter: storage_adapter

amqp_url = System.get_env("CLOUDAMQP_URL") || "amqp://guest:guest@localhost:5672/"

# Con amqps:// se verifica el certificado del broker contra las CA del sistema
# y que corresponda al host (sin esto, cualquiera en el camino podria hacerse
# pasar por el broker y leer las credenciales y los mensajes). Con amqp:// no
# hay TLS. AMQP_SSL_VERIFY=false desactiva la verificacion (solo para pruebas).
amqp_ssl_options =
  case URI.parse(amqp_url) do
    %URI{scheme: "amqps", host: host} when is_binary(host) ->
      if System.get_env("AMQP_SSL_VERIFY") == "false" do
        [verify: :verify_none]
      else
        [
          verify: :verify_peer,
          cacerts: :public_key.cacerts_get(),
          server_name_indication: String.to_charlist(host),
          depth: 4,
          customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
        ]
      end

    _ ->
      :none
  end

config :amqp,
  connections: [
    connection: [url: amqp_url, ssl_options: amqp_ssl_options]
  ],
  channels: [
    channel: [connection: :connection]
  ]
