# CiscoAutoConfig 運用変更ガイド

機器を切り替えるときの設定変更は、原則として
`config\devices.csv`と`config\settings.json`だけで行います。
PowerShellスクリプトの編集や`RequiredCsvFields`の保守は不要です。

## CSV列を機器ごとに変更する

CSVは1行が1台です。照合に必要なシリアル番号列だけは必須です。
列名は自由にできますが、`settings.json`の`CsvColumns.SerialNumber`を
実際の列名に合わせてください。他の列は、使用しないならCSVから削除できます。

例：CSVの識別列が`Serial`で、機器名が`Name`の場合:

```json
"CsvColumns": {
  "SerialNumber": "Serial",
  "DeviceID": "AssetTag",
  "Hostname": "Name",
  "ManagementIP": "MgmtAddress",
  "ConsolePassword": "ConsoleSecret"
}
```

未使用のマッピングは削除して構いません。未設定の意味項目は、既定で同名のCSV列を
探します。テンプレートやJSON内コマンドが参照するCSV列は、その設定に必要です。
必要な列がない、またはテンプレート置換後に`{{...}}`が残る場合は投入前に停止します。

## 機器ごとの設定コマンド

`TemplateRules`で照合に使う列と正規表現を指定します。`MatchField`はCSV列名または
`CsvColumns`の意味項目名です。一致ルールは必ず1件にしてください。

テンプレートファイルを変更せずに運用する場合は、ルールへ`Commands`を直接記載します。
コマンド中の`{{CSV列名}}`または`{{CsvColumnsの意味名}}`はCSV値に置換されます。

```json
{
  "Id": "switch-type-a",
  "MatchField": "Model",
  "Pattern": "^C3750$",
  "Commands": [
    "hostname {{Name}}",
    "interface Vlan1",
    "ip address {{MgmtAddress}} {{Mask}}",
    "no shutdown",
    "exit",
    "ip default-gateway {{Gateway}}"
  ]
}
```

`Commands`の代わりに既存テンプレートを使うこともできます。

```json
{
  "Id": "switch-type-b",
  "MatchField": "Model",
  "Pattern": "^C2960$",
  "Template": "templates\\cisco_config_c2960_stn01.template.txt"
}
```

正規表現はPowerShell形式です。意図しない機器へ一致しないよう、通常は`^`と`$`を
付けます。0件または複数件一致の場合、設定は投入されません。

## 対話プロンプト

初回起動時の対話や、設定中の対話は`DialogRules`で管理します。
設定中にも応答させるルールには`TtlPrompt`を設定します。

```json
{
  "Id": "setup-confirm",
  "Pattern": "Continue with setup\\?\\s*\\[yes/no\\]\\s*:",
  "TtlPrompt": "Continue with setup?",
  "Response": "no",
  "AppendEnter": true,
  "MaxMatches": 1
}
```

未登録プロンプトへは推測応答しません。パスワードや秘密鍵などの機密値を
`Response`へ記載しないでください。

## CSVの例

```csv
Serial,AssetTag,Model,Name,MgmtAddress,Mask,Gateway,ConsoleSecret
FOC1349W2HK,SW-001,C3750,A-C3750-01,192.0.2.11,255.255.255.0,192.0.2.1,ChangeMe
```

シリアル番号は機器から取得した値と一意に一致させてください。
重複、欠落、照合不一致があれば設定しません。

## 変更後の確認

1. `devices.csv`と`settings.json`を保存する。
2. `settings.json`が有効なJSONであることを確認する。
3. `Generate-Configs.ps1`を実行し、生成内容を確認する（テンプレート方式の場合）。
4. 検証用機器1台で実行し、`logs`と`results`を確認する。
5. 本番機器へ適用する。

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
