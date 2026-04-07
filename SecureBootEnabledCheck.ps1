try {
    $sb = Confirm-SecureBootUEFI
    if ($sb -eq $true) {
        return $true
    }
    else {
        return $false
    }
}
catch {
    # Systems that don't support Secure Boot (Legacy BIOS etc.)
    return $false
}