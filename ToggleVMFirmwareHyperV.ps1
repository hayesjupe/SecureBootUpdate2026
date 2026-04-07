<#
.SYNOPSIS
    Toggles SecureBoot template for Hyper-V VMs to address SecureBoot issues.
    Searches across multiple clusters and skips if VM not found on a cluster.
#>
$VMListFile = "C:\SecureBoot\vms.txt"
$ClusterNames = @("HyperVCL1", "HyperVCL2", "HyperVCL3")

# Check if running as Administrator
if (-NOT ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Error "This script must be run as Administrator!"
    exit 1
}

# Check if file exists
if (-not (Test-Path $VMListFile)) {
    Write-Error "VM list file not found: $VMListFile"
    exit 1
}

# Read VM names from file
$vmNames = @(Get-Content $VMListFile | Where-Object { $_.Trim() -ne "" })
if ($vmNames.Count -eq 0) {
    Write-Warning "No VM names found in file: $VMListFile"
    exit 0
}

Write-Host "Found $($vmNames.Count) VM(s) to process across $($ClusterNames.Count) cluster(s)" -ForegroundColor Cyan
Write-Host ""

foreach ($vmName in $vmNames) {
    $vmName = $vmName.Trim()
    Write-Host "Processing VM: $vmName" -ForegroundColor Yellow

    $foundOnCluster = $null

    # Search each cluster for the VM
    foreach ($cluster in $ClusterNames) {
        try {
            $vm = Get-VM -Name $vmName -ComputerName $cluster -ErrorAction Stop
            $foundOnCluster = $cluster
            Write-Host "  Found on cluster: $cluster" -ForegroundColor Gray
            break
        } catch {
            Write-Host "  Not found on cluster: $cluster — skipping" -ForegroundColor DarkGray
        }
    }

    if (-not $foundOnCluster) {
        Write-Warning "  ✗ VM '$vmName' not found on any cluster. Skipping."
        Write-Host ""
        continue
    }

    try {
        # Store original state
        $originalState = $vm.State
        Write-Host "  Current state: $originalState" -ForegroundColor Gray

        # Stop the VM if it's running
        if ($vm.State -eq 'Running') {
            Write-Host "  Stopping VM..." -ForegroundColor Gray
            Stop-VM -Name $vmName -ComputerName $foundOnCluster -Force -ErrorAction Stop

            # Wait for VM to stop completely
            $timeout = 60
            $elapsed = 0
            while ((Get-VM -Name $vmName -ComputerName $foundOnCluster).State -ne 'Off' -and $elapsed -lt $timeout) {
                Start-Sleep -Seconds 2
                $elapsed += 2
            }

            if ((Get-VM -Name $vmName -ComputerName $foundOnCluster).State -ne 'Off') {
                Write-Warning "  VM did not stop within timeout period. Skipping..."
                continue
            }
        }

        # Change SecureBoot Template to Microsoft UEFI Certificate Authority
        Write-Host "  Changing SecureBoot template to 'MicrosoftUEFICertificateAuthority'..." -ForegroundColor Gray
        Set-VMFirmware -VMName $vmName -ComputerName $foundOnCluster -SecureBootTemplate "MicrosoftUEFICertificateAuthority" -ErrorAction Stop

        # Change SecureBoot Template back to Microsoft Windows
        Write-Host "  Changing SecureBoot template back to 'MicrosoftWindows'..." -ForegroundColor Gray
        Set-VMFirmware -VMName $vmName -ComputerName $foundOnCluster -SecureBootTemplate "MicrosoftWindows" -ErrorAction Stop

        # Start the VM if it was originally running
        if ($originalState -eq 'Running') {
            Write-Host "  Starting VM..." -ForegroundColor Gray
            Start-VM -Name $vmName -ComputerName $foundOnCluster -ErrorAction Stop
        }

        Write-Host "  ✓ Successfully processed $vmName" -ForegroundColor Green

    } catch {
        Write-Error "  ✗ Error processing VM '$vmName': $($_.Exception.Message)"
    }

    Write-Host ""
}

Write-Host "Script completed!" -ForegroundColor Cyan