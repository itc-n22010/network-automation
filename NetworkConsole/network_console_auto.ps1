#requires -Version 5.1

<#
.SYNOPSIS
    Network Console Automation

.DESCRIPTION
    commands フォルダ内のコマンドファイルを読み込み、
    ネットワーク機器へシリアルコンソール接続して順番に実行する。

    実行するコマンドは command file に記載されたものだけ。

    ログ:
        logs\<ホスト名>\<コマンドファイル名>.log

    重要:
      - PS1側から運用コマンドを送信しない
      - commands\*.txt の内容だけを送信する
      - 機器から受信したデータだけをログへ保存する
      - プロンプトをPS1側で生成しない
      - ログイン処理は状態機械で処理する
      - コマンド送信後はホスト名 + > / # が返るまで待つ
      - show running-config 等も同じ方式で待つ
      - コマンド実行待機時間は最大30分
#>

$ErrorActionPreference = 'Stop'

# ============================================================
# Console
# ============================================================

try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
}
catch {
}

# ============================================================
# Serial settings
# ============================================================

$Baud     = 9600
$Parity   = [System.IO.Ports.Parity]::None
$DataBits = 8
$StopBits = [System.IO.Ports.StopBits]::One

# ============================================================
# Timing
# ============================================================

# COMポート探索
$ProbeInitialWaitMs = 500
$ProbeMaxMs         = 5000
$ProbeIdleMs        = 500

# ログイン
$LoginMaxMs         = 30000
$LoginIdleMs        = 500

# 通常コマンド
$CommandMaxMs       = 1800000
$CommandIdleMs      = 500

# プロンプト検出後の安定待ち
$PromptSettleMs     = 200

# ============================================================
# Script root
# ============================================================

$ScriptRoot = $PSScriptRoot

if ([string]::IsNullOrWhiteSpace($ScriptRoot)) {
    $ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}

# ============================================================
# Directories
# ============================================================

$CommandDir = Join-Path $ScriptRoot 'commands'
$LogRoot    = Join-Path $ScriptRoot 'logs'

# ============================================================
# Authentication
# ============================================================

$script:Username       = 'admin'
$script:LoginPassword  = 'password'
$script:EnablePassword = 'password'

# ============================================================
# Session log
# ============================================================

$script:SessionLog = New-Object System.Text.StringBuilder

# ============================================================
# Convert SecureString
# ============================================================

function ConvertFrom-SecureStringPlain {

    param(
        [System.Security.SecureString]$Secure
    )

    if ($null -eq $Secure) {
        return ''
    }

    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)

    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
    }
}

# ============================================================
# Remove ANSI escape
# ============================================================

function Remove-AnsiEscape {

    param(
        [AllowNull()]
        [string]$Text
    )

    if ([string]::IsNullOrEmpty($Text)) {
        return $Text
    }

    return [regex]::Replace(
        $Text,
        '\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])',
        ''
    )
}

# ============================================================
# Add session log
# ============================================================

function Add-SessionData {

    param(
        [AllowNull()]
        [string]$Data
    )

    if ([string]::IsNullOrEmpty($Data)) {
        return
    }

    if ($null -eq $script:SessionLog) {
        $script:SessionLog = New-Object System.Text.StringBuilder
    }

    if (
        -not (
            $script:SessionLog -is
            [System.Text.StringBuilder]
        )
    ) {
        $script:SessionLog = New-Object System.Text.StringBuilder
    }

    [void]$script:SessionLog.Append($Data)
}

# ============================================================
# Get clean buffer
# ============================================================

function Get-CleanBuffer {

    param(
        [AllowNull()]
        [string]$Buffer
    )

    if ([string]::IsNullOrEmpty($Buffer)) {
        return ''
    }

    $clean = Remove-AnsiEscape $Buffer

    $clean = $clean -replace "`0", ''

    return $clean
}

# ============================================================
# Get last meaningful line
# ============================================================

