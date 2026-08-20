-- CDDN#3 デモ環境の構築スクリプト
--
-- 実行前に置き換えるプレースホルダー
--   <SF_HOST>           Snowflake アカウント URL   例) abc12345.ap-northeast-1.aws.snowflakecomputing.com
--   <DBX_HOST>          Databricks ワークスペース  例) dbc-xxxxxxxx-xxxx.cloud.databricks.com
--   <EMAIL>             デモ用ユーザーのメールアドレス
--   <INITIAL_PASSWORD>  デモ用ユーザーの初期パスワード
--
-- ウェアハウス / データベース名（cddn_demo_wh / cddn_demo_db）は
-- 既存環境に合わせて変更してよい。変更した場合は teardown.sql と
-- databricks/SETUP.md の同名箇所も揃えること。

-----------------------------------------------------------------
-- ⓪ セッション初期化
-----------------------------------------------------------------
USE ROLE ACCOUNTADMIN;

CREATE WAREHOUSE IF NOT EXISTS cddn_demo_wh
  WAREHOUSE_SIZE      = XSMALL
  AUTO_SUSPEND        = 60
  INITIALLY_SUSPENDED = TRUE;

CREATE DATABASE IF NOT EXISTS cddn_demo_db;
CREATE SCHEMA   IF NOT EXISTS cddn_demo_db.cddn_3_demo;

USE WAREHOUSE cddn_demo_wh;
USE SCHEMA cddn_demo_db.cddn_3_demo;


-----------------------------------------------------------------
-- ① データ作成 : 株式会社ユキレンガ物産（除雪用品 × レンガ）
-----------------------------------------------------------------

-- 1-1. 売上明細テーブル
CREATE OR REPLACE TABLE cddn_demo_db.cddn_3_demo.sales_fact (
  order_id    NUMBER      NOT NULL,
  order_date  DATE        NOT NULL,
  region      VARCHAR(20) NOT NULL,
  category    VARCHAR(20) NOT NULL,
  product     VARCHAR(60) NOT NULL,
  quantity    NUMBER      NOT NULL,
  amount_jpy  NUMBER      NOT NULL,
  CONSTRAINT pk_sales_fact PRIMARY KEY (order_id)
);

-- 1-2. 2年分（2024-04-01 〜 2026-03-31）の売上を生成
--      除雪用品 = 冬 × 北日本 / レンガ = 春秋 × 西日本 に需要が偏るよう重み付けする
INSERT INTO cddn_demo_db.cddn_3_demo.sales_fact
  (order_id, order_date, region, category, product, quantity, amount_jpy)
WITH cal AS (
  SELECT DATEADD(day, SEQ4(), DATE '2024-04-01') AS order_date
  FROM TABLE(GENERATOR(ROWCOUNT => 730))
),
prod AS (
  SELECT * FROM VALUES
    ('除雪用品', 'スノーダンプ しんちゃん号',      9800),
    ('除雪用品', 'アルミ雪はね 幅50cm',            3200),
    ('除雪用品', '融雪剤 塩化カルシウム 25kg',     2400),
    ('除雪用品', 'タイヤチェーン 金属亀甲型',      8600),
    ('レンガ',   '赤レンガ 標準 210x100x60',        120),
    ('レンガ',   '耐火レンガ SK-32',                480),
    ('レンガ',   '敷きレンガ アンティーク調',       260),
    ('レンガ',   '化粧ブロック グレー',             340)
  AS p(category, product, unit_price)
),
reg AS (
  SELECT * FROM VALUES
    ('北海道', 1.80, 0.35),
    ('東北',   1.40, 0.60),
    ('北陸',   1.25, 0.55),
    ('関東',   0.45, 1.60),
    ('関西',   0.30, 1.40),
    ('九州',   0.10, 1.20)
  AS r(region, snow_weight, brick_weight)
),
base AS (
  SELECT
    cal.order_date, reg.region, prod.category, prod.product, prod.unit_price,
    CASE WHEN prod.category = '除雪用品'
      THEN reg.snow_weight * CASE MONTH(cal.order_date)
             WHEN 11 THEN 1.10 WHEN 12 THEN 1.60 WHEN 1 THEN 1.80
             WHEN 2  THEN 1.30 WHEN 3  THEN 0.60 WHEN 10 THEN 0.35
             ELSE 0.05 END
      ELSE reg.brick_weight * CASE
             WHEN MONTH(cal.order_date) BETWEEN 4 AND 6  THEN 1.30
             WHEN MONTH(cal.order_date) BETWEEN 7 AND 8  THEN 0.70
             WHEN MONTH(cal.order_date) BETWEEN 9 AND 10 THEN 1.15
             ELSE 0.35 END
    END AS season_weight
  FROM cal CROSS JOIN reg CROSS JOIN prod
),
sized AS (
  SELECT base.*,
    GREATEST(0, ROUND(
      CASE WHEN category = 'レンガ' THEN 220 ELSE 14 END
      * season_weight
      * UNIFORM(0.35::FLOAT, 1.75::FLOAT, RANDOM())
    )) AS quantity
  FROM base
  WHERE UNIFORM(0::FLOAT, 1::FLOAT, RANDOM()) < 0.30
)
SELECT
  ROW_NUMBER() OVER (ORDER BY order_date, region, product),
  order_date, region, category, product, quantity,
  ROUND(quantity * unit_price * UNIFORM(0.94::FLOAT, 1.06::FLOAT, RANDOM()))
