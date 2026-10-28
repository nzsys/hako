# 箱の検証手順

段階0について「動くこと」と「安全なこと」を分けて確かめるための
手順書。どちらも再現できる形で書く。実施したら結果を §2.3 と
§3 の実施記録に残すこと（PASS / FAIL の一覧と日付）。

- 機能の確認は §2（起動、自動起動、メモの CRUD、拒否の確認）
- 安全の確認は §3（攻撃試験。侵入の成否ではなく **被害の上限** で
  判定する。箱の前提は「アプリは乗っ取られ済み」）
- 検証環境は2種類ある。混同しないこと:
  - **ビルダー VM（box-builder）**: 開発と生成のホスト。イメージ
    生成も攻撃試験（§3 の全部）もここで回す
  - **製品 VM（box-product）**: 生成した qcow2 をそのまま起動した
    検証対象。配布物の姿のまま確かめるのが目的

前提の数値（段階0のデモ固定値）:

- ログイン: `box` / `box`（wheel グループ。検証専用）
- セッション Cookie: `box_session=stage0-demo-session`
- 利用者 UUID: `11111111-1111-4111-8111-111111111111`
- シードのメモ: `22222222-2222-4222-8222-222222222222`（買い物
  リスト）、`33333333-3333-4333-8333-333333333333`（箱の設計メモ）
- adapter の待ち受けは **ゲスト内の 127.0.0.1:8080 のみ**。外から
  直接は叩けない。確認コマンドはゲストの中で（SSH 越しに）打つ

## 1. 検証用 VM の構築手順

### 1.1 ビルダー VM（box-builder）

1. 公式イメージ `FreeBSD-15.1-RELEASE-amd64-ufs.qcow2` を用意し、
   チェックサムを確認する（`mac-verification.md` §1）。
2. UTM で新規 VM: Emulate / Other / x86_64、起動ドライブにその
   qcow2、メモリ 8192MB（cargo のビルドで要る）、CPU 4。
3. ディスクは余裕を持つこと。30GB では生成時の raw（約21GB）と
   成果物（qcow2 + vmdk で約16GB）が同居できず溢れた実績がある
   （`secure/knowledge/reproducibility.md` §4）。
4. 初期設定（ゲスト内、root。公式イメージの root はコンソール
   からパスワード無しで入れる）:

```
pkg install -y qemu git-lite rust python3 curl tailscale
```

`python3` と `curl` は攻撃試験の駆動（poc.sh / verify.sh）に要る。
`tailscale` は任意（外から SSH で入る経路が欲しい場合）。

### 1.2 製品イメージの生成

ビルダー VM の中で root で実行する（生成ホストとイメージの
リリース一致が前提。今は 15.1-RELEASE）:

```
cd <repo>/src
sh image/build-image.sh --out /root/out
```

生成物は `box-15.1-RELEASE-amd64.qcow2` / `.vmdk` /
`SHA256SUMS`。所要はエミュレーション下で1〜2時間オーダー。
途中で止まったら最後の `==` の節とエラーが証拠になるので残す。

### 1.3 製品 VM（box-product）— UTM

1. **原イメージは起動しない。** 作業コピーを作ってそちらを使う:

```
cp box-15.1-RELEASE-amd64.qcow2 work.qcow2
```

2. UTM で新規 VM: Emulate / Other / x86_64、起動ドライブに
   `work.qcow2`、メモリ 2048MB 以上、CPU 2、ネットワークは
   共有ネットワークのまま。
3. 起動する。エミュレーションなので数分かかる。コンソールに
   ログインプロンプトが出れば起動完了。

ネットワークについて実測で分かったこと（2026-10-28）:

- この構成の共有ネットワークの実体は **vmnet
  （192.168.64.0/24、ホストは 192.168.64.1）** で、Mac から
  ゲストの DHCP アドレスへ直接届く。ビルダーは .4、製品 VM は
  .5 を取った
