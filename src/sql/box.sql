-- box.sql -- 「箱」の DB 定義（PostgreSQL 18 想定）
--
-- 前提:
--   * スーパーユーザーが、データベース box に接続して流す（例: psql -d box -f box.sql）。
--     接続先データベースの名前は box であること（REVOKE TEMPORARY は接続中 DB に対して書く）。
--   * LOGIN ロール（relay / auth / admin / send）のパスワードはここには書かない。
--     installer が各 jail の中で生成し、別途 ALTER ROLE ... PASSWORD で設定する。
--   * テーブルの所有者は own_table（NOLOGIN、何も実行しない）。関数の所有者とは分ける。
--     テーブル所有者のロールに属すると所有者として扱われ RLS が掛からないため、
--     接続ロール・関数所有者ロールのいずれにも own_table を GRANT しない。
--
-- 方針:
--   * 関数はすべて SECURITY DEFINER、SET search_path = <自分のスキーマ>, pg_temp、動的 SQL 無し。
--   * すべての関数で REVOKE EXECUTE ... FROM PUBLIC し、呼べるロールにだけ GRANT EXECUTE する。
--   * app.user_id を参照する関数（biz）は、先頭で必ず set_config('app.user_id', ..., true) する。

-- 拡張
-- gen_random_bytes / digest は pgcrypto の関数。gen_random_uuid は PG13 以降コアにある。
-- SECURITY DEFINER 関数の search_path は固定されるため、pgcrypto の関数は
-- 配置先スキーマ（既定では public）を明示して呼ぶ。
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ロール
-- 所有者ロール（すべて NOLOGIN）: own_table = テーブル、own_* = スキーマごとの関数の所有者。
-- 接続ロール（すべて LOGIN）: jail ごとに 1 つ。パスワードは installer が設定する。

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'own_table') THEN
        CREATE ROLE own_table NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'own_biz') THEN
        CREATE ROLE own_biz NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'own_auth') THEN
        CREATE ROLE own_auth NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'own_outbox') THEN
        CREATE ROLE own_outbox NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'own_adm') THEN
        CREATE ROLE own_adm NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'relay') THEN
        CREATE ROLE relay LOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'auth') THEN
        CREATE ROLE auth LOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'admin') THEN
        CREATE ROLE admin LOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'send') THEN
        CREATE ROLE send LOGIN;
    END IF;
END
$$;

-- 一時テーブルの作成を接続ロールから外す。
-- データベースの既定では TEMPORARY は PUBLIC に付いている。
-- ※ 接続中のデータベースが box である前提。
REVOKE TEMPORARY ON DATABASE box FROM PUBLIC;

-- スキーマ（所有者は対応する own_*）

CREATE SCHEMA IF NOT EXISTS biz    AUTHORIZATION own_biz;
CREATE SCHEMA IF NOT EXISTS authn  AUTHORIZATION own_auth;
CREATE SCHEMA IF NOT EXISTS outbox AUTHORIZATION own_outbox;
CREATE SCHEMA IF NOT EXISTS adm    AUTHORIZATION own_adm;

-- 関数所有者が今後作る関数の既定 EXECUTE（PUBLIC への付与）を外す。
-- IN SCHEMA はスキーマが存在してからでないと書けないため、CREATE SCHEMA の後に置く。
-- このファイルで作る関数には、個別にも REVOKE / GRANT を明示する。
ALTER DEFAULT PRIVILEGES FOR ROLE own_biz   IN SCHEMA biz    REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
ALTER DEFAULT PRIVILEGES FOR ROLE own_auth  IN SCHEMA authn  REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
ALTER DEFAULT PRIVILEGES FOR ROLE own_outbox IN SCHEMA outbox REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
ALTER DEFAULT PRIVILEGES FOR ROLE own_adm   IN SCHEMA adm    REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

-- スキーマの USAGE は、関数を実行するためにだけ必要（関数を呼ぶには対象スキーマの
-- USAGE が要る）。接続ロールには自分の用途のスキーマの USAGE だけを与える。
-- テーブルへの権限は接続ロールには一切与えない（触れるのは SECURITY DEFINER 関数経由だけ）。
GRANT USAGE ON SCHEMA biz    TO relay;
GRANT USAGE ON SCHEMA authn  TO auth;
GRANT USAGE ON SCHEMA outbox TO send;
GRANT USAGE ON SCHEMA adm    TO admin;
-- 例外: outbox.outbox_enqueue は relay が呼ぶ（業務の関数が outbox に積む経路の中継側）。
-- そのため relay には outbox スキーマの USAGE も要る。テーブル権限は与えない。
GRANT USAGE ON SCHEMA outbox TO relay;
-- 例外: adm.adm_user_suspend は SECURITY DEFINER で own_adm として動き、
-- authn.session を参照する。スキーマを参照するには所有者ロールにも USAGE が
-- 要るため、own_adm に authn の USAGE を与える（テーブル権限は DELETE のみ、
-- 下記の GRANT で個別に与える）。
GRANT USAGE ON SCHEMA authn TO own_adm;

