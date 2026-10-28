<?php
declare(strict_types=1);

/*
 * 題材アプリ「個人メモ」のフロントコントローラ（php-cgi / FastCGI 用）。
 *
 * 1リクエスト = 1プロセス（PHP_FCGI_MAX_REQUESTS=1）が前提なので、
 * 中継の接続はリクエストのたびに受け取り口から受け取り直し、使い回さない。
 * データには BoxRelay 経由でしか触れない（DB の資格情報は持たない）。
 *
 * 出力はすべて htmlspecialchars を通す。
 */

require_once __DIR__ . '/../lib/box.php';

function e($s): string
{
    return htmlspecialchars((string) ($s ?? ''), ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
}

function isUuid(string $s): bool
{
    return (bool) preg_match(
        '/^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/',
        $s
    );
}

function render(int $status, string $title, string $bodyHtml): void
{
    http_response_code($status);
    header('Content-Type: text/html; charset=UTF-8');
    echo '<!DOCTYPE html>', "\n",
        '<html lang="ja"><head><meta charset="UTF-8"><title>', e($title), '</title></head><body>', "\n",
        $bodyHtml, "\n</body></html>\n";
}

function fail(int $status, string $message): void
{
    render($status, 'エラー',
        '<h1>エラー</h1><p>' . e($message) . '</p><p><a href="/memos">一覧へ</a></p>');
}

/** 303 は POST の応答にだけ使う。 */
function redirect303(string $path): void
{
    http_response_code(303);
    header('Location: ' . $path);
}

/** 作成・編集フォーム。$version があれば楽観ロック用に hidden で持つ。 */
function memoForm(string $action, string $title, string $body, $version): string
{
    $html = '<form method="post" action="' . e($action) . '">'
        . '<p><label>タイトル<br><input type="text" name="title" maxlength="200" value="'
        . e($title) . '"></label></p>'
        . '<p><label>本文<br><textarea name="body" rows="10" cols="60">'
        . e($body) . '</textarea></label></p>';
    if ($version !== null && is_scalar($version)) {
        $html .= '<input type="hidden" name="version" value="' . e($version) . '">';
    }
    return $html . '<p><button type="submit">保存</button></p></form>'
        . '<p><a href="/memos">一覧へ</a></p>';
}

function postString(string $key): string
{
    $v = $_POST[$key] ?? '';
    return is_string($v) ? $v : '';
}

$method = $_SERVER['REQUEST_METHOD'] ?? 'GET';
$path = parse_url($_SERVER['REQUEST_URI'] ?? '/', PHP_URL_PATH);
if (!is_string($path)) {
    $path = '/';
}

try {
    if ($method === 'GET' && $path === '/memos') {
        // 一覧（scope: memo.index → memo.list）
        $result = BoxRelay::fromReceivingPort()->op('memo.list', []);
        $items = $result['items'] ?? [];
        $html = '<h1>メモ一覧</h1><p><a href="/memos/new">新規作成</a></p>';
        if (is_array($items) && $items !== []) {
            $html .= '<ul>';
            foreach ($items as $item) {
                if (!is_array($item)) {
                    continue;
                }
                $html .= '<li><a href="/memos/' . e($item['id'] ?? '') . '">'
                    . e($item['title'] ?? '') . '</a> <small>'
                    . e($item['updated_at'] ?? '') . '</small></li>';
            }
            $html .= '</ul>';
        } else {
            $html .= '<p>メモはまだありません。</p>';
        }
        render(200, 'メモ一覧', $html);
    } elseif ($method === 'GET' && $path === '/memos/new') {
        // 作成フォーム（このルートに対応する範囲は memo.create、操作なし）
        render(200, 'メモを作成', '<h1>メモを作成</h1>' . memoForm('/memos', '', '', null));
    } elseif ($method === 'POST' && $path === '/memos') {
        // 作成（scope: memo.create → memo.create）
        $memo = BoxRelay::fromReceivingPort()->op('memo.create', [
            'title' => postString('title'),
            'body' => postString('body'),
        ]);
        $newId = isset($memo['id']) && is_string($memo['id']) ? $memo['id'] : '';
        redirect303($newId !== '' ? '/memos/' . $newId : '/memos');
    } elseif (preg_match('#^/memos/([^/]+)/edit$#', $path, $m) === 1 && $method === 'GET' && isUuid($m[1])) {
        // 編集フォーム（scope: memo.edit → memo.get）
        $memo = BoxRelay::fromReceivingPort()->op('memo.get', ['id' => $m[1]]);
        render(200, 'メモを編集', '<h1>メモを編集</h1>' . memoForm(
            '/memos/' . $m[1],
            (string) ($memo['title'] ?? ''),
            (string) ($memo['body'] ?? ''),
            $memo['version'] ?? null
        ));
    } elseif (preg_match('#^/memos/([^/]+)/delete$#', $path, $m) === 1 && $method === 'POST' && isUuid($m[1])) {
        // 削除（scope: memo.delete → memo.delete）
        BoxRelay::fromReceivingPort()->op('memo.delete', ['id' => $m[1]]);
        redirect303('/memos');
    } elseif (preg_match('#^/memos/([^/]+)$#', $path, $m) === 1 && isUuid($m[1]) && $method === 'GET') {
        // 詳細（scope: memo.show → memo.get）
        $memo = BoxRelay::fromReceivingPort()->op('memo.get', ['id' => $m[1]]);
        $html = '<h1>' . e($memo['title'] ?? '') . '</h1>'
            . '<p><small>更新: ' . e($memo['updated_at'] ?? '') . '</small></p>'
            . '<div>' . nl2br(e($memo['body'] ?? '')) . '</div>'
            . '<p><a href="/memos/' . e($m[1]) . '/edit">編集</a> '
            . '<a href="/memos">一覧へ</a></p>'
            . '<form method="post" action="/memos/' . e($m[1]) . '/delete">'
            . '<button type="submit">削除</button></form>';
        render(200, (string) ($memo['title'] ?? 'メモ'), $html);
    } elseif (preg_match('#^/memos/([^/]+)$#', $path, $m) === 1 && isUuid($m[1]) && $method === 'POST') {
        // 更新（scope: memo.update → memo.update）
        $args = [
            'id' => $m[1],
            'title' => postString('title'),
            'body' => postString('body'),
        ];
        $version = postString('version');
        if ($version !== '' && ctype_digit($version)) {
            $args['version'] = (int) $version;
        }
        BoxRelay::fromReceivingPort()->op('memo.update', $args);
        redirect303('/memos/' . $m[1]);
    } else {
        fail(404, 'ページが見つかりません');
    }
} catch (BoxError $ex) {
    // 中継の固定コードだけを HTTP の状態に写す（DB の文言は出さない）。
    $status = match ($ex->boxCode()) {
        'forbidden' => 403,
        'not_found' => 404,
        'bad_request' => 400,
        'conflict' => 409,
        default => 500,
    };
    fail($status, '操作できませんでした（' . $ex->boxCode() . '）');
} catch (Throwable $ex) {
    fail(500, '内部エラーが発生しました');
}