FROM sized
WHERE quantity > 0;

-- 1-3. 現場メモ（Cortex Search の対象）
CREATE OR REPLACE TABLE cddn_demo_db.cddn_3_demo.sales_notes (
  note_id   NUMBER,
  note_date DATE,
  region    VARCHAR(20),
  category  VARCHAR(20),
  author    VARCHAR(40),
  body      VARCHAR
);

INSERT INTO cddn_demo_db.cddn_3_demo.sales_notes VALUES
(1,  '2024-10-18', '北海道', '除雪用品', '営業一課 佐々木',
 '旭川エリアの建設会社数社から、融雪剤の前倒し発注の打診。昨年の11月末納品が現場に間に合わなかった反省とのこと。10月中の内示発注を受け付ける運用に変えたい。'),
(2,  '2024-12-05', '北海道', '除雪用品', '営業一課 佐々木',
 'スノーダンプ しんちゃん号、初雪と同時に問い合わせが急増。名前がふざけているという指摘を毎年受けるが、リピート率は全商品で最高。ネーミング変更は反対。'),
(3,  '2025-01-22', '東北', '除雪用品', '営業二課 阿部',
 '青森・秋田で融雪剤が完売。塩化カルシウムの調達が追いつかない。代替として塩化ナトリウム系を提案したが、コンクリート面への影響を懸念され断られた案件が3件。'),
(4,  '2024-05-14', '関東', 'レンガ', '営業三課 井上',
 '外構業者向けの敷きレンガ アンティーク調が春の主力。SNSで施工事例が拡散した影響が続いている。ゴールデンウィーク明けの発注が例年より2週間早い。'),
(5,  '2024-07-30', '関西', 'レンガ', '営業三課 井上',
 '猛暑で外構工事が軒並み延期。7〜8月のレンガ需要が落ちるのは毎年だが、今年は特に顕著。9月以降にずれ込む前提で在庫を持ち越す判断をした。'),
(6,  '2024-09-11', '九州', 'レンガ', '営業四課 有馬',
 '耐火レンガ SK-32 は窯業向けの定期需要が中心で、季節性がほとんどない。有田・唐津の窯元からの補充発注が売上の下支えになっている。'),
(7,  '2025-02-03', '北陸', '除雪用品', '営業二課 阿部',
 '富山・福井の記録的な大雪でアルミ雪はねが在庫切れ。ホームセンター経由の引き合いが通常の4倍。除雪用品は在庫を持てるかどうかで売上が決まる商売だと再認識。'),
