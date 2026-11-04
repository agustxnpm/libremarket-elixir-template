# Arquitectura Lab 4 (opción B)

La web (Apache + PHP en N2 y N3) lee de su base local y, para iniciar una compra, hace un `POST` a la API HTTP de Compras en el Nodo 1. Los servicios Elixir son los únicos que escriben en el primario. Detalle en [PLAN_LAB4.md](./PLAN_LAB4.md).

```mermaid
flowchart LR
    UShell["Usuario (Shell)<br/>iex / Simulador"]
    UWeb["Usuario (Web)<br/>Navegador"]
    AMQP[["AMQP Cloud<br/>(RabbitMQ)"]]

    subgraph N1["Nodo 1 - 192.168.56.10"]
        direction TB
        HAP["HAProxy :80<br/>Round Robin + health check"]
        subgraph SVC["Servicios Elixir (Docker)"]
            direction LR
            Compras["Compras<br/>+ API HTTP :4000"]
            Ventas["Ventas"]
            Infracciones["Infracciones"]
            Pagos["Pagos"]
            Envios["Envíos"]
        end
    end

    subgraph N2["Nodo 2 - 192.168.56.11"]
        direction TB
        WEB2["Apache + PHP<br/>panel + formulario de compra"]
        DB1[("PostgreSQL PRIMARIO<br/>libremarket :5432")]
        WEB2 -- "lee (solo lectura)" --> DB1
    end

    subgraph N3["Nodo 3 - 192.168.56.12"]
        direction TB
        WEB3["Apache + PHP<br/>panel + formulario de compra"]
        DB2[("PostgreSQL RÉPLICA<br/>hot standby")]
        WEB3 -- "lee (solo lectura)" --> DB2
    end

    UShell -- "inicia simulaciones" --> Compras
    UWeb -- "HTTP :80" --> HAP
    HAP -- "HTTP :80" --> WEB2
    HAP -- "HTTP :80" --> WEB3

    WEB2 -- "POST /compras<br/>GET /compras/:id<br/>(X-Api-Token)" --> Compras
    WEB3 -- "POST /compras<br/>GET /compras/:id<br/>(X-Api-Token)" --> Compras

    Compras <-. "RPC AMQP" .-> AMQP
    Ventas <-. "RPC AMQP" .-> AMQP
    Infracciones <-. "RPC AMQP" .-> AMQP
    Pagos <-. "RPC AMQP" .-> AMQP
    Envios <-. "RPC AMQP" .-> AMQP

    Compras == "lectura/escritura :5432" ==> DB1
    Ventas == "lectura/escritura :5432" ==> DB1
    Infracciones == "lectura/escritura :5432" ==> DB1
    Pagos == "lectura/escritura :5432" ==> DB1
    Envios == "lectura/escritura :5432" ==> DB1

    DB1 -. "Streaming replication (WAL)" .-> DB2
```

Referencias: las líneas gruesas son las escrituras de los servicios Elixir hacia el primario; las punteadas son AMQP y la replicación; las flechas de la web hacia Compras son los comandos HTTP.
