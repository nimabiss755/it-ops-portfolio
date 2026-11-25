#requires -version 5.1

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param()

$ErrorActionPreference = 'Stop'

# This operation must be performed from an elevated PowerShell session.
$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($currentIdentity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run PowerShell as Administrator, then run this script again.'
}

# Resolve the built-in Administrators group by SID so this works on localized Windows.
$administratorsSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
$administratorsAccount = $administratorsSid.Translate([Security.Principal.NTAccount]).Value
$administratorsName = ($administratorsAccount -split '\\', 2)[-1]
$administratorsGroup = [ADSI]("WinNT://./{0},group" -f $administratorsName)

$targets = @(
    [pscustomobject]@{
        DisplayName = 'CONTOSO\Administrator'
        Authority   = 'CONTOSO'
        UserName    = 'Administrator'
    }
    [pscustomobject]@{
        DisplayName = "$env:COMPUTERNAME\olduser"
        Authority   = $env:COMPUTERNAME
        UserName    = 'olduser'
    }
)

function Get-GroupMembers {
    param([System.DirectoryServices.DirectoryEntry]$Group)

    @($Group.psbase.Invoke('Members')) | ForEach-Object {
        [pscustomobject]@{
            Name    = $_.GetType().InvokeMember('Name', 'GetProperty', $null, $_, $null)
            AdsPath = $_.GetType().InvokeMember('AdsPath', 'GetProperty', $null, $_, $null)
        }
    }
}

foreach ($target in $targets) {
    $expectedPath = "WinNT://$($target.Authority)/$($target.UserName)"
    $member = Get-GroupMembers -Group $administratorsGroup | Where-Object {
        $_.AdsPath.TrimEnd('/') -ieq $expectedPath
    } | Select-Object -First 1

    if (-not $member) {
        Write-Host "No change: $($target.DisplayName) is not a member of the local $administratorsName group." -ForegroundColor Yellow
        continue
    }

    if ($PSCmdlet.ShouldProcess(
        $target.DisplayName,
        "Remove from the local $administratorsName group"
    )) {
        $administratorsGroup.psbase.Invoke('Remove', $member.AdsPath)
        $administratorsGroup.psbase.CommitChanges()
        Write-Host "Removed: $($target.DisplayName)" -ForegroundColor Green
    }
}

# Disable the local account "olduser" after removing its local administrator membership.
try {
    $localUser = [ADSI]("WinNT://{0}/olduser,user" -f $env:COMPUTERNAME)
    $userFlags = [int]$localUser.Properties['UserFlags'].Value

    if (($userFlags -band 0x2) -ne 0) {
        Write-Host "No change: local account $env:COMPUTERNAME\olduser is already disabled." -ForegroundColor Yellow
    }
    elseif ($PSCmdlet.ShouldProcess(
        "$env:COMPUTERNAME\olduser",
        'Disable local account'
    )) {
        $localUser.Properties['UserFlags'].Value = ($userFlags -bor 0x2)
        $localUser.CommitChanges()
        Write-Host "Disabled: $env:COMPUTERNAME\olduser" -ForegroundColor Green
    }
}
catch {
    throw "Unable to disable local account $env:COMPUTERNAME\olduser. $($_.Exception.Message)"
}

Write-Host ''
Write-Host 'Operation completed. Press Enter to close this window.' -ForegroundColor Cyan
[void](Read-Host)
