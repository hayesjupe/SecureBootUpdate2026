<#
.SYNOPSIS
    Checks Secure Boot certificate status on local or remote computers.

.DESCRIPTION
    This script checks the Secure Boot status and certificate update progress
    based on Microsoft's guidance for KB5062713. It can run against the local
    machine or a list of computers from a text file.

.PARAMETER ComputerListFile
    Path to a text file containing computer names (one per line).
    If not specified, runs against the local machine.

.PARAMETER ExportPath
    Path to export results as CSV. If not specified, displays results on screen.

.EXAMPLE
    .\Check-SecureBootStatus.ps1
    Checks the local machine.

.EXAMPLE
    .\Check-SecureBootStatus.ps1 -ComputerListFile "C:\computers.txt" -ExportPath "C:\Results.csv"
    Checks all computers in the file and exports results to CSV.

.NOTES
    Requires administrative privileges.
    Based on Microsoft KB5062713 guidance.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$ComputerListFile,
    
    [Parameter(Mandatory=$false)]
    [string]$ExportPath
)

# ============================================================
# CONFIGURATION VARIABLE
# Set to $true to trigger the Secure Boot scheduled task on
# each computer after collecting status. Set to $false to
# collect status only (read-only / reporting mode).
# ============================================================
$KickOffScheduledTask = $true

# Name of the Secure Boot certificate update scheduled task.
# Adjust if your environment uses a different task name.
$SecureBootTaskName = "Microsoft\Windows\PI\Secure-Boot-Update"
# ============================================================

