<?php
// Utilidades compartidas por las páginas de LibreMarket. La web NUNCA escribe en
// PostgreSQL: lee de la base local y dispara compras por la API HTTP de Compras.

error_reporting(E_ALL);
ini_set('display_errors', '0');

const CONFIG_POR_DEFECTO = [
    'db_host'   => '127.0.0.1',
    'db_port'   => 5432,
    'db_name'   => 'libremarket',
    'db_user'   => 'webuser',
    'db_pass'   => '',
    'api_url'   => 'http://192.168.56.10:4000',
    'api_token' => '',
];

function cfg(string $clave)
{
    static $cfg = null;
    if ($cfg === null) {
        $archivo = __DIR__ . '/config.php';
        $propia = is_file($archivo) ? require $archivo : [];
        $cfg = array_merge(CONFIG_POR_DEFECTO, is_array($propia) ? $propia : []);
    }
    return $cfg[$clave];
}

// Nunca devolver HTTP 500 al navegador: cualquier excepción se muestra como alerta.
set_exception_handler(function (Throwable $e) {
    error_log('libremarket web: ' . $e->getMessage());
    if (!headers_sent()) {
        http_response_code(200);
    }
    layout_inicio('Error');
    alerta('error', 'Ocurrió un error inesperado. Intente nuevamente en unos segundos.');
    layout_fin(null);
});

// Protección CSRF con "double submit cookie": el formulario lleva el mismo valor
// aleatorio que una cookie SameSite=Strict, y comprar.php exige que coincidan.
// No usa la sesión de PHP porque HAProxy reparte cada petición entre N2 y N3, y
// la sesión de un nodo no existe en el otro; la cookie viaja con el navegador.
const CSRF_COOKIE = 'lm_csrf';

// Debe llamarse antes de imprimir cualquier salida (envía una cookie).
function csrf_token(): string
{
    $token = $_COOKIE[CSRF_COOKIE] ?? '';
    if (!is_string($token) || !preg_match('/^[0-9a-f]{64}$/', $token)) {
        $token = bin2hex(random_bytes(32));
        setcookie(CSRF_COOKIE, $token, ['path' => '/', 'httponly' => true, 'samesite' => 'Strict']);
        $_COOKIE[CSRF_COOKIE] = $token;
    }
    return $token;
}

function csrf_valido(): bool
{
    $cookie = $_COOKIE[CSRF_COOKIE] ?? '';
    $form   = $_POST['csrf'] ?? '';
    return is_string($cookie) && is_string($form) && $cookie !== '' && hash_equals($cookie, $form);
}

function h($valor): string
{
    return htmlspecialchars((string) $valor, ENT_QUOTES, 'UTF-8');
}

function db_conectar()
{
    $clave = addcslashes((string) cfg('db_pass'), "'\\");
    $dsn = sprintf(
        "host=%s port=%d dbname=%s user=%s password='%s' connect_timeout=3",
        cfg('db_host'), (int) cfg('db_port'), cfg('db_name'), cfg('db_user'), $clave
    );
    $db = @pg_connect($dsn);
    return $db ?: null;
}

// Sentencia preparada; devuelve un array de filas o null si falla.
function db_filas($db, string $sql, array $params = []): ?array
{
    if (!$db) {
        return null;
    }
    $res = @pg_query_params($db, $sql, $params);
    if (!$res) {
        return null;
    }
    $filas = pg_fetch_all($res);
    return $filas === false ? [] : $filas;
}

function db_rol($db): string
{
    $filas = db_filas($db, 'SELECT pg_is_in_recovery() AS r');
    if (!$filas) {
        return 'DESCONOCIDO';
    }
    return $filas[0]['r'] === 't' ? 'RÉPLICA (Standby, solo lectura)' : 'PRIMARIO (lectura y escritura)';
}

