## 概要

本リポジトリは、Code-Driven データ分析ナイト #3 AIエージェント共有（2026/8/12）における発表
「Unity AI Gateway 経由で Cortex Agents を呼び出してみよう」のデモで使用したスクリプト一式です。

Databricks の Unity AI Gateway から、Snowflake 上に構築した Cortex Agent を MCP 経由で呼び出します。

https://code-based-presentation.connpass.com/event/401427/

## アーキテクチャ

```
[Databricks]                                    [Snowflake]
ユーザー
  → Unity AI Gateway
      → MCP Service（Unity Catalog）
          → HTTP Connection ──────→ Security Integration
                                        → MCP Server
                                            → Cortex Agent
                                                ├→ Cortex Analyst（Semantic View）
                                                └→ Cortex Search（現場メモ）
```

構築は Snowflake 側（図の右）から Databricks 側（図の左）へ遡る順に行います。

仲介用リソースには MCP Service を使っています。Agent Service は Beta のため台帳登録のみでランタイム実行ができず、
Model Provider Service は chat / completions / embeddings に限られ、`http_request()` は非推奨になったためです。

認証は OAuth（U2M Per User）を採用しています。ユーザー単位で識別できるため、
Snowflake 側の監査ログに個人が残ります。PAT（Bearer Token）でも動きますが、全員が同じシステムユーザー権限になります。

## ディレクトリ構成

- `snowflake/setup.sql` : Snowflake 側の構築スクリプト（データ、Semantic View、Cortex Search、Cortex Agent、MCP Server、権限、Security Integration）
- `snowflake/teardown.sql` : 上記の削除スクリプト
- `databricks/SETUP.md` : Databricks 側の構築手順（HTTP Connection、MCP Service、権限、動作確認）

## 使用データ

架空の商社「株式会社ユキレンガ物産」の売上データを、スクリプト内で生成します。外部データは不要です。

- 除雪用品（冬 × 北日本に需要が偏る）とレンガ（春秋 × 西日本に需要が偏る）の2カテゴリ
- `sales_fact` : 2024-04 〜 2026-03 の売上明細。Cortex Analyst（Semantic View）の対象
- `sales_notes` : 営業担当の現場メモ 12件。Cortex Search の対象

季節性・地域差という数値で追える構造と、その背景が書かれたテキストを両方持たせることで、
Agent が Analyst と Search を使い分ける様子を確認できるようにしています。

## 前提環境

| 環境 | 条件 |
| --- | --- |
| Snowflake | Cortex Agents / Analyst / Search、MCP Server が利用できるアカウント。`ACCOUNTADMIN` 相当のロール |
| Databricks | Unity AI Gateway (Beta) と Managed MCP Servers プレビューが有効、Model Serving サポートリージョンのワークスペース |

Snowflake のトライアルアカウントでは Cortex AI が制限されるため、通常アカウントを推奨します。

## 実行手順

1. `snowflake/setup.sql` の冒頭のプレースホルダーを自分の環境の値に置き換える
2. `snowflake/setup.sql` を ⓪ から ⑧ まで順に実行する（⓪ でウェアハウス・データベース・スキーマも作成されます）
3. ④-1 のコメントに沿って、Snowsight の Agent playground で Agent 単体の動作を確認する
4. ⑦ で作成したデモ用ユーザーで一度 Snowsight にログインし、初期パスワードを変更する
5. ⑧ の出力から client_id / client_secret とエンドポイントを控える
6. `databricks/SETUP.md` に従って Databricks 側を構築する
7. AI Playground から MCP Service を呼び出す

片付けは Databricks 側（MCP Service → HTTP Connection）を先に削除してから、`snowflake/teardown.sql` を実行します。

## 注意

- スクリプト中の `<SF_HOST>` / `<DBX_HOST>` / `<EMAIL>` / `<INITIAL_PASSWORD>`、および `<catalog>.<schema>` はプレースホルダーです。実行時はご自身の環境の値に置き換えてください。client_id / client_secret はスクリプトに書き戻さず、Databricks の Connection にのみ設定してください。
- ウェアハウス名 `cddn_demo_wh` とデータベース名 `cddn_demo_db` は既存環境に合わせて変更できます。変更する場合は `snowflake/` の2ファイルと `databricks/SETUP.md` を揃えてください。
- `CREATE OR REPLACE AGENT` / `CREATE OR REPLACE MCP SERVER` を実行すると既存の GRANT が消えます。作り直した場合は `setup.sql` の ⑥ を必ず再実行してください。
- 本リポジトリは特定製品の優劣を示すものではありません。
