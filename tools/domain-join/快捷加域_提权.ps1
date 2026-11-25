#Requires -Version 5.1
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$DomainName,
    [string]$NewComputerName,
    [string[]]$AdminUsers,
    [string[]]$DnsServer = @('10.0.0.10')
)

$ErrorActionPreference = 'Stop'
$TaskName = 'Company-PostDomainJoin'
$LegacyTaskNames = @('AddAdmin_PostJoin', 'AddAdmin_PostJoin_Logon')
$AdminGroupSid = 'S-1-5-32-544'

function Write-Log {
    param([string]$Message, [ValidateSet('INFO','WARN','ERROR','OK')][string]$Level = 'INFO')
    $line = '{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date), $Level, $Message
    if ($script:LogFile) { Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 }
    $color = @{ INFO='Gray'; WARN='Yellow'; ERROR='Red'; OK='Green' }[$Level]
    Write-Host $line -ForegroundColor $color
}

function Get-AdministratorsGroupName {
    try {
        return (Get-LocalGroup -SID $AdminGroupSid -ErrorAction Stop).Name
    } catch {
        return ([System.Security.Principal.SecurityIdentifier]$AdminGroupSid).
            Translate([System.Security.Principal.NTAccount]).Value.Split('\\')[-1]
    }
}

function Remove-LegacyScheduledTasks {
    foreach ($legacy in @($TaskName) + $LegacyTaskNames) {
        $existingTask = Get-ScheduledTask -TaskName $legacy -ErrorAction SilentlyContinue
        if ($existingTask) {
            Unregister-ScheduledTask -TaskName $legacy -Confirm:$false -ErrorAction SilentlyContinue
            Write-Log "已删除旧计划任务：$legacy" 'INFO'
        }
    }
    Remove-Item -LiteralPath (Join-Path $env:ProgramData 'CompanyProvisioning\DomainJoin-PostConfig.json') -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $env:ProgramData 'CompanyProvisioning\DomainJoin-PostConfig.ps1') -Force -ErrorAction SilentlyContinue
}

function Add-RequestedLocalAdmins {
    param([string[]]$Users)
    $groupName = Get-AdministratorsGroupName
    $allOk = $true
    foreach ($user in @($Users | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)) {
        try {
            # 先解析为 SID：避免 FQDN/NetBIOS 域名差异和系统显示语言影响。
            $account = New-Object System.Security.Principal.NTAccount($user)
            $accountSid = $account.Translate([System.Security.Principal.SecurityIdentifier])
            $existingSids = @(Get-LocalGroupMember -Group $groupName -ErrorAction SilentlyContinue |
                Where-Object SID | ForEach-Object { $_.SID.Value })
            if ($accountSid.Value -in $existingSids) {
                Write-Log "$user 已在本地管理员组中（SID：$($accountSid.Value)）。" 'OK'
                continue
            }
            $primaryError = $null
            try {
                # 直接传账号字符串，部分 Windows 版本不接受 SID 对象作为 -Member。
                Add-LocalGroupMember -Group $groupName -Member $user -ErrorAction Stop
            } catch {
                $primaryError = $_.Exception.Message
                # WinNT ADSI 作为备用通道，兼容 LocalAccounts 模块处理域账号失败的机器。
                if ($user -match '^(?<domain>[^\\]+)\\(?<name>.+)$') {
                    $accountDomain = $matches.domain.Split('.')[0]
                    $accountName = $matches.name
                } elseif ($user -match '^(?<name>[^@]+)@(?<domain>.+)$') {
                    $accountDomain = $matches.domain.Split('.')[0]
                    $accountName = $matches.name
                } else {
                    throw "无法拆分域账号：$user；LocalAccounts：$primaryError"
                }
                try {
                    $adsiGroup = [ADSI]("WinNT://./{0},group" -f $groupName)
                    $adsiGroup.Add(("WinNT://{0}/{1},user" -f $accountDomain, $accountName))
                } catch {
                    throw "LocalAccounts：$primaryError；ADSI：$($_.Exception.Message)"
                }
            }
            $verifiedSids = @(Get-LocalGroupMember -Group $groupName -ErrorAction Stop |
                Where-Object SID | ForEach-Object { $_.SID.Value })
            if ($accountSid.Value -notin $verifiedSids) { throw '命令未报错，但加入后 SID 核验失败' }
            Write-Log "$user 已加入本地管理员组并通过 SID 核验。" 'OK'
        } catch {
            Write-Log "处理 $user 失败：$($_.Exception.Message)" 'WARN'
            $allOk = $false
        }
    }
    return $allOk
}

