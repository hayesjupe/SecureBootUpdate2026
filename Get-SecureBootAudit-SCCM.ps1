# ============================================================
# Get-SecureBootAudit-SCCM.ps1
# Pulls devices from 3 SCCM collections, pings each machine,
# and retrieves hardware/OS/BIOS/SecureBoot info to CSV.
# ============================================================

#Requires -Version 5.1

# --- SCCM Module ---
$cmPath = Join-Path $env:SMS_ADMIN_UI_PATH "..\ConfigurationManager.psd1"
Import-Module $cmPath -ErrorAction Stop

# --- CONFIGURATION ---
$SCCMSiteServer = "SCCM.company.com"
$SCCMSiteCode   = "XXX"

$Collections = @(
    "CB-Secure.Boot.Update.Incomplete-EUC",
    "CB-Secure.Boot.Update.Incomplete-Servers"
)

$LogPath    = "C:\SecureBoot"
$ExportPath = "$LogPath\SecureBoot_Audit_$(Get-Date -Format 'yyyy-MM-dd_HHmmss').csv"

# Set to a number to limit devices processed (e.g. 10 for testing). Set to 0 for all devices.
$TestLimit  = 0

# ============================================================

# --- LOG SETUP ---
if (-not (Test-Path $LogPath)) { New-Item -Path $LogPath -ItemType Directory | Out-Null }
$LogFile = "$LogPath\SecureBoot_Audit_$(Get-Date -Format 'yyyy-MM-dd_HHmmss').log"

function Write-Log {
    param([string]$Message, [string]$Color = "White")
    $Line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
    $Line | Out-File -Append -FilePath $LogFile
    Write-Host $Line -ForegroundColor $Color
}

# --- HELPER: Resolve OverallStatus from a completed Result object ---
function Get-OverallStatus {
    param([PSCustomObject]$Result)

    if (-not $Result.Pingable) { return "Not Pingable" }

    switch ($Result.CertificateUpdateStatus) {
        "Completed - Confirmed by Event 1808"                        { return "Complete - will be removed from this list soon" }
        "Completed - Confirmed by Event 1808 and 1799"               { return "Complete - will be removed from this list soon" }
        "In Progress - KEK applied, boot manager pending"            { return "Reboot required to proceed to next step" }
        "Boot Manager Updated - Event 1799 (awaiting Event 1808)"    { return "Reboot required to complete" }
        "Not Started - Pending deployment"                           { return "Windows updates required before process can commence" }
        "In Progress - Custom state (0x2)"                           { return "BIOS updates required before process can commence" }
        "Unknown"                                                    { return "BIOS and Windows update required before process can commence" }
        "In Progress - Microsoft UEFI CA applied"                    { return "Likely VM - if VMWare, delete NVRam. If Hyper-V, toggle boot image" }
        "In Progress - Windows UEFI CA 2023 applied"                 { return "Likely VM - if VMWare, delete NVRam. If Hyper-V, toggle boot image" }
    }

    if ($Result.ErrorMessage) { return "Error retrieving status" }

    return "Unknown"
}

# --- CONNECT TO SCCM ---
Write-Log "Connecting to SCCM site $SCCMSiteCode on $SCCMSiteServer" "Cyan"
Set-Location "$SCCMSiteCode`:"

# --- COLLECT DEVICES FROM ALL 3 COLLECTIONS ---
$AllDevices = @()

foreach ($CollectionName in $Collections) {
    $Collection = Get-CMDeviceCollection -Name $CollectionName
    if (-not $Collection) {
        Write-Log "WARNING: Collection '$CollectionName' not found, skipping." "Yellow"
        continue
    }

    $Devices = @(Get-CMDevice -CollectionId $Collection.CollectionID | Select-Object Name)
    Write-Log "Collection '$CollectionName': $($Devices.Count) devices" "Green"

    foreach ($Device in $Devices) {
        $AllDevices += [PSCustomObject]@{
            Name       = $Device.Name
            Collection = $CollectionName
        }
    }
}

# Return to filesystem after SCCM work
Set-Location C:

Write-Log "Total devices across all collections: $($AllDevices.Count)" "Cyan"

if ($TestLimit -gt 0) {
    $AllDevices = $AllDevices | Select-Object -First $TestLimit
    Write-Log "TEST MODE: Limiting to $TestLimit devices" "Magenta"
}

