<?php
require __DIR__ . '/lib.php';

const MEDIOS_DE_PAGO = ['efectivo', 'transferencia', 'td', 'tc'];
const ENTREGAS = ['correo', 'retira'];

if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
    header('Location: index.php');
    exit;
}

$producto  = filter_input(INPUT_POST, 'producto', FILTER_VALIDATE_INT, ['options' => ['min_range' => 1, 'max_range' => 10]]);
$medioPago = $_POST['medio_pago'] ?? '';
$entrega   = $_POST['entrega'] ?? '';

function fallo(string $mensaje, int $status = 200): void
{
    http_response_code($status);
    layout_inicio('Compra');
    alerta('error', $mensaje);
    echo '<p class="centro"><a class="btn" href="index.php">Volver</a></p>';
    layout_fin(db_conectar());
    exit;
}

if ($producto === false || $producto === null || !in_array($medioPago, MEDIOS_DE_PAGO, true) || !in_array($entrega, ENTREGAS, true)) {
    fallo('Datos de compra inválidos. Revise el producto, el medio de pago y la entrega.', 400);
}

[$status, $datos] = api_llamar('POST', '/compras', [
    'producto'   => $producto,
    'medio_pago' => $medioPago,
    'entrega'    => $entrega,
]);

if ($status === 202 && isset($datos['id_compra']) && is_int($datos['id_compra'])) {
    header('Location: compra.php?id=' . $datos['id_compra']);
    exit;
}

if ($status === 401) {
    fallo('El servicio de compras rechazó la solicitud (credenciales de la web mal configuradas).');
} elseif ($status === 400) {
    fallo('El servicio de compras rechazó los datos de la compra.');
} elseif ($status === 0 || $status >= 500) {
    fallo('El servicio de compras no está disponible en este momento. Intente nuevamente en unos instantes.');
}
fallo('No se pudo iniciar la compra. Intente nuevamente.');
