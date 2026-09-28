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
$csvColumns = if ($settings.PSObject.Properties['CsvColumns']) { $settings.CsvColumns } else { [pscustomobject]@{} }
function Get-DeviceValue([object]$device,[string]$fieldName) {
    $columnProperty = $csvColumns.PSObject.Properties[$fieldName]
    $columnName = if ($columnProperty) { [string]$columnProperty.Value } else { $fieldName }
    if ([string]::IsNullOrWhiteSpace($columnName)) { return '' }
    $property = $device.PSObject.Properties[$columnName]
    if (-not $property -or $null -eq $property.Value) { return '' }
    return [string]$property.Value
}
$templateRules = @($settings.TemplateRules)
if ($templateRules.Count -eq 0) {
    throw 'settings.json TemplateRules is empty.'
}
$devices = Import-Csv -LiteralPath $DeviceCsv

foreach ($device in $devices) {
    $ruleMatches = @($templateRules | Where-Object {
        $patternProperty = $_.PSObject.Properties['Pattern']
        $legacyPatternProperty = $_.PSObject.Properties['HostnamePattern']
        $matchFieldProperty = $_.PSObject.Properties['MatchField']
        $pattern = if ($patternProperty -and -not [string]::IsNullOrWhiteSpace([string]$patternProperty.Value)) {
            [string]$patternProperty.Value
        } elseif ($legacyPatternProperty) {
            [string]$legacyPatternProperty.Value
        } else {
            ''
        }
        $ruleField = if ($matchFieldProperty -and -not [string]::IsNullOrWhiteSpace([string]$matchFieldProperty.Value)) {
            [string]$matchFieldProperty.Value
        } elseif ($settings.PSObject.Properties['TemplateMatchField'] -and -not [string]::IsNullOrWhiteSpace([string]$settings.TemplateMatchField)) {
            [string]$settings.TemplateMatchField
        } else {
            'Hostname'
        }
        $matchValue = Get-DeviceValue $device $ruleField
        $pattern -and $matchValue -match $pattern
    })
    if ($ruleMatches.Count -ne 1) {
        throw "CSV row matched $($ruleMatches.Count) template rules. Exactly one match is required."
    }
    $commandsProperty = $ruleMatches[0].PSObject.Properties['Commands']
    if ($commandsProperty -and $commandsProperty.Value) {
        $text = ($commandsProperty.Value -join "`r`n")
    } else {
        $templateProperty = $ruleMatches[0].PSObject.Properties['Template']
        if (-not $templateProperty -or [string]::IsNullOrWhiteSpace([string]$templateProperty.Value)) {
            throw "Template rule '$($ruleMatches[0].Id)' must define either Commands or Template."
        }
        $templatePath = Join-Path $root ([string]$templateProperty.Value)
        if (-not (Test-Path -LiteralPath $templatePath)) {
            throw "Template file was not found for match value '$matchValue': $templatePath"
        }
        $text = Get-Content -LiteralPath $templatePath -Raw -Encoding UTF8
    }
    foreach ($property in $device.PSObject.Properties) {
        $name = [string]$property.Name
        $value = if ($null -eq $property.Value) { '' } else { [string]$property.Value }
        $text = $text.Replace("{{$name}}", $value)
    }
    foreach ($mapping in $csvColumns.PSObject.Properties) {
        $text = $text.Replace("{{$($mapping.Name)}}", (Get-DeviceValue $device ([string]$mapping.Name)))
    }
    $unresolved = [regex]::Matches($text, '\{\{([A-Za-z_][A-Za-z0-9_]*)\}\}') |
        ForEach-Object { $_.Groups[1].Value } |
        Select-Object -Unique
    if (@($unresolved).Count -gt 0) {
        throw "Template contains CSV fields not found in devices.csv: $($unresolved -join ', ')"
    }
    $id = Get-DeviceValue $device 'DeviceID'
    if ([string]::IsNullOrWhiteSpace($id)) { $id = Get-DeviceValue $device 'SerialNumber' }
    if ([string]::IsNullOrWhiteSpace($id)) { $id = 'device' }
    $safeId = [regex]::Replace($id, '[^A-Za-z0-9_.-]', '_')
    $path = Join-Path $OutputDirectory "$safeId.config.txt"
    Set-Content -LiteralPath $path -Value $text -Encoding UTF8 -NoNewline
    Write-Host "Generated: $path"
}