(8,  '2024-11-27', '北海道', 'レンガ', '営業一課 佐々木',
 '北海道でレンガが売れないのは冬期に外構工事ができないため。ただし赤レンガは屋内の暖炉・薪ストーブ周りの改修需要が冬にわずかにある。'),
(9,  '2025-03-19', '東北', '除雪用品', '営業二課 阿部',
 '3月に入ってタイヤチェーンの返品相談が増加。未開封であれば翌シーズンまで預かる運用を提案。除雪用品の売上は3月で急落し、翌10月まで谷になる。'),
(10, '2025-04-08', '関東', 'レンガ', '営業三課 井上',
 '化粧ブロック グレーが集合住宅の外構リニューアル案件で大口受注。単価は低いが数量がまとまるため、レンガカテゴリの数量の大半をこの商品が占める。'),
(11, '2025-06-24', '関西', 'レンガ', '営業四課 有馬',
 '梅雨の長雨で施工が止まり、6月後半の出荷が翌月に流れた。数量ベースでは4〜6月がレンガのピークだが、月次で見ると天候で前後1か月ぶれる。'),
(12, '2025-01-09', '関東', '除雪用品', '営業三課 井上',
 '関東でも都心の降雪予報が出た日だけ融雪剤と雪はねが瞬間的に売れる。年間では小さいが、1〜2月に極端なスパイクが立つのが関東の特徴。');

-- Cortex Search は差分取り込みに変更追跡を使う
ALTER TABLE cddn_demo_db.cddn_3_demo.sales_notes SET CHANGE_TRACKING = TRUE;

-- 1-4. 【確認】生成されたデータを見る
SELECT * FROM cddn_demo_db.cddn_3_demo.sales_fact LIMIT 5;

SELECT MONTH(order_date) AS m,
       SUM(IFF(category = '除雪用品', amount_jpy, 0)) AS "除雪用品",
       SUM(IFF(category = 'レンガ',   amount_jpy, 0)) AS "レンガ"
FROM cddn_demo_db.cddn_3_demo.sales_fact
GROUP BY 1 ORDER BY 1;


-----------------------------------------------------------------
-- ② Cortex Analyst : セマンティックビュー
-----------------------------------------------------------------
CREATE OR REPLACE SEMANTIC VIEW cddn_demo_db.cddn_3_demo.sales_sv
  TABLES (
    sales AS cddn_demo_db.cddn_3_demo.sales_fact
      PRIMARY KEY (order_id)
      COMMENT = '株式会社ユキレンガ物産の売上明細。除雪用品とレンガの2カテゴリを扱う。'
  )
  FACTS (
    sales.qty AS quantity   COMMENT = '受注数量',
    sales.amt AS amount_jpy COMMENT = '売上金額（円）'
  )
  DIMENSIONS (
    sales.order_date  AS order_date                     COMMENT = '受注日',
    sales.order_month AS TO_CHAR(order_date, 'YYYY-MM') COMMENT = '受注年月（YYYY-MM）',
    sales.order_year  AS YEAR(order_date)               COMMENT = '受注年',
    sales.region      AS region                         COMMENT = '販売地域（北海道/東北/北陸/関東/関西/九州）',
    sales.category    AS category                       COMMENT = '商品カテゴリ（除雪用品/レンガ）',
    sales.product     AS product                        COMMENT = '商品名'
  )
  METRICS (
    sales.total_amount   AS SUM(sales.amt)        COMMENT = '売上金額合計（円）',
    sales.total_quantity AS SUM(sales.qty)        COMMENT = '受注数量合計',
    sales.order_count    AS COUNT(sales.order_id) COMMENT = '受注件数'
  )
  COMMENT = 'ユキレンガ物産の売上分析用セマンティックビュー';

-- 2-1. 【確認】
SELECT * FROM SEMANTIC_VIEW(
  cddn_demo_db.cddn_3_demo.sales_sv
  DIMENSIONS sales.region, sales.category
  METRICS    sales.total_amount
) ORDER BY 1, 2;


