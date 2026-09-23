# ==========================================
# IP Address Add / Delete Tool
# ==========================================

$CsvPath = Join-Path $PSScriptRoot "secondary_ips.csv"

# ------------------------------------------
# Check CSV
# ------------------------------------------

if (-not (Test-Path $CsvPath)) {
    Write-Host ""
    Write-Host "ERROR: CSV not found." -ForegroundColor Red
    Write-Host $CsvPath -ForegroundColor Red
    exit 1
}

# ------------------------------------------
# Get NIC list
# ------------------------------------------

$adapters = @(Get-NetAdapter | Sort-Object ifIndex)

if ($adapters.Count -eq 0) {
    Write-Host "ERROR: NIC not found." -ForegroundColor Red
    exit 1
}

# ------------------------------------------
# Select NIC
# ------------------------------------------

Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host " IP Address Add / Delete Tool" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""

Write-Host "Select Target NIC:"
Write-Host ""

for ($i = 0; $i -lt $adapters.Count; $i++) {

    $adapter = $adapters[$i]

    Write-Host ("  {0} : {1}  [ifIndex={2}, Status={3}]" -f `
        ($i + 1),
        $adapter.Name,
        $adapter.ifIndex,
        $adapter.Status)
}

Write-Host ""
Write-Host "  0 : Exit"
Write-Host ""

$nicChoice = Read-Host "Select NIC"

if ($nicChoice -eq "0") {
    exit 0
}

$nicNumber = 0

if (-not [int]::TryParse($nicChoice, [ref]$nicNumber)) {
    Write-Host "Invalid selection." -ForegroundColor Red
    exit 1
}

if ($nicNumber -lt 1 -or $nicNumber -gt $adapters.Count) {
    Write-Host "Invalid selection." -ForegroundColor Red
    exit 1
}

$selectedAdapter = $adapters[$nicNumber - 1]
$InterfaceIndex = $selectedAdapter.ifIndex

Write-Host ""
Write-Host "Selected NIC:" -ForegroundColor Green
Write-Host "  Name    : $($selectedAdapter.Name)"
Write-Host "  ifIndex : $InterfaceIndex"
Write-Host "  Status  : $($selectedAdapter.Status)"
Write-Host ""

# ------------------------------------------
# Select operation
# ------------------------------------------

Write-Host "Select operation:"
Write-Host ""
Write-Host "  1 : Add IP addresses"
Write-Host "  2 : Delete IP addresses"
Write-Host "  3 : Show current IP addresses"
Write-Host "  0 : Exit"
Write-Host ""

$mode = Read-Host "Select"

# ==========================================
# ADD
# ==========================================

if ($mode -eq "1") {

    Write-Host ""
    Write-Host "Adding IP addresses..." -ForegroundColor Cyan
    Write-Host ""

    $existingIPs = @(
        Get-NetIPAddress `
            -InterfaceIndex $InterfaceIndex `
            -AddressFamily IPv4 `
            -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty IPAddress
    )

    # Existing default gateways
    $existingGateways = @(
        Get-NetIPConfiguration `
            -InterfaceIndex $InterfaceIndex `
            -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty IPv4DefaultGateway |
            Where-Object { $_ } |
            Select-Object -ExpandProperty NextHop
    )

    Import-Csv $CsvPath | ForEach-Object {

        $ip = $_.IPAddress
        $prefix = $_.PrefixLength
        $gateway = $_.DefaultGateway

        if ([string]::IsNullOrWhiteSpace($ip)) {
            return
        }

        if ([string]::IsNullOrWhiteSpace($prefix)) {
            $prefix = 24
        }

        # Already exists
        if ($existingIPs -contains $ip) {
            Write-Host "$ip : already exists" -ForegroundColor Yellow
            return
        }

        try {

            # Gateway specified
            if (-not [string]::IsNullOrWhiteSpace($gateway)) {

                # Gateway already exists
                if ($existingGateways -contains $gateway) {

                    New-NetIPAddress `
                        -InterfaceIndex $InterfaceIndex `
                        -IPAddress $ip `
                        -PrefixLength ([int]$prefix) `
                        -AddressFamily IPv4 `
                        -ErrorAction Stop

                    Write-Host "$ip/$prefix : added (Gateway already exists: $gateway)" -ForegroundColor Green
                }

                # Gateway does not exist
                else {

                    New-NetIPAddress `
                        -InterfaceIndex $InterfaceIndex `
                        -IPAddress $ip `
                        -PrefixLength ([int]$prefix) `
                        -DefaultGateway $gateway `
                        -AddressFamily IPv4 `
                        -ErrorAction Stop

                    # Keep local list updated
                    $existingGateways += $gateway

                    Write-Host "$ip/$prefix : added (Gateway=$gateway)" -ForegroundColor Green
                }
            }

            # No Gateway
            else {

                New-NetIPAddress `
                    -InterfaceIndex $InterfaceIndex `
                    -IPAddress $ip `
                    -PrefixLength ([int]$prefix) `
                    -AddressFamily IPv4 `
                    -ErrorAction Stop

                Write-Host "$ip/$prefix : added (No Gateway)" -ForegroundColor Green
            }

            # Keep local IP list updated
            $existingIPs += $ip
        }
        catch {

            Write-Host "$ip : FAILED" -ForegroundColor Red
            Write-Host "  $($_.Exception.Message)" -ForegroundColor Red

        }
    }
}


# ==========================================
# DELETE
# ==========================================

elseif ($mode -eq "2") {

    Write-Host ""
    Write-Host "Deleting IP addresses..." -ForegroundColor Yellow
    Write-Host ""

    Import-Csv $CsvPath | ForEach-Object {

        $ip = $_.IPAddress

        if ([string]::IsNullOrWhiteSpace($ip)) {
            return
        }

        try {

            $address = Get-NetIPAddress `
                -InterfaceIndex $InterfaceIndex `
                -IPAddress $ip `
                -AddressFamily IPv4 `
                -ErrorAction SilentlyContinue

            if (-not $address) {
                Write-Host "$ip : not found" -ForegroundColor Yellow
                return
            }

            Remove-NetIPAddress `
                -InterfaceIndex $InterfaceIndex `
                -IPAddress $ip `
                -Confirm:$false `
                -ErrorAction Stop

            Write-Host "$ip : deleted" -ForegroundColor Green

        }
        catch {

            Write-Host "$ip : FAILED" -ForegroundColor Red
            Write-Host "  $($_.Exception.Message)" -ForegroundColor Red

        }
    }
}

# ==========================================
# SHOW
# ==========================================

elseif ($mode -eq "3") {

    Write-Host ""
    Write-Host "Current IPv4 addresses:" -ForegroundColor Cyan
    Write-Host ""

    Get-NetIPAddress `
        -InterfaceIndex $InterfaceIndex `
        -AddressFamily IPv4 `
        -ErrorAction SilentlyContinue |
        Format-Table IPAddress,PrefixLength,AddressState -AutoSize
}

# ==========================================
# EXIT
# ==========================================

elseif ($mode -eq "0") {

    exit 0

}

else {

    Write-Host ""
    Write-Host "Invalid selection." -ForegroundColor Red

}

Write-Host ""
Write-Host "Done." -ForegroundColor Cyan
