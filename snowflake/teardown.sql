-- CDDN#3 デモ環境の削除スクリプト
-- setup.sql の逆順（⑧ → ①）で実行する
--
-- ★ 先に Databricks 側を削除しておくこと ★
--   1. MCP Service      <catalog>.<schema>.cddn_cortex_agent
--   2. HTTP Connection  <catalog>.<schema>.cddn_snowflake_mcp_conn
--   Connection を残したまま Security Integration を消すと、
--   Databricks 側に認証だけ失敗する Connection が残る。

-----------------------------------------------------------------
-- ⓪ セッション初期化
-----------------------------------------------------------------
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE cddn_demo_wh;
USE SCHEMA cddn_demo_db.cddn_3_demo;


-----------------------------------------------------------------
-- ⑧ Security Integration
-----------------------------------------------------------------
DROP SECURITY INTEGRATION IF EXISTS cddn_mcp_oauth;


-----------------------------------------------------------------
-- ⑦ デモ用ユーザー
-----------------------------------------------------------------
DROP USER IF EXISTS cddn_3_demo_user;


-----------------------------------------------------------------
-- ⑥ ロール（付与済みの GRANT はロール削除で一緒に消える）
-----------------------------------------------------------------
DROP ROLE IF EXISTS mcp_full_role;


-----------------------------------------------------------------
-- ⑤ MCP Server
-----------------------------------------------------------------
DROP MCP SERVER IF EXISTS cddn_demo_db.cddn_3_demo.cddn_mcp;


-----------------------------------------------------------------
-- ④ Cortex Agent
-----------------------------------------------------------------
DROP AGENT IF EXISTS cddn_demo_db.cddn_3_demo.sales_agent;


-----------------------------------------------------------------
-- ③ Cortex Search
-----------------------------------------------------------------
DROP CORTEX SEARCH SERVICE IF EXISTS cddn_demo_db.cddn_3_demo.sales_notes_search_svc;


-----------------------------------------------------------------
-- ② セマンティックビュー
-----------------------------------------------------------------
DROP SEMANTIC VIEW IF EXISTS cddn_demo_db.cddn_3_demo.sales_sv;


-----------------------------------------------------------------
-- ① テーブル
-----------------------------------------------------------------
DROP TABLE IF EXISTS cddn_demo_db.cddn_3_demo.sales_notes;
DROP TABLE IF EXISTS cddn_demo_db.cddn_3_demo.sales_fact;


-----------------------------------------------------------------
-- ⑨ 【確認】残存オブジェクトがないこと
-----------------------------------------------------------------
SHOW MCP SERVERS            IN SCHEMA cddn_demo_db.cddn_3_demo;
SHOW AGENTS                 IN SCHEMA cddn_demo_db.cddn_3_demo;
SHOW CORTEX SEARCH SERVICES IN SCHEMA cddn_demo_db.cddn_3_demo;
SHOW SEMANTIC VIEWS         IN SCHEMA cddn_demo_db.cddn_3_demo;
SHOW TABLES                 IN SCHEMA cddn_demo_db.cddn_3_demo;

SHOW INTEGRATIONS LIKE 'cddn_mcp_oauth';
SHOW USERS        LIKE 'cddn_3_demo_user';
SHOW ROLES        LIKE 'mcp_full_role';


-----------------------------------------------------------------
-- ⑩ まとめて消す場合（デモ専用のため通常はこちらで十分）
--    ⑤〜① の代わりに実行する。⑧⑦⑥ はスキーマ外なので別途必要。
--    ウェアハウス / データベースを setup.sql の ⓪ で新規作成した場合のみ、
--    最後の2行も実行する（既存のものを流用した場合は実行しない）。
-----------------------------------------------------------------
-- DROP SCHEMA    IF EXISTS cddn_demo_db.cddn_3_demo CASCADE;
-- DROP DATABASE  IF EXISTS cddn_demo_db;
-- DROP WAREHOUSE IF EXISTS cddn_demo_wh;