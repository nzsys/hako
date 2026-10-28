<?php
declare(strict_types=1);

/*
 * BoxRelay: スロット内のアプリからデータ中継へ操作を依頼する窓口。
 *
 * 継承した受け取り口（fd 3）から、中継の接続を SCM_RIGHTS で受け取り、
 * その接続へ {"v":1,"t":"op","op":...,"args":{...}} を1レコード送って
 * 応答を受け取る。境界は MSG_EOR。
 *
 * 経路は2つあり、本命を優先する。
 *   - Socket 経路: boxfd_recv_socket() で受け取り口を Socket にし、
 *     socket_recvmsg で中継の Socket を受け取り、socket_sendmsg /
 *     socket_recvmsg で話す。
 *   - fd 経路（保険）: boxfd_relay_fd() で中継の fd 番号を受け取り、
 *     boxfd_send_op() で送受信する（C 拡張の中で完結）。
 *
 * user_id は中継が接続に束縛している。アプリは指定できない。
 */

/** 中継からのエラー。固定のエラーコードをそのまま保持する。 */
final class BoxError extends Exception
{
    private string $boxCode;

    public function __construct(string $boxCode, string $message = '')
    {
        $this->boxCode = $boxCode;
        parent::__construct($message === '' ? $boxCode : $message);
    }

    /** bad_request / forbidden / not_found / conflict / rate_limited / unavailable など。 */
    public function boxCode(): string
    {
        return $this->boxCode;
    }
}

final class BoxRelay
{
    /** 1メッセージの上限（64 KiB）。 */
    private const MAX_MSG = 65536;

    private ?Socket $socket;
    private ?int $fd;

    private function __construct(?Socket $socket, ?int $fd)
    {
        $this->socket = $socket;
        $this->fd = $fd;
        if ($this->socket !== null && function_exists('socket_set_option')) {
            // 中継の接続期限（30秒）に合わせ、待ち続けを防ぐ。
            @socket_set_option($this->socket, SOL_SOCKET, SO_RCVTIMEO, ['sec' => 30, 'usec' => 0]);
            @socket_set_option($this->socket, SOL_SOCKET, SO_SNDTIMEO, ['sec' => 30, 'usec' => 0]);
        }
    }

    /**
     * 受け取り口から中継の接続を得る。Socket 経路を優先し、
     * だめなら fd 経路（boxfd_relay_fd）にフォールバックする。
     */
    public static function fromReceivingPort(): self
    {
        if (function_exists('boxfd_recv_socket') && function_exists('socket_recvmsg')) {
            $port = @boxfd_recv_socket();
            if ($port instanceof Socket) {
                try {
                    [, $fds] = self::recvRecord($port);
                    if (isset($fds[0])) {
                        // 最初の1つが中継の接続。余分な fd は即座に閉じる。
                        for ($i = 1, $n = count($fds); $i < $n; $i++) {
                            @socket_close($fds[$i]);
                        }
                        return new self($fds[0], null);
                    }
                } catch (BoxError $e) {
                    // Socket 経路で失敗したら、fd 経路に落として続ける。
                }
            }
        }
        if (function_exists('boxfd_relay_fd') && function_exists('boxfd_send_op')) {
            $fd = @boxfd_relay_fd();
            if (is_int($fd)) {
                return new self(null, $fd);
            }
        }
        throw new BoxError('unavailable', '中継の接続が得られませんでした');
    }

    /**
     * 操作を1つ依頼する。応答が {"ok":true,"result":...} なら result を返し、
     * {"ok":false,"error":<コード>} ならそのコードで BoxError を投げる。
     *
     * @param array<string,mixed> $args
     * @return array<mixed>
     */
    public function op(string $op, array $args): array
    {
        $json = json_encode(
            ['v' => 1, 't' => 'op', 'op' => $op, 'args' => (object) $args],
            JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES
        );
        if ($json === false || strlen($json) > self::MAX_MSG) {
            // UTF-8 として正しくない引数などがここに来る。
            throw new BoxError('bad_request', '操作の組み立てに失敗しました');
        }
        if ($this->socket !== null) {
            $raw = $this->roundTripSocket($json);
        } elseif ($this->fd !== null) {
            $raw = @boxfd_send_op($this->fd, $json);
            if ($raw === false) {
                throw new BoxError('unavailable', '中継への送信に失敗しました');
            }
        } else {
            throw new BoxError('unavailable', '中継の接続がありません');
        }
        return self::parseResult($raw);
    }

