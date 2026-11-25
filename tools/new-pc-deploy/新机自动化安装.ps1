#Requires -Version 5.1
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$SourceDir,
    [ValidateRange(1,120)][int]$InstallerTimeoutMinutes = 20,
    [string]$DomainAdminToRemove = 'CONTOSO\Domain Admins',
    [string]$LocalUserToDisable = 'olduser'
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($SourceDir)) {
    if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        $SourceDir = $PSScriptRoot
    } elseif ($MyInvocation.MyCommand.Path) {
        $SourceDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    } else {
        $SourceDir = (Get-Location).ProviderPath
    }
}
$SourceDir = $SourceDir.Trim().Trim('"')
try {
    $sourceItem = Get-Item -LiteralPath $SourceDir -ErrorAction Stop
    if (-not $sourceItem.PSIsContainer) { throw "安装包路径不是目录：$SourceDir" }
    $SourceDir = $sourceItem.FullName.TrimEnd([IO.Path]::DirectorySeparatorChar)
} catch {
    Write-Host "安装包目录无效：$SourceDir" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}
$workDir = Join-Path $env:ProgramData 'CompanyProvisioning'
New-Item -ItemType Directory -Path $workDir -Force | Out-Null
$LogFile = Join-Path $workDir ("NewPC_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))
$script:Results = @()

function Write-Log {
    param([string]$Message, [ValidateSet('INFO','WARN','ERROR','OK')][string]$Level = 'INFO')
    $line = '{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date), $Level, $Message
    Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
    Write-Host $line -ForegroundColor (@{ INFO='Gray'; WARN='Yellow'; ERROR='Red'; OK='Green' }[$Level])
}

function Add-Result {
    param([string]$Name, [string]$Status, [string]$Detail)
    $script:Results += [pscustomobject]@{ Name=$Name; Status=$Status; Detail=$Detail }
}

function Disable-ConsoleQuickEdit {
    try {
        if (-not ('CompanyConsoleMode' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class CompanyConsoleMode {
    [DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr GetStdHandle(int nStdHandle);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);
}
'@
        }
        $inputHandle = [CompanyConsoleMode]::GetStdHandle(-10)
        $consoleMode = [uint32]0
        if ([CompanyConsoleMode]::GetConsoleMode($inputHandle, [ref]$consoleMode)) {
            # 保留扩展标志并关闭 Quick Edit，避免鼠标选择文字时暂停整个安装流程。
            $newMode = [uint32](($consoleMode -bor 0x80) -band 0xFFFFFFBF)
            [void][CompanyConsoleMode]::SetConsoleMode($inputHandle, $newMode)
        }
    } catch {
        Write-Log "无法关闭控制台快速编辑模式：$($_.Exception.Message)" 'WARN'
    }
}

function Wait-InstallerProcess {
    param(
        [Parameter(Mandatory=$true)][Diagnostics.Process]$Process,
        [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(Mandatory=$true)][int]$TimeoutMinutes
    )
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $nextNotice = (Get-Date).AddSeconds(30)
    while (-not $Process.HasExited) {
        if ((Get-Date) -ge $deadline) { return $false }
        if ((Get-Date) -ge $nextNotice) {
            $elapsed = [math]::Round(((Get-Date) - $Process.StartTime).TotalMinutes, 1)
            Write-Host "  $Name 仍在安装（已等待 $elapsed 分钟），无需按回车，请继续等待..." -ForegroundColor Yellow
            $nextNotice = (Get-Date).AddSeconds(30)
        }
        [void]$Process.WaitForExit(5000)
        $Process.Refresh()
    }
    return $true
}

function Resolve-Installer {
    param([string[]]$Pattern)
    $items = @(Get-ChildItem -LiteralPath $SourceDir -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object {
            $fileName = $_.Name
            @($Pattern | Where-Object { $fileName -like $_ }).Count -gt 0
        } |
        Sort-Object @{Expression={
                        $candidateName = $_.Name
                        $rank = 999
                        for ($i = 0; $i -lt $Pattern.Count; $i++) {
                            if ($candidateName -like $Pattern[$i]) { $rank = $i; break }
                        }
                        $rank
                    }; Ascending=$true},
                    @{Expression={ try { [version]$_.VersionInfo.FileVersion } catch { [version]'0.0' } }; Descending=$true},
                    LastWriteTime -Descending)
    if ($items.Count -gt 1) {
        Write-Log "匹配到多个安装包（$($Pattern -join ', ')），使用：$($items[0].FullName)" 'WARN'
    }
    return $items | Select-Object -First 1
}

function Test-AppInstalled {
    param([string]$DisplayNamePattern)
    $registryPaths = @(
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    return [bool](Get-ItemProperty -Path $registryPaths -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like $DisplayNamePattern } | Select-Object -First 1)
}

function Invoke-PackageInstall {
    param(
        [string]$Name,
        [string[]]$Pattern,
        [string]$Arguments,
        [string]$DetectionPattern
    )
    if ($DetectionPattern -and (Test-AppInstalled $DetectionPattern)) {
        Write-Log "$Name 已安装，跳过重复安装。" 'OK'
        Add-Result $Name '已安装' '注册表检测到现有版本'
        return
    }
    $installer = Resolve-Installer $Pattern
    if (-not $installer) {
        Write-Log "$Name：未找到安装包（$($Pattern -join ', ')），已跳过。" 'WARN'
        Add-Result $Name '跳过' "缺少 $($Pattern -join ', ')"
        return
    }
    $executable = $installer.FullName
    $effectiveArguments = $Arguments
    if ($installer.Extension -ieq '.msi') {
        $executable = Join-Path $env:SystemRoot 'System32\msiexec.exe'
        $effectiveArguments = "/i `"$($installer.FullName)`" /qn /norestart"
    }
    Write-Log "安装 $Name：$($installer.FullName)"
    try {
        # 清除从网络/浏览器复制时附带的区域标记，避免 SmartScreen 或二次提升提示。
        Unblock-File -LiteralPath $installer.FullName -ErrorAction SilentlyContinue
        # 直接继承当前脚本的管理员令牌；UseShellExecute=false 可避免 Shell 再次请求 UAC。
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $executable
        $startInfo.Arguments = $effectiveArguments
        $startInfo.WorkingDirectory = $installer.DirectoryName
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $false
        $process = [System.Diagnostics.Process]::Start($startInfo)
        if (-not $process) { throw '安装进程未能创建' }
        if (-not (Wait-InstallerProcess -Process $process -Name $Name -TimeoutMinutes $InstallerTimeoutMinutes)) {
            Write-Log "$Name 在 $InstallerTimeoutMinutes 分钟内未结束；未强制终止进程。" 'ERROR'
            Add-Result $Name '失败' '安装超时，进程仍可能在后台运行'
            return
        }
        $exitCode = $process.ExitCode
        if ($exitCode -in @(0, 1641, 3010)) {
            $detail = if ($exitCode -in @(1641,3010)) { "退出码 $exitCode，需要重启" } else { '退出码 0' }
            Write-Log "$Name 安装成功（$detail）。" 'OK'
            Add-Result $Name '成功' $detail
        } else {
            Write-Log "$Name 安装失败，退出码：$exitCode。" 'ERROR'
            Add-Result $Name '失败' "退出码 $exitCode"
        }
    } catch {
        Write-Log "$Name 启动失败：$($_.Exception.Message)" 'ERROR'
        Add-Result $Name '失败' $_.Exception.Message
    }
}

function Invoke-OfficeInstall {
    $clickToRun = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' -ErrorAction SilentlyContinue
    if ($clickToRun -and $clickToRun.ProductReleaseIds) {
        Write-Log "Office 已安装（$($clickToRun.ProductReleaseIds)），跳过重复配置。" 'OK'
        Add-Result 'Office 365' '已安装' $clickToRun.ProductReleaseIds
        return
    }
    $odtDir = Join-Path $SourceDir 'Office365\odt'
    $setup = Join-Path $odtDir 'setup.exe'
    $config = Join-Path $odtDir 'configuration-Office365-x64.xml'
    if (-not (Test-Path -LiteralPath $setup) -or -not (Test-Path -LiteralPath $config)) {
        Write-Log 'Office 365：缺少 setup.exe 或配置 XML，已跳过。' 'WARN'
        Add-Result 'Office 365' '跳过' 'ODT 文件不完整'
        return
    }
    Write-Log "安装 Office 365：$setup /configure $config"
    try {
        $process = Start-Process -FilePath $setup -ArgumentList @('/configure', "`"$config`"") -WorkingDirectory $odtDir -PassThru
        if (-not (Wait-InstallerProcess -Process $process -Name 'Office 365' -TimeoutMinutes $InstallerTimeoutMinutes)) {
            Write-Log 'Office 安装超时；未强制终止进程。' 'ERROR'
            Add-Result 'Office 365' '失败' '安装超时'
        } elseif ($process.ExitCode -eq 0) {
            Write-Log 'Office 365 安装成功。' 'OK'
            Add-Result 'Office 365' '成功' '退出码 0'
        } else {
            Write-Log "Office 365 安装失败，退出码：$($process.ExitCode)。" 'ERROR'
            Add-Result 'Office 365' '失败' "退出码 $($process.ExitCode)"
        }
    } catch {
        Write-Log "Office 365 启动失败：$($_.Exception.Message)" 'ERROR'
        Add-Result 'Office 365' '失败' $_.Exception.Message
    }
}

function Invoke-PowerCfg {
    param([string]$Name, [string[]]$Arguments)
    & powercfg.exe @Arguments 2>&1 | ForEach-Object { Write-Log "powercfg: $_" }
    if ($LASTEXITCODE -eq 0) {
        Add-Result $Name '成功' ($Arguments -join ' ')
        return $true
    }
    Write-Log "$Name 配置失败，powercfg 退出码：$LASTEXITCODE。" 'ERROR'
    Add-Result $Name '失败' "powercfg 退出码 $LASTEXITCODE"
    return $false
}

function Get-AdministratorsGroupName {
    $administratorsSid = 'S-1-5-32-544'
    try {
        return (Get-LocalGroup -SID $administratorsSid -ErrorAction Stop).Name
    } catch {
        return ([Security.Principal.SecurityIdentifier]$administratorsSid).
            Translate([Security.Principal.NTAccount]).Value.Split('\\')[-1]
    }
}

function Remove-AdministratorMember {
    param(
        [Parameter(Mandatory=$true)][string]$Account,
        [Security.Principal.SecurityIdentifier]$KnownSid
    )
    $groupName = Get-AdministratorsGroupName
    try {
        $members = @(Get-LocalGroupMember -Group $groupName -ErrorAction SilentlyContinue)
        $member = $members | Where-Object { $_.Name -ieq $Account } | Select-Object -First 1
        if (-not $member -and $KnownSid) {
            $member = $members | Where-Object { $_.SID.Value -eq $KnownSid.Value } | Select-Object -First 1
        }
        if (-not $member) {
            try {
                $resolvedSid = (New-Object Security.Principal.NTAccount($Account)).Translate([Security.Principal.SecurityIdentifier])
                $member = $members | Where-Object { $_.SID.Value -eq $resolvedSid.Value } | Select-Object -First 1
            } catch {
                Write-Log "$Account 当前无法解析，但也不在本地管理员组成员列表中。" 'INFO'
            }
        }
        if (-not $member) {
            Write-Log "$Account 已不在本地管理员组中，无需处理。" 'OK'
            return $true
        }

        # 某些 Windows 版本无法把 SecurityIdentifier 对象绑定到 -Member，使用已解析名称删除。
        Remove-LocalGroupMember -Group $groupName -Member $member.Name -ErrorAction Stop
        $remaining = @(Get-LocalGroupMember -Group $groupName -ErrorAction SilentlyContinue)
        if ($remaining | Where-Object { $_.SID.Value -eq $member.SID.Value }) {
            throw '移除命令完成后，成员 SID 仍然存在'
        }
        Write-Log "$Account 已从本地管理员组移除并通过 SID 核验。" 'OK'
        return $true
    } catch {
        Write-Log "从本地管理员组移除 $Account 失败：$($_.Exception.Message)" 'ERROR'
        return $false
    }
}

function Set-LocalAccountRestrictions {
    Write-Log '================ 账户权限收口 ================'

    # 防锁死：必须由已被“直接”加入本地 Administrators 的 CONTOSO 域用户执行。
    # 仅通过 Domain Admins 间接获得权限不算通过，因为下面会移除该域组。
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $currentAccount = $currentIdentity.Name
    $currentSid = $currentIdentity.User.Value
    $adminGroupName = Get-AdministratorsGroupName
    $directAdminSids = @(Get-LocalGroupMember -Group $adminGroupName -ErrorAction SilentlyContinue |
        Where-Object SID | ForEach-Object { $_.SID.Value })
    if ($currentAccount -notlike 'CONTOSO\*' -or $currentSid -notin $directAdminSids) {
        $detail = "当前账号 $currentAccount 不是直接加入 Administrators 的 CONTOSO 域用户"
        Write-Log "$detail；为避免管理员锁死，跳过移除 Domain Admins、移除/禁用本地账户。" 'ERROR'
        Add-Result '账户安全收口' '失败' $detail
        return
    }
    Write-Log "安全检查通过：$currentAccount 已直接加入本地管理员组。" 'OK'

    if ($DomainAdminToRemove) {
        if (Remove-AdministratorMember -Account $DomainAdminToRemove) {
            Add-Result "移除 $DomainAdminToRemove 管理员权限" '成功' '已确认不在 Administrators 组'
        } else {
            Add-Result "移除 $DomainAdminToRemove 管理员权限" '失败' '请查看日志'
        }
    }

    if (-not $LocalUserToDisable) { return }
    $localUser = Get-LocalUser -Name $LocalUserToDisable -ErrorAction SilentlyContinue
    if (-not $localUser) {
        Write-Log "本地用户 $LocalUserToDisable 不存在，无需禁用。" 'WARN'
        Add-Result "禁用本地用户 $LocalUserToDisable" '跳过' '账户不存在'
        return
    }

    $localAccountName = "$env:COMPUTERNAME\$LocalUserToDisable"
    if (Remove-AdministratorMember -Account $localAccountName -KnownSid $localUser.SID) {
        Add-Result "移除本地用户 $LocalUserToDisable 管理员权限" '成功' '已确认不在 Administrators 组'
    } else {
        Add-Result "移除本地用户 $LocalUserToDisable 管理员权限" '失败' '请查看日志'
    }

    try {
        if ($localUser.Enabled) {
            Disable-LocalUser -SID $localUser.SID -ErrorAction Stop
        }
        $verifiedUser = Get-LocalUser -SID $localUser.SID -ErrorAction Stop
        if ($verifiedUser.Enabled) { throw '禁用命令完成后，账户仍处于启用状态' }
        Write-Log "本地用户 $LocalUserToDisable 已禁用并通过状态核验。" 'OK'
        Add-Result "禁用本地用户 $LocalUserToDisable" '成功' 'Enabled=False'
    } catch {
        Write-Log "禁用本地用户 $LocalUserToDisable 失败：$($_.Exception.Message)" 'ERROR'
        Add-Result "禁用本地用户 $LocalUserToDisable" '失败' $_.Exception.Message
    }
}

Write-Log '================ 新机自动化安装开始 ================'
Write-Log "安装包目录：$SourceDir"
Write-Log '脚本只使用静默参数，不再向其他应用窗口自动发送按键。'
Disable-ConsoleQuickEdit

# 如厂商安装包的静默参数有变化，只需修改下面对应的 Arguments。
$packages = @(
    @{ Name='微信';     Pattern='WeChatWin_*.exe';  Arguments='/S'; Detection='微信*' },
    @{ Name='企业微信'; Pattern='WeCom_*.exe';      Arguments='/S'; Detection='企业微信*' },
    @{ Name='Everything'; Pattern='*Everything*.exe'; Arguments='/S'; Detection='Everything*' },
    @{ Name='Google Chrome'; Pattern=@('GoogleChrome*.msi','*Chrome*.msi','ChromeStandaloneSetup*.exe','ChromeSetup*.exe','*Chrome*.exe'); Arguments='/silent /install'; Detection='Google Chrome*' },
    @{ Name='奇安信';   Pattern='installer*.exe';   Arguments='/S'; Detection='*奇安信*' }
)
foreach ($package in $packages) {
    Invoke-PackageInstall -Name $package.Name -Pattern $package.Pattern -Arguments $package.Arguments -DetectionPattern $package.Detection
}
Invoke-OfficeInstall

Write-Log '================ 电源配置 ================'
[void](Invoke-PowerCfg '交流电关闭屏幕' @('-change','-monitor-timeout-ac','0'))
[void](Invoke-PowerCfg '交流电睡眠时间' @('-change','-standby-timeout-ac','300'))
$highPerformance = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
& powercfg.exe -setactive $highPerformance 2>$null
if ($LASTEXITCODE -ne 0) {
    $duplicateOutput = & powercfg.exe -duplicatescheme $highPerformance 2>&1
    $newGuid = [regex]::Match(($duplicateOutput -join ' '), '[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}').Value
    if ($newGuid) { [void](Invoke-PowerCfg '高性能电源方案' @('-setactive',$newGuid)) }
    else { Write-Log '无法创建高性能电源方案。' 'ERROR'; Add-Result '高性能电源方案' '失败' '方案不可用' }
} else {
    Add-Result '高性能电源方案' '成功' $highPerformance
}

# 飞书安装包不支持可靠的静默安装，安排在所有自动步骤完成后交互安装。
Write-Log '================ 最后安装飞书（需要手动操作） ================'
if (-not (Test-AppInstalled '飞书*')) {
    Write-Host ''
    Write-Host '即将自动打开飞书安装窗口，请手动点击并完成安装；不需要先按回车。' -ForegroundColor Yellow
}
Invoke-PackageInstall -Name '飞书（交互安装）' -Pattern 'Feishu*.exe' -Arguments '' -DetectionPattern '飞书*'

# 最后执行账户收口，避免安装过程因当前管理员账户被禁用而中断。
Set-LocalAccountRestrictions

Write-Host "`n================ 安装摘要 ================" -ForegroundColor Cyan
$script:Results | Format-Table -AutoSize Name, Status, Detail
$failed = @($script:Results | Where-Object Status -eq '失败').Count
$skipped = @($script:Results | Where-Object Status -eq '跳过').Count
Write-Log "处理完成：失败 $failed 项，跳过 $skipped 项。日志：$LogFile" $(if ($failed) { 'ERROR' } else { 'OK' })
if ($failed) { exit 2 }
exit 0
