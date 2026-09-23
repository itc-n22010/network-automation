[CmdletBinding()]
param(
    [ValidateSet('All','Pending','Failed','Serial','GenerateOnly')]
    [string]$Selection = 'All',
    [string]$SerialNumber,
    [string]$DeviceCsv,
    [string]$SettingsPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrWhiteSpace($DeviceCsv)) {
    $DeviceCsv = Join-Path $root 'config\devices.csv'
}
if ([string]::IsNullOrWhiteSpace($SettingsPath)) {
    $SettingsPath = Join-Path $root 'config\settings.json'
}
$settings = Get-Content -LiteralPath $SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
foreach ($directory in @($settings.LogDirectory,$settings.ResultDirectory,$settings.GeneratedDirectory,$settings.BackupDirectory)) {
    New-Item -ItemType Directory -Force -Path (Join-Path $root $directory) | Out-Null
}
$macroExe = [Environment]::ExpandEnvironmentVariables([string]$settings.TeraTermMacro)
if (-not (Test-Path -LiteralPath $macroExe)) {
    $macroCandidates = @(
        (Join-Path ${env:ProgramFiles} 'teraterm5\ttpmacro.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'teraterm5\ttpmacro.exe'),
        (Join-Path ${env:ProgramFiles} 'teraterm\ttpmacro.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'teraterm\ttpmacro.exe')
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
    if (@($macroCandidates).Count -eq 1) {
        $macroExe = $macroCandidates[0]
    }
}
if ($Selection -eq 'GenerateOnly') {
    & (Join-Path $root 'Generate-Configs.ps1') -DeviceCsv $DeviceCsv -SettingsPath $SettingsPath -OutputDirectory (Join-Path $root $settings.GeneratedDirectory)
    exit 0
}
if (-not (Test-Path -LiteralPath $macroExe)) {
    throw "Tera Term macro executable was not found. Edit config\settings.json and set TeraTermMacro to the full path of ttpmacro.exe."
}

$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$logRoot = Join-Path $root $settings.LogDirectory
$resultDirectory = Join-Path $root $settings.ResultDirectory
$resultPath = Join-Path $resultDirectory "results_$timestamp.csv"
$devices = @(Import-Csv -LiteralPath $DeviceCsv)
$requiredFields = @($settings.RequiredCsvFields)
if ($requiredFields.Count -eq 0) {
    throw 'settings.json RequiredCsvFields is empty.'
}
foreach ($device in $devices) {
    foreach ($name in $requiredFields) {
        if ([string]::IsNullOrWhiteSpace([string]$device.$name)) {
            throw "CSV field '$name' is empty for DeviceID '$($device.DeviceID)'."
        }
    }
}
$serialGroups = $devices | Group-Object SerialNumber
$duplicateSerials = @($serialGroups | Where-Object Count -gt 1 | ForEach-Object Name)
$previousResults = @()
$latestResult = Get-ChildItem -LiteralPath (Join-Path $root $settings.ResultDirectory) -Filter 'results_*.csv' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($latestResult) { $previousResults = @(Import-Csv -LiteralPath $latestResult.FullName) }

function New-Result([string]$status,[string]$reason,[object]$device,[string]$com,[string]$serial,[string]$log) {
    [pscustomobject]@{
        Timestamp = (Get-Date).ToString('o'); Status=$status; Reason=$reason
        SerialNumber=if($device){$device.SerialNumber}else{$serial}; DeviceID=if($device){$device.DeviceID}else{''}
        Hostname=if($device){$device.Hostname}else{''}; ManagementIP=if($device){$device.ManagementIP}else{''}
        ComPort=$com; LogPath=$log
    }
}
function Invoke-Ttl([string]$ttlPath) {
    $p = Start-Process -FilePath $macroExe -ArgumentList ('"' + $ttlPath + '"') -Wait -PassThru -WindowStyle Normal
    return $p.ExitCode
}
function Get-ConfigCommands([object]$device) {
    $templateRules = @($settings.TemplateRules)
    if ($templateRules.Count -eq 0) {
        throw 'settings.json TemplateRules is empty.'
    }
    $ruleMatches = @($templateRules | Where-Object {
        $_.HostnamePattern -and ([string]$device.Hostname -match [string]$_.HostnamePattern)
    })
    if ($ruleMatches.Count -ne 1) {
        throw "Hostname '$($device.Hostname)' matched $($ruleMatches.Count) template rules. Exactly one match is required."
    }
    $templatePath = Join-Path $root ([string]$ruleMatches[0].Template)
    if (-not (Test-Path -LiteralPath $templatePath)) {
        throw "Template file was not found for hostname '$($device.Hostname)': $templatePath"
    }
    $text = Get-Content -LiteralPath $templatePath -Raw -Encoding UTF8
    foreach ($property in $device.PSObject.Properties) {
        $name = [string]$property.Name
        $value = if ($null -eq $property.Value) { '' } else { [string]$property.Value }
        $text = $text.Replace("{{$name}}", $value)
    }
    $unresolved = [regex]::Matches($text, '\{\{([A-Za-z_][A-Za-z0-9_]*)\}\}') |
        ForEach-Object { $_.Groups[1].Value } |
        Select-Object -Unique
    if (@($unresolved).Count -gt 0) {
        throw "Template contains CSV fields not found in devices.csv: $($unresolved -join ', ')"
    }
    $commands = New-Object System.Collections.Generic.List[string]
    foreach ($line in ($text -split "`r?`n")) {
        $command = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($command) -or $command -eq '!' -or $command -eq 'end') { continue }
        [void]$commands.Add($command)
    }
    return @($commands)
}
function New-Ttl([int]$comNumber,[string]$logPath,[string]$consolePassword,[string[]]$commands,[int]$timeout,[string]$rsaKeyBits) {
    $ttl = Get-Content -LiteralPath (Join-Path $root 'templates\cisco_build.ttl') -Raw -Encoding UTF8
    $escapedPassword = $consolePassword.Replace("'", "''")
    $escapedLog = $logPath.Replace("'","''")
    $ttlDialogRules = @($settings.DialogRules | Where-Object {
        $ttlPromptProperty = $_.PSObject.Properties['TtlPrompt']
        $ttlPromptProperty -and
        -not [string]::IsNullOrWhiteSpace([string]$ttlPromptProperty.Value) -and
        $_.Id -notin @('rsa-replace-existing-no','rsa-modulus-2048')
    })
    foreach ($rule in $ttlDialogRules) {
        if ([bool]$rule.AppendEnter -ne $true) {
            throw "TtlPrompt rule '$($rule.Id)' must set AppendEnter to true."
        }
        if ($null -eq $rule.Response) {
            throw "TtlPrompt rule '$($rule.Id)' must define Response."
        }
    }
    $dialogWaitParts = @($ttlDialogRules | ForEach-Object {
        "'" + ([string]$_.TtlPrompt).Replace("'","''") + "'"
    })
    $dialogWait = if ($dialogWaitParts.Count -gt 0) {
        ($dialogWaitParts + "'#'") -join ' '
    } else {
        "'#'"
    }
    $lines = foreach ($command in $commands) {
        $escaped = $command.Replace("'", "''")
        if ($command -eq 'crypto key generate rsa') {
            $replaceRule = @($settings.DialogRules | Where-Object { $_.Id -eq 'rsa-replace-existing-no' } | Select-Object -First 1)
            $rsaRule = @($settings.DialogRules | Where-Object { $_.Id -eq 'rsa-modulus-2048' } | Select-Object -First 1)
            if ($replaceRule.Count -ne 1) { throw 'DialogRules must contain rsa-replace-existing-no for existing RSA key handling.' }
            if ($rsaRule.Count -ne 1) { throw 'DialogRules must contain rsa-modulus-2048 for SSH key generation.' }
            $replacePromptProperty = $replaceRule[0].PSObject.Properties['TtlPrompt']
            $replacePrompt = if (-not $replacePromptProperty -or [string]::IsNullOrWhiteSpace([string]$replacePromptProperty.Value)) { 'Do you really want to replace them?' } else { [string]$replacePromptProperty.Value }
            $response = if ([string]::IsNullOrWhiteSpace($rsaKeyBits)) { ([string]$rsaRule[0].Response) } else { $rsaKeyBits }
            $replaceResponse = [string]$replaceRule[0].Response
            $replacePrompt = $replacePrompt.Replace("'","''")
            $replaceResponse = $replaceResponse.Replace("'","''")
            $response = $response.Replace("'","''")
            "timeout = 300`r`nsendln '$escaped'`r`nwait '$replacePrompt' 'How many bits in the modulus' '#'`r`nif result=1 sendln '$replaceResponse'`r`nif result=1 wait '#'`r`nif result=2 sendln '$response'`r`nif result=2 wait '#'`r`nif result=0 goto command_error`r`ntimeout = $timeout"
        } else {
            if ($command -match '^username\s+\S+\s+privilege\s+\d+\s+secret\s+') {
                $block = New-Object System.Collections.Generic.List[string]
                [void]$block.Add("logpause")
                [void]$block.Add("sendln '$escaped'")
                [void]$block.Add("wait $dialogWait")
                for ($index = 0; $index -lt $ttlDialogRules.Count; $index++) {
                    $rule = $ttlDialogRules[$index]
                    $response = ([string]$rule.Response).Replace("'","''")
                    [void]$block.Add("if result=$($index + 1) sendln '$response'")
                    [void]$block.Add("if result=$($index + 1) wait '#'")
                }
                [void]$block.Add("logstart")
                $block -join "`r`n"
            } else {
                $block = New-Object System.Collections.Generic.List[string]
                [void]$block.Add("sendln '$escaped'")
                [void]$block.Add("wait $dialogWait")
                for ($index = 0; $index -lt $ttlDialogRules.Count; $index++) {
                    $rule = $ttlDialogRules[$index]
                    $response = ([string]$rule.Response).Replace("'","''")
                    [void]$block.Add("if result=$($index + 1) sendln '$response'")
                    [void]$block.Add("if result=$($index + 1) wait '#'")
                }
                $block -join "`r`n"
            }
        }
        "if result=0 goto command_error"
    }
    $ttl = $ttl.Replace('{{ComNumber}}', [string]$comNumber).Replace('{{LogPath}}',$escapedLog).
        Replace('{{ConsolePassword}}',$escapedPassword).Replace('{{TimeoutSeconds}}',[string]$timeout).
        Replace('{{Timestamp}}',(Get-Date -Format 'o')).Replace('{{ConfigCommands}}',($lines -join "`r`n"))
    if ($ttl -match '\{\{[^}]+\}\}') {
        throw 'Generated Tera Term macro contains an unresolved placeholder. No configuration was sent.'
    }
    $path = Join-Path $env:TEMP ("CiscoAutoConfig_{0}_{1}.ttl" -f $comNumber,[guid]::NewGuid().ToString('N'))
    Set-Content -LiteralPath $path -Value $ttl -Encoding ASCII -NoNewline
    return $path
}
function New-ProbeTtl([int]$comNumber,[string]$logPath,[int]$timeout) {
    $escapedLog = $logPath.Replace("'","''")
    $ttl = @"
timeout = $timeout
mtimeout = 0
connect '/C=$comNumber /BAUD=9600'
pause 2
logopen '$escapedLog' 0 0 1 0 1
logwrite 'PROBE_START COM$comNumber'#13#10
sendln
pause 1
sendln 'show version'
wait '#' '>'
if result=0 goto probe_error
sendln 'show inventory'
wait '#' '>'
if result=0 goto probe_error
logwrite 'PROBE_SUCCESS'#13#10
goto finish
:connect_error
logwrite 'ERROR CONNECT_FAILED'#13#10
goto finish
:probe_error
logwrite 'ERROR PROBE_RESPONSE_TIMEOUT'#13#10
:finish
logclose
disconnect 0
closett
end
"@
    $path = Join-Path $env:TEMP ("CiscoAutoConfig_Probe_{0}_{1}.ttl" -f $comNumber,[guid]::NewGuid().ToString('N'))
    Set-Content -LiteralPath $path -Value $ttl -Encoding ASCII -NoNewline
    return $path
}
function Get-ComPorts {
    @(
        [System.IO.Ports.SerialPort]::GetPortNames() |
        Sort-Object {
            if ($_ -match '\d+$') { [int]$Matches[0] } else { 99999 }
        }
    )
}
function Read-SerialUntilPrompt([System.IO.Ports.SerialPort]$serialPort,[string]$hostname,[int]$timeoutMilliseconds) {
    $buffer = ''
    $start = Get-Date
    $promptPattern = '(?m)(^|[\r\n])[A-Za-z0-9_.-]+(?:\([^)]+\))?[#>]\s*'
    while (((Get-Date) - $start).TotalMilliseconds -lt $timeoutMilliseconds) {
        if ($serialPort.BytesToRead -gt 0) {
            $chunk = $serialPort.ReadExisting()
            if ($chunk) {
                $buffer += $chunk
                if ($buffer -match '--More--') {
                    $serialPort.Write(' ')
                }
                if ($buffer -match $promptPattern) {
                    Start-Sleep -Milliseconds 200
                    while ($serialPort.BytesToRead -gt 0) {
                        $tail = $serialPort.ReadExisting()
                        if ($tail) { $buffer += $tail } else { break }
                    }
                    return $buffer
                }
            }
        } else {
            Start-Sleep -Milliseconds 25
        }
    }
    return $buffer
}
function Read-SerialUntilCiscoPrompt([System.IO.Ports.SerialPort]$serialPort,[int]$timeoutMilliseconds) {
    $buffer = ''
    $start = Get-Date
    $promptPattern = '(?m)(^|[\r\n])[A-Za-z0-9_.-]+(?:\([^)]+\))?[#>]\s*'
    while (((Get-Date) - $start).TotalMilliseconds -lt $timeoutMilliseconds) {
        if ($serialPort.BytesToRead -gt 0) {
            $chunk = $serialPort.ReadExisting()
            if ($chunk) {
                $buffer += $chunk
                if ($buffer -match '--More--') { $serialPort.Write(' ') }
                if ($buffer -match $promptPattern) {
                    Start-Sleep -Milliseconds 200
                    while ($serialPort.BytesToRead -gt 0) {
                        $tail = $serialPort.ReadExisting()
                        if ($tail) { $buffer += $tail } else { break }
                    }
                    return $buffer
                }
            }
        } else {
            Start-Sleep -Milliseconds 25
        }
    }
    return $buffer
}
function Invoke-StartupDialog([System.IO.Ports.SerialPort]$serialPort,[string]$initialBuffer,[int]$timeoutMilliseconds) {
    $buffer = $initialBuffer
    $start = Get-Date
    $handled = @{}
    $rules = @($settings.DialogRules)
    while (((Get-Date) - $start).TotalMilliseconds -lt $timeoutMilliseconds) {
        if ($serialPort.BytesToRead -gt 0) {
            $chunk = $serialPort.ReadExisting()
            if ($chunk) { $buffer += $chunk }
        }
        $clean = $buffer -replace "`0", ''
        foreach ($rule in $rules) {
            $id = [string]$rule.Id
            if ([string]::IsNullOrWhiteSpace($id)) { throw 'DialogRules contains a rule without Id.' }
            $maxMatches = [int]$rule.MaxMatches
            if ($maxMatches -lt 1) { $maxMatches = 1 }
            $count = if ($handled.ContainsKey($id)) { [int]$handled[$id] } else { 0 }
            if ($count -ge $maxMatches) { continue }
            if ($clean -match [string]$rule.Pattern) {
                $responseText = if ($null -eq $rule.Response) { '' } else { [string]$rule.Response }
                $serialPort.Write($responseText)
                if ([bool]$rule.AppendEnter) { $serialPort.Write("`r") }
                $handled[$id] = $count + 1
                Start-Sleep -Milliseconds 150
                break
            }
        }
        if ($clean -match '(?m)(^|[\r\n])([A-Za-z0-9_.-]+)(?:\([^)]+\))?[#>]\s*') {
            Start-Sleep -Milliseconds 200
            while ($serialPort.BytesToRead -gt 0) {
                $tail = $serialPort.ReadExisting()
                if ($tail) { $buffer += $tail } else { break }
            }
            return $buffer
        }
        Start-Sleep -Milliseconds 25
    }
    return $buffer
}
function Invoke-SerialProbe([string]$comPort,[string]$logPath,[int]$timeoutSeconds) {
    $serialPort = $null
    $response = ''
    try {
        $serialPort = New-Object System.IO.Ports.SerialPort(
            $comPort,
            [int]$settings.BaudRate,
            [System.IO.Ports.Parity]::None,
            8,
            [System.IO.Ports.StopBits]::One
        )
        $serialPort.NewLine = "`r"
        $serialPort.ReadTimeout = 500
        $serialPort.WriteTimeout = 3000
        $serialPort.Open()
        $serialPort.DiscardInBuffer()
        $serialPort.DiscardOutBuffer()
        $serialPort.Write("`r")
        Start-Sleep -Milliseconds 500
        $start = Get-Date
        $lastData = Get-Date
        while (((Get-Date) - $start).TotalMilliseconds -lt ([Math]::Min($timeoutSeconds * 1000, 5000))) {
            if ($serialPort.BytesToRead -gt 0) {
                $chunk = $serialPort.ReadExisting()
                if ($chunk) {
                    $response += $chunk
                    $lastData = Get-Date
                }
            } elseif (((Get-Date) - $lastData).TotalMilliseconds -ge 500) {
                break
            } else {
                Start-Sleep -Milliseconds 25
            }
        }
        if ([string]::IsNullOrEmpty($response)) {
            Set-Content -LiteralPath $logPath -Value 'ERROR NO_CONSOLE_RESPONSE' -Encoding Default -NoNewline
            return ''
        }
        $response = Invoke-StartupDialog $serialPort $response ([Math]::Max(10000, $timeoutSeconds * 1000))
        if ($response -match '(?im)Erasing the nvram filesystem.*Continue\?\s*\[confirm\]') {
            throw 'Dangerous erase confirmation prompt detected. No confirmation was sent.'
        }
        if ($response -match '(?m)(^|[\r\n])([A-Za-z0-9_.-]+)(?:\([^)]+\))?[#>]\s*') {
            $hostname = $Matches[2]
            $serialPort.Write("terminal length 0`r")
            $step = Read-SerialUntilCiscoPrompt $serialPort ([Math]::Max(5000, $timeoutSeconds * 1000))
            $response += $step
            if ($step -notmatch '(?m)(^|[\r\n])[A-Za-z0-9_.-]+(?:\([^)]+\))?[#>]') {
                throw 'Cisco prompt was not returned after terminal length 0.'
            }
            $serialPort.Write("show version`r")
            $step = Read-SerialUntilPrompt $serialPort $hostname ([Math]::Max(10000, $timeoutSeconds * 1000))
            $response += $step
            if ($step -notmatch [regex]::Escape($hostname) + '[#>]') {
                throw 'Cisco prompt was not returned after show version.'
            }
            $serialPort.Write("show inventory`r")
            $step = Read-SerialUntilPrompt $serialPort $hostname ([Math]::Max(10000, $timeoutSeconds * 1000))
            $response += $step
        }
        Set-Content -LiteralPath $logPath -Value $response -Encoding Default -NoNewline
        return $response
    } catch {
        Set-Content -LiteralPath $logPath -Value ("ERROR SERIAL_PROBE: " + $_.Exception.Message) -Encoding Default -NoNewline
        return ''
    } finally {
        if ($serialPort) {
            if ($serialPort.IsOpen) { $serialPort.Close() }
            $serialPort.Dispose()
        }
    }
}
function Get-SerialFromLog([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $text = Get-Content -LiteralPath $path -Raw -Encoding Default
    if ($text -match '(?im)\bProcessor board ID\s+([A-Z0-9-]+)') { return $Matches[1].ToUpperInvariant() }
    if ($text -match '(?im)\bSystem serial number\s*:\s*([A-Z0-9-]+)') { return $Matches[1].ToUpperInvariant() }
    if ($text -match '(?im)\bSN\s*:\s*([A-Z0-9-]+)') { return $Matches[1].ToUpperInvariant() }
    return $null
}
function Test-CiscoLog([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return $false }
    $text = Get-Content -LiteralPath $path -Raw -Encoding Default
    return [bool]($text -match '(?m)(^|[\r\n])[A-Za-z0-9_.-]+(?:\([^)]+\))?[#>]')
}

$scan = @()
foreach ($port in Get-ComPorts) {
    $comNumber = [int]($port -replace '\D','')
    $probeLog = Join-Path $logRoot ("probe_COM{0}_{1}.log" -f $comNumber,$timestamp)
    $probeText = Invoke-SerialProbe $port $probeLog ([int]$settings.ProbeTimeoutSeconds)
    $serial = Get-SerialFromLog $probeLog
    $isCisco = [bool]($probeText -match '(?m)(^|[\r\n])[A-Za-z0-9_.-]+(?:\([^)]+\))?[#>]')
    $scan += [pscustomobject]@{ComPort=$port; SerialNumber=$serial; Cisco=$isCisco; LogPath=$probeLog}
}
if ($scan.Count -eq 0) { throw 'No usable COM port was found.' }
$targets = @($scan | Where-Object { $_.Cisco -and $_.SerialNumber })
if ($targets.Count -eq 0) {
    $results = New-Object System.Collections.Generic.List[object]
    foreach ($item in $scan) {
        $reason = if (Test-Path -LiteralPath $item.LogPath) {
            (Get-Content -LiteralPath $item.LogPath -Raw -Encoding Default).Trim()
        } else {
            'No probe log was created.'
        }
        $results.Add((New-Result 'NOT_EXECUTED' $reason $null $item.ComPort $item.SerialNumber $item.LogPath))
    }
    $results | Export-Csv -LiteralPath $resultPath -NoTypeInformation -Encoding UTF8
    throw 'No port returned both a Cisco prompt and a serial number. No configuration was sent. See the probe log and result CSV.'
}
if ($targets.Count -gt 1) {
    $results = New-Object System.Collections.Generic.List[object]
    foreach ($item in $targets) {
        $results.Add((New-Result 'NOT_EXECUTED' 'Multiple Cisco console responses detected; exactly one connected device is required.' $null $item.ComPort $item.SerialNumber $item.LogPath))
    }
    $results | Export-Csv -LiteralPath $resultPath -NoTypeInformation -Encoding UTF8
    throw 'Multiple Cisco console responses were detected. Connect exactly one device and retry. No configuration was sent.'
}

$results = New-Object System.Collections.Generic.List[object]
foreach ($target in $targets) {
    $matches = @($devices | Where-Object { $_.SerialNumber.ToUpperInvariant() -eq $target.SerialNumber })
    if ($target.SerialNumber -in $duplicateSerials) {
        $results.Add((New-Result 'SERIAL_DUPLICATE' 'Serial number is duplicated in CSV' $null $target.ComPort $target.SerialNumber $target.LogPath)); continue
    }
    if ($matches.Count -ne 1) {
        $results.Add((New-Result 'SERIAL_MISMATCH' 'Serial number is not registered in CSV' $null $target.ComPort $target.SerialNumber $target.LogPath)); continue
    }
    $device = $matches[0]
    $old = @($previousResults | Where-Object { $_.SerialNumber -eq $device.SerialNumber })
    if ($Selection -eq 'Serial' -and $device.SerialNumber -ne $SerialNumber) { continue }
    if ($Selection -eq 'Pending' -and $old.Status -in @('SUCCESS')) { continue }
    if ($Selection -eq 'Failed' -and $old.Status -notin @('FAILED')) { continue }
    $commands = Get-ConfigCommands $device
    Write-Host ("Applying automatically: COM={0} Serial={1} DeviceID={2} Hostname={3} IP={4}" -f $target.ComPort,$device.SerialNumber,$device.DeviceID,$device.Hostname,$device.ManagementIP)
    $deviceLog = Join-Path $logRoot ("{0}_{1}_{2}.log" -f $device.DeviceID,$target.ComPort,$timestamp)
    if ([string]$device.SshKeyBits -notmatch '^(1024|2048|3072|4096)$') {
        throw "SshKeyBits must be 1024, 2048, 3072, or 4096 for DeviceID '$($device.DeviceID)'."
    }
    $ttlPath = New-Ttl ([int]($target.ComPort -replace '\D','')) $deviceLog ([string]$device.ConsolePassword) $commands ([int]$settings.CommandTimeoutSeconds) ([string]$device.SshKeyBits)
    try {
        [void](Invoke-Ttl $ttlPath)
        $text = if(Test-Path $deviceLog){Get-Content $deviceLog -Raw -Encoding Default}else{''}
        if ($text -match '% Invalid input|% Incomplete command|% Ambiguous command|% Error|SESSION_FAILED|ERROR ') {
            $results.Add((New-Result 'FAILED' 'Cisco response error or macro error' $device $target.ComPort $target.SerialNumber $deviceLog))
        } elseif ($text -match 'SESSION_SUCCESS') {
            $results.Add((New-Result 'SUCCESS' 'Configuration applied and saved' $device $target.ComPort $target.SerialNumber $deviceLog))
        } else {
            $results.Add((New-Result 'FAILED' 'Success marker was not confirmed' $device $target.ComPort $target.SerialNumber $deviceLog))
        }
    } finally { Remove-Item -LiteralPath $ttlPath -Force -ErrorAction SilentlyContinue }
}
foreach ($target in $scan | Where-Object { $_ -notin $targets }) {
    $results.Add((New-Result 'NOT_EXECUTED' 'Cisco device or serial number was not confirmed' $null $target.ComPort $target.SerialNumber $target.LogPath))
}
$results | Export-Csv -LiteralPath $resultPath -NoTypeInformation -Encoding UTF8
Write-Host "結果CSV: $resultPath"
