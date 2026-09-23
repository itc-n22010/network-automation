[CmdletBinding()]
param(
    [string]$DeviceCsv,
    [string]$Template,
    [string]$OutputDirectory,
    [string]$SettingsPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrWhiteSpace($DeviceCsv)) {
    $DeviceCsv = Join-Path $root 'config\devices.csv'
}
if ([string]::IsNullOrWhiteSpace($Template)) {
    $Template = Join-Path $root 'templates\cisco_config.template.txt'
}
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $root 'generated'
}
if ([string]::IsNullOrWhiteSpace($SettingsPath)) {
    $SettingsPath = Join-Path $root 'config\settings.json'
}

New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$settings = Get-Content -LiteralPath $SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
$templateRules = @($settings.TemplateRules)
if ($templateRules.Count -eq 0) {
    throw 'settings.json TemplateRules is empty.'
}
$requiredFields = @($settings.RequiredCsvFields)
if ($requiredFields.Count -eq 0) {
    throw 'settings.json RequiredCsvFields is empty.'
}
$devices = Import-Csv -LiteralPath $DeviceCsv

foreach ($device in $devices) {
    foreach ($name in $requiredFields) {
        if ([string]::IsNullOrWhiteSpace([string]$device.$name)) {
            throw "CSV field '$name' is empty for DeviceID '$($device.DeviceID)'."
        }
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
    $safeId = [regex]::Replace([string]$device.DeviceID, '[^A-Za-z0-9_.-]', '_')
    $path = Join-Path $OutputDirectory "$safeId.config.txt"
    Set-Content -LiteralPath $path -Value $text -Encoding UTF8 -NoNewline
    Write-Host "Generated: $path"
}