function Get-SecureBootStatus {
    param(
        [string]$ComputerName = $env:COMPUTERNAME
    )
    
    $result = [PSCustomObject]@{
        ComputerName              = $ComputerName
        CollectionTime            = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        SecureBootEnabled         = $null
        SecureBootSupported       = $null
        AvailableUpdates          = $null
        HighConfidenceOptOut      = $null
        UEFICA2023Status          = $null
        UEFICA2023Capable         = $null
        UEFICA2023Error           = $null
        OEMManufacturer           = $null
        OEMModel                  = $null
        FirmwareVersion           = $null
        FirmwareReleaseDate       = $null
        OSVersion                 = $null
        OSArchitecture            = $null
        LatestEvent1799           = $null
        LatestEvent1801           = $null
        LatestEvent1808           = $null
        Event1801Confidence       = $null
        CertificateUpdateStatus   = "Unknown"
        ScheduledTaskTriggered    = $null
        ScheduledTaskResult       = $null
        ErrorMessage              = $null
    }
    
    try {
        # Create script block for remote or local execution
$scriptBlock = {
    $output = @{
        SecureBootEnabled       = $null
        SecureBootSupported     = $null
        AvailableUpdates        = $null
        HighConfidenceOptOut    = $null
        UEFICA2023Status        = $null
        UEFICA2023Capable       = $null
        UEFICA2023Error         = $null
        OEMManufacturer         = $null
        OEMModel                = $null
        FirmwareVersion         = $null
        FirmwareReleaseDate     = $null
        OSArchitecture          = $null
        OSVersion               = $null
        LatestEvent1799         = $null
        LatestEvent1801         = $null
        LatestEvent1808         = $null
        Event1801Confidence     = $null
        CertificateUpdateStatus = "Unknown"
        ErrorMessage            = $null
        WMIError                = $null
        EventLogError           = $null
    }
            
            try {
                # Check Secure Boot status
                try {
                    $output.SecureBootEnabled = Confirm-SecureBootUEFI -ErrorAction Stop
                    $output.SecureBootSupported = $true
                } catch {
                    $output.SecureBootEnabled = $false
                    $output.SecureBootSupported = $false
                    $output.ErrorMessage = "Secure Boot not supported or not enabled: $_"
                }
                
                # Get registry values - Secure Boot Main Key
                # FIX: Read the whole key as a single object, then safely access each
                # property via the object's PSObject.Properties to avoid
                # PropertyNotFoundException when a value doesn't exist on the machine.
                $secureBootPath = "HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot"
                if (Test-Path $secureBootPath) {
                    $sbKey = Get-ItemProperty -Path $secureBootPath -ErrorAction SilentlyContinue
                    if ($sbKey) {
                        if ($sbKey.PSObject.Properties['AvailableUpdates'])     { $output.AvailableUpdates     = $sbKey.AvailableUpdates     }
                        if ($sbKey.PSObject.Properties['HighConfidenceOptOut']) { $output.HighConfidenceOptOut = $sbKey.HighConfidenceOptOut }
                    }
                }
                
                # Get registry values - Servicing Key
                $servicingPath = "HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\Servicing"
                if (Test-Path $servicingPath) {
                    $svcKey = Get-ItemProperty -Path $servicingPath -ErrorAction SilentlyContinue
                    if ($svcKey) {
                        if ($svcKey.PSObject.Properties['UEFICA2023Status'])  { $output.UEFICA2023Status  = $svcKey.UEFICA2023Status  }
                        if ($svcKey.PSObject.Properties['UEFICA2023Capable']) { $output.UEFICA2023Capable = $svcKey.UEFICA2023Capable }
                        if ($svcKey.PSObject.Properties['UEFICA2023Error'])   { $output.UEFICA2023Error   = $svcKey.UEFICA2023Error   }
                    }
                }
                
                # Get Device Attributes
                $deviceAttrPath = "HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\Servicing\DeviceAttributes"
                if (Test-Path $deviceAttrPath) {
                    $daKey = Get-ItemProperty -Path $deviceAttrPath -ErrorAction SilentlyContinue
                    if ($daKey) {
                        if ($daKey.PSObject.Properties['OEMManufacturerName']) { $output.OEMManufacturer     = $daKey.OEMManufacturerName }
                        if ($daKey.PSObject.Properties['OEMModelNumber'])      { $output.OEMModel            = $daKey.OEMModelNumber      }
                        if ($daKey.PSObject.Properties['FirmwareVersion'])     { $output.FirmwareVersion     = $daKey.FirmwareVersion     }
                        if ($daKey.PSObject.Properties['FirmwareReleaseDate']) { $output.FirmwareReleaseDate = $daKey.FirmwareReleaseDate }
                        if ($daKey.PSObject.Properties['OSArchitecture'])      { $output.OSArchitecture      = $daKey.OSArchitecture      }
                    }
                }
                
                # Get WMI/CIM information
                try {
                    $os  = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
                    $ubr = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -Name UBR -ErrorAction SilentlyContinue).UBR
                    $fullVersion = if ($ubr) { "$($os.Version).$ubr" } else { $os.Version }
                    $output.OSVersion = $os.Caption + " " + $fullVersion
                    
                    $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
                    if (!$output.OEMManufacturer) { $output.OEMManufacturer = $cs.Manufacturer }
                    if (!$output.OEMModel)        { $output.OEMModel        = $cs.Model }
                    
                    $bios = Get-CimInstance Win32_BIOS -ErrorAction Stop
                    if (!$output.FirmwareVersion) {
                        $output.FirmwareVersion = $bios.SMBIOSBIOSVersion
                    }
                } catch {
                    $output.WMIError = $_.Exception.Message
                }
                
                # Check Event Logs for 1799, 1801 and 1808
                try {
                    $allEventIds = @(1799, 1801, 1808)
                    $events = @(Get-WinEvent -FilterHashtable @{LogName='System'; ID=$allEventIds} -MaxEvents 30 -ErrorAction SilentlyContinue)
                    
                    $latest1799 = $events | Where-Object {$_.Id -eq 1799} | Sort-Object TimeCreated -Descending | Select-Object -First 1
                    $latest1801 = $events | Where-Object {$_.Id -eq 1801} | Sort-Object TimeCreated -Descending | Select-Object -First 1
                    $latest1808 = $events | Where-Object {$_.Id -eq 1808} | Sort-Object TimeCreated -Descending | Select-Object -First 1
                    
                    if ($latest1799) { $output.LatestEvent1799 = $latest1799.TimeCreated.ToString("yyyy-MM-dd HH:mm:ss") }
                    
                    if ($latest1801) {
                        $output.LatestEvent1801 = $latest1801.TimeCreated.ToString("yyyy-MM-dd HH:mm:ss")
                        if ($latest1801.Message -match '(High Confidence|Needs More Data|Unknown|Paused)') {
                            $output.Event1801Confidence = $matches[1]
                        }
                    }
                    
                    if ($latest1808) { $output.LatestEvent1808 = $latest1808.TimeCreated.ToString("yyyy-MM-dd HH:mm:ss") }
                } catch {
                    $output.EventLogError = $_.Exception.Message
                }
                
                # Determine certificate update status based on AvailableUpdates
                if ($output.AvailableUpdates) {
                    $updates = [int]$output.AvailableUpdates
                    switch ($updates) {
                        0x4000 { $output.CertificateUpdateStatus = "Completed - All certificates updated" }
                        0x5944 { $output.CertificateUpdateStatus = "Not Started - Pending deployment" }
                        0x5904 { $output.CertificateUpdateStatus = "In Progress - Windows UEFI CA 2023 applied" }
                        0x5104 { $output.CertificateUpdateStatus = "In Progress - Option ROM CA applied" }
                        0x4104 { $output.CertificateUpdateStatus = "In Progress - Microsoft UEFI CA applied" }
                        0x4100 { $output.CertificateUpdateStatus = "In Progress - KEK applied, boot manager pending" }
                        default { $output.CertificateUpdateStatus = "In Progress - Custom state (0x$($updates.ToString('X')))" }
                    }
                }
                
                # If Event 1808 exists, certificates are updated
                if ($output.LatestEvent1808) {
                    $output.CertificateUpdateStatus = "Completed - Confirmed by Event 1808"
                }
                
                # If Event 1799 exists, boot manager has been updated (especially relevant for Hyper-V)
                if ($output.LatestEvent1799) {
                    if ($output.LatestEvent1808) {
                        $output.CertificateUpdateStatus = "Completed - Confirmed by Event 1808 and 1799"
                    } else {
                        $output.CertificateUpdateStatus = "Boot Manager Updated - Event 1799 (awaiting Event 1808)"
                    }
                }
                
            } catch {
                $output.ErrorMessage = $_.Exception.Message
            }
            
            return $output
        }
        
        # Execute locally or remotely
        if ($ComputerName -eq $env:COMPUTERNAME -or $ComputerName -eq "localhost" -or $ComputerName -eq ".") {
            $output = & $scriptBlock
        } else {
            try {
                $output = Invoke-Command -ComputerName $ComputerName -ScriptBlock $scriptBlock -ErrorAction Stop
            } catch {
                $result.ErrorMessage = "Failed to connect to $ComputerName : $($_.Exception.Message)"
                return $result
            }
        }
        
        # Populate result object
        $result.SecureBootEnabled       = $output.SecureBootEnabled
        $result.SecureBootSupported     = $output.SecureBootSupported
        $result.AvailableUpdates        = if ($output.AvailableUpdates) { "0x$([int]$output.AvailableUpdates.ToString('X'))" } else { $null }
        $result.HighConfidenceOptOut    = $output.HighConfidenceOptOut
        $result.UEFICA2023Status        = $output.UEFICA2023Status
        $result.UEFICA2023Capable       = $output.UEFICA2023Capable
        $result.UEFICA2023Error         = $output.UEFICA2023Error
        $result.OEMManufacturer         = $output.OEMManufacturer
        $result.OEMModel                = $output.OEMModel
        $result.FirmwareVersion         = $output.FirmwareVersion
        $result.FirmwareReleaseDate     = $output.FirmwareReleaseDate
        $result.OSVersion               = $output.OSVersion
        $result.OSArchitecture          = $output.OSArchitecture
        $result.LatestEvent1799         = $output.LatestEvent1799
        $result.LatestEvent1801         = $output.LatestEvent1801
        $result.LatestEvent1808         = $output.LatestEvent1808
        $result.Event1801Confidence     = $output.Event1801Confidence
        $result.CertificateUpdateStatus = $output.CertificateUpdateStatus
        if ($output.ErrorMessage) { $result.ErrorMessage = $output.ErrorMessage }
        
    } catch {
        $result.ErrorMessage = $_.Exception.Message
    }
    
    return $result
}