$workDir = Join-Path $env:ProgramData 'CompanyProvisioning'
New-Item -ItemType Directory -Path $workDir -Force | Out-Null
$script:LogFile = Join-Path $workDir ("DomainJoin_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))
Remove-LegacyScheduledTasks

Write-Host '========================================' -ForegroundColor Cyan
Write-Host '       快捷加域 + 域用户提权' -ForegroundColor Cyan
Write-Host '========================================' -ForegroundColor Cyan

if ([string]::IsNullOrWhiteSpace($DomainName)) { $DomainName = (Read-Host '域名（如 corp.company.com）').Trim() }
if ($DomainName -notmatch '^(?=.{1,253}$)([A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z0-9][A-Za-z0-9-]{0,62}$') {
    Write-Log "域名格式无效：$DomainName" 'ERROR'; exit 1
}

$currentName = $env:COMPUTERNAME
if ([string]::IsNullOrWhiteSpace($NewComputerName)) {
    $NewComputerName = (Read-Host "新计算机名（回车保留 $currentName）").Trim()
    if (-not $NewComputerName) { $NewComputerName = $currentName }
}
$NewComputerName = $NewComputerName.ToUpperInvariant()
if ($NewComputerName.Length -gt 15 -or $NewComputerName -notmatch '^[A-Z0-9](?:[A-Z0-9-]{0,13}[A-Z0-9])?$' -or $NewComputerName -match '^\d+$') {
    Write-Log '计算机名须为 1-15 位字母/数字/连字符，不能以连字符开头结尾，也不能全为数字。' 'ERROR'; exit 1
}

$computerSystem = Get-CimInstance Win32_ComputerSystem
if ($computerSystem.PartOfDomain -and $computerSystem.Domain -ine $DomainName) {
    Write-Log "此电脑已加入其他域 $($computerSystem.Domain)，脚本不会自动迁移域。" 'ERROR'; exit 1
}

$joinCred = $null
if (-not $computerSystem.PartOfDomain -or $NewComputerName -ine $currentName) {
    Write-Host '请输入有加域/改名权限的域凭据。' -ForegroundColor Yellow
    $joinCred = Get-Credential -Message "加入 $DomainName"
    if (-not $joinCred) { Write-Log '未提供凭据，已取消。' 'WARN'; exit 1 }
}

if (-not $computerSystem.PartOfDomain) {
    $AdminUsers = @()
    Write-Host '当前为第一次运行：本次只执行加域，重启后请用域管理员再次运行以添加域用户权限。' -ForegroundColor Yellow
} elseif (-not $PSBoundParameters.ContainsKey('AdminUsers')) {
    $inputUsers = (Read-Host '需加入本地管理员组的域用户（多个用英文逗号分隔，不可留空）').Trim()
    if (-not $inputUsers) { Write-Log '第二次运行必须输入要授权的域用户。' 'ERROR'; exit 1 }
    $AdminUsers = @($inputUsers -split ',')
}
$AdminUsers = @($AdminUsers | ForEach-Object {
    $u = $_.Trim()
    # 未限定域的用户名统一转成 UPN，避免猜错 AD 的 NetBIOS 短域名。
    if ($u) { if ($u -match '[@\\]') { $u } else { "$u@$DomainName" } }
} | Where-Object { $_ } | Select-Object -Unique)

Write-Host "`n域名：$DomainName"
Write-Host "计算机名：$NewComputerName"
Write-Host "DNS：主用网卡固定设置为 $($DnsServer -join ', ')，后续不恢复"
Write-Host "本地管理员：$($AdminUsers -join ', ')"
if ((Read-Host '确认执行？(Y/N)') -notmatch '^[Yy]$') { Write-Log '用户取消。' 'WARN'; exit 0 }

try {
    $routeIndexes = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Sort-Object RouteMetric, InterfaceMetric | Select-Object -ExpandProperty InterfaceIndex -Unique -First 1)
    if (-not $routeIndexes) {
        $routeIndexes = @(Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -ExpandProperty InterfaceIndex -First 1)
    }
    if (-not $routeIndexes) { throw '未找到活动网络适配器。' }
    foreach ($index in $routeIndexes) {
        $currentDns = @(Get-DnsClientServerAddress -InterfaceIndex $index -AddressFamily IPv4).ServerAddresses
        Write-Log "网卡索引 $index 当前 DNS：$($currentDns -join ', ')" 'INFO'
        Set-DnsClientServerAddress -InterfaceIndex $index -ServerAddresses $DnsServer
        Write-Log "已将主用网卡 DNS 固定设置为：$($DnsServer -join ', ')；后续不会自动恢复或重置。" 'OK'
    }
    $srv = Resolve-DnsName -Type SRV "_ldap._tcp.dc._msdcs.$DomainName" -ErrorAction Stop
    $dcTargets = @($srv | Where-Object Type -eq 'SRV' | ForEach-Object { $_.NameTarget.TrimEnd('.') } | Select-Object -Unique)
    Write-Log "域 DNS 检查通过，发现 $($dcTargets.Count) 个域控目标。" 'OK'
    $reachableDc = $dcTargets | Where-Object { Test-NetConnection -ComputerName $_ -Port 389 -InformationLevel Quiet -WarningAction SilentlyContinue } | Select-Object -First 1
    if (-not $reachableDc) { throw 'DNS 可以解析域控，但无法连接任何域控的 LDAP 端口 389。' }
    Write-Log "域控连通性检查通过：${reachableDc}:389" 'OK'
} catch {
    Write-Log "网络/DNS 预检失败：$($_.Exception.Message)" 'ERROR'
    Write-Log "主用网卡 DNS 已保持为 $($DnsServer -join ', ')；脚本不会恢复原值。" 'WARN'
    exit 2
}

