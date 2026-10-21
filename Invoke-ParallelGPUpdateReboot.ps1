#Requires -Version 5.1

<#
.SYNOPSIS
Runs parallel computer-side GPUpdate operations and optionally reboots
successful targets.
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param (
    [Parameter(Mandatory, Position = 0)]
    [Alias('Computer', 'CN', 'Name')]
    [ValidateNotNullOrEmpty()]
    [string[]]$ComputerName,

    # Maximum simultaneous remote operations.
    [ValidateRange(1, 100)]
    [int]$ThrottleLimit = 10,

    # Apply policy but do not reboot successful systems.
    [switch]$SkipReboot
)

# Normalize the supplied target list.
$ComputerName = @(
    $ComputerName |
        ForEach-Object { $_.Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Select-Object -Unique
)

if ($ComputerName.Count -eq 0) {
    throw 'No valid target computers were provided.'
}

# Invoke-Command and gpupdate.exe do not natively honor -WhatIf.
if ($WhatIfPreference) {
    foreach ($Computer in $ComputerName) {
        $Action = if ($SkipReboot) {
            'Run computer-side GPUpdate'
        }
        else {
            'Run computer-side GPUpdate and reboot if successful'
        }

        $null = $PSCmdlet.ShouldProcess($Computer, $Action)
    }

    return
}

$GpUpdateErrors = @()
$RestartErrors = @()

Write-Host "Starting GPUpdate on $($ComputerName.Count) system(s)..." -ForegroundColor Cyan

# Run computer-side GPUpdate concurrently on all targets.
$GpUpdateResults = Invoke-Command `
    -ComputerName $ComputerName `
    -ThrottleLimit $ThrottleLimit `
    -ErrorAction SilentlyContinue `
    -ErrorVariable +GpUpdateErrors `
    -ScriptBlock {
        $null = & "$env:SystemRoot\System32\gpupdate.exe" `
            /target:computer `
            /force `
            /wait:-1

        if ($LASTEXITCODE -ne 0) {
            throw "gpupdate.exe failed with exit code $LASTEXITCODE."
        }

        [PSCustomObject]@{
            ComputerName = $env:COMPUTERNAME
            Status       = 'GPUpdate succeeded'
            Completed    = Get-Date
        }
    }

$SuccessfulComputers = @(
    $GpUpdateResults |
        Select-Object -ExpandProperty PSComputerName -Unique
)

if ($GpUpdateResults) {
    $GpUpdateResults |
        Select-Object PSComputerName, Status, Completed |
        Format-Table -AutoSize
}

if ($SkipReboot) {
    Write-Host 'Reboot phase skipped.' -ForegroundColor Yellow
}
elseif ($SuccessfulComputers.Count -eq 0) {
    Write-Warning 'No systems completed GPUpdate successfully; no reboot commands sent.'
}
else {
    $TargetDescription = "$($SuccessfulComputers.Count) system(s)"

    # Confirm once before initiating forced parallel reboots.
    if ($PSCmdlet.ShouldProcess($TargetDescription, 'Force restart')) {
        Write-Host "Sending reboot requests to $($SuccessfulComputers.Count) system(s)..." `
            -ForegroundColor Yellow

        Restart-Computer `
            -ComputerName $SuccessfulComputers `
            -Protocol WSMan `
            -WsmanAuthentication Kerberos `
            -ThrottleLimit $ThrottleLimit `
            -Force `
            -ErrorAction SilentlyContinue `
            -ErrorVariable +RestartErrors

        Write-Host 'Reboot commands sent.' -ForegroundColor Green
    }
}

if ($GpUpdateErrors.Count -gt 0) {
    Write-Warning 'GPUpdate or remote connection errors occurred:'

    $GpUpdateErrors | ForEach-Object {
        Write-Warning $_
    }
}

if ($RestartErrors.Count -gt 0) {
    Write-Warning 'Reboot command errors occurred:'

    $RestartErrors | ForEach-Object {
        Write-Warning $_
    }
}
