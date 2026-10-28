# 検証用 VM イメージ

FreeBSD のサーバー機を用意しなくても箱（段階0）を触れるように、
公式の FreeBSD VM イメージへ段階0を仕込んだ起動可能イメージを
自動生成する。イメージを起動すると段階0が自動で立ち上がる。

## 生成物

- `box-15.1-RELEASE-amd64.qcow2` — QEMU 用
- `box-15.1-RELEASE-amd64.vmdk` — VirtualBox 用
- `SHA256SUMS`

## 起動のしかた

QEMU（ホストの 8080 を箱へつなぐ）:

```
qemu-system-x86_64 -m 2048 -smp 2 \
  -drive file=box-15.1-RELEASE-amd64.qcow2,format=qcow2,if=virtio \
  -netdev user,id=net0,hostfwd=tcp::8080-:8080,hostfwd=tcp::2222-:22 \
  -device virtio-net-pci,netdev=net0
```

VirtualBox: 既存のハードディスクとして vmdk を選んで VM を作り、
ネットワークを NAT にして、ポートフォワーディングで
ホスト 8080 → ゲスト 8080（と、要れば 2222 → 22）を足す。

## 試しかた

起動したら（初回は growfs と鍵生成で少し待つ）:

```
curl -H 'Cookie: box_session=stage0-demo-session' \
     -H 'Sec-Fetch-User: ?1' \
     http://127.0.0.1:8080/memos/22222222-2222-4222-8222-222222222222
```

コンソール / SSH のログインは **box / box**（wheel に入っている）。
**検証専用の使い捨て前提**。パスワードは公開情報として扱い、
このイメージを公開サーバーとして使わないこと。止め方とログは
`service box stop` / `/var/log/box.log`。

## Mac で検証する場合

UTM / VirtualBox / QEMU での起動と確認の手順は
`mac-verification.md` にまとめてある。

## 検証の進め方

検証用 VM の構築から、動作検証のコマンド、攻撃試験による
安全性の確認までの一式は `verification.md` にまとめてある。

## 生成のしかた

FreeBSD 15.1 の実機または VM（root、ネットワーク、qemu-img）で:

```
pkg install -y qemu        # qemu-img が要る
sh src/image/build-image.sh --out image-out
```

生成ホストとイメージのリリースは一致が必要（chroot 内の uname が
ホストのカーネルを返すため）。中では公式イメージの取得と
チェックサム検証、イメージ内での build.sh / stage0.sh setup、
rc.d/box の配置、検証用ユーザーの作成を行い、最後にビルド用
ツールチェーン（rust）を消してから qcow2 / vmdk に戻す。

生成の本命は、UTM の中の FreeBSD でこのスクリプトを回すこと
（`mac-verification.md` の「UTM の中でイメージを生成する」）。
GitHub Actions の `build_image` でも試せるが、ランナーの資源
（ディスク）の制約でステップごと落ちる失敗が続いており、
現時点では参考扱い。`image_tag` を入れると、その名前で
Release を作ってイメージを添付する。

## 既知の制約

- イメージは数 GB になる（base のコピーが jail / スロットごとに
  入る段階0の構成のため）。配布は圧縮済み qcow2 が前提。
- 生成スクリプトは 2026-10-27 に完走し、生成イメージの起動
  確認まで 2026-10-28 に完了した。実走で判明した前提:
  対象は FreeBSD 15.1（ports のバイナリが 15.1 の libc を要求する
  ため）。詰まったら、どの節で止まったかと出力を教えてほしい。
