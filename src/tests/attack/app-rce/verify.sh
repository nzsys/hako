#!/bin/sh
# 封じ込めの確認（app-rce）。スタックが起動していて、脆弱なアプリが
# 配置されている前提（tests/attack/run.sh が用意する）。
# 「攻撃が失敗するか」ではなく「被害が宣言の範囲に収まるか」を見る。
set -u
BASE=${BASE:-http://127.0.0.1:8080}
MEMO=22222222-2222-4222-8222-222222222222
OTHER=33333333-3333-4333-8333-333333333333
CANARY=/tmp/box-attack-canary
echo "canary-content-$$" > "$CANARY"
# 開始時点のスロット世代（この後のリクエストを捌く世代）。§6 で
# 「攻撃に使われた世代が片付いたか」を見るために控える
GEN0=$(jls -n name 2>/dev/null | grep 'ap\.slot' || true)
FAILS=0

req() { # req <payload-php> -> response body
    ENC=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1")
    curl -s -H 'Cookie: box_session=stage0-demo-session' -H 'Sec-Fetch-User: ?1' \
        "$BASE/memos/$MEMO?x=$ENC"
}
check() { # check <name> <body> <want-substring>
    case "$2" in
        *"$3"*) echo "PASS: $1" ;;
        *) echo "FAIL: $1 (want: $3)"; FAILS=$((FAILS + 1)) ;;
    esac
}
check_not() { # check_not <name> <body> <unwanted-substring>
    case "$2" in
        *"$3"*) echo "FAIL: $1 (leaked: $3)"; FAILS=$((FAILS + 1)) ;;
        *) echo "PASS: $1" ;;
    esac
}

echo "== 1. 実行はスロットの中（uid はスロット用、jail の中）"
B=$(req 'echo shell_exec("/usr/bin/id -u"); echo "jailed="; echo shell_exec("/sbin/sysctl -n security.jail.jailed");')
check "uid はスロット用 (300x)" "$B" "300"
check "jail の中" "$B" "jailed=1"

echo "== 2. 予算: 宣言は memo.get 1回。2回目は弾かれる"
B=$(req 'try { $r = $relay->op("memo.get", ["id" => "'"$MEMO"'"]); echo "op1=ok\n"; } catch (BoxError $e) { echo "op1=" . $e->boxCode() . "\n"; } try { $r = $relay->op("memo.get", ["id" => "'"$MEMO"'"]); echo "op2=ok\n"; } catch (BoxError $e) { echo "op2=" . $e->boxCode() . "\n"; }')
check "1回目は通る" "$B" "op1=ok"
check_not "2回目は通らない" "$B" "op2=ok"

echo "== 3. 対象: 他のメモは宣言の外（forbidden）"
B=$(req 'try { $r = $relay->op("memo.get", ["id" => "'"$OTHER"'"]); echo "other=ok\n"; } catch (BoxError $e) { echo "other=" . $e->boxCode() . "\n"; }')
check "他の対象は forbidden" "$B" "other=forbidden"

echo "== 4. ネットワークは無い / ホストのファイルは見えない"
B=$(req '$s = @fsockopen("203.0.113.1", 443, $en, $es, 3); echo $s ? "net=ok\n" : "net=blocked\n"; $c = @file_get_contents("'"$CANARY"'"); echo $c === false ? "canary=unreadable\n" : "canary=LEAKED\n"; file_put_contents("/work/pwned.txt", "x"); echo "wrote=/work/pwned.txt\n";')
check "外向き接続はできない" "$B" "net=blocked"
check "ホストのファイルは読めない" "$B" "canary=unreadable"
check "作業領域への書き込み自体はできる" "$B" "wrote=/work/pwned.txt"

echo "== 5. 永続化しない: 次のリクエストでは消えている"
B=$(req 'echo file_exists("/work/pwned.txt") ? "persist=PRESENT\n" : "persist=gone\n";')
check "書いたファイルは次で消える" "$B" "persist=gone"

echo "== 6. ホスト側: 攻撃に使われた世代が残っていない"
# 準備済みスロット（次世代の jail と php-cgi）の常駐は正常な姿で、
# 残骸ではない。ここでは開始時に控えた世代が、強制片付けの期限
# （45秒）を過ぎても残っていないことを見る
LEFT=1
i=0
while [ $i -lt 12 ]; do
    LEFT=0
    for g in $GEN0; do
        if jls -n name 2>/dev/null | grep -qx "$g"; then LEFT=1; fi
    done
    [ "$LEFT" = "0" ] && break
    sleep 5
    i=$((i + 1))
done
if [ "$LEFT" = "0" ]; then
    echo "PASS: 攻撃時の世代は全て片付いた"
else
    echo "FAIL: 攻撃時の世代が残っている"; FAILS=$((FAILS + 1))
fi

rm -f "$CANARY"
echo
if [ "$FAILS" = "0" ]; then echo "ALL PASS"; else echo "$FAILS FAILURES"; exit 1; fi
