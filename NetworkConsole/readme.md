Network Console Automation

ネットワーク機器へコンソール接続し、指定したコマンドを自動実行してログを保存します。

フォルダ構成
NetworkConsole
├─ Run-ALL.bat
├─ Run-Select.bat
├─ network\_console\_auto.ps1
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

うまく動かない場合
Access to the port 'COMx' is denied

他のソフトがCOMポートを使用しています。

Tera Termなどを閉じて再実行してください。

No responding console port found

USB-シリアル接続、COMポート、コンソール設定を確認してください。

Login prompt timeout

機器からログイン画面が返っているか確認してください。

通常の運用では Run-ALL.bat または Run-Select.bat を実行するだけです。