-- biz: 個人メモ

CREATE TABLE IF NOT EXISTS biz.memo (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id    uuid NOT NULL,
    title      text CHECK (char_length(title) BETWEEN 1 AND 200),
    body       text CHECK (char_length(body) <= 10000),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE biz.memo OWNER TO own_table;

-- 関数の所有者（own_biz）にだけ DML を与える。接続ロール relay には与えない。
GRANT SELECT, INSERT, UPDATE, DELETE ON biz.memo TO own_biz;

-- RLS: ポリシーは関数の所有者ロールに対して定義する
-- （SECURITY DEFINER の中では current_user が関数の所有者になるため）。
-- FORCE によりテーブル所有者 own_table にもポリシーが掛かる（own_table 向けの
-- ポリシーは無いので、own_table からは一切見えない。スーパーユーザーは迂回する）。
ALTER TABLE biz.memo ENABLE ROW LEVEL SECURITY;
ALTER TABLE biz.memo FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS memo_own_biz ON biz.memo;
CREATE POLICY memo_own_biz ON biz.memo
    FOR ALL TO own_biz
    USING      (user_id = current_setting('app.user_id')::uuid)
    WITH CHECK (user_id = current_setting('app.user_id')::uuid);
-- 注意: app.user_id が未設定だと current_setting がエラーになる。
-- biz の関数はすべて先頭で set_config するので、関数経由では必ず設定済みになる。

-- biz の関数（所有者 own_biz、呼べるのは relay だけ）
-- 引数の UUID の形は、引数の型が uuid であること自体が検査になる
-- （不正な文字列は呼び出し時の型変換で落ちる）。
-- title / body の長さ超過は RAISE EXCEPTION（SQLSTATE 付き）で返す。
-- 中継は DB のエラーを internal に写し、文言は AP に返さない。

CREATE OR REPLACE FUNCTION biz.memo_list(p_user_id uuid)
RETURNS TABLE (id uuid, title text, updated_at timestamptz)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = biz, pg_temp
AS $$
#variable_conflict use_column
BEGIN
    PERFORM set_config('app.user_id', p_user_id::text, true);
    RETURN QUERY
        SELECT m.id, m.title, m.updated_at
          FROM biz.memo AS m
         ORDER BY m.updated_at DESC
         LIMIT 100;
END;
$$;
ALTER FUNCTION biz.memo_list(uuid) OWNER TO own_biz;
REVOKE EXECUTE ON FUNCTION biz.memo_list(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION biz.memo_list(uuid) TO relay;

CREATE OR REPLACE FUNCTION biz.memo_get(p_user_id uuid, p_id uuid)
RETURNS TABLE (id uuid, title text, body text, updated_at timestamptz)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = biz, pg_temp
AS $$
#variable_conflict use_column
BEGIN
    PERFORM set_config('app.user_id', p_user_id::text, true);
    RETURN QUERY
        SELECT m.id, m.title, m.body, m.updated_at
          FROM biz.memo AS m
         WHERE m.id = p_id;
END;
$$;
ALTER FUNCTION biz.memo_get(uuid, uuid) OWNER TO own_biz;
REVOKE EXECUTE ON FUNCTION biz.memo_get(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION biz.memo_get(uuid, uuid) TO relay;

CREATE OR REPLACE FUNCTION biz.memo_create(p_user_id uuid, p_title text, p_body text)
RETURNS TABLE (id uuid, title text, body text, updated_at timestamptz)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = biz, pg_temp
AS $$
#variable_conflict use_column
DECLARE
    v_id         uuid;
    v_title      text;
    v_body       text;
    v_updated_at timestamptz;
BEGIN
    PERFORM set_config('app.user_id', p_user_id::text, true);
    IF p_title IS NULL OR char_length(p_title) NOT BETWEEN 1 AND 200 THEN
        RAISE EXCEPTION 'title must be 1..200 characters' USING ERRCODE = '22001';
    END IF;
    IF p_body IS NOT NULL AND char_length(p_body) > 10000 THEN
        RAISE EXCEPTION 'body must be at most 10000 characters' USING ERRCODE = '22001';
    END IF;
    INSERT INTO biz.memo (user_id, title, body)
    VALUES (p_user_id, p_title, p_body)
    RETURNING id, title, body, updated_at INTO v_id, v_title, v_body, v_updated_at;
    RETURN QUERY SELECT v_id, v_title, v_body, v_updated_at;
END;
$$;
ALTER FUNCTION biz.memo_create(uuid, text, text) OWNER TO own_biz;
REVOKE EXECUTE ON FUNCTION biz.memo_create(uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION biz.memo_create(uuid, text, text) TO relay;

CREATE OR REPLACE FUNCTION biz.memo_update(p_user_id uuid, p_id uuid, p_title text, p_body text)
RETURNS TABLE (id uuid, title text, body text, updated_at timestamptz)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = biz, pg_temp
AS $$
#variable_conflict use_column
BEGIN
    PERFORM set_config('app.user_id', p_user_id::text, true);
    IF p_title IS NULL OR char_length(p_title) NOT BETWEEN 1 AND 200 THEN
        RAISE EXCEPTION 'title must be 1..200 characters' USING ERRCODE = '22001';
    END IF;
    IF p_body IS NOT NULL AND char_length(p_body) > 10000 THEN
        RAISE EXCEPTION 'body must be at most 10000 characters' USING ERRCODE = '22001';
    END IF;
    RETURN QUERY
        UPDATE biz.memo AS m
           SET title = p_title, body = p_body, updated_at = now()
         WHERE m.id = p_id
        RETURNING m.id, m.title, m.body, m.updated_at;
END;
$$;
ALTER FUNCTION biz.memo_update(uuid, uuid, text, text) OWNER TO own_biz;
REVOKE EXECUTE ON FUNCTION biz.memo_update(uuid, uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION biz.memo_update(uuid, uuid, text, text) TO relay;

CREATE OR REPLACE FUNCTION biz.memo_delete(p_user_id uuid, p_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = biz, pg_temp
AS $$
DECLARE
    n integer;
BEGIN
    PERFORM set_config('app.user_id', p_user_id::text, true);
    DELETE FROM biz.memo AS m WHERE m.id = p_id;
    GET DIAGNOSTICS n = ROW_COUNT;
    RETURN n > 0;
END;
$$;
ALTER FUNCTION biz.memo_delete(uuid, uuid) OWNER TO own_biz;
REVOKE EXECUTE ON FUNCTION biz.memo_delete(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION biz.memo_delete(uuid, uuid) TO relay;

-- authn: 利用者とセッション

CREATE TABLE IF NOT EXISTS authn.app_user (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    email         text NOT NULL UNIQUE CHECK (email = lower(email)),
    password_hash text,
    created_at    timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE authn.app_user OWNER TO own_table;

-- セッションは平文でなく SHA-256 のハッシュだけを保存する。
CREATE TABLE IF NOT EXISTS authn.session (
    token_hash bytea PRIMARY KEY,
    user_id    uuid NOT NULL REFERENCES authn.app_user (id),
    created_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL
);
ALTER TABLE authn.session OWNER TO own_table;

GRANT SELECT, INSERT, UPDATE, DELETE ON authn.app_user TO own_auth;
GRANT SELECT, INSERT, UPDATE, DELETE ON authn.session  TO own_auth;
-- 管理の adm_user_suspend が対象利用者のセッションを失効させるために要る DELETE。
-- authn のテーブルへの権限は、この 1 つだけを own_adm に渡す。
GRANT DELETE ON authn.session TO own_adm;

-- RLS: ログイン時はまだ user_id が無いため、own_auth に対しては全行を許す
-- 業務のロールからは見えない。
ALTER TABLE authn.app_user ENABLE ROW LEVEL SECURITY;
ALTER TABLE authn.app_user FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS app_user_own_auth ON authn.app_user;
CREATE POLICY app_user_own_auth ON authn.app_user
    FOR ALL TO own_auth
    USING (true)
    WITH CHECK (true);

ALTER TABLE authn.session ENABLE ROW LEVEL SECURITY;
ALTER TABLE authn.session FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS session_own_auth ON authn.session;
CREATE POLICY session_own_auth ON authn.session
    FOR ALL TO own_auth
    USING (true)
    WITH CHECK (true);
-- own_adm は adm_user_suspend の中でのみ、セッションの削除だけができる。
DROP POLICY IF EXISTS session_own_adm_delete ON authn.session;
CREATE POLICY session_own_adm_delete ON authn.session
    FOR DELETE TO own_adm
    USING (true);

-- authn の関数（所有者 own_auth、呼べるのは auth だけ）

CREATE OR REPLACE FUNCTION authn.user_find_by_email(p_email text)
RETURNS TABLE (id uuid, password_hash text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = authn, pg_temp
AS $$
#variable_conflict use_column
BEGIN
    RETURN QUERY
        SELECT u.id, u.password_hash
          FROM authn.app_user AS u
         WHERE u.email = lower(p_email);
END;
$$;
ALTER FUNCTION authn.user_find_by_email(text) OWNER TO own_auth;
REVOKE EXECUTE ON FUNCTION authn.user_find_by_email(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION authn.user_find_by_email(text) TO auth;

CREATE OR REPLACE FUNCTION authn.user_create(p_email text, p_hash text)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = authn, pg_temp
AS $$
DECLARE
    v_id uuid;
BEGIN
    -- メールアドレスは小文字化して保持する（UNIQUE の CHECK でも担保）。
    -- 重複は UNIQUE 違反（23505）の例外として呼び出し側に返る。
    INSERT INTO authn.app_user (email, password_hash)
    VALUES (lower(p_email), p_hash)
    RETURNING id INTO v_id;
    RETURN v_id;
END;
$$;
ALTER FUNCTION authn.user_create(text, text) OWNER TO own_auth;
REVOKE EXECUTE ON FUNCTION authn.user_create(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION authn.user_create(text, text) TO auth;

CREATE OR REPLACE FUNCTION authn.session_create(p_user_id uuid)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = authn, pg_temp
AS $$
DECLARE
    v_token text;
BEGIN
    -- トークンは 32 バイトの乱数を base64 化したもの。返すのはこの平文だけで、
    -- DB には SHA-256 のハッシュだけを保存する。有効期限は 30 日。
    v_token := encode(public.gen_random_bytes(32), 'base64');
    INSERT INTO authn.session (token_hash, user_id, expires_at)
    VALUES (public.digest(convert_to(v_token, 'UTF8'), 'sha256'),
            p_user_id,
            now() + interval '30 days');
    RETURN v_token;
END;
$$;
ALTER FUNCTION authn.session_create(uuid) OWNER TO own_auth;
REVOKE EXECUTE ON FUNCTION authn.session_create(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION authn.session_create(uuid) TO auth;

CREATE OR REPLACE FUNCTION authn.session_lookup(p_token text)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = authn, pg_temp
AS $$
DECLARE
    v_user_id uuid;
BEGIN
    SELECT s.user_id INTO v_user_id
      FROM authn.session AS s
     WHERE s.token_hash = public.digest(convert_to(p_token, 'UTF8'), 'sha256')
       AND s.expires_at > now();
    -- 見つからない／期限切れは NULL（例外にしない）。
    RETURN v_user_id;
END;
$$;
ALTER FUNCTION authn.session_lookup(text) OWNER TO own_auth;
REVOKE EXECUTE ON FUNCTION authn.session_lookup(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION authn.session_lookup(text) TO auth;

CREATE OR REPLACE FUNCTION authn.session_revoke(p_token text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = authn, pg_temp
AS $$
BEGIN
    DELETE FROM authn.session AS s
     WHERE s.token_hash = public.digest(convert_to(p_token, 'UTF8'), 'sha256');
END;
$$;
ALTER FUNCTION authn.session_revoke(text) OWNER TO own_auth;
REVOKE EXECUTE ON FUNCTION authn.session_revoke(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION authn.session_revoke(text) TO auth;

CREATE OR REPLACE FUNCTION authn.session_revoke_all(p_user_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = authn, pg_temp
AS $$
BEGIN
    DELETE FROM authn.session AS s WHERE s.user_id = p_user_id;
END;
$$;
ALTER FUNCTION authn.session_revoke_all(uuid) OWNER TO own_auth;
REVOKE EXECUTE ON FUNCTION authn.session_revoke_all(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION authn.session_revoke_all(uuid) TO auth;

-- outbox: 送信待ちメール

CREATE TABLE IF NOT EXISTS outbox.mail_outbox (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id    uuid NOT NULL,
    to_addr    text NOT NULL,
    subject    text NOT NULL,
    body       text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    sent_at    timestamptz
);
ALTER TABLE outbox.mail_outbox OWNER TO own_table;

GRANT SELECT, INSERT, UPDATE ON outbox.mail_outbox TO own_outbox;

ALTER TABLE outbox.mail_outbox ENABLE ROW LEVEL SECURITY;
ALTER TABLE outbox.mail_outbox FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS mail_outbox_own_outbox ON outbox.mail_outbox;
CREATE POLICY mail_outbox_own_outbox ON outbox.mail_outbox
    FOR ALL TO own_outbox
    USING (true)
    WITH CHECK (true);

-- outbox の関数（所有者 own_outbox）
--   outbox_enqueue: relay だけ（業務の操作の中で中継が積む）
--   outbox_fetch_unsent / outbox_mark_sent: send だけ

CREATE OR REPLACE FUNCTION outbox.outbox_enqueue(p_user_id uuid, p_to text, p_subject text, p_body text)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = outbox, pg_temp
AS $$
DECLARE
    v_id uuid;
BEGIN
    INSERT INTO outbox.mail_outbox (user_id, to_addr, subject, body)
    VALUES (p_user_id, p_to, p_subject, p_body)
    RETURNING id INTO v_id;
    RETURN v_id;
END;
$$;
ALTER FUNCTION outbox.outbox_enqueue(uuid, text, text, text) OWNER TO own_outbox;
REVOKE EXECUTE ON FUNCTION outbox.outbox_enqueue(uuid, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION outbox.outbox_enqueue(uuid, text, text, text) TO relay;

CREATE OR REPLACE FUNCTION outbox.outbox_fetch_unsent(p_limit int)
RETURNS TABLE (id uuid, user_id uuid, to_addr text, subject text, body text, created_at timestamptz)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = outbox, pg_temp
AS $$
#variable_conflict use_column
BEGIN
    RETURN QUERY
        SELECT m.id, m.user_id, m.to_addr, m.subject, m.body, m.created_at
          FROM outbox.mail_outbox AS m
         WHERE m.sent_at IS NULL
         ORDER BY m.created_at
         LIMIT p_limit;
END;
$$;
ALTER FUNCTION outbox.outbox_fetch_unsent(int) OWNER TO own_outbox;
REVOKE EXECUTE ON FUNCTION outbox.outbox_fetch_unsent(int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION outbox.outbox_fetch_unsent(int) TO send;

CREATE OR REPLACE FUNCTION outbox.outbox_mark_sent(p_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = outbox, pg_temp
AS $$
DECLARE
    n integer;
BEGIN
    UPDATE outbox.mail_outbox AS m
       SET sent_at = now()
     WHERE m.id = p_id AND m.sent_at IS NULL;
    GET DIAGNOSTICS n = ROW_COUNT;
    RETURN n > 0;
END;
$$;
ALTER FUNCTION outbox.outbox_mark_sent(uuid) OWNER TO own_outbox;
REVOKE EXECUTE ON FUNCTION outbox.outbox_mark_sent(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION outbox.outbox_mark_sent(uuid) TO send;

-- adm: 管理
-- adm スキーマ自体にはテーブルを持たない。管理操作は関数の形で足していく。

-- 対象利用者のセッションをすべて失効させる。
-- authn.session を直接消すのではなく「失効」として扱うが、保存形式に revoked_at は
-- 無いため、実装は DELETE になる。権限は次の 2 つで成立させる:
--   * 関数の所有者を own_adm にする（SECURITY DEFINER で own_adm として動く）
--   * authn.session への DELETE を own_adm に GRANT し、RLS でも DELETE を許す
--     （session_own_adm_delete ポリシー、上記）
-- 参照はスキーマ修飾で書き、search_path は adm, pg_temp に固定する。
CREATE OR REPLACE FUNCTION adm.adm_user_suspend(p_user_id uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = adm, pg_temp
AS $$
DECLARE
    n integer;
BEGIN
    DELETE FROM authn.session AS s WHERE s.user_id = p_user_id;
    GET DIAGNOSTICS n = ROW_COUNT;
    RETURN n;
END;
$$;
ALTER FUNCTION adm.adm_user_suspend(uuid) OWNER TO own_adm;
REVOKE EXECUTE ON FUNCTION adm.adm_user_suspend(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION adm.adm_user_suspend(uuid) TO admin;
