import Config

# Configuración para la conexión AMQP, se carga desde variable de entorno CLOUDAMQP_URL
# Adaptador de persistencia: :postgres si hay DATABASE_URL, :memory si no.
# En test siempre :memory (los tests de integracion lo pisan con Application.put_env/3).
storage_adapter =
  if config_env() != :test and System.get_env("DATABASE_URL") not in [nil, ""],
    do: :postgres,
    else: :memory

config :libremarket, storage_adapter: storage_adapter

config :amqp,
  connections: [
    # sin certtificados SSL
    connection: [url: System.get_env("CLOUDAMQP_URL") || "amqp://guest:guest@localhost:5672/", ssl_options: [verify: :verify_none]]
  ],
  channels: [
    channel: [connection: :connection]
  ]
