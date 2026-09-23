Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$baseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ttlPath = Join-Path $baseDir 'network_SSH_select.ttl'
$commandDir = Join-Path $baseDir 'commands'

if (-not (Test-Path -LiteralPath $ttlPath)) {
    [System.Windows.Forms.MessageBox]::Show("TTL file was not found:`n$ttlPath", "Error")
    exit 1
}

$devices = @(foreach ($line in Get-Content -LiteralPath $ttlPath -Encoding UTF8) {
    if ($line -match "strconcat\s+DEVICE_LIST\s+'([^,;]+),([^;']+);'") {
        [pscustomobject]@{ Name = $Matches[1]; IP = $Matches[2] }
    }
})

if ($devices.Count -eq 0) {
    [System.Windows.Forms.MessageBox]::Show("No devices were found in the TTL file.", "Error")
    exit 1
}

if (-not (Test-Path -LiteralPath $commandDir -PathType Container)) {
    [System.Windows.Forms.MessageBox]::Show("The commands folder was not found:`n$commandDir", "Error")
    exit 1
}

$tests = @(Get-ChildItem -LiteralPath $commandDir -Filter '*.txt' -File |
    Sort-Object Name)
if ($tests.Count -eq 0) {
    [System.Windows.Forms.MessageBox]::Show("No test files were found in the commands folder.", "Error")
    exit 1
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Network SSH Test Runner'
$form.Size = New-Object System.Drawing.Size(900, 650)
$form.StartPosition = 'CenterScreen'
$form.MinimumSize = New-Object System.Drawing.Size(760, 540)
$form.Font = New-Object System.Drawing.Font('Meiryo UI', 10)

$deviceLabel = New-Object System.Windows.Forms.Label
$deviceLabel.Text = '1. Select a device'
$deviceLabel.Location = New-Object System.Drawing.Point(20, 20)
$deviceLabel.AutoSize = $true
$form.Controls.Add($deviceLabel)

$deviceList = New-Object System.Windows.Forms.ListBox
$deviceList.Location = New-Object System.Drawing.Point(20, 50)
$deviceList.Size = New-Object System.Drawing.Size(840, 230)
$deviceList.SelectionMode = 'One'
$deviceList.HorizontalScrollbar = $true
[void]$deviceList.Items.AddRange([string[]]($devices | ForEach-Object { "$($_.Name) ($($_.IP))" }))
$form.Controls.Add($deviceList)

$testLabel = New-Object System.Windows.Forms.Label
$testLabel.Text = '2. Select a test'
$testLabel.Location = New-Object System.Drawing.Point(20, 305)
$testLabel.AutoSize = $true
$form.Controls.Add($testLabel)

$testList = New-Object System.Windows.Forms.ListBox
$testList.Location = New-Object System.Drawing.Point(20, 335)
$testList.Size = New-Object System.Drawing.Size(840, 170)
$testList.HorizontalScrollbar = $true
[void]$testList.Items.AddRange([string[]]($tests | ForEach-Object { $_.BaseName }))
$form.Controls.Add($testList)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = 'Select a device and a test, then click Run.'
$statusLabel.Location = New-Object System.Drawing.Point(20, 525)
$statusLabel.AutoSize = $true
$form.Controls.Add($statusLabel)

$runButton = New-Object System.Windows.Forms.Button
$runButton.Text = 'Run'
$runButton.Location = New-Object System.Drawing.Point(670, 555)
$runButton.Size = New-Object System.Drawing.Size(90, 36)
$runButton.Enabled = $false
$runButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
$form.Controls.Add($runButton)

$cancelButton = New-Object System.Windows.Forms.Button
$cancelButton.Text = 'Cancel'
$cancelButton.Location = New-Object System.Drawing.Point(770, 555)
$cancelButton.Size = New-Object System.Drawing.Size(90, 36)
$cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
$form.Controls.Add($cancelButton)
$form.AcceptButton = $runButton
$form.CancelButton = $cancelButton
$updateRunButton = {
    $runButton.Enabled = ($deviceList.SelectedIndex -ge 0 -and $testList.SelectedIndex -ge 0)
}
$deviceList.Add_SelectedIndexChanged({
    if ($deviceList.SelectedIndex -ge 0) {
        $statusLabel.Text = "Device: $($devices[$deviceList.SelectedIndex].Name) / $($devices[$deviceList.SelectedIndex].IP)"
    }
    & $updateRunButton
})
$testList.Add_SelectedIndexChanged({
    if ($testList.SelectedIndex -ge 0) {
        $statusLabel.Text = "Test: $($tests[$testList.SelectedIndex].BaseName)"
    }
    & $updateRunButton
})
$deviceList.Add_DoubleClick({
    if ($deviceList.SelectedIndex -ge 0 -and $testList.SelectedIndex -ge 0) {
        $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
    }
})
$testList.Add_DoubleClick({
    if ($deviceList.SelectedIndex -ge 0 -and $testList.SelectedIndex -ge 0) {
        $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
    }
})

if ($form.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
    exit 0
}
if ($deviceList.SelectedIndex -lt 0 -or $testList.SelectedIndex -lt 0) {
    [System.Windows.Forms.MessageBox]::Show('Select a device and a test.', 'Error')
    exit 1
}

$device = $devices[$deviceList.SelectedIndex]
$test = $tests[$testList.SelectedIndex].Name
$ttpmacro = Get-Command 'ttpmacro.exe' -ErrorAction SilentlyContinue
if ($null -eq $ttpmacro) {
    $candidates = @(
        (Join-Path ${env:ProgramFiles} 'teraterm\ttpmacro.exe'),
        (Join-Path ${env:ProgramFiles} 'teraterm5\ttpmacro.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'teraterm\ttpmacro.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'teraterm5\ttpmacro.exe'),
        (Join-Path ${env:LOCALAPPDATA} 'teraterm\ttpmacro.exe'),
        (Join-Path ${env:LOCALAPPDATA} 'teraterm5\ttpmacro.exe')
    )
    $ttpmacroPath = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
} else {
    $ttpmacroPath = $ttpmacro.Source
}
if ([string]::IsNullOrWhiteSpace($ttpmacroPath)) {
    [System.Windows.Forms.MessageBox]::Show('ttpmacro.exe was not found. Add the Tera Term folder to PATH.', 'Error')
    exit 1
}

Push-Location -LiteralPath $baseDir
try {
    $env:NETWORK_SSH_HOST = $device.Name
    $env:NETWORK_SSH_IP = $device.IP
    $env:NETWORK_SSH_TEST = $test
    & $ttpmacroPath $ttlPath
} finally {
    Pop-Location
}
