-- LibreMarket Lab 4 - esquema inicial (ejecutar en el PRIMARIO, base `libremarket`, como superusuario)
-- Idempotente: puede ejecutarse más de una vez.
-- Requiere que los roles `libremarket_app` y `webuser` ya existan.

BEGIN;

CREATE TABLE IF NOT EXISTS productos (
  id_producto INT PRIMARY KEY,
  stock       INT NOT NULL CHECK (stock >= 0)
);

CREATE TABLE IF NOT EXISTS compras (
  id_compra     BIGSERIAL PRIMARY KEY,
  id_producto   INT NOT NULL,
  medio_pago    VARCHAR(20) NOT NULL,
  entrega       VARCHAR(20) NOT NULL,
  paso          VARCHAR(30) NOT NULL,
  estado        VARCHAR(20) NOT NULL,
  resultado     VARCHAR(50),
  creada_at     TIMESTAMPTZ DEFAULT NOW(),
  finalizada_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS compras_estado_idx ON compras (estado);

CREATE TABLE IF NOT EXISTS pagos (
  id_compra  BIGINT PRIMARY KEY,
  autorizado BOOLEAN NOT NULL,
  ts         TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS envios (
  id_compra BIGINT PRIMARY KEY,
  costo     INT NOT NULL,
  agendado  BOOLEAN NOT NULL,
  ts        TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS infracciones (
  id_compra BIGINT PRIMARY KEY,
  detectada BOOLEAN NOT NULL,
  ts        TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS eventos (
  id        BIGSERIAL PRIMARY KEY,
  id_compra BIGINT,
  servicio  VARCHAR(20),
  evento    VARCHAR(50),
  reloj     JSONB,
  ts        TIMESTAMPTZ DEFAULT NOW()
);

-- Semilla idempotente: productos 1..10 con stock inicial 10
INSERT INTO productos (id_producto, stock)
SELECT g, 10 FROM generate_series(1, 10) AS g
ON CONFLICT DO NOTHING;

-- Permisos
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM libremarket_app, webuser;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM libremarket_app, webuser;

GRANT USAGE ON SCHEMA public TO libremarket_app, webuser;

GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA public TO libremarket_app;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO libremarket_app;

GRANT SELECT ON ALL TABLES IN SCHEMA public TO webuser;

-- Tablas futuras creadas por el superusuario heredan los mismos permisos
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE ON TABLES TO libremarket_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO libremarket_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO webuser;

COMMIT;
