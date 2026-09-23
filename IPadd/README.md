IP Add / Delete Tool

WindowsのNICに、CSV記載のIPアドレスを追加・削除するツールです。

1. ファイル構成
IPadd\
├─ ip_manage.ps1
└─ secondary_ips.csv

2. CSVを編集

secondary_ips.csv に設定するIPを記載します。

IPAddress,PrefixLength,DefaultGateway
192.168.1.20,24,
192.168.1.21,24,
192.168.2.20,24,192.168.2.1


IPAddress：IPアドレス

PrefixLength：サブネット（通常 24）

DefaultGateway：ゲートウェイ。不要なら空欄

3. 実行

管理者としてPowerShellを起動し、以下を実行します。

cd D:\network\work\K\IPadd
.\ip_manage.ps1

4. NICを選択

表示されたNICから対象を番号で選択します。

Select Target NIC:

  1 : Wi-Fi
  2 : VMware Network Adapter VMnet1
  3 : VMware Network Adapter VMnet8
  4 : イーサネット 3
  5 : Bluetooth
  6 : イーサネット 2

Select NIC:


対象NICの番号を入力します。

5. 操作を選択
1 : Add IP addresses
2 : Delete IP addresses
3 : Show current IP addresses
0 : Exit

IP追加

1 を入力。

CSVのIPが一括で追加されます。

IP削除

2 を入力。

CSVのIPが一括で削除されます。

IP確認

3 を入力。

対象NICの現在のIPv4アドレスを表示します。

注意

PowerShellは管理者権限で実行してください。

削除されるのはCSVに記載されたIPだけです。

プライマリIPをCSVに記載しないでください。

DefaultGateway は必要な場合のみ指定してください。

作業前に対象NICを確認してください。