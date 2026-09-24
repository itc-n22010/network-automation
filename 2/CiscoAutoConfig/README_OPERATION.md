# CiscoAutoConfig 運用変更README

このファイルは、キッティング内容を変更するときに運用担当者が編集する場所だけを
まとめたものです。

## 編集してよいファイル

通常の運用変更では、次のファイルだけを編集します。

| 変更内容 | 編集するファイル |
|---|---|
| 機器ごとのシリアル番号、ホスト名、IP、パスワード | `config\devices.csv` |
| Ciscoへ投入するコマンド | `templates\*.template.txt` |
| ホスト名とテンプレートの割り当て | `config\settings.json` の `TemplateRules` |
| Ciscoの対話プロンプトと応答 | `config\settings.json` の `DialogRules` |
| 必須CSV列 | `config\settings.json` の `RequiredCsvFields` |
| 通信速度、タイムアウト、保存先 | `config\settings.json` の該当項目 |
| 長時間かかる特定コマンドの待機時間 | `config\settings.json` の `CommandTimeoutRules` |

`Run-CiscoAutoConfig.ps1`、`Generate-Configs.ps1`、`templates\cisco_build.ttl`、
BATファイルは、通常の運用変更では編集しません。

## 1. 機器情報を変更する

編集ファイル:

`config\devices.csv`

1行が1台分です。`SerialNumber`は機器から取得したシリアル番号と完全一致させます。
同じシリアル番号を複数行に登録しないでください。

```csv
SerialNumber,DeviceID,Hostname,ManagementIP,SubnetMask,DefaultGateway,EnablePassword,ConsolePassword,SshUsername,SshPassword,SshDomain,SshKeyBits
FOC1349W2H0,EDGE-002,A-C2960-ije92,192.0.2.12,255.255.255.0,192.0.2.1,ChangeMeEnable,ChangeMeConsole,admin,ChangeMeSsh,example.local,2048
```

実運用ではサンプルパスワードを必ず変更し、CSVファイルのアクセス権を制限してください。
パスワードは平文で保存されるため、ログや画面共有へ出さないでください。

## 2. ホスト名ごとのテンプレートを変更する

編集ファイル:

`config\settings.json`

`TemplateRules`の`HostnamePattern`がCSVの`Hostname`に一致すると、指定された
`Template`が選択されます。現在の設定例:

```json
{
  "Id": "c2960-stn01",
  "HostnamePattern": "^A-C2960-[A-Za-z0-9_-]+$",
  "Template": "templates\\cisco_config_c2960_stn01.template.txt"
}
```

例えば実際のホスト名が`A-C2960-ije92`なら、上の規則に一致します。

### 正規表現の基本例

| 目的 | `HostnamePattern` |
|---|---|
| 完全一致 | `^A-C2960-ije92$` |
| 後半を任意にする | `^A-C2960-[A-Za-z0-9_-]+$` |
| `A-C2960-`で始まる任意の文字列 | `^A-C2960-.*$` |
| 2種類の固定文字列 | `^(A-C2960|A-C3750)-[A-Za-z0-9_-]+$` |

安全のため、通常は`^`と`$`を付け、意図しないホスト名まで一致しないようにします。
1つのホスト名に一致するルールは必ず1件だけにしてください。0件または複数件の場合は、
誤ったテンプレートを投入せず停止します。

### 新しいテンプレートを追加する

1. `templates`フォルダーにテンプレートファイルを作成する。
2. `settings.json`の`TemplateRules`へルールを追加する。
3. `devices.csv`の`Hostname`を確認する。

例:

```json
{
  "Id": "new-c2960",
  "HostnamePattern": "^A-C2960-NEW-[A-Za-z0-9_-]+$",
  "Template": "templates\\cisco_config_c2960_new.template.txt"
}
```

## 3. Cisco投入コマンドを変更する

編集ファイル:

該当する`templates\*.template.txt`

CSVの列は`{{列名}}`で参照します。

```text
hostname {{Hostname}}
interface Vlan1
 ip address {{ManagementIP}} {{SubnetMask}}
 description {{Description}}
```