    /** Socket 経路の送受信。応答に fd が付いていたら閉じて異常にする。 */
    private function roundTripSocket(string $json): string
    {
        $flags = defined('MSG_EOR') ? MSG_EOR : 0;
        $sent = @socket_sendmsg($this->socket, ['iov' => [$json]], $flags);
        if ($sent === false || $sent !== strlen($json)) {
            throw new BoxError('unavailable', '中継への送信に失敗しました');
        }
        [$data, $fds] = self::recvRecord($this->socket);
        if ($fds !== []) {
            // 操作の応答に fd は付かない決まり。
            foreach ($fds as $f) {
                @socket_close($f);
            }
            throw new BoxError('protocol', '応答に予期しない fd が付いていました');
        }
        return $data;
    }

    /**
     * 1レコードを受け取る。MSG_EOR が立つまで読み足し、届いた fd
     * （Socket オブジェクト）を本文と分けて返す。
     *
     * @return array{0:string, 1:array<int,Socket>}
     */
    private static function recvRecord(Socket $socket): array
    {
        $data = '';
        $fds = [];
        $eor = defined('MSG_EOR') ? MSG_EOR : 0;
        for ($i = 0; $i < 32; $i++) {
            $msg = ['iov' => [str_repeat("\0", self::MAX_MSG + 1)]];
            $n = @socket_recvmsg($socket, $msg, 0);
            if ($n === false) {
                throw new BoxError('unavailable', '中継からの受信に失敗しました');
            }
            self::collectSockets($msg['control'] ?? [], $fds);
            foreach ($msg['iov'] ?? [] as $chunk) {
                if (is_string($chunk)) {
                    $data .= $chunk;
                }
            }
            if (strlen($data) > self::MAX_MSG) {
                throw new BoxError('protocol', '応答が上限を超えました');
            }
            // 'flags' が返らない実装では、SEQPACKET の1回分を1レコードとみなす。
            $flags = isset($msg['flags']) && is_int($msg['flags']) ? $msg['flags'] : $eor;
            if (($flags & $eor) !== 0) {
                return [$data, $fds];
            }
            if ($n === 0) {
                // レコードの途中で相手が閉じた。
                throw new BoxError('unavailable', '中継が接続を閉じました');
            }
        }
        throw new BoxError('protocol', 'レコードの境界が見つかりませんでした');
    }

    /** 制御データの中から Socket（= 受け渡された fd）を再帰的に拾う。 */
    private static function collectSockets($value, array &$out): void
    {
        if ($value instanceof Socket) {
            $out[] = $value;
            return;
        }
        if (is_array($value)) {
            foreach ($value as $v) {
                self::collectSockets($v, $out);
            }
        }
    }

    /**
     * 応答 JSON を解釈する。本命は proto の OpResult の形
     * （{"v":1,"t":"result","ok":bool,"result":...,"error":...}）。
     *
     * @return array<mixed>
     */
    private static function parseResult(string $raw): array
    {
        $res = json_decode($raw, true);
        if (!is_array($res)) {
            throw new BoxError('protocol', '応答が JSON ではありませんでした');
        }
        if (array_key_exists('ok', $res)) {
            if ($res['ok'] === true) {
                return self::asArray($res['result'] ?? null);
            }
            $code = isset($res['error']) && is_string($res['error']) ? $res['error'] : 'protocol';
            throw new BoxError($code);
        }
        if (($res['t'] ?? null) === 'ok') {
            return self::asArray($res['data'] ?? null);
        }
        if (($res['t'] ?? null) === 'err' && isset($res['code']) && is_string($res['code'])) {
            throw new BoxError($res['code']);
        }
        throw new BoxError('protocol', '応答の形が想定と違いました');
    }

    /** 操作の結果は連想配列のはず。違う形なら包んで返す。 */
    private static function asArray($value): array
    {
        if (is_array($value)) {
            return $value;
        }
        return $value === null ? [] : ['value' => $value];
    }
}
