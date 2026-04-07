try {
    $servicingPath = "HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\Servicing"
    
    if (Test-Path $servicingPath) {
        $status = (Get-ItemProperty -Path $servicingPath -Name "UEFICA2023Status" -ErrorAction SilentlyContinue).UEFICA2023Status
        
        if ($status -eq "Updated") {
            return "Updated"
        }
        else {
            return $status
        }
    }
    else {
        return "NotFound"
    }
}
catch {
    return "Error"
}