- UTM の設定画面に出る「ゲストネットワーク 10.0.2.0/24」は
  この実体を表していない。ポート転送の UI もこの版の UTM の
  ネットワーク画面には無い（vmnet なので不要）
- UTM コンソールは **貼り付けが効かない**。ホスト側からの
  画面入力では Shift / Ctrl がゲストに届かず、大文字や記号を
  送れない。コンソールは起動ログの観察専用と割り切り、操作は
  すべて SSH で行う

### 1.4 ゲストへのアクセス

ゲストのアドレスは、起動ログの `bound to 192.168.64.x` の行か
UTM の詳細表示で確認する。

```
ssh box@192.168.64.5        # パスワード box
```

root が要る作業（攻撃試験、stage0.sh の直接操作）は、コンソール
で root ログインするか、box で入って `su` する。製品イメージの
`/usr/local/box/src` にソース一式が入り、段階0の部品も構築・
配置済み（ツールチェーンだけ生成時に消してある）。

## 2. 動作検証

### 2.1 起動状態の確認（ゲスト内）

製品 VM は起動すれば rc.d/box が段階0を自動で立ち上げる。
ビルダー側で手動起動する場合は `sh src/install/stage0.sh setup`
→ `start`（製品 VM では `service box start` でもよい）。

```
tail -20 /var/log/box.log     # 自動起動の記録（製品 VM）
ls /var/run/box               # adapter / grant / dispatcher / relay の pidfile
jls                           # ap / relay と、準備済みスロットが見える
sockstat -4l | grep 8080      # 127.0.0.1:8080 の待ち受け
```

### 2.2 メモアプリの確認

ゲストの中で実行する。`curl` がある環境（ビルダー）では:

```
C='Cookie: box_session=stage0-demo-session'
G='Sec-Fetch-User: ?1'
B=http://127.0.0.1:8080

curl -s -H "$C" -H "$G" $B/memos                                        # 一覧 200（シード2件）
curl -s -H "$C" -H "$G" $B/memos/22222222-2222-4222-8222-222222222222    # 詳細 200
curl -s -i -H "$C" -H "$G" -d 'title=検証メモ' -d 'body=本文' $B/memos   # 作成 → 303
curl -s -H "$C" -H "$G" $B/memos/44444444-4444-4444-8444-000000000003    # 作成分が読める
curl -s -i -H "$C" -H "$G" -X POST $B/memos/44444444-4444-4444-8444-000000000003/delete   # 削除 → 303
curl -s -o /dev/null -w '%{http_code}\n' -H "$C" -H "$G" $B/memos/44444444-4444-4444-8444-000000000003   # 404
curl -s -o /dev/null -w '%{http_code}\n' -H "$C" $B/memos               # ジェスチャ無し → 403
```

作成で採番される ID は中継スタブの次の番号（`44444444-…-0003`。
再起動や実行順で変わることがあるので、303 の `Location` で
実際の ID を確認すること）。

製品イメージのホストには `curl` が無い。そこでは `nc` と
`printf` で同じリクエストを送る（Mac から SSH 越しの一行）:

```
ssh box@192.168.64.5 "printf 'GET /memos HTTP/1.0\r\nCookie: box_session=stage0-demo-session\r\nSec-Fetch-User: ?1\r\n\r\n' | nc localhost 8080"
```

200 でシード2件の一覧 HTML が返れば応答確認は完了。

### 2.3 実施記録（機能）

- 2026-10-27: ビルダー上で段階0の全スタック実走。一覧・詳細・
  作成（303）・削除（303 → 404）・ジェスチャ無し 403・スロット
  世代の消費と再準備まで確認
- 2026-10-28: 製品 VM（box-product、192.168.64.5）で自動起動を
  確認し、SSH 越しに一覧 200（シード2件）を確認

## 3. 安全性の確認（攻撃試験）

