# Databricks 側の構築手順

Snowflake の MCP Server（`cddn_demo_db.cddn_3_demo.cddn_mcp`）を Unity Catalog に登録し、
Unity AI Gateway 経由で Cortex Agent を呼び出すまでの手順。

先に `../snowflake/setup.sql` を ⓪ から ⑧ まで実行しておくこと。

## この手順で使う名前

| 項目 | 値 |
| --- | --- |
| Databricks カタログ / スキーマ | `<catalog>.<schema>`（既存のものを使う） |
| HTTP Connection 名 | `cddn_snowflake_mcp_conn` |
| MCP Service 名 | `<catalog>.<schema>.cddn_cortex_agent` |
| Snowflake ホスト | `<SF_HOST>`（例: `abc12345.ap-northeast-1.aws.snowflakecomputing.com`） |
| Databricks ワークスペース | `<DBX_HOST>`（例: `dbc-xxxxxxxx-xxxx.cloud.databricks.com`） |

## 0. 前提条件

- アカウントで **Unity AI Gateway (Beta)** と **Managed MCP Servers** のプレビューが有効になっていること。アカウントコンソールの Previews ページから有効化する。
- ワークスペースが Model Serving のサポートリージョンにあること。
- 必要な権限
  - Connection 作成: スキーマに対する `CREATE CONNECTION`
  - MCP Service 作成: `USE CATALOG` / `USE SCHEMA`、スキーマに対する `CREATE SERVICE`、参照する Connection に対する `USE CONNECTION`
  - MCP Service 呼び出し: MCP Service に対する `EXECUTE`

## 1. Snowflake 側から控えておく値

`setup.sql` の ⑧ で作成した Security Integration から取得する。

```sql
-- client_id とエンドポイント
DESCRIBE SECURITY INTEGRATION cddn_mcp_oauth;

-- client_secret（DESCRIBE には出ない。統合名は大文字で指定）
SELECT SYSTEM$SHOW_OAUTH_CLIENT_SECRETS('CDDN_MCP_OAUTH');
```

| 用途 | 取得元 |
| --- | --- |
| Client ID | `DESCRIBE` の `OAUTH_CLIENT_ID` |
| Client secret | `SYSTEM$SHOW_OAUTH_CLIENT_SECRETS` の `OAUTH_CLIENT_SECRET` |
| Authorization endpoint | `DESCRIBE` の `OAUTH_ALLOWED_AUTHORIZATION_ENDPOINTS`（通常 `https://<SF_HOST>/oauth/authorize`） |
| Token endpoint | `DESCRIBE` の `OAUTH_ALLOWED_TOKEN_ENDPOINTS`（通常 `https://<SF_HOST>/oauth/token-request`） |

Security Integration 側の `OAUTH_REDIRECT_URI` には `https://<DBX_HOST>/login/oauth/http.html` を設定しておく。

## 2. HTTP Connection を作成する

**Catalog** > **Connections** > **Create connection** から作成する。

| 項目 | 値 |
| --- | --- |
| Connection name | `cddn_snowflake_mcp_conn` |
| Connection type | HTTP |
| Auth type | **OAuth User to Machine Per User** → **Manual Configuration** |
| Host | `https://<SF_HOST>` |
| Port | `443` |
| Base path | `/api/v2/databases/cddn_demo_db/schemas/cddn_3_demo/mcp-servers/cddn_mcp` |
| Client ID / Client secret | 手順 1 の値 |
| OAuth scope | `refresh_token session:role:mcp_full_role` |
| Authorization endpoint | `https://<SF_HOST>/oauth/authorize` |
| Token endpoint | `https://<SF_HOST>/oauth/token-request` |
| OAuth credential exchange method | `header_and_body`（既定） |

Connection は MCP Service と同じスキーマ配下に作成する。メタストアレベルでも作成できるが推奨されない。

> **scope の注意**
> - `refresh_token` を含めないとトークンが約10分で失効し、デモ中に落ちる。
> - `session:role:all` を指定すると `BLOCKED_ROLES_LIST` に引っかかってエラーになる。ロールは明示指定する。

## 3. MCP Service を作成する

**AI Gateway** > **MCPs** > **Register MCP Server**、または **Catalog** でスキーマを選んで **Create** > **MCP Service**。

1. カタログ、スキーマ、名前を入力する（名前は作成後に変更できない）
2. 手順 2 で作成した HTTP Connection を選択する
3. **Tools** で公開するツールを選択する。今回は Snowflake 側で 1 ツール（`yukirenga-sales-agent`）しか公開していないため、全選択で問題ない
4. **Create**