-----------------------------------------------------------------
-- ③ Cortex Search
-----------------------------------------------------------------
CREATE OR REPLACE CORTEX SEARCH SERVICE cddn_demo_db.cddn_3_demo.sales_notes_search_svc
  ON body
  ATTRIBUTES region, category
  WAREHOUSE = cddn_demo_wh
  TARGET_LAG = '1 hour'
  AS
    SELECT note_id, note_date, region, category, author, body
    FROM cddn_demo_db.cddn_3_demo.sales_notes;


-----------------------------------------------------------------
-- ④ Cortex Agent
-----------------------------------------------------------------
CREATE OR REPLACE AGENT cddn_demo_db.cddn_3_demo.sales_agent
  WITH PROFILE = '{"display_name": "ユキレンガ物産 売上エージェント"}'
  COMMENT = 'CDDN#3 デモ用。売上の定量質問は Analyst、現場メモは Search に振り分ける。'
  FROM SPECIFICATION $$
models:
  orchestration: claude-sonnet-4-5
instructions:
  response: "日本語で簡潔に答える。金額は円、数量は個数で単位を明示する。"
  orchestration: "売上・数量・地域別・期間別など数値を伴う質問は SalesAnalyst を使う。背景・理由・現場の事情に関する質問は NotesSearch を使う。両方必要なら両方使う。"
tools:
  - tool_spec:
      type: "cortex_analyst_text_to_sql"
      name: "SalesAnalyst"
      description: "ユキレンガ物産の売上明細（地域・カテゴリ・商品・期間別の金額と数量）に関する定量的な質問に答える"
  - tool_spec:
      type: "cortex_search"
      name: "NotesSearch"
      description: "営業現場の日報メモを検索する。季節性や地域差の背景、個別案件の事情を調べるのに使う"
tool_resources:
  SalesAnalyst:
    semantic_view: "cddn_demo_db.cddn_3_demo.sales_sv"
    execution_environment:
      type: "warehouse"
      warehouse: "CDDN_DEMO_WH"
  NotesSearch:
    name: "cddn_demo_db.cddn_3_demo.sales_notes_search_svc"
    max_results: 5
$$;

-- 4-1. 【確認】Snowsight の Agent playground を開いて3問投げる
--   ・2025年1月に一番売れた商品は？                  → Analyst
--   ・北海道でレンガが売れないのはなぜ？              → Search
--   ・除雪用品の売上が一番多い月と、その理由を教えて  → 両方


-----------------------------------------------------------------
-- ⑤ MCP Server : Agent を1ツールとして公開
-----------------------------------------------------------------
CREATE OR REPLACE MCP SERVER cddn_demo_db.cddn_3_demo.cddn_mcp
  FROM SPECIFICATION $$
tools:
  - title: "ユキレンガ物産 売上エージェント"
    name: "yukirenga-sales-agent"
    type: "CORTEX_AGENT_RUN"
    identifier: "cddn_demo_db.cddn_3_demo.sales_agent"
    description: "株式会社ユキレンガ物産（除雪用品・レンガの商社）の売上データと営業現場メモに関する質問に答える。地域別・季節別の売上分析が得意。"
  $$;

DESCRIBE MCP SERVER cddn_demo_db.cddn_3_demo.cddn_mcp;

-- Databricks の HTTP Connection に設定する MCP Server の URL:
--   https://<SF_HOST>/api/v2/databases/cddn_demo_db/schemas/cddn_3_demo/mcp-servers/cddn_mcp


-----------------------------------------------------------------
-- ⑥ 権限  ★★★ ④⑤ を REPLACE したら毎回ここを再実行 ★★★
-----------------------------------------------------------------
USE ROLE ACCOUNTADMIN;

CREATE ROLE IF NOT EXISTS mcp_full_role;
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_AGENT_USER TO ROLE mcp_full_role;

-- 6-1. 親オブジェクト
GRANT USAGE ON WAREHOUSE cddn_demo_wh              TO ROLE mcp_full_role;
GRANT USAGE ON DATABASE  cddn_demo_db              TO ROLE mcp_full_role;
GRANT USAGE ON SCHEMA    cddn_demo_db.cddn_3_demo  TO ROLE mcp_full_role;