# --- REMOTE SCRIPT BLOCK ---
$ScriptBlock = {
    $output = @{
        Make                    = $null
        Model                   = $null
        BIOSVersion             = $null
        OSVersion               = $null
        LastPatchDate           = $null
        SecureBootEnabled       = $null
        AvailableUpdates        = $null
        UEFICA2023Status        = $null
        UEFICA2023Capable       = $null
        UEFICA2023Error         = $null
        LatestEvent1799         = $null
        LatestEvent1801         = $null
        LatestEvent1808         = $null
        Event1801Confidence     = $null
        CertificateUpdateStatus = "Unknown"
        ErrorMessage            = $null
    }

    try {
        # Make / Model
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        $output.Make  = $cs.Manufacturer
        $output.Model = $cs.Model

        # BIOS Version
        $bios = Get-CimInstance Win32_BIOS -ErrorAction Stop
        $output.BIOSVersion = $bios.SMBIOSBIOSVersion

        # OS Version (full build number e.g. 10.0.22631.4890)
        $os  = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $ubr = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -Name UBR -ErrorAction SilentlyContinue).UBR
        $output.OSVersion = if ($ubr) { "$($os.Version).$ubr" } else { $os.Version }

        # Last Patch Date
        $HotFix = Get-HotFix -ErrorAction SilentlyContinue |
          ForEach-Object {
              $date = $null
              if ($_.InstalledOn) {
                  try { $date = [datetime]$_.InstalledOn } catch { $date = $null }
              }
              [PSCustomObject]@{
                  HotFixID    = $_.HotFixID
                  InstalledOn = $date
              }
          } |
          Where-Object { $_.InstalledOn -ne $null } |
          Sort-Object InstalledOn -Descending |
          Select-Object -First 1

        $output.LastPatchDate = if ($HotFix -and $HotFix.InstalledOn) {
            $HotFix.InstalledOn.ToString("yyyy-MM-dd")
        } else {
            $Session = New-Object -ComObject Microsoft.Update.Session
            $Searcher = $Session.CreateUpdateSearcher()
            $HistoryCount = $Searcher.GetTotalHistoryCount()
            if ($HistoryCount -gt 0) {
                $LastUpdate = $Searcher.QueryHistory(0, 1) | Select-Object -First 1
                if ($LastUpdate) { $LastUpdate.Date.ToString("yyyy-MM-dd") } else { "Unknown" }
            } else { "Unknown" }
        }

        # Secure Boot enabled
        try {
            $output.SecureBootEnabled = Confirm-SecureBootUEFI -ErrorAction Stop
        } catch {
            $output.SecureBootEnabled = $false
        }

        # Secure Boot registry - main key
        $secureBootPath = "HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot"
        if (Test-Path $secureBootPath) {
            $sbKey = Get-ItemProperty -Path $secureBootPath -ErrorAction SilentlyContinue
            if ($sbKey -and $sbKey.PSObject.Properties['AvailableUpdates']) {
                $output.AvailableUpdates = $sbKey.AvailableUpdates
            }
        }

        # Secure Boot registry - servicing key
        $servicingPath = "HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\Servicing"
        if (Test-Path $servicingPath) {
            $svcKey = Get-ItemProperty -Path $servicingPath -ErrorAction SilentlyContinue
            if ($svcKey) {
                if ($svcKey.PSObject.Properties['UEFICA2023Status'])  { $output.UEFICA2023Status  = $svcKey.UEFICA2023Status  }
                if ($svcKey.PSObject.Properties['UEFICA2023Capable']) { $output.UEFICA2023Capable = $svcKey.UEFICA2023Capable }
                if ($svcKey.PSObject.Properties['UEFICA2023Error'])   { $output.UEFICA2023Error   = $svcKey.UEFICA2023Error   }
            }
        }

        # Event logs - 1799, 1801, 1808
        try {
            $events = @(Get-WinEvent -FilterHashtable @{LogName='System'; ID=@(1799,1801,1808)} -MaxEvents 30 -ErrorAction SilentlyContinue)
            $latest1799 = $events | Where-Object { $_.Id -eq 1799 } | Sort-Object TimeCreated -Descending | Select-Object -First 1
            $latest1801 = $events | Where-Object { $_.Id -eq 1801 } | Sort-Object TimeCreated -Descending | Select-Object -First 1
            $latest1808 = $events | Where-Object { $_.Id -eq 1808 } | Sort-Object TimeCreated -Descending | Select-Object -First 1
            if ($latest1799) { $output.LatestEvent1799 = $latest1799.TimeCreated.ToString("yyyy-MM-dd HH:mm:ss") }
            if ($latest1801) {
                $output.LatestEvent1801 = $latest1801.TimeCreated.ToString("yyyy-MM-dd HH:mm:ss")
                if ($latest1801.Message -match '(High Confidence|Needs More Data|Unknown|Paused)') {
                    $output.Event1801Confidence = $matches[1]
                }
            }
            if ($latest1808) { $output.LatestEvent1808 = $latest1808.TimeCreated.ToString("yyyy-MM-dd HH:mm:ss") }
        } catch {}

        # Certificate update status from AvailableUpdates
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

        if ($output.LatestEvent1808) { $output.CertificateUpdateStatus = "Completed - Confirmed by Event 1808" }
        if ($output.LatestEvent1799) {
            $output.CertificateUpdateStatus = if ($output.LatestEvent1808) {
                "Completed - Confirmed by Event 1808 and 1799"
            } else {
                "Boot Manager Updated - Event 1799 (awaiting Event 1808)"
            }
        }

    } catch {
        $output.ErrorMessage = $_.Exception.Message
    }

    return $output
}

# --- PROCESS EACH DEVICE ---
$Results     = @()
$CountOnline = 0
$CountOffline = 0
$CountError  = 0
$AllDevices  = @($AllDevices)
$Total       = $AllDevices.Count
$Current     = 0

