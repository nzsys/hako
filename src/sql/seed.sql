-- seed.sql -- デモ用の初期データ
--
-- 前提:
--   * box.sql を流した後のデータベース box に、スーパーユーザーで流す。
--   * スーパーユーザーは RLS を迂回する（FORCE ROW LEVEL SECURITY でも対象外）ため、
--     biz.memo への直接 INSERT がそのまま入る。通常運用でこの経路は使わない
--     （pg_hba.conf にスーパーユーザーの行を置かない）。
--   * 再実行しても重複しないよう、主キーで ON CONFLICT DO NOTHING にしてある。

BEGIN;

-- デモ利用者。password_hash はプレースホルダであり、本物のハッシュではない
-- （デモ利用者ではログインできない。ログインを試す場合は auth 経由で登録すること）。
INSERT INTO authn.app_user (id, email, password_hash)
VALUES (
    '11111111-1111-4111-8111-111111111111',
    'demo@example.invalid',
    'PLACEHOLDER-not-a-real-password-hash'
)
ON CONFLICT (id) DO NOTHING;

-- デモ利用者のメモ 2 件。中継スタブ（relay の StubBackend）
-- の内容と揃えてある。
INSERT INTO biz.memo (id, user_id, title, body)
VALUES (
    '22222222-2222-4222-8222-222222222222',
    '11111111-1111-4111-8111-111111111111',
    '買い物リスト',
    '牛乳、卵、醤油'
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO biz.memo (id, user_id, title, body)
VALUES (
    '33333333-3333-4333-8333-333333333333',
    '11111111-1111-4111-8111-111111111111',
    '箱の設計メモ',
    '中継は範囲と対象と回数を保持する'
)
ON CONFLICT (id) DO NOTHING;

COMMIT;
