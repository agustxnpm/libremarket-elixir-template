<?php
require __DIR__ . '/lib.php';

$id = filter_input(INPUT_GET, 'id', FILTER_VALIDATE_INT, ['options' => ['min_range' => 1]]);

if ($id === false || $id === null) {
    layout_inicio('Compra');
    alerta('error', 'Identificador de compra inválido.');
    echo '<p class="centro"><a class="btn" href="index.php">Volver</a></p>';
    layout_fin(db_conectar());
    exit;
}

// Se consulta la API (lee del primario) y no la base local, que en la réplica puede ir atrasada.
[$status, $compra] = api_llamar('GET', '/compras/' . $id);

$estado = ($status === 200 && is_array($compra)) ? ($compra['estado'] ?? '') : null;
$refrescar = ($estado === 'en_curso') ? 3 : (($estado === null && $status !== 404 && $status !== 401) ? 5 : 0);

layout_inicio('Compra #' . $id, $refrescar);
echo '<h2 class="centro">Compra #' . h($id) . '</h2>';

if ($estado === 'en_curso') {
    alerta('info', 'En curso... paso actual: ' . ($compra['paso'] ?? '-') . ' (esta página se actualiza sola).');
} elseif ($estado === 'finalizada') {
    $resultado = $compra['resultado'] ?? null;
    alerta($resultado === 'producto_enviado' ? 'ok' : 'error', resultado_texto($resultado, $id));
} elseif ($estado === 'interrumpida') {
    alerta('error', 'La compra fue interrumpida por un reinicio del servicio y el stock reservado fue liberado.');
} elseif ($status === 404) {
    alerta('error', 'No se encontró la compra.');
} elseif ($status === 401) {
    alerta('error', 'El servicio de compras rechazó la consulta (credenciales de la web mal configuradas).');
} else {
    alerta('error', 'No se pudo consultar el estado de la compra (servicio no disponible). Se reintentará automáticamente.');
}
?>
<p class="centro"><a class="btn" href="index.php">Volver al panel</a></p>
<?php
layout_fin(db_conectar());
