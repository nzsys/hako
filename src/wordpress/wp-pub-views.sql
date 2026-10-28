-- WordPress 収容: スキーマ、アカウント、公開ビューの DDL
-- 2026-10-28 にビルダー（FreeBSD 15.1 / MySQL 8.4.11）で実行した
-- ものの再現用。MySQL の root で流す。
-- パスワードのプレースホルダ（<...>）は、設置時に生成した十分に
-- 長い乱数に置き換えること。実物はリポジトリに入れず、ホストの
-- /root/wp-secrets.txt (600) に置く。

CREATE DATABASE wp CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE wp_pub CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

-- 管理・バッチ用。スキーマ wp の DML + DDL
CREATE USER 'wp_adm'@'localhost' IDENTIFIED BY '<WP_ADM_PASSWORD>' WITH MAX_USER_CONNECTIONS 8;
GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, ALTER, DROP, INDEX ON wp.* TO 'wp_adm'@'localhost';

-- ビューの DEFINER 専用。ログインはさせない（DEFINER としての
-- 実行は ACCOUNT LOCK でも動く）
CREATE USER 'wp_view'@'localhost' IDENTIFIED BY '<WP_VIEW_PASSWORD>';
GRANT SELECT ON wp.* TO 'wp_view'@'localhost';
ALTER USER 'wp_view'@'localhost' ACCOUNT LOCK;

-- 公開側。ビューのスキーマの SELECT だけ
CREATE USER 'wp_pub'@'localhost' IDENTIFIED BY '<WP_PUB_PASSWORD>' WITH MAX_USER_CONNECTIONS 8;
GRANT SELECT ON wp_pub.* TO 'wp_pub'@'localhost';

-- 公開ビュー
CREATE DEFINER='wp_view'@'localhost' SQL SECURITY DEFINER VIEW wp_pub.wp_posts AS
  SELECT * FROM wp.wp_posts
  WHERE (post_status = 'publish' OR (post_type = 'attachment' AND post_status = 'inherit'))
    AND post_password = '';

CREATE DEFINER='wp_view'@'localhost' SQL SECURITY DEFINER VIEW wp_pub.wp_postmeta AS
  SELECT pm.* FROM wp.wp_postmeta pm
  JOIN wp.wp_posts p ON p.ID = pm.post_id
  WHERE (p.post_status = 'publish' OR (p.post_type = 'attachment' AND p.post_status = 'inherit'))
    AND p.post_password = '';

CREATE DEFINER='wp_view'@'localhost' SQL SECURITY DEFINER VIEW wp_pub.wp_users AS
  SELECT u.ID, u.user_login, '' AS user_pass, u.user_nicename, '' AS user_email,
         u.user_url, u.user_registered, '' AS user_activation_key, u.user_status, u.display_name
  FROM wp.wp_users u
  WHERE EXISTS (SELECT 1 FROM wp.wp_posts p WHERE p.post_author = u.ID AND p.post_status = 'publish');

CREATE DEFINER='wp_view'@'localhost' SQL SECURITY DEFINER VIEW wp_pub.wp_usermeta AS
  SELECT m.* FROM wp.wp_usermeta m
  WHERE m.meta_key IN ('nickname','first_name','last_name','description')
    AND EXISTS (SELECT 1 FROM wp.wp_posts p WHERE p.post_author = m.user_id AND p.post_status = 'publish');

CREATE DEFINER='wp_view'@'localhost' SQL SECURITY DEFINER VIEW wp_pub.wp_comments AS
  SELECT comment_ID, comment_post_ID, comment_author, '' AS comment_author_email,
         comment_author_url, '' AS comment_author_IP, comment_date, comment_date_gmt,
         comment_content, comment_karma, comment_approved, '' AS comment_agent,
         comment_type, comment_parent, user_id
  FROM wp.wp_comments WHERE comment_approved = '1';

CREATE DEFINER='wp_view'@'localhost' SQL SECURITY DEFINER VIEW wp_pub.wp_commentmeta AS
  SELECT cm.* FROM wp.wp_commentmeta cm
  JOIN wp.wp_comments c ON c.comment_ID = cm.comment_id
  WHERE c.comment_approved = '1';

-- 絞らないビュー
CREATE DEFINER='wp_view'@'localhost' SQL SECURITY DEFINER VIEW wp_pub.wp_options AS SELECT * FROM wp.wp_options;
CREATE DEFINER='wp_view'@'localhost' SQL SECURITY DEFINER VIEW wp_pub.wp_terms AS SELECT * FROM wp.wp_terms;
CREATE DEFINER='wp_view'@'localhost' SQL SECURITY DEFINER VIEW wp_pub.wp_term_taxonomy AS SELECT * FROM wp.wp_term_taxonomy;
CREATE DEFINER='wp_view'@'localhost' SQL SECURITY DEFINER VIEW wp_pub.wp_term_relationships AS SELECT * FROM wp.wp_term_relationships;
CREATE DEFINER='wp_view'@'localhost' SQL SECURITY DEFINER VIEW wp_pub.wp_termmeta AS SELECT * FROM wp.wp_termmeta;
CREATE DEFINER='wp_view'@'localhost' SQL SECURITY DEFINER VIEW wp_pub.wp_links AS SELECT * FROM wp.wp_links;