MCP Service に SQL DDL は用意されていない。UI か REST API のみ。

REST API の場合:

```bash
databricks api post \
  "/api/2.1/unity-catalog/mcp-services?parent=schemas/<catalog>.<schema>&mcp_service_id=cddn_cortex_agent" \
  --json '{
    "comment": "CDDN#3: Snowflake Cortex Agent via MCP",
    "config": {
      "source_connection": {
        "name": "connections/<catalog>.<schema>.cddn_snowflake_mcp_conn"
      },
      "include_tool_selectors": []
    }
  }'
```

`include_tool_selectors` を空リストにすると全ツールを公開する。前方一致（`get_*`）と完全一致のパターンが使えるが、除外パターン（`!delete_*`）は使えない。

## 4. OAuth ログイン（初回のみ）

Per-user OAuth を使う Connection では、初回呼び出し前に一度ログインが必要。

1. Catalog Explorer で MCP Service の詳細ページを開く
2. **Login** をクリックし、Snowflake の認証を完了する
3. サインイン後、詳細ページに検出されたツール一覧が表示される

ログイン前に呼び出すと、AI Gateway が認証を促すエラーを返す。

> ログインに使うのは `setup.sql` の ⑦ で作成した `cddn_3_demo_user`（`MUST_CHANGE_PASSWORD = TRUE` のため、
> 先に Snowsight で初期パスワードを変更しておく）。自分の Snowflake ユーザーで入る場合は、
> そのユーザーに `mcp_full_role` を付与しておく。

## 5. 権限を付与する

既定では MCP Service のオーナーしか呼び出せない。

1. Catalog Explorer で MCP Service を開く（または **AI Gateway** > **MCPs**）
2. **Permissions** タブ > **Grant**
3. 対象のユーザー / グループ / サービスプリンシパルを選択
4. **EXECUTE** を付与

`EXECUTE` 1つで、その Service が公開する全ツールをカバーする。

```bash
databricks api patch \
  "/api/2.1/unity-catalog/permissions/mcp_service/<catalog>.<schema>.cddn_cortex_agent" \
  --json '{ "changes": [ { "principal": "<group>", "add": ["EXECUTE"] } ] }'
```

> **`USE CONNECTION` を利用者に付与しないこと**
> MCP Service の呼び出しに Connection 側の権限は不要。`USE CONNECTION` を付与すると、
> Connection 経由で外部サーバーを直接叩いたり、自分で別の MCP Service を登録したりできてしまい、
> ツール選択・service policy・監査をすべて迂回される。Connection へのアクセスは作成者と管理者に限定する。

## 6. 動作確認

### AI Playground

1. **AI Playground** を開く
2. **Tools enabled** ラベルのついたモデルを選択
3. **Tools** > **+ Add tool** > **MCP Servers**
4. **External MCP servers** から作成した MCP Service を選択
5. 質問を投げる

デモで使った質問:

- 2025年1月に一番売れた商品は？ → Cortex Analyst
- 北海道でレンガが売れないのはなぜ？ → Cortex Search
- 除雪用品の売上が一番多い月と、その理由を教えて → 両方

### CLI

```bash
databricks auth login --host https://<DBX_HOST>
TOKEN=$(databricks auth token | jq -r .access_token)

# ツール一覧（arguments のキー名は返ってくる inputSchema で確認する）
curl -s -X POST \
  "https://<DBX_HOST>/ai-gateway/mcp-services/<catalog>.<schema>.cddn_cortex_agent" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Accept: application/json, text/event-stream" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'

# ツール呼び出し（<key> は上の inputSchema に合わせる）
curl -s -X POST \
  "https://<DBX_HOST>/ai-gateway/mcp-services/<catalog>.<schema>.cddn_cortex_agent" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Accept: application/json, text/event-stream" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"yukirenga-sales-agent","arguments":{"<key>":"2025年1月に一番売れた商品は？"}}}'
```

## 片付け

Snowflake 側より先に、この手順で作ったものを削除する（MCP Service → HTTP Connection の順）。
Connection を残したまま Snowflake の Security Integration を消すと、認証だけ失敗する Connection が残る。

## 参考

- [Connect agents to third-party tools with MCP Services](https://docs.databricks.com/aws/en/agents/mcp/mcp-services)
- [Register an external MCP server](https://docs.databricks.com/aws/en/ai-gateway/register-mcp-service)
- [Connect to external HTTP services](https://docs.databricks.com/aws/en/query-federation/http)
- [Govern an MCP service](https://docs.databricks.com/aws/en/ai-gateway/govern-mcp-service)
