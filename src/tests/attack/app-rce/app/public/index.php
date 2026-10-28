<?php
declare(strict_types=1);

/*
 * 攻撃試験専用の「脆弱なアプリ」。本番の題材アプリではない。
 *
 * 題材アプリと同じ土台（BoxRelay、受け取り口から中継の接続を
 * 得る）で動きながら、パラメータ x をそのまま eval する
 * 意図的な脆弱性を持つ。「アプリが乗っ取られた状態」を再現し、
 * 被害上限（宣言した範囲・対象・回数、使い捨て、ネットワーク
 * 無し）が本当に効くかを、攻撃者の手で確かめるためのもの。
 *
 * 使い方は tests/attack/README.md と、この階層の poc.sh / verify.sh。
 */

require_once __DIR__ . '/../lib/box.php';

function e($s): string
{
    return htmlspecialchars((string) ($s ?? ''), ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
}

$method = $_SERVER['REQUEST_METHOD'] ?? 'GET';
$path = parse_url($_SERVER['REQUEST_URI'] ?? '/', PHP_URL_PATH);
if (!is_string($path)) {
    $path = '/';
}

header('Content-Type: text/plain; charset=UTF-8');

if ($method === 'GET' && preg_match('#^/memos/([0-9a-fA-F-]{36})$#', $path, $m)) {
    $id = $m[1];
    try {
        $relay = BoxRelay::fromReceivingPort();
    } catch (BoxError $err) {
        http_response_code(502);
        echo 'relay unavailable: ', e($err->boxCode()), "\n";
        exit;
    }

    // === 意図的な脆弱性（攻撃試験用） ============================
    // 中継の接続と予算を握った状態で、攻撃者のコードが
    // アプリのプロセス内で走る。最悪の前提の再現。
    if (isset($_GET['x']) && is_string($_GET['x'])) {
        eval($_GET['x']);
    }

    try {
        $memo = $relay->op('memo.get', ['id' => $id]);
        echo 'memo: ', e($memo['title'] ?? ''), "\n";
    } catch (BoxError $err) {
        echo 'app op failed: ', e($err->boxCode()), "\n";
    }
    exit;
}

http_response_code(404);
echo "not found\n";