foreach ($Device in $AllDevices) {
    $Current++
    $DeviceName = $Device.Name
    $Collection = $Device.Collection

    Write-Progress -Activity "Auditing Secure Boot Status" `
                   -Status "$Current / $Total : $DeviceName" `
                   -PercentComplete (($Current / $Total) * 100)

    Write-Log "[$Current/$Total] Processing: $DeviceName ($Collection)"

    # Base result object
    $Result = [PSCustomObject]@{
        ComputerName            = $DeviceName
        Collection              = $Collection
        Pingable                = $false
        Make                    = $null
        Model                   = $null
        BIOSVersion             = $null
        OSVersion               = $null
        LastPatchDate           = $null
        SecureBootEnabled       = $null
        CertificateUpdateStatus = $null
        AvailableUpdates        = $null
        UEFICA2023Status        = $null
        UEFICA2023Capable       = $null
        UEFICA2023Error         = $null
        LatestEvent1799         = $null
        LatestEvent1801         = $null
        LatestEvent1808         = $null
        Event1801Confidence     = $null
        ErrorMessage            = $null
        OverallStatus           = $null
    }

    # Ping test
    if (-not (Test-Connection -ComputerName $DeviceName -Count 1 -Quiet -ErrorAction SilentlyContinue)) {
        Write-Log "  OFFLINE: $DeviceName" "Red"
        $Result.Pingable      = $false
        $Result.ErrorMessage  = "Not pingable"
        $Result.OverallStatus = Get-OverallStatus -Result $Result
        $CountOffline++
        $Results += $Result
        continue
    }

    $Result.Pingable = $true
    $CountOnline++

    # Remote data collection (with timeout)
    try {
        $Job = Invoke-Command -ComputerName $DeviceName -ScriptBlock $ScriptBlock -AsJob -ErrorAction Stop
        $Completed = Wait-Job -Job $Job -Timeout 60

        if (-not $Completed) {
            Stop-Job -Job $Job
            Remove-Job -Job $Job -Force
            Write-Log "  TIMEOUT: $DeviceName - no response after 60 seconds, skipping." "Yellow"
            $Result.ErrorMessage  = "Timed out after 60 seconds"
            $Result.OverallStatus = Get-OverallStatus -Result $Result
            $CountError++
        } else {
            $Data = Receive-Job -Job $Job
            Remove-Job -Job $Job -Force

            $Result.Make                    = $Data.Make
            $Result.Model                   = $Data.Model
            $Result.BIOSVersion             = $Data.BIOSVersion
            $Result.OSVersion               = $Data.OSVersion
            $Result.LastPatchDate           = $Data.LastPatchDate
            $Result.SecureBootEnabled       = $Data.SecureBootEnabled
            $Result.CertificateUpdateStatus = $Data.CertificateUpdateStatus
            $Result.AvailableUpdates        = if ($Data.AvailableUpdates) { "0x$([int]$Data.AvailableUpdates.ToString('X'))" } else { $null }
            $Result.UEFICA2023Status        = $Data.UEFICA2023Status
            $Result.UEFICA2023Capable       = $Data.UEFICA2023Capable
            $Result.UEFICA2023Error         = $Data.UEFICA2023Error
            $Result.LatestEvent1799         = $Data.LatestEvent1799
            $Result.LatestEvent1801         = $Data.LatestEvent1801
            $Result.LatestEvent1808         = $Data.LatestEvent1808
            $Result.Event1801Confidence     = $Data.Event1801Confidence
            $Result.ErrorMessage            = $Data.ErrorMessage
            $Result.OverallStatus           = Get-OverallStatus -Result $Result

            Write-Log "  OK - SecureBoot: $($Data.SecureBootEnabled) | CertStatus: $($Data.CertificateUpdateStatus) | OverallStatus: $($Result.OverallStatus) | OS: $($Data.OSVersion)" "Green"
        }

    } catch {
        Write-Log "  ERROR: $DeviceName - $($_.Exception.Message)" "Red"
        $Result.ErrorMessage  = $_.Exception.Message
        $Result.OverallStatus = Get-OverallStatus -Result $Result
        $CountError++
    }

    $Results += $Result
}

Write-Progress -Activity "Auditing Secure Boot Status" -Completed

# --- EXPORT CSV ---
$Results | Export-Csv -Path $ExportPath -NoTypeInformation
Write-Log "Results exported to: $ExportPath" "Cyan"

# --- SUMMARY ---
Write-Log "--- Summary ---" "Cyan"
Write-Log "    Total devices     : $Total"
Write-Log "    Online / checked  : $CountOnline"
Write-Log "    Offline / skipped : $CountOffline"
Write-Log "    Remote errors     : $CountError"
Write-Log "    Secure Boot ON    : $(@($Results | Where-Object { $_.SecureBootEnabled -eq $true }).Count)"
Write-Log "    Secure Boot OFF   : $(@($Results | Where-Object { $_.SecureBootEnabled -eq $false }).Count)"
Write-Log "--- Audit complete ---" "Cyan"