試験一式は `src/tests/attack/`（考え方と約束は同梱の README）。
共通の前提:

- すべて FreeBSD の root で実行する
- 脆弱なコードとパッチ前バイナリは検証用ルート
  （`/var/jails/vuln-*`）と試験アプリだけに置き、通常の
  slotbase / アプリには混ぜない
- FAIL が出たら試験側を黙って直さず、設計への指摘として扱う

### 3.1 app-rce（本命：中継の強制と封じ込め）

題材アプリに意図的な `eval` の穴を開けた版を通常経路に置き、
攻撃者の PHP をスロットの中で走らせる。判定は verify.sh の
6節（スロット内で実行されること／予算は宣言の1回まで／他の
対象は forbidden／外向きネットワーク無し・ホストのファイル
不可／非永続／攻撃に使われた世代の片付け）。

```
sh src/tests/attack/run.sh
```

- 駆動に `curl` と `python3` が要る（ビルダーには入っている）
- **攻撃試験はビルダーで回す**（2026-10-28 に整理）。製品
  イメージはツールチェーンを持たない設計で、CVE のビルド等は
  そもそも回らない。製品側は §2 の機能確認までで、安全性の
  判定はビルダー側の結果をもって行う
- run.sh は終わりに段階0を止める。続けて作業する場合は
  `stage0.sh start` で上げ直す

実施記録:

- 2026-10-27: ビルダー上で ALL PASS
- 2026-10-28: 現行ツリーで再実行し ALL PASS（PoC は uid=3001
  のスロットで発火、判定6節すべて PASS）

### 3.2 CVE-2012-1823（パッチ前 PHP-CGI の引数注入）

CGI モードでのみ発火する歴史的脆弱性を、パッチ前 PHP 5.3.11
で再現し、jail に閉じた場合の被害上限を見る。箱の通常経路は
FastCGI で、この発火点自体に届かない（対比は試験の README）。

```
sh src/tests/attack/cve-2012-1823-php-cgi/build-vuln-php.sh
sh src/tests/attack/cve-2012-1823-php-cgi/run-cgi.sh
```

- build は museum.php.net から 5.3.11 を取得してコンパイルし、
  `/var/jails/vuln-php53` を組む。初回は configure + make で
  相応に時間がかかる（エミュレーション環境では数十分）。
  ビルド済みなら再実行は組み直しだけ
- 判定: 発火すること（PWNED・uid=3001・jailed=1）／外向き
  接続不可／ホストのファイル不可／その後アプリ本体も走る／
  世代を作り直すと書いたファイルが消える

実施記録:

- 2026-10-28: ビルダー上で **ALL PASS**。発火した上で全項目が
  収まった

実機で踏んで直した試験側の不備（いずれも箱本体ではなく
fixture の欠陥。記録として残す）:

1. base.txz には `/usr/local` が無く、そのまま `install`
   すると落ちた → 先に `install -d` する
2. FreeBSD 15.1 の `jexec -u` はユーザーを**ホスト側で名前
   として**解決する。数値 uid を渡しても引けない →
   `-u slot1` に改め、検証用ルート内にも `pw -R` で
   slot1（uid 3001）を用意した。前提として、ホスト側に
   stage0 の setup が作る slot1 が要る
3. `QUERY_STRING` env に書くだけでは発火しなかった。
   CGI/1.1 の indexed query として Web サーバーが argv に
   渡すところまで再現し、php-cgi 自身の `-d` オプションに
   なって初めて発火した
4. `/work` が素のディレクトリだと jail の作り直しで消えず、
   永続化の判定にならない → run 側で tmpfs を張る。所有も
   uid 3001 に移す（書けないと判定が空転する）

### 3.3 React2Shell（CVE-2025-55182、現行の RCE）

脆弱な Next.js 15.0.0 / react 19.0.0 を jail で受け、OS 層の
封じ込めだけを見る。

