#!/bin/sh
# 箱: 性能測定
#
# 起動済みのスタック（adapter が 127.0.0.1:8080）に対して
# デモメモの取得を N 回（既定 100）繰り返し、curl の time_total の
# 合計から req/s を出す。1回ごとの内訳ではなく「直列に叩いたときの
# 毎秒リクエスト数」の目安。
#
# 使い方: bench.sh [回数]
# 前提: install/stage0.sh start 済み、curl があること。
set -eu

N=${1:-100}
URL=http://127.0.0.1:8080/memos/22222222-2222-4222-8222-222222222222

command -v curl >/dev/null 2>&1 || { echo "bench.sh: curl が必要です" >&2; exit 1; }

req() {
    curl -s -o /dev/null \
        -w '%{time_total} %{http_code}\n' \
        -H 'Cookie: box_session=stage0-demo-session' \
        -H 'Sec-Fetch-User: ?1' \
        -H 'Sec-Fetch-Site: same-origin' \
        -H 'Sec-Fetch-Mode: navigate' \
        "$URL"
}

# ウォームアップ（数に数えない）
req >/dev/null

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT INT TERM

i=0
while [ $i -lt $N ]; do
    req >> "$TMP"
    i=$((i + 1))
done

awk -v n="$N" '
    { total += $1; if ($2 == 200) ok++; else ng++ }
    END {
        printf "requests : %d (200: %d, other: %d)\n", n, ok, ng
        printf "total    : %.3f s\n", total
        if (total > 0) {
            printf "avg      : %.4f s/req\n", total / n
            printf "req/s    : %.1f\n", n / total
        }
    }' "$TMP"