// Llamada a la API de Compras. Devuelve [status, datos|null]; status 0 si no hubo respuesta.
function api_llamar(string $metodo, string $ruta, array $campos = []): array
{
    $ch = curl_init(rtrim((string) cfg('api_url'), '/') . $ruta);
    $opciones = [
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_CONNECTTIMEOUT => 2,
        CURLOPT_TIMEOUT        => 4,
        CURLOPT_HTTPHEADER     => ['X-Api-Token: ' . cfg('api_token'), 'Accept: application/json'],
    ];
    if ($metodo === 'POST') {
        $opciones[CURLOPT_POST] = true;
        $opciones[CURLOPT_POSTFIELDS] = http_build_query($campos);
    }
    curl_setopt_array($ch, $opciones);
    $cuerpo = curl_exec($ch);
    $status = (int) curl_getinfo($ch, CURLINFO_HTTP_CODE);
    curl_close($ch);

    if ($cuerpo === false) {
        return [0, null];
    }
    $datos = json_decode((string) $cuerpo, true);
    return [$status, is_array($datos) ? $datos : null];
}

// Mismos mensajes que Libremarket.Ui.informar_resultado/1.
function resultado_texto(?string $resultado, $id): string
{
    switch ($resultado) {
        case 'producto_enviado':      return "Compra " . (int) $id . " confirmada";
        case 'sin_stock':             return 'No hay stock disponible';
        case 'infraccion':            return 'La compra fue rechazada por una infracción';
        case 'pago_rechazado':        return 'El pago fue rechazado';
        case 'timeout':               return 'La compra no pudo completarse: un servicio no respondió a tiempo';
        case 'persistencia':          return 'La compra no pudo completarse: error de persistencia';
        case 'respuesta_inesperada':  return 'La compra falló: respuesta inesperada de un servicio';
        default:                      return 'Resultado de compra: ' . ($resultado ?? 'desconocido');
    }
}

function layout_inicio(string $titulo, int $refrescar = 0): void
{
    ?><!DOCTYPE html>
<html lang="es">
<head>
    <meta charset="UTF-8">
    <title><?php echo h($titulo); ?> - LibreMarket</title>
<?php if ($refrescar > 0) { ?>    <meta http-equiv="refresh" content="<?php echo (int) $refrescar; ?>">
<?php } ?>
    <style>
        body { font-family: system-ui, sans-serif; background: #f4f4f9; padding: 20px; }
        .container { max-width: 900px; margin: 0 auto; background: white; padding: 30px; border-radius: 8px; box-shadow: 0 4px 6px rgba(0,0,0,0.1); }
        .centro { text-align: center; }
        .btn { background: #007bff; color: white; border: none; padding: 10px 20px; font-size: 16px; border-radius: 4px; cursor: pointer; text-decoration: none; display: inline-block; }
        .btn:hover { background: #0056b3; }
        .stats { margin-top: 20px; padding: 15px; background: #e9ecef; border-radius: 4px; }
        table { border-collapse: collapse; width: 100%; margin-top: 10px; }
        th, td { border-bottom: 1px solid #ddd; padding: 6px 10px; text-align: left; font-size: 14px; }
        th { background: #f0f0f5; }
        .grid { display: grid; grid-template-columns: 1fr 1fr; gap: 20px; }
        .alerta { padding: 12px 16px; border-radius: 4px; margin: 15px 0; font-weight: bold; }
        .alerta.error { background: #fde8e8; color: #b00020; }
        .alerta.ok { background: #e6f4ea; color: #1e7e34; }
        .alerta.info { background: #e8f0fe; color: #1a4fa3; }
        .pie { margin-top: 25px; font-size: 13px; color: #555; text-align: center; border-top: 1px solid #ddd; padding-top: 10px; }
        label { display: inline-block; margin: 6px 10px 6px 0; }
    </style>
</head>
<body>
<div class="container">
<?php
}

function alerta(string $tipo, string $mensaje): void
{
    echo '<div class="alerta ' . h($tipo) . '">' . h($mensaje) . '</div>' . "\n";
}

// Pie con hostname y rol del motor (pg_is_in_recovery) del nodo que atendió.
function layout_fin($db): void
{
    $rol = $db ? db_rol($db) : 'DESCONECTADO';
    ?>
    <div class="pie">
        Atendido por: <strong><?php echo h(gethostname()); ?></strong> |
        Motor local: <strong><?php echo h($rol); ?></strong>
    </div>
</div>
</body>
</html>
<?php
}
