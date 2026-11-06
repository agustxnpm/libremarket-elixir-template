<?php
require __DIR__ . '/lib.php';

$db = db_conectar();
$csrf = csrf_token();

layout_inicio('Panel');
?>
<div class="centro">
    <h2>LibreMarket - Atendido por: <strong><?php echo h(gethostname()); ?></strong></h2>
    <p>Estado del motor local: <strong><?php echo h($db ? db_rol($db) : 'DESCONECTADO'); ?></strong></p>
</div>
<?php
if (!$db) {
    alerta('error', 'Error crítico: la capa de aplicación no puede alcanzar a la base de datos local.');
    layout_fin(null);
    exit;
}

$stock   = db_filas($db, 'SELECT id_producto, stock FROM productos ORDER BY id_producto');
$compras = db_filas($db, 'SELECT id_compra, id_producto, medio_pago, entrega, estado, paso, resultado, creada_at
                          FROM compras ORDER BY id_compra DESC LIMIT 15');
$totales = db_filas($db, 'SELECT COALESCE(resultado, estado) AS resultado, COUNT(*) AS total
                          FROM compras GROUP BY 1 ORDER BY 2 DESC');
$total   = db_filas($db, 'SELECT COUNT(*) AS total FROM compras');

if ($stock === null || $compras === null || $totales === null || $total === null) {
    alerta('error', 'No se pudieron leer los datos de la base local.');
}
?>
<h3>Comprar</h3>
<form method="POST" action="comprar.php">
    <input type="hidden" name="csrf" value="<?php echo h($csrf); ?>">
    <label>Producto
        <select name="producto">
            <?php for ($i = 1; $i <= 10; $i++) { echo '<option value="' . $i . '">Producto ' . $i . '</option>'; } ?>
        </select>
    </label>
    <label>Medio de pago
        <select name="medio_pago">
            <option value="tc">Tarjeta de crédito</option>
            <option value="td">Tarjeta de débito</option>
            <option value="transferencia">Transferencia</option>
            <option value="efectivo">Efectivo</option>
        </select>
    </label>
    <label>Entrega
        <select name="entrega">
            <option value="correo">Correo</option>
            <option value="retira">Retira en sucursal</option>
        </select>
    </label>
    <button type="submit" class="btn">Comprar</button>
</form>

<div class="stats">
    <h3>Total de compras registradas: <strong><?php echo h($total[0]['total'] ?? '?'); ?></strong></h3>
    <small>Datos leídos de la base local de este nodo (en la réplica pueden estar levemente atrasados).</small>
</div>

<div class="grid">
    <div>
        <h3>Stock actual</h3>
        <table>
            <tr><th>Producto</th><th>Stock</th></tr>
            <?php foreach ($stock ?? [] as $f) { ?>
                <tr><td><?php echo h($f['id_producto']); ?></td><td><?php echo h($f['stock']); ?></td></tr>
            <?php } ?>
        </table>
    </div>
    <div>
        <h3>Compras por resultado</h3>
        <table>
            <tr><th>Resultado</th><th>Cantidad</th></tr>
            <?php foreach ($totales ?? [] as $f) { ?>
                <tr><td><?php echo h($f['resultado']); ?></td><td><?php echo h($f['total']); ?></td></tr>
            <?php } ?>
        </table>
    </div>
</div>

<h3>Últimas compras</h3>
<table>
    <tr><th>#</th><th>Producto</th><th>Pago</th><th>Entrega</th><th>Estado</th><th>Resultado</th><th>Creada</th></tr>
    <?php foreach ($compras ?? [] as $f) { ?>
        <tr>
            <td><a href="compra.php?id=<?php echo (int) $f['id_compra']; ?>"><?php echo h($f['id_compra']); ?></a></td>
            <td><?php echo h($f['id_producto']); ?></td>
            <td><?php echo h($f['medio_pago']); ?></td>
            <td><?php echo h($f['entrega']); ?></td>
            <td><?php echo h($f['estado']); ?></td>
            <td><?php echo h($f['resultado'] ?? '-'); ?></td>
            <td><?php echo h($f['creada_at']); ?></td>
        </tr>
    <?php } ?>
</table>
<?php
layout_fin($db);