```
sh src/tests/attack/react2shell-cve-2025-55182/build-vuln-node.sh
sh src/tests/attack/react2shell-cve-2025-55182/run-node.sh
```

- 発火ペイロード本体はリポジトリに入れない。検証者が公開
  PoC を `poc.local.sh` として差し込む分担（.gitignore 済み）
- PoC は証拠ファイル `/work/evidence.txt` を書く約束。証拠が
  無ければ **POC-NO-FIRE**（終了コード 2）で、これは
  「防げた」ではない。ペイロードを突き合わせてから再実行する
- 受け側 jail は 127.0.0.2 のループバックを持つ。箱の
  スロットの「IP 無し」より弱い形である点に注意
- `/work` は tmpfs で、所有は uid 3001（マウント直後に
  chown する。でないと発火しても証拠が書けない）

実施記録:

- 2026-10-28: ビルダー上で受け側の構築と起動を確認（jail 内
  uid 3001 で Next.js が Ready になり応答）。`poc.local.sh`
  未投入のため判定は POC-NO-FIRE で、これは設計どおりの
  「未発火」の表示。発火の確認は `poc.local.sh` の差し込み待ち

実機で直した fixture の不備（箱本体ではなく受け側の欠陥）:

- npm は node 本体と別パッケージ（`npm-node22`）。build の
  pkg 判定も npm の有無まで見ないと、再実行で入れ直されない
- `pkg -r` では ldconfig の hints が作られず、node が
  libllhttp を見つけられない → chroot で
  `/etc/rc.d/ldconfig onestart` を回す
- next 15.0.0 の peer 範囲は react 19 の rc までで、19.0.0
  （正式版）が ERESOLVE になる → `--legacy-peer-deps`。
  版固定そのものが検証対象なので、peer の厳密一致は外す
- App Router にはルートレイアウトが必須 → `app/layout.js`
  を追加した
- `/root` は 0700 で uid 3001 がアプリに辿り着けない →
  配置後に `a+rX`（コードは読み取り専用で開ける）
- jail の 127.0.0.2 はホストの lo0 に alias が無いと bind
  できない → run 側で alias の張り・剥がしを行う

### 3.4 段階0で「安全」と言える範囲

言えること（実測の範囲）:

- スロットに閉じたコードは、宣言された中継操作（対象と
  予算）を超えて永続層に触れられない。外向き通信もホストの
  ファイルも届かない。世代が終われば作業領域は消え、攻撃に
  使われた世代は片付く — app-rce と CVE-2012-1823 の実測で
  確認したのはここまで

まだ言えないこと（段階0の簡略化）:

- 中継の DB はインメモリのスタブ（本物の PostgreSQL 未接続）
- 認証は固定セッションのスタブ。adapter は edge と
  ゲートウェイの一体化。jail は ap と relay のみで、pf は
  未適用、egress / admin / auth の jail は未実装
- 設計文書全体の保証は、段階を進めて初めて言える

## 4. 詰まったとき

- まず `/var/log/box.log`、`jls`、`ls /var/run/box` を見る
- ビルダーのディスク残量（`df -h /`）。イメージ生成物や
  検証用ルートは GB 単位で場所を取る
- スロット jail が残っていたら、`stage0.sh stop` か
  `jail -r` で片付けてから start し直す（dispatcher は残った
  子 jail を回収しない）
- 起動直後の応答確認は、ソケットとポートで判断する
  （エミュレーションでは準備が遅れることがある）
- 再現に必要な条件の詳細は
  `secure/knowledge/reproducibility.md` に集約してある

## 5. WordPress 収容の検証

`secure/wordpress.md` の形のうち、wpdb と公開側のデータ層
（W2・W3）を先に実物で確かめた記録。wp-pub スロットでの
描画は次段（§5.5）。

### 5.1 wpdb jail の構築

