# CiscoAutoConfig

運用時に編集するファイルだけを確認する場合は、
[README_OPERATION.md](D:/network/work/CiscoAutoConfig/README_OPERATION.md)を参照する。

## 目的と設計上の問題点

COM番号はPC・ドライバー・接続順で変わるため固定できない。そこで
`Win32_SerialPort`で列挙した全COMに対してTera Termを実際に接続し、改行、
`show version`、`show inventory`を送る。ログ中にCisco形式のプロンプトと
シリアル番号が揃わないポートは設定対象にしない。

シリアル番号は機種・IOS・出力形式で異なるため、現在は`Processor board ID`,
`System serial number`, `SN`を正規表現で抽出する。未知の出力形式は安全側に
倒れて不一致になる。CSV内の重複、未登録、取得不能、Cisco未検出は全て設定を
投入しない。USBケーブルは1本なので、1台完了後にユーザーがケーブルを次の
機器へ差し替えて再実行する。

## 処理フロー

1. 設定・CSVを読み込む。
2. 利用可能なCOMを列挙し、各ポートへTera Termで実通信する。
3. `show version`/`show inventory`の受信ログからCiscoプロンプトとシリアル番号を確認する。
4. CSVのシリアル番号と一意に照合する。
5. 画面にCOM、シリアル、DeviceID、ホスト名、IPを表示する。
6. enable、configure terminal、機器別コマンド、copy running-config startup-configを実行する。
7. Ciscoエラーまたは成功マーカーを確認し、機器別ログと結果CSVに記録する。

プローブ中のコマンドは、各コマンドの後にCiscoプロンプトが戻るまで待ってから
次のコマンドを送信する。`terminal length 0`でページングを無効化し、
`--More--`が返った場合はスペースを送信するため、長い`show version`出力でも
次のコマンドと連結しない。

危険な`write erase`、`erase startup-config`、`reload`はコードに存在しない。
パスワードはTTLの送信にのみ使用し、ログへ書き込む`logwrite`には含めない。
機器ログ本文にはTera Termの行単位タイムスタンプを付けない。実行日時は
結果CSVの`Timestamp`列とログファイル名で記録する。

## フォルダー構成

`Run-CiscoAutoConfig.ps1`が実行本体、`Generate-Configs.ps1`が設定ファイル
生成専用、`templates`がTTL/設定テンプレート、`config`が入力、`logs`が受信
ログ、`results`が結果CSV、`backup`が将来のバックアップ領域である。

テンプレートの設定コマンドは一括送信せず、1行ずつ送信してCiscoプロンプトを待機する。
長時間かかる`commit`などの待機時間は`config\settings.json`の
`CommandTimeoutRules`で設定する。

## セットアップ

1. Windows 11にTera Termをオフライン導入し、`config\settings.json`の
   `TeraTermMacro`を実際の`ttpmacro.exe`へ変更する。
2. `config\devices.csv`をUTF-8 CSVで編集し、必要な機器情報を登録する。
   CSV列の変更・削除に合わせて`config\settings.json`の`CsvColumns`を編集する。
   `RequiredCsvFields`は使用せず、シリアル番号列のみ一意照合のため必須。
3. コンソール設定を機器に合わせる。TTLはCisco標準の9600/8/N/1を前提とする。
4. PowerShell実行ポリシーに応じて、管理者判断で
   `Set-ExecutionPolicy -Scope Process Bypass`を実行する。

## 実行

通常運用では、コンソールケーブルを対象機器へ接続して
`Run-CiscoAutoConfig.bat`をダブルクリックするだけでよい。BATはメニューを
表示せず、検出したCOMポートのうちCisco応答があるポートを1つだけ選び、
取得したシリアル番号に一致するCSV行の設定を自動投入する。

```powershell
.\Run-CiscoAutoConfig.ps1 -Selection All
.\Run-CiscoAutoConfig.ps1 -Selection Pending
.\Run-CiscoAutoConfig.ps1 -Selection Failed
.\Run-CiscoAutoConfig.ps1 -Selection Serial -SerialNumber FTX00000001
.\Run-CiscoAutoConfig.ps1 -Selection GenerateOnly
```

BAT実行後は確認入力なしで自動投入する。ただし、COMポートの実通信、
Ciscoプロンプト検出、シリアル番号取得、CSVとの一意な照合が全て成功した
機器だけを対象とする。照合失敗、取得不能、重複、Cisco未検出の場合は
設定を投入しない。

COMポートが複数見えても、Cisco応答があるポートを実通信で判定する。
ポートを開けない場合やCiscoプロンプトが返らない場合は、そのポートを
未実施として結果CSVへ記録し、別ポートの判定を続ける。

現在のCSVサンプルには、初回キッティング用のSSH設定も含まれる。投入される
SSH設定は、ドメイン名、ローカルユーザー、SSH version 2、VTYの
`login local`、`transport input ssh`である。RSA鍵は自動生成しない。
SSHサーバーを利用する場合は、機器と運用要件に適した鍵を別途生成する必要がある。