$joinChanged = $false
try {
    if (-not $computerSystem.PartOfDomain) {
        $args = @{ DomainName=$DomainName; Credential=$joinCred; Force=$true; ErrorAction='Stop' }
        if ($NewComputerName -ine $currentName) { $args.NewName = $NewComputerName; $args.Options = 'JoinWithNewName','AccountCreate' }
        Add-Computer @args
        $joinChanged = $true
        Write-Log "加域请求成功：$DomainName。" 'OK'
    } elseif ($NewComputerName -ine $currentName) {
        Rename-Computer -NewName $NewComputerName -DomainCredential $joinCred -Force -ErrorAction Stop
        $joinChanged = $true
        Write-Log "改名请求成功：$NewComputerName。" 'OK'
    } else {
        Write-Log '电脑已在目标域中，无需重复加域。' 'INFO'
    }
} catch {
    Write-Log "加域/改名失败：$($_.Exception.Message)" 'ERROR'
    Write-Log "DNS 继续保持为 $($DnsServer -join ', ')。" 'WARN'
    exit 3
}

if ($AdminUsers.Count -gt 0) {
    Write-Log '正在同步添加域用户到本地管理员组（不使用计划任务）。' 'INFO'
    if (-not (Add-RequestedLocalAdmins -Users $AdminUsers)) {
        Write-Log '添加失败。请确认已在加域后重启，并使用域管理员账号运行本脚本。' 'ERROR'
        exit 4
    }
    Write-Log '域用户管理员权限添加完成；目标用户需注销后重新登录以刷新权限令牌。' 'OK'
}

Write-Host "`n操作成功。日志：$script:LogFile" -ForegroundColor Green
if ($joinChanged) {
    Write-Host '重启后请使用域管理员登录，再次运行本脚本并输入需要授权的域用户。' -ForegroundColor Cyan
    if ((Read-Host '需要重启才能生效，是否立即重启？(Y/N)') -match '^[Yy]$') { Restart-Computer -Force }
    else { Write-Host '请稍后手动重启。' -ForegroundColor Yellow }
}
exit 0
