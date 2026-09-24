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
└─ logs

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