CSVに新しい列を追加してテンプレートで使うだけなら、PS1の変更は不要です。
テンプレートに存在しないCSV列は、設定へ自動投入されません。

設定コマンドの空行、`!`、`end`は自動的に除外されます。危険なコマンド
(`write erase`、`erase startup-config`、`reload`)は追加しないでください。

## 4. 対話プロンプトを変更する

編集ファイル:

`config\settings.json` の `DialogRules`

初回起動時の対話は、次の形式で追加・変更します。

```json
{
  "Id": "continue-setup-no",
  "Pattern": "Continue with setup\\?\\s*\\[yes/no\\]\\s*:",
  "Response": "no",
  "AppendEnter": true,
  "MaxMatches": 1
}
```

設定投入中にも対応させる場合は`TtlPrompt`を追加します。

```json
{
  "Id": "confirm-example",
  "Pattern": "Continue with setup\\?\\s*\\[yes/no\\]\\s*:",
  "TtlPrompt": "Continue with setup?",
  "Response": "no",
  "AppendEnter": true,
  "MaxMatches": 1
}
```

`TtlPrompt`を設定するルールは、`Response`を定義し、
`AppendEnter`を`true`にしてください。パスワードや秘密鍵をDialogRulesへ追加しないでください。

不要なルールは、ルールオブジェクト全体を削除します。`Id`だけを削除した不完全な
オブジェクトは残さないでください。

## 5. 必須CSV列を変更する

編集ファイル:

`config\settings.json` の `RequiredCsvFields`

空欄を許可しない列を登録します。

```json
"RequiredCsvFields": [
  "SerialNumber",
  "DeviceID",
  "Hostname",
  "ManagementIP",
  "Description"
]
```

テンプレートで使う列は、原則として必須列へ追加してください。CSVに列がない、
または値が空欄の場合は設定投入前に停止します。

## 6. 変更後の確認

1. JSONのカンマ、引用符、括弧を確認する。
2. `devices.csv`をUTF-8 CSVで保存する。
3. BATを実行する前に、生成だけを実行する。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Generate-Configs.ps1
```

4. `generated`の内容が意図したコマンドになっていることを確認する。
5. 検証用機器1台で`Run-CiscoAutoConfig.bat`を実行する。
6. `logs`と`results`で、対象シリアル番号、テンプレート内容、`SUCCESS`を確認する。

ホスト名に一致するテンプレートがない場合、CSV不備やテンプレート不備がある場合は、
安全のため設定を投入しません。

## 長時間コマンドの待機時間

通常のコマンドは`CommandTimeoutSeconds`（既定12秒）で待機します。SD-WANなどで
`commit`に時間がかかる場合は、`CommandTimeoutRules`へコマンドの正規表現と秒数を
登録します。現在は`commit`を最大300秒待機する設定です。

```json
"CommandTimeoutRules": [
  {
    "Id": "sdwan-commit",
    "Pattern": "^commit(?:\\s|$)",
    "TimeoutSeconds": 300
  }
]
```

テンプレート内のコマンドは一括送信されません。空行と`!`を除く各行について、
`sendln`で1行送信し、Ciscoプロンプトまたは`TtlPrompt`を`wait`してから次の行へ
進みます。`commit`も同じ動作ですが、上記の長いタイムアウトを使用します。

`Erasing the nvram filesystem will remove all configuration files! Continue? [confirm]`
のような初期化・消去確認が表示された場合も、自動で`confirm`を送信しません。
機器のコンソールで現在の操作を確認し、手動で中止または完了させてから、機器が
通常の`Switch>`または`Switch#`プロンプトに戻った状態で再実行してください。

## 編集しないファイル

次のファイルは、運用上の設定変更では編集しません。

- `Run-CiscoAutoConfig.ps1`
- `Generate-Configs.ps1`
- `templates\cisco_build.ttl`
- `Run-CiscoAutoConfig.bat`

これらを変更する必要がある場合は、実機投入前にスクリプトの検証とテストを行ってください。
