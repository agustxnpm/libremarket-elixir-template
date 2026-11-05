<?php
// Healthcheck para HAProxy: SELECT 1 contra la base local; 503 si falla.
require __DIR__ . '/lib.php';

header('Content-Type: text/plain; charset=UTF-8');

$db = db_conectar();
$filas = $db ? db_filas($db, 'SELECT 1 AS ok') : null;

if ($filas === null || ($filas[0]['ok'] ?? null) !== '1') {
    http_response_code(503);
    echo "DB DOWN\n";
    exit;
}

echo "OK\n";