function Invoke-SecureBootScheduledTask {
    <#
    .SYNOPSIS
        Triggers the Secure Boot certificate update scheduled task on a target computer.
    .OUTPUTS
        PSCustomObject with ScheduledTaskTriggered ($true/$false) and ScheduledTaskResult (string).
    #>
    param(
        [string]$ComputerName = $env:COMPUTERNAME,
        [string]$TaskName
    )

    $taskResult = [PSCustomObject]@{
        ScheduledTaskTriggered = $false
        ScheduledTaskResult    = $null
    }

    $taskScriptBlock = {
        param($TaskName)
        try {
            $task = Get-ScheduledTask -TaskName ($TaskName -split '\\')[-1] `
                                      -TaskPath  ("\$( ($TaskName -split '\\')[0..($TaskName.Split('\').Count - 2)] -join '\')\" ) `
                                      -ErrorAction Stop
            Start-ScheduledTask -InputObject $task -ErrorAction Stop
            return "Task '$TaskName' triggered successfully"
        } catch {
            return "Failed to trigger task '$TaskName': $($_.Exception.Message)"
        }
    }

    try {
        if ($ComputerName -eq $env:COMPUTERNAME -or $ComputerName -eq "localhost" -or $ComputerName -eq ".") {
            $msg = & $taskScriptBlock -TaskName $TaskName
        } else {
            $msg = Invoke-Command -ComputerName $ComputerName -ScriptBlock $taskScriptBlock -ArgumentList $TaskName -ErrorAction Stop
        }

        $taskResult.ScheduledTaskTriggered = $msg -notlike "Failed*"
        $taskResult.ScheduledTaskResult    = $msg
    } catch {
        $taskResult.ScheduledTaskTriggered = $false
        $taskResult.ScheduledTaskResult    = "Invoke-Command failed: $($_.Exception.Message)"
    }

    return $taskResult
}