function Get-LastMeaningfulLine {

    param(
        [AllowNull()]
        [string]$Buffer
    )

    if ([string]::IsNullOrEmpty($Buffer)) {
        return ''
    }

    $clean = Get-CleanBuffer $Buffer

    $clean = $clean -replace "`r", ''

    $lines = $clean -split "`n"

    for (
        $i = $lines.Count - 1;
        $i -ge 0;
        $i--
    ) {

        $line = $lines[$i].Trim()

        if (-not [string]::IsNullOrWhiteSpace($line)) {
            return $line
        }
    }

    return ''
}

# ============================================================
# Test prompt
#
# 例:
# Allied-SW-01>
# Allied-SW-01#
# Cisco-SW-01>
# Cisco-SW-01#
# ============================================================

function Test-Prompt {

    param(
        [AllowNull()]
        [string]$Buffer,

        [AllowNull()]
        [string]$Hostname
    )

    if ([string]::IsNullOrWhiteSpace($Hostname)) {
        return $false
    }

    if ([string]::IsNullOrEmpty($Buffer)) {
        return $false
    }

    $line = Get-LastMeaningfulLine $Buffer

    if ([string]::IsNullOrWhiteSpace($line)) {
        return $false
    }

    $hostPattern = [regex]::Escape($Hostname)

    return (
        $line -match
        ('^' + $hostPattern + '[>#]\s*$')
    )
}

# ============================================================
# Get hostname
# ============================================================

function Get-HostnameFromBuffer {

    param(
        [AllowNull()]
        [string]$Buffer
    )

    if ([string]::IsNullOrWhiteSpace($Buffer)) {
        return $null
    }

    $clean = Get-CleanBuffer $Buffer

    $clean = $clean -replace "`r", ''

    $lines = $clean -split "`n"

    for (
        $i = $lines.Count - 1;
        $i -ge 0;
        $i--
    ) {

        $line = $lines[$i].Trim()

        if (
            $line -match
            '^([A-Za-z0-9_.\-]+)[>#]\s*$'
        ) {
            return $Matches[1]
        }
    }

    return $null
}

# ============================================================
# Read available serial data
# ============================================================

function Read-SerialData {

    param(
        [System.IO.Ports.SerialPort]$Port
    )

    if ($null -eq $Port) {
        return ''
    }

    if (-not $Port.IsOpen) {
        return ''
    }

    $result = ''

    try {

        while ($Port.BytesToRead -gt 0) {

            $chunk = $Port.ReadExisting()

            if (-not [string]::IsNullOrEmpty($chunk)) {

                $result += $chunk

                Add-SessionData $chunk
            }
            else {
                break
            }
        }
    }
    catch {
    }

    return $result
}

# ============================================================
# Read until quiet
# ============================================================

function Read-UntilQuiet {

    param(
        [System.IO.Ports.SerialPort]$Port,

        [int]$IdleMs = 500,

        [int]$MaxTotalMs = 30000
    )

    $buffer = ''

    $start = Get-Date
    $lastData = Get-Date

    while (
        ((Get-Date) - $start).TotalMilliseconds -lt
        $MaxTotalMs
    ) {

        if ($Port.BytesToRead -gt 0) {

            $chunk = Read-SerialData $Port

            if (-not [string]::IsNullOrEmpty($chunk)) {

                $buffer += $chunk
                $lastData = Get-Date
                continue
            }
        }

        if (
            ((Get-Date) - $lastData).TotalMilliseconds -ge
            $IdleMs
        ) {
            break
        }

        Start-Sleep -Milliseconds 25
    }

    return $buffer
}

# ============================================================
# Read until prompt
#
# ホスト名 + # / > が返るまで待つ。
#
# 最大30分。
# ============================================================

