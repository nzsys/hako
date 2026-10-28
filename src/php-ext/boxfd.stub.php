<?php

/**
 * boxfd 拡張の関数シグネチャ（説明用）。
 * 実装は boxfd.c。arginfo は .c 側に手書きしてあり、このファイルは
 * gen_stub.php に通すためではなく、関数の契約を1か所で読むためのもの。
 *
 * 受け取り口 = スロットの php-cgi が fd 3 として継承した socketpair。
 * 環境変数 BOX_RECV_FD があれば、その番号を使う。
 */

/**
 * 受け取り口を stream にし、socket_import_stream で sockets 拡張の
 * Socket オブジェクトに包んで返す（本命の経路）。
 * sockets 拡張が無い、または Socket 化に失敗したら false。
 */
function boxfd_recv_socket(): Socket|false {}

/**
 * フォールバック（すべて C で完結する経路の前半）。
 * 受け取り口から1レコード recvmsg し、SCM_RIGHTS で届いた最初の fd を
 * 生の番号で返す。余分な fd は全部閉じる。fd が届かなければ false。
 */
function boxfd_relay_fd(): int|false {}

/**
 * フォールバック（後半）。$fd（中継の接続）へ $json を fd なし・
 * MSG_EOR 付きの sendmsg で1レコード送り、応答を MSG_EOR の立つ
 * レコードが来るまで recvmsg して本文を文字列で返す。
 * 応答に紛れて届いた fd は即座に閉じる。失敗したら false。
 */
function boxfd_send_op(int $fd, string $json): string|false {}