# ---------------------------------------------------------------------------
# Main execution
# ---------------------------------------------------------------------------
Write-Host "Secure Boot Certificate Status Checker" -ForegroundColor Cyan
Write-Host "Based on Microsoft KB5062713" -ForegroundColor Cyan
if ($KickOffScheduledTask) {
    Write-Host "Mode: Check + Trigger Scheduled Task ($SecureBootTaskName)" -ForegroundColor Magenta
} else {
    Write-Host "Mode: Check Only (read-only)" -ForegroundColor Gray
}
Write-Host ("-" * 60) -ForegroundColor Cyan

# FIX: Always wrap Get-Content in @() so $computers is always an array,
# even when the file contains only a single line. Without this, PowerShell
# returns a bare [String] object which has no .Count property, causing a
# PropertyNotFoundException in strict mode.
$computers = @()

if ($ComputerListFile) {
    if (Test-Path $ComputerListFile) {
        $computers = @(Get-Content $ComputerListFile | Where-Object { $_.Trim() -ne "" })
        Write-Host "Loaded $($computers.Count) computers from $ComputerListFile" -ForegroundColor Green
    } else {
        Write-Error "Computer list file not found: $ComputerListFile"
        exit 1
    }
} else {
    $computers = @($env:COMPUTERNAME)
    Write-Host "Checking local machine: $env:COMPUTERNAME" -ForegroundColor Green
}

$results  = @()
$current  = 0
$skipped  = 0
$tasksFired = 0