function Read-UntilPrompt {

    param(
        [System.IO.Ports.SerialPort]$Port,

        [string]$Hostname,

        [int]$MaxTotalMs = 1800000,

        [int]$SettleMs = 200
    )

    $buffer = ''

    $start = Get-Date
    $promptSeenAt = $null

    while (
        ((Get-Date) - $start).TotalMilliseconds -lt
        $MaxTotalMs
    ) {

        if ($Port.BytesToRead -gt 0) {

            $chunk = Read-SerialData $Port

            if (-not [string]::IsNullOrEmpty($chunk)) {

                $buffer += $chunk

                $promptSeenAt = $null

                continue
            }
        }

        if (
            Test-Prompt `
                -Buffer $buffer `
                -Hostname $Hostname
        ) {

            if ($null -eq $promptSeenAt) {

                $promptSeenAt = Get-Date
            }
            else {

                if (
                    ((Get-Date) - $promptSeenAt).TotalMilliseconds -ge
                    $SettleMs
                ) {
                    break
                }
            }
        }

        Start-Sleep -Milliseconds 25
    }

    if (
        -not (
            Test-Prompt `
                -Buffer $buffer `
                -Hostname $Hostname
        )
    ) {

        throw `
            "Prompt timeout. Hostname='$Hostname'."
    }

    return $buffer
}

# ============================================================
# Send raw Enter
# ============================================================

function Send-Enter {

    param(
        [System.IO.Ports.SerialPort]$Port
    )

    if ($null -eq $Port) {
        throw 'Serial port is null.'
    }

    if (-not $Port.IsOpen) {
        throw 'Serial port is not open.'
    }

    $Port.Write("`r")
}

# ============================================================
# Send command
#
# コマンドファイルの内容だけ送信する。
# ============================================================

function Send-ConsoleCommand {

    param(
        [System.IO.Ports.SerialPort]$Port,

        [string]$Command,

        [string]$Hostname
    )

    if ($null -eq $Port) {
        throw 'Serial port is null.'
    }

    if (-not $Port.IsOpen) {
        throw 'Serial port is not open.'
    }

    # 送信前の残データを取得
    if ($Port.BytesToRead -gt 0) {

        [void](Read-SerialData $Port)
    }

    # コマンド送信
    $Port.Write($Command)
    $Port.Write("`r")

    # プロンプトまで待つ
    return Read-UntilPrompt `
        -Port $Port `
        -Hostname $Hostname `
        -MaxTotalMs $CommandMaxMs `
        -SettleMs $PromptSettleMs
}

# ============================================================
# Detect login prompt
# ============================================================

function Test-LoginPrompt {

    param(
        [string]$Buffer
    )

    if ([string]::IsNullOrEmpty($Buffer)) {
        return $false
    }

    $clean = Get-CleanBuffer $Buffer

    return (
        $clean -match
        '(?im)(?:^|\r?\n)[^\r\n]*(?:login|username|user[\s_-]*name)\s*:?\s*$'
    )
}

# ============================================================
# Detect password prompt
# ============================================================

function Test-PasswordPrompt {

    param(
        [string]$Buffer
    )

    if ([string]::IsNullOrEmpty($Buffer)) {
        return $false
    }

    $clean = Get-CleanBuffer $Buffer

    return (
        $clean -match
        '(?im)(?:^|\r?\n)\s*password\s*:?\s*$'
    )
}

# ============================================================
# Detect login failure
# ============================================================

function Test-LoginFailure {

    param(
        [string]$Buffer
    )

    if ([string]::IsNullOrEmpty($Buffer)) {
        return $false
    }

    $clean = Get-CleanBuffer $Buffer

    return (
        $clean -match
        '(?i)(login incorrect|login invalid|authentication failed|access denied|bad password)'
    )
}

# ============================================================
# Login state machine
#
# WAIT_LOGIN
# SEND_USERNAME
# WAIT_PASSWORD
# SEND_PASSWORD
# WAIT_RESULT
# AUTHENTICATED
# ============================================================

function Invoke-Login {

    param(
        [System.IO.Ports.SerialPort]$Port
    )

    Write-Host ''
    Write-Host '========== LOGIN =========='
    Write-Host ''

    $state = 'WAIT_LOGIN'

    $buffer = ''

    $start = Get-Date

    $lastAction = Get-Date

    while (
        ((Get-Date) - $start).TotalMilliseconds -lt
        $LoginMaxMs
    ) {

        # ----------------------------------------------------
        # 受信
        # ----------------------------------------------------

        if ($Port.BytesToRead -gt 0) {

            $chunk = Read-SerialData $Port

            if (-not [string]::IsNullOrEmpty($chunk)) {

                $buffer += $chunk
            }
        }

        # ----------------------------------------------------
        # 既にログイン済み
        # ----------------------------------------------------

        $existingHostname =
            Get-HostnameFromBuffer $buffer

        if ($existingHostname) {

            return $buffer
        }

        # ----------------------------------------------------
        # State: WAIT_LOGIN
        # ----------------------------------------------------

        if ($state -eq 'WAIT_LOGIN') {

            if (
                Test-LoginPrompt $buffer
            ) {

                $state = 'SEND_USERNAME'
                continue
            }

            if (
                Test-PasswordPrompt $buffer
            ) {

                $state = 'SEND_PASSWORD'
                continue
            }

            # 一定時間反応がない場合Enter
            if (
                ((Get-Date) - $lastAction).TotalMilliseconds -ge
                1000
            ) {

                Send-Enter $Port

                $lastAction = Get-Date
            }
        }

        # ----------------------------------------------------
        # State: SEND_USERNAME
        # ----------------------------------------------------

        elseif ($state -eq 'SEND_USERNAME') {

            Write-Host 'Sending username...'

            $Port.Write($script:Username)
            $Port.Write("`r")

            $buffer = ''

            $lastAction = Get-Date

            $state = 'WAIT_PASSWORD'

            Start-Sleep -Milliseconds 100

            continue
        }

        # ----------------------------------------------------
        # State: WAIT_PASSWORD
        # ----------------------------------------------------

        elseif ($state -eq 'WAIT_PASSWORD') {

            if (
                Test-PasswordPrompt $buffer
            ) {

                $state = 'SEND_PASSWORD'
                continue
            }

            if (
                Test-LoginPrompt $buffer
            ) {

                # 再びlogin promptが出た場合
                # usernameを再送
                $state = 'SEND_USERNAME'
                continue
            }

            if (
                Test-LoginFailure $buffer
            ) {

                $state = 'WAIT_LOGIN'

                $buffer = ''

                continue
            }
        }

        # ----------------------------------------------------
        # State: SEND_PASSWORD
        # ----------------------------------------------------

        elseif ($state -eq 'SEND_PASSWORD') {

            Write-Host 'Sending login password...'

            if (
                [string]::IsNullOrWhiteSpace(
                    $script:LoginPassword
                )
            ) {

                $secure =
                    Read-Host `
                        'Login password' `
                        -AsSecureString

                $script:LoginPassword =
                    ConvertFrom-SecureStringPlain $secure
            }

            $Port.Write($script:LoginPassword)
            $Port.Write("`r")

            $buffer = ''

            $lastAction = Get-Date

            $state = 'WAIT_RESULT'

            Start-Sleep -Milliseconds 150

            continue
        }

        # ----------------------------------------------------
        # State: WAIT_RESULT
        # ----------------------------------------------------

        elseif ($state -eq 'WAIT_RESULT') {

            if (
                Test-LoginFailure $buffer
            ) {

                $state = 'WAIT_LOGIN'

                $buffer = ''

                continue
            }

            $hostAfterLogin =
                Get-HostnameFromBuffer $buffer

            if ($hostAfterLogin) {

                return $buffer
            }

            if (
                Test-LoginPrompt $buffer
            ) {

                $state = 'SEND_USERNAME'

                continue
            }
        }

        Start-Sleep -Milliseconds 25
    }

    throw 'Login timeout.'
}

# ============================================================
# Enable
#
# PS1から enable を送信する必要がある機器だけ対応。
# これはログイン後のセッション確立処理であり、
# 運用コマンドではない。
# ============================================================

function Invoke-EnableMode {

    param(
        [System.IO.Ports.SerialPort]$Port,

        [string]$CurrentBuffer
    )

    $hostname =
        Get-HostnameFromBuffer $CurrentBuffer

    if (-not $hostname) {
        throw 'Hostname could not be detected after login.'
    }

    $lastLine =
        Get-LastMeaningfulLine $CurrentBuffer

    # 既に #
    if ($lastLine -match '^' + [regex]::Escape($hostname) + '#\s*$') {
        return $CurrentBuffer
    }

    # >
    if ($lastLine -match '^' + [regex]::Escape($hostname) + '>\s*$') {

        # enable はログイン後の権限昇格に必要な場合のみ送る
        $Port.Write('enable')
        $Port.Write("`r")

        $buffer = Read-UntilQuiet `
            -Port $Port `
            -IdleMs $LoginIdleMs `
            -MaxTotalMs 10000

        if (
            Test-PasswordPrompt $buffer
        ) {

            if (
                [string]::IsNullOrWhiteSpace(
                    $script:EnablePassword
                )
            ) {

                $secure =
                    Read-Host `
                        'Enable password' `
                        -AsSecureString

                $script:EnablePassword =
                    ConvertFrom-SecureStringPlain $secure
            }

            $Port.Write($script:EnablePassword)
            $Port.Write("`r")

            $buffer = Read-UntilQuiet `
                -Port $Port `
                -IdleMs $LoginIdleMs `
                -MaxTotalMs 10000
        }

        $resultHostname =
            Get-HostnameFromBuffer $buffer

        if (-not $resultHostname) {
            throw 'Hostname could not be detected after enable.'
        }

        $lastLine =
            Get-LastMeaningfulLine $buffer

        if (
            $lastLine -notmatch
            '^' + [regex]::Escape($resultHostname) + '#\s*$'
        ) {

            throw 'Enable mode elevation failed.'
        }

        return $buffer
    }

    throw 'Unknown console prompt after login.'
}

# ============================================================
# Test COM port
#
# 「最初に開けたポート」ではなく、
# 実際にコンソール応答があったポートを採用する。
# ============================================================

function Test-ConsolePort {

    param(
        [string]$PortName
    )

    $port = $null

    try {

        Write-Host "Testing COM port: $PortName"

        $port =
            New-Object System.IO.Ports.SerialPort(
                $PortName,
                $Baud,
                $Parity,
                $DataBits,
                $StopBits
            )

        $port.NewLine = "`r"

        $port.ReadTimeout = 500
        $port.WriteTimeout = 3000

        $port.Open()

        $port.DiscardInBuffer()
        $port.DiscardOutBuffer()

        # ----------------------------------------------------
        # Enterを送信して機器を起こす
        # ----------------------------------------------------

        $port.Write("`r")

        Start-Sleep -Milliseconds $ProbeInitialWaitMs

        $probe = ''

        $start = Get-Date
        $lastData = Get-Date

        while (
            ((Get-Date) - $start).TotalMilliseconds -lt
            $ProbeMaxMs
        ) {

            if ($port.BytesToRead -gt 0) {

                $chunk = $port.ReadExisting()

                if (-not [string]::IsNullOrEmpty($chunk)) {

                    $probe += $chunk

                    $lastData = Get-Date
                }
            }
            else {

                if (
                    ((Get-Date) - $lastData).TotalMilliseconds -ge
                    $ProbeIdleMs
                ) {
                    break
                }

                Start-Sleep -Milliseconds 25
            }
        }

        # ----------------------------------------------------
        # 応答判定
        #
        # 何らかのデータが返れば候補。
        # ----------------------------------------------------

        if (-not [string]::IsNullOrEmpty($probe)) {

            Write-Host `
                "Response detected: $($probe.Length) bytes" `
                -ForegroundColor Green

            return [PSCustomObject]@{
                Port = $port
                InitialData = $probe
            }
        }

        Write-Host `
            'No response.' `
            -ForegroundColor Yellow

        try {
            $port.Close()
        }
        catch {
        }

        try {
            $port.Dispose()
        }
        catch {
        }

        return $null
    }
    catch {

        Write-Host `
            "Open failed: $($_.Exception.Message)" `
            -ForegroundColor Yellow

        if ($port) {

            try {
                if ($port.IsOpen) {
                    $port.Close()
                }
            }
            catch {
            }

            try {
                $port.Dispose()
            }
            catch {
            }
        }

        return $null
    }
}

# ============================================================
# Read command file
# ============================================================

function Read-CommandFile {

    param(
        [string]$Path
    )

    if (
        -not (
            Test-Path `
                -LiteralPath $Path `
                -PathType Leaf
        )
    ) {

        throw "Command file not found: $Path"
    }

    # BOMありUTF-8 / UTF-8 / ASCIIをPowerShell 5.1で読む
    $utf8 =
        New-Object System.Text.UTF8Encoding($false)

    $lines =
        [System.IO.File]::ReadAllLines(
            $Path,
            $utf8
        )

    $commands =
        New-Object System.Collections.Generic.List[string]

    foreach ($line in $lines) {

        $command = $line.Trim()

        if (
            [string]::IsNullOrWhiteSpace($command)
        ) {
            continue
        }

        # # で始まる行はコメント
        if ($command.StartsWith('#')) {
            continue
        }

        [void]$commands.Add($command)
    }

    return ,$commands
}

# ============================================================
# Save log
# ============================================================

function Save-SessionLog {

    param(
        [string]$Path
    )

    if ($null -eq $script:SessionLog) {
        return
    }

    $text =
        $script:SessionLog.ToString()

    $utf8Bom =
        New-Object System.Text.UTF8Encoding($true)

    [System.IO.File]::WriteAllText(
        $Path,
        $text,
        $utf8Bom
    )
}

# ============================================================
# Main
# ============================================================

$serial = $null
$logPath = $null

try {

    Write-Host ''
    Write-Host '========================================'
    Write-Host ' Network Console Automation'
    Write-Host '========================================'
    Write-Host ''

    # ========================================================
    # Command file
    # ========================================================

    if ($args.Count -lt 1) {
        throw 'Command file argument is missing.'
    }

    $CommandFile = $args[0]

    if (
        -not (
            [System.IO.Path]::IsPathRooted(
                $CommandFile
            )
        )
    ) {

        $CommandFile =
            Join-Path `
                $ScriptRoot `
                $CommandFile
    }

    $CommandFile =
        [System.IO.Path]::GetFullPath(
            $CommandFile
        )

    Write-Host "Command file: $CommandFile"

    # ========================================================
    # Load commands
    # ========================================================

    $commands =
        Read-CommandFile $CommandFile

    if ($null -eq $commands) {
        throw 'Command list could not be loaded.'
    }

    if ($commands.Count -eq 0) {

        Write-Host ''
        Write-Host 'No commands found.'
        Write-Host 'Nothing to execute.'
        Write-Host ''

        exit 0
    }

    Write-Host `
        "Command count: $($commands.Count)"

    # ========================================================
    # COM ports
    # ========================================================

    $candidatePorts =
        @(
            [System.IO.Ports.SerialPort]::GetPortNames() |
            Sort-Object {
                if ($_ -match '\d+$') {
                    [int]$Matches[0]
                }
                else {
                    99999
                }
            }
        )

    if ($candidatePorts.Count -eq 0) {
        throw 'No COM ports detected.'
    }

    Write-Host ''
    Write-Host `
        "Detected COM ports: $($candidatePorts -join ', ')"

    # ========================================================
    # Find console port
    # ========================================================

    $selected = $null

    foreach ($portName in $candidatePorts) {

        Write-Host ''
        Write-Host "Checking: $portName"

        $result =
            Test-ConsolePort $portName

        if ($null -ne $result) {

            $selected = $result

            break
        }
    }

    if ($null -eq $selected) {
        throw 'No responding console port found.'
    }

    $serial =
        $selected.Port

    Write-Host ''
    Write-Host `
        "Using port: $($serial.PortName)" `
        -ForegroundColor Green

    # ========================================================
    # 正式ログ開始
    #
    # ポート探索時のデータはここには入れない。
    # ========================================================

    $script:SessionLog =
        New-Object System.Text.StringBuilder

    # ========================================================
    # 初期応答
    #
    # COMポート検出時の応答もログへ残す。
    # ========================================================

    if (
        -not [string]::IsNullOrEmpty(
            $selected.InitialData
        )
    ) {

        Add-SessionData `
            $selected.InitialData
    }

    # ========================================================
    # Login
    # ========================================================

    $loginBuffer =
        Invoke-Login `
            -Port $serial

    # ========================================================
    # Enable
    # ========================================================

    $enableBuffer =
        Invoke-EnableMode `
            -Port $serial `
            -CurrentBuffer $loginBuffer

    # ========================================================
    # Hostname
    # ========================================================

    $hostname =
        Get-HostnameFromBuffer $enableBuffer

    if (
        [string]::IsNullOrWhiteSpace($hostname)
    ) {

        throw `
            'Hostname could not be detected.'
    }

    Write-Host ''
    Write-Host `
        "Hostname detected: $hostname" `
        -ForegroundColor Green

    # ========================================================
    # Log directory
    # ========================================================

    $logDir =
        Join-Path `
            $LogRoot `
            $hostname

    if (
        -not (
            Test-Path `
                -LiteralPath $logDir `
                -PathType Container
        )
    ) {

        New-Item `
            -ItemType Directory `
            -Path $logDir `
            -Force |
            Out-Null
    }

    # ========================================================
    # Log filename
    # ========================================================

    $baseName =
        [System.IO.Path]::GetFileNameWithoutExtension(
            $CommandFile
        )

    $logPath =
        Join-Path `
            $logDir `
            ($baseName + '.log')

    # ========================================================
    # Execute commands
    # ========================================================

    foreach ($command in $commands) {

        Write-Host ''
        Write-Host `
            "Executing: $command"

        # ----------------------------------------------------
        # コマンドファイルにあるものをそのまま送信
        #
        # 例:
        #
        # terminal length 0
        # show clock
        #
        # PS1から別のコマンドを追加しない。
        # ----------------------------------------------------

        [void](
            Send-ConsoleCommand `
                -Port $serial `
                -Command $command `
                -Hostname $hostname
        )
    }

    # ========================================================
    # Save log BEFORE closing
    # ========================================================

    Save-SessionLog `
        -Path $logPath

    # ========================================================
    # Close COM
    # ========================================================

    if (
        $serial -and
        $serial.IsOpen
    ) {

        $serial.Close()
    }

    try {
        $serial.Dispose()
    }
    catch {
    }

    $serial = $null

    # ========================================================
    # Completed
    # ========================================================

    Write-Host ''
    Write-Host '========================================'
    Write-Host ' COMPLETED'
    Write-Host '========================================'
    Write-Host ''
    Write-Host `
        "Log: $logPath" `
        -ForegroundColor Green
    Write-Host ''

    exit 0
}
catch {

    Write-Host ''
    Write-Host '========================================'
    Write-Host ' ERROR'
    Write-Host '========================================'
    Write-Host ''

    Write-Host `
        $_.Exception.Message `
        -ForegroundColor Red

    # ========================================================
    # エラー時も、それまで受信したログを保存
    # ========================================================

    if (
        $null -ne $logPath
    ) {

        try {
            Save-SessionLog `
                -Path $logPath
        }
        catch {
        }
    }

    # ========================================================
    # Close COM
    # ========================================================

    if ($serial) {

        try {

            if ($serial.IsOpen) {
                $serial.Close()
            }
        }
        catch {
        }

        try {
            $serial.Dispose()
        }
        catch {
        }
    }

    exit 1
}
