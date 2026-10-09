#!/bin/bash

start() {
    # Levantar los contenedores en segundo plano
    export DOCKER_UID=$UID
    export DOCKER_GID=$GID
    docker compose up -d "$@"
}

stop() {
    export DOCKER_UID=$UID
    export DOCKER_GID=$GID
    docker compose down
}

# Comprobar el argumento proporcionado
if [[ $1 == "start" ]]; then
    shift
    start "$@"
elif [[ $1 == "stop" ]]; then
    stop
elif [[ $1 == "iex" ]]; then
    docker attach $2
elif [[ $1 == "logs" ]]; then
    shift
    # Sin argumentos: logs de todos los contenedores, siguiendo la salida (-f).
    # Con argumentos: se pasan a docker compose logs (ej: logs compras, logs --tail 50 pagos).
    if [[ $# -eq 0 ]]; then
        docker compose logs -f --tail 100
    else
        docker compose logs -f "$@"
    fi
elif [[ $1 == "ps" ]]; then
    docker compose ps -a
else
    echo "Uso: $0 {start|stop|logs [servicio...]|ps|iex nombre_de_contenedor}"
    exit 1
fi