foreach ($computer in $computers) {
    $current++
    Write-Progress -Activity "Checking Secure Boot Status" -Status "Processing $computer" -PercentComplete (($current / $computers.Count) * 100)
    
    Write-Host "`nChecking $computer..." -ForegroundColor Yellow
    
    # Ping test for remote computers
    if ($computer -ne $env:COMPUTERNAME -and $computer -ne "localhost" -and $computer -ne ".") {
        Write-Host "  Testing connectivity..." -ForegroundColor Gray -NoNewline
        if (Test-Connection -ComputerName $computer -Count 1 -Quiet -ErrorAction SilentlyContinue) {
            Write-Host " Online" -ForegroundColor Green
        } else {
            Write-Host " Offline - Skipping" -ForegroundColor Red
            $skipped++
            continue
        }
    }
    
    $result = Get-SecureBootStatus -ComputerName $computer
    
    # Optionally trigger the Secure Boot scheduled task
    if ($KickOffScheduledTask) {
        Write-Host "  Triggering scheduled task..." -ForegroundColor Gray -NoNewline
        $taskOutcome = Invoke-SecureBootScheduledTask -ComputerName $computer -TaskName $SecureBootTaskName
        $result.ScheduledTaskTriggered = $taskOutcome.ScheduledTaskTriggered
        $result.ScheduledTaskResult    = $taskOutcome.ScheduledTaskResult

        if ($taskOutcome.ScheduledTaskTriggered) {
            Write-Host " OK" -ForegroundColor Green
            $tasksFired++
        } else {
            Write-Host " FAILED" -ForegroundColor Red
            Write-Host "  Task Error: $($taskOutcome.ScheduledTaskResult)" -ForegroundColor Red
        }
    } else {
        $result.ScheduledTaskTriggered = "N/A"
        $result.ScheduledTaskResult    = "N/A"
    }

    $results += $result
    
    # Display key information
    if ($result.ErrorMessage) {
        Write-Host "  ERROR: $($result.ErrorMessage)" -ForegroundColor Red
    } else {
        Write-Host "  Secure Boot: $($result.SecureBootEnabled)" -ForegroundColor $(if ($result.SecureBootEnabled) { "Green" } else { "Red" })
        if (-not $result.SecureBootEnabled) {
            $osDisplay = if ($result.OSVersion) { $result.OSVersion } else { "OS version unavailable" }
            Write-Host "  OS Version:  $osDisplay" -ForegroundColor Yellow
            Write-Host "  NOTE: Secure Boot disabled - may not yet be patched or unsupported hardware" -ForegroundColor DarkYellow
        }
        Write-Host "  Status: $($result.CertificateUpdateStatus)" -ForegroundColor Cyan
        if ($result.AvailableUpdates) {
            Write-Host "  Available Updates: $($result.AvailableUpdates)" -ForegroundColor Gray
        }
    }
}

Write-Progress -Activity "Checking Secure Boot Status" -Completed

# Output results
if ($ExportPath) {
    $results | Export-Csv -Path $ExportPath -NoTypeInformation
    Write-Host "`nResults exported to: $ExportPath" -ForegroundColor Green
}

# Summary
Write-Host "`n`nSummary:" -ForegroundColor Cyan
Write-Host ("=" * 60) -ForegroundColor Cyan
Write-Host "Total Computers in List:    $($computers.Count)"
Write-Host "Computers Checked:          $(@($results).Count)"
if ($skipped -gt 0) {
    Write-Host "Computers Skipped (Offline): $skipped" -ForegroundColor Yellow
}
Write-Host "Secure Boot Enabled:        $(@($results | Where-Object { $_.SecureBootEnabled -eq $true }).Count)"
Write-Host "Secure Boot Disabled:       $(@($results | Where-Object { $_.SecureBootEnabled -eq $false }).Count)"
Write-Host "Updates Completed:          $(@($results | Where-Object { $_.CertificateUpdateStatus -like '*Completed*' }).Count)"
Write-Host "Updates In Progress:        $(@($results | Where-Object { $_.CertificateUpdateStatus -like '*In Progress*' }).Count)"
Write-Host "Errors:                     $(@($results | Where-Object { $_.ErrorMessage }).Count)"
if ($KickOffScheduledTask) {
    Write-Host "Scheduled Tasks Triggered:  $tasksFired" -ForegroundColor Magenta
    Write-Host "Task Trigger Failures:      $(@($results | Where-Object { $_.ScheduledTaskTriggered -eq $false }).Count)" -ForegroundColor $(if (@($results | Where-Object { $_.ScheduledTaskTriggered -eq $false }).Count -gt 0) { "Red" } else { "White" })
}
