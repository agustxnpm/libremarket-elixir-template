# Los tests de integracion necesitan el broker AMQP (CLOUDAMQP_URL) y solo
# corren con `mix test --include integration`.
ExUnit.start(exclude: [:integration])