1. ルート `/var/jails/wpdb` に base.txz を展開し、
   `pkg -r` で `mysql84-server` と `mysql84-client` を入れる
   （mysqld は `/usr/local/libexec/mysqld`）。chroot で
   `/etc/rc.d/ldconfig onestart` を回す
2. `/usr/local/etc/mysql/my.cnf`:

```
[mysqld]
user=mysql
datadir=/var/db/mysql
socket=/run/db/mysql.sock
pid-file=/run/db/mysqld.pid
skip_networking=ON
mysqlx=OFF
local_infile=OFF
secure_file_priv=NULL
```

3. `mysqld --initialize-insecure` で初期化し、ネットワーク
   無しの jail の中で `mysqld --daemonize` で起動する
4. 確認: `SHOW VARIABLES` で `skip_networking=ON`、
   `local_infile=OFF`、`secure_file_priv=NULL`。待ち受け
   ポートは 0（socket のみ）

### 5.2 設置用の作業場（wpwork）

管理側（wp-adm）の代わりに WordPress を設置するための
使い捨ての作業場。本番形の wp-adm そのものではない。

- base に `pkg -r` で php85 と拡張を入れる: mysqli、curl、
  mbstring、xml、dom、zip、gd、exif、fileinfo、simplexml、
  intl、**phar**、**filter**
  - `php85-openssl` というパッケージは無い。存在しない名前を
    混ぜると pkg は取引ごと中止するので注意
  - phar が無いと wp-cli が、filter が無いと WordPress の
    設置直後のメール送信が落ちる
- wpdb の socket ディレクトリ（`/var/jails/wpdb/run/db`）を
  作業場の `/run/db` に nullfs でマウントする
- wordpress.org から `wordpress-7.1.3.tar.gz` と
  `wp-cli.phar` を取得し、`wp_adm` の権限で
  `wp core config` → `wp core install` する
  （`--dbhost='localhost:/run/db/mysql.sock'`）
  - 設置が最後の通知メールで落ちても、設置自体は完了して
    いることがある。`wp core is-installed` で確かめる

### 5.3 アカウントとビュー

- アカウントは3つ（詳細と DDL は
  `src/wordpress/wp-pub-views.sql`）:
  - `wp_adm`: スキーマ `wp` の DML + DDL（設置と管理用）
  - `wp_view`: スキーマ `wp` の SELECT のみ + ACCOUNT LOCK
    （ビューの DEFINER 専用）
  - `wp_pub`: スキーマ `wp_pub` の SELECT のみ（公開側）
- 秘密は設置時に乱数で生成し、ホストの
  `/root/wp-secrets.txt` (600) に置く。リポジトリには入れない
- ビューは12本、`SQL SECURITY DEFINER`（DEFINER は
  `wp_view`）。絞り方は wordpress.md の表どおり

### 5.4 実施記録（2026-10-28、ビルダー）

検証データ: 著者と会員（購読者）、公開・下書き・非公開・
パスワード付きの記事、承認済み・未承認・スパムのコメント。

`wp_pub` として接続した実測:

- 見える記事は公開済みだけ。下書き・非公開・パスワード
  付きは行ごと見えない
- `wp_users` は公開記事の著者だけ（会員は行が無い）。
  `user_pass` と `user_email` は空文字
- コメントは承認済みだけ。投稿者のメール・IP・エージェント
  は空文字
- `INSERT` は ERROR 1142（command denied）。本体スキーマ
  `wp` への SELECT も ERROR 1142
- `LOAD_FILE` は NULL が返り遮断される（FILE 権限なし＋
  `secure_file_priv=NULL`）

### 5.5 次段

wp-pub スロットで実物の WordPress を読み取り専用コードで
描画する。鍵は wp-config の接続先スキーマを `wp_pub` に
すること（ビューを表として読む）。あわせて W1・W4・W5
（外に出られない、残らない、応答を変えられない）を
app-rce と同じ型の判定で確かめる。
...[truncated 2281 chars]