## CSV列と機器別設定

シリアル番号がCSVと一致した後、`TemplateRules`がCSVの指定列を照合し、
機器用の設定を選択する。CSV列名は`CsvColumns`で意味項目に対応付ける。
不要なCSV列と未使用の`CsvColumns`項目は削除できる。照合に使うシリアル列だけは
必須である。

各テンプレート規則には`MatchField`、`Pattern`と、`Template`または`Commands`を指定する。
`Commands`はJSON内にCiscoコマンドを直接書く方式であり、機器切替時にCSVとJSONだけを
編集したい場合に利用する。テンプレートまたはコマンド内の`{{列名}}`はCSV値で置換される。
`CsvColumns`でマッピングした意味項目名もプレースホルダーとして利用できる。

`Pattern`はPowerShell正規表現である。一致するルールが0件または複数件の場合は、
誤った設定の投入を防ぐため停止する。CSVから削除した項目をコマンドやテンプレートが
参照している場合も、プレースホルダー検査で投入前に停止する。

初回起動時にCiscoが表示する既知の対話には自動応答する。初期設定ダイアログと
暗号関連のyes/no確認は安全側の`no`、autoinstall終了確認は`yes`、`Press RETURN`
はEnterを送信する。ユーザー名、パスワード、enable secretなど値の不明な入力を
推測して送信することはなく、未対応の対話は設定投入せず失敗として記録する。

対話ルールは [config/settings.json](D:/network/work/K/CiscoAutoConfig/config/settings.json)
の`DialogRules`で編集できる。各ルールは`Id`、PowerShell正規表現の`Pattern`、
送信文字列の`Response`、末尾にEnterを送るかの`AppendEnter`、同じルールを
何回まで使うかの`MaxMatches`を持つ。Tera Termマクロで待機するルールには
固定部分を指定する`TtlPrompt`も設定する。例えば任意の確認対話には次のようなルールを追加する。

```json
{
  "Id": "continue-setup",
  "Pattern": "Continue with setup\\?\\s*\\[yes/no\\]\\s*:",
  "TtlPrompt": "Continue with setup?",
  "Response": "no",
  "AppendEnter": true,
  "MaxMatches": 1
}
```

`TtlPrompt`を持つルールは、設定コマンド実行時にも待機対象になります。
質問文が検出されると`Response`を送信し、Ciscoプロンプトへ戻るまで待機します。
この機能を使うルールは`AppendEnter: true`にしてください。`TtlPrompt`を追加した
ルールの`Response`が未定義、または`AppendEnter`が`false`の場合は、危険な推測送信を
せず、マクロ生成前にエラーとして停止します。

機器やIOSで表示文が違う場合は、実際のログに出た質問文を`Pattern`へ正規表現
として登録する。順序は配列の上から評価される。パスワードや秘密鍵などの値を
ログや設定ファイルへ平文で保存するルールは追加しないこと。

また、実行前に生成されたTera Termマクロ内の`{{...}}`未置換プレースホルダーを検査する。
残っている場合は設定投入を開始せず、エラーとして停止する。

## 動作確認

まず実機ではなく、1台の検証用Cisco機器で実行する。`logs`で送信結果と
Cisco応答を確認し、`results`でSUCCESS/FAILED/SERIAL_MISMATCH等を確認する。
意図的にCSVのシリアルを変更し、設定が投入されず`SERIAL_MISMATCH`になること、
コマンドを検証環境だけで誤入力し`FAILED`になることを確認する。

## エラー対処と再実行

COM未検出はケーブル、ドライバー、別プロセスのCOM占有を確認する。
Ciscoプロンプト未検出はコンソール速度、ケーブル、端末状態を確認する。
シリアル不一致は`show version`ログとCSVを比較する。FAILED後は原因を解消し、
`-Selection Failed`またはシリアル指定で再実行する。設定保存完了を確認できない
場合は成功扱いにしない。

## 制限事項

Cisco IOS系の対話プロンプトを想定し、ROMMON、バナー、enableパスワード要求の
特殊形式、複数台同時接続、IOS XR/NX-OSの差異は未検証である。シリアル抽出の
正規表現に合わない機種は安全側に未実施となる。Tera Term 5.xで文法を確認した
コマンドだけを使用しているが、実機での全IOS組合せは未検証である。

## 安全チェックリスト

- [ ] CSVのシリアル番号が実機ラベル/`show version`と一致している
- [ ] 重複シリアルがない
- [ ] 管理IP・マスク・ゲートウェイをレビューした
- [ ] まず1台でログと結果を確認した
- [ ] コンソールケーブルが対象機器だけに接続されている
- [ ] 自動投入対象のCOM、シリアル番号、DeviceID、ホスト名、IPを実行前に確認した
- [ ] `write erase`/`erase startup-config`/`reload`がない
- [ ] `logs`と`results`を保護した
