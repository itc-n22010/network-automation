Network Console Automation

ネットワーク機器へコンソール接続し、指定したコマンドを自動実行してログを保存します。

フォルダ構成
NetworkConsole
├─ Run-ALL.bat
├─ Run-Select.bat
├─ network\_console\_auto.ps1
├─ NetworkConsole.ttl
├─ commands
│  ├─ test-01.txt
│  ├─ test-02.txt
│  └─ ...
├─ logs
└─ check
  ├─ index.html
  └─ check-tool.js

実行方法
全テストを実行

Run-ALL.bat をダブルクリックします。

commands フォルダ内のテストを上から順番に実行します。

テストを選択して実行

Run-Select.bat をダブルクリックします。

表示された一覧から実行するテストを選択します。

コマンドを追加・変更する

commands フォルダの .txt ファイルを編集します。

例：

terminal length 0
show clock
show version



ここに書いたコマンドだけが実行されます。

空行と # から始まる行は実行されません。

ログ

実行結果は機器のホスト名ごとに保存されます。

logs
└─ Allied-SW-01
├─ test-01.log
└─ test-02.log



ログには、機器から実際に返ってきたコンソール内容がそのまま保存されます。

機器結果の照合

オフライン端末では、ブラウザで `check\index.html` を開きます。

1. `Run-ALL.bat` でテストを実行します。
2. `logs` の中から対象機器名のフォルダーを選択します。通常操作はこれだけです。
3. 条件CSVと `CiscoAutoConfig/config/devices.csv` は自動で読み込まれ、フォルダー内の各ログがコマンド単位で判定されます。
4. 表示されたPASS / FAILを確認します。自動CSVを読めない場合は結果欄に理由が表示されます。

`show version` は期待する機器シリアル番号、`show run` は必須設定と禁止設定、
その他のコマンドは出力に含む文字列・含まない文字列を指定できます。
テストケースや条件を変更する担当者は `check/test-rules.csv` を編集します。変更後にページを再読み込みすると反映されます。
条件CSVは `CommandPattern,Type,Required,Forbidden` 列を使います。`CommandPattern` はコマンドに
照合する正規表現で、上から最初に一致した行を使います。Type は `auto`（従来の自動判定）、
`text`、`config`、`serial`、`setup` を指定できます。`setup` は出力内容を照合せず、コマンドエラーがなく
プロンプトへ戻ったことを確認します。Required / Forbidden は複数行を指定でき、
CSVではセルをダブルクォートで囲んで改行してください。コマンドの追加・変更や固定文字列の変更は
このCSVで行えます。条件CSVに一致するコマンドでは、CSVのRequired / Forbiddenが画面入力値より優先されます。

Required / Forbidden や画面入力には `${列名}` を指定でき、機器CSVの該当行の値に置き換えて照合します
（例：`${ManagementIP}`）。機器行はログ内のシリアル番号を優先して特定し、見つからない場合は
ログフォルダー名とCSVの `Hostname` / `DeviceID` を照合します。機器行や列を特定できない場合は
未判定として表示します。
`terminal length 0` はログで実行とプロンプト復帰を確認します。
期待値はブラウザに保存され、次回同じ機器・テストのログを開くと復元されます。
画面で個別に入力した条件はコマンド文字列ごとに保存されるため、項番の追加や並べ替えで別コマンドへ移りません。
設定照合は設定行の有無を確認するもので、設定全体の意味的な正しさまでは検証しません。

注意

USB-シリアルを接続してから実行してください。

Tera Termなど、COMポートを使用するソフトは閉じてください。

コンソール設定は 9600 / 8 / N / 1 です。

network\_console\_auto.ps1 は通常変更しません。

実行するコマンドは必ず commands のファイルで確認してください。

ページャ（`--More--`、`More:` など）が表示される機器では、継続キー
（スペース）を自動送信します。そのため `show logging` のような大量出力でも、
ページャで停止したままになりません。プロンプトは
`hostname#` / `hostname>` に加えて `hostname(config)#` の形式にも対応します。

COMポートを自動判定できない端末では、PowerShellからポートを明示できます。
ネットワーク接続は使用しません。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\network_console_auto.ps1 `
  .\commands\test-01.txt `
  -PortName COM3 `
  -BaudRate 9600
```

通常は9600 baudです。機器側が115200などに変更されている場合は、
`-BaudRate 115200` のように機器と同じ値を指定してください。

コマンド単位の待機時間を変更する場合（秒、既定30分）：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\network_console_auto.ps1 `
  .\commands\test-01.txt `
  -PortName COM3 `
  -CommandTimeoutSeconds 3600
```

うまく動かない場合
Access to the port 'COMx' is denied

他のソフトがCOMポートを使用しています。

Tera Termなどを閉じて再実行してください。

No responding console port found

USB-シリアル接続、COMポート、コンソール設定を確認してください。

Login prompt timeout

機器からログイン画面が返っているか確認してください。

`show logging` などで止まる場合は、まず `--More--` が表示されていないか確認
してください。新しい実装では自動継続します。なお、失敗してもホスト名を検出
する前の受信データは `logs\unidentified\コマンド名.log` に保存されます。

通常の運用では Run-ALL.bat または Run-Select.bat を実行するだけです。

Tera Termを使う場合

PowerShellを使えない端末では、`NetworkConsole.ttl` をTera Term Macro
（`ttpmacro.exe`）で実行できます。ファイル冒頭の以下を機器に合わせて変更します。

- `COM_PORT`：COM番号（例：3）
- `BAUD_RATE`：通信速度（通常9600）
- `USERNAME` / `PASSWORD`
- `ENABLE_PASSWORD`
- `COMMAND_FILE`

TTL版も `commands` のコマンドファイルを読み込み、`--More--` などのページャには
スペースを送信して継続し、受信内容を `logs` フォルダへ保存します。ネットワーク接続は
使用しません。Tera Term本体で先にCOMポートを開く必要はありません。

実行するコマンドファイルは、`NetworkConsole.ttl` 冒頭の
`COMMAND_FILE = 'commands\test-01.txt'` を変更してください。Tera Term Macroの
古いバージョンでも動作するよう、マクロ引数取得コマンドは使用していません。

TTL版は古いTera Termとの互換性を優先し、`wait` は必ず1個の固定文字列だけを
待ちます。ログイン画面が `login:`、`Username:`、`Password:` のいずれでも
ない場合は、[NetworkConsole.ttl](./NetworkConsole.ttl) の待機文字列を機器の
表示に合わせて変更してください。