-- 6-2. MCP Server と Agent
GRANT USAGE ON MCP SERVER cddn_demo_db.cddn_3_demo.cddn_mcp    TO ROLE mcp_full_role;
GRANT USAGE ON AGENT      cddn_demo_db.cddn_3_demo.sales_agent TO ROLE mcp_full_role;

-- 6-3. Agent が内部で使うリソース
GRANT SELECT ON SEMANTIC VIEW cddn_demo_db.cddn_3_demo.sales_sv   TO ROLE mcp_full_role;
GRANT SELECT ON TABLE         cddn_demo_db.cddn_3_demo.sales_fact TO ROLE mcp_full_role;
GRANT USAGE  ON CORTEX SEARCH SERVICE
              cddn_demo_db.cddn_3_demo.sales_notes_search_svc     TO ROLE mcp_full_role;

-- 6-4. 【確認】
SHOW GRANTS TO ROLE mcp_full_role;


-----------------------------------------------------------------
-- ⑦ デモ用ユーザー : Databricks 側の OAuth ログインで使う
-----------------------------------------------------------------
CREATE USER IF NOT EXISTS cddn_3_demo_user
  TYPE = PERSON
  LOGIN_NAME = 'cddn_3_demo_user'
  EMAIL = '<EMAIL>'
  DEFAULT_ROLE = 'MCP_FULL_ROLE'
  DEFAULT_WAREHOUSE = 'CDDN_DEMO_WH'
  PASSWORD = '<INITIAL_PASSWORD>'
  MUST_CHANGE_PASSWORD = TRUE
  COMMENT = 'CDDN#3 demo';

GRANT ROLE mcp_full_role TO USER cddn_3_demo_user;

-- CREATE USER IF NOT EXISTS は既存ユーザーには何もしないため、
-- DEFAULT_ROLE / DEFAULT_WAREHOUSE を明示再セットする
-- （DEFAULT_WAREHOUSE が無いとセッション初期化が失敗する）
ALTER USER cddn_3_demo_user
  SET DEFAULT_ROLE = 'MCP_FULL_ROLE' DEFAULT_WAREHOUSE = 'CDDN_DEMO_WH';

-- ★ MUST_CHANGE_PASSWORD = TRUE のため、このユーザーで一度 Snowsight にログインして
--   パスワードを変更しておく。未変更のまま Databricks 側の OAuth ログインに進むと失敗する。


-----------------------------------------------------------------
-- ⑧ Security Integration : Databricks からの OAuth（U2M Per User）用
-----------------------------------------------------------------
CREATE OR REPLACE SECURITY INTEGRATION cddn_mcp_oauth
  TYPE = OAUTH
  OAUTH_CLIENT = CUSTOM
  OAUTH_CLIENT_TYPE = 'CONFIDENTIAL'
  ENABLED = TRUE
  OAUTH_REDIRECT_URI = 'https://<DBX_HOST>/login/oauth/http.html'
  OAUTH_USE_SECONDARY_ROLES = NONE
  OAUTH_ISSUE_REFRESH_TOKENS = TRUE
  OAUTH_REFRESH_TOKEN_VALIDITY = 86400
  ALLOWED_ROLES_LIST = ('MCP_FULL_ROLE')
  COMMENT = 'CDDN#3: Databricks Unity AI Gateway -> Snowflake MCP';

-- 8-1. client_id とエンドポイントを確認する
--   OAUTH_CLIENT_ID                        → Databricks の Connection に入れる
--   OAUTH_ALLOWED_AUTHORIZATION_ENDPOINTS  → 通常 https://<SF_HOST>/oauth/authorize
--   OAUTH_ALLOWED_TOKEN_ENDPOINTS          → 通常 https://<SF_HOST>/oauth/token-request
DESCRIBE SECURITY INTEGRATION cddn_mcp_oauth;

-- 8-2. client_secret を取得する（DESCRIBE には出ない。統合名は大文字で指定）
SELECT SYSTEM$SHOW_OAUTH_CLIENT_SECRETS('CDDN_MCP_OAUTH');
