<#
    Hosts 管理工具 v3.1
    ------------------------------------------------------------------
    设计要点（针对 v1/v2 出现的两个错误）：
      1. "对路径 ...\hosts 的访问被拒绝" —— 保存进程没有管理员权限（或提权没有真正生效）。
         现在主界面不再强制提权，读取随时可用；保存时由一个单独的提权子进程完成写入，
         并且会把结果、身份、位数写进结果文件，失败原因一目了然。
      2. "未能找到文件 ...\hosts" —— 提权后的进程在异常的上下文中取路径。
         现在路径统一由 Resolve-HostsPath 解析并留档；32 位进程也不会去碰
         System32 重定向后的 SysWOW64 副本。
      另外：写盘前自动备份、写盘后回读校验、写前检测文件是否被其他程序改动、
      行格式校验、诊断报告、操作日志（%LOCALAPPDATA%\HostsEditor\editor.log）。
#>
param(
    [switch]$ElevatedWrite,
    [string]$SourcePath,
    [string]$TargetPath,
    [string]$BackupPath,
    [string]$ResultPath,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'

$script:AppDir    = Join-Path $env:LOCALAPPDATA 'HostsEditor'
$script:BackupDir = Join-Path $script:AppDir 'Backups'
$script:LogFile   = Join-Path $script:AppDir 'editor.log'
$script:EncodingInfo = $null

# ---------------------------------------------------------------- 基础工具

function Write-Log {
    param([string]$Message)
    try {
        if (-not (Test-Path -LiteralPath $script:AppDir)) { New-Item -ItemType Directory -Force -Path $script:AppDir | Out-Null }
        Add-Content -LiteralPath $script:LogFile -Encoding UTF8 -Value ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message)
    } catch { }
}

function Test-Admin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Get-CurrentIdentity {
    try { return [Security.Principal.WindowsIdentity]::GetCurrent().Name } catch { return '(unknown)' }
}

function Get-BitnessText {
    if ([Environment]::Is64BitProcess) { return '64 位进程' }
    return '32 位进程'
}

# ---------------------------------------------------------------- hosts 路径

function Get-HostsPathCandidates {
    $win = $env:SystemRoot
    if ([string]::IsNullOrWhiteSpace($win)) { $win = 'C:\Windows' }
    $list = New-Object System.Collections.Generic.List[string]
    if (-not [Environment]::Is64BitProcess) {
        # 32 位进程里 Sysnative 才是真正的 System32
        $list.Add((Join-Path $win 'Sysnative\drivers\etc\hosts'))
    }
    $list.Add((Join-Path $win 'System32\drivers\etc\hosts'))
    $list.Add('C:\Windows\System32\drivers\etc\hosts')
    $seen = @{}
    foreach ($p in $list) {
        $k = $p.ToLowerInvariant()
        if (-not $seen.ContainsKey($k)) { $seen[$k] = $true; $p }
    }
}

function ConvertTo-NativeHostsPath {
    param([string]$Path)
    # 传给 64 位子进程时必须把 Sysnative 换回 System32
    if ([string]::IsNullOrEmpty($Path)) { return $Path }
    $win = $env:SystemRoot; if ([string]::IsNullOrWhiteSpace($win)) { $win = 'C:\Windows' }
    return ($Path -replace [regex]::Escape((Join-Path $win 'Sysnative')), (Join-Path $win 'System32'))
}

function Resolve-HostsPath {
    $candidates = @(Get-HostsPathCandidates)
    foreach ($p in $candidates) { if (Test-Path -LiteralPath $p) { return $p } }
    return $candidates[0]
}

function Get-ElevatedPowerShellPath {
    $win = $env:SystemRoot
    if ([string]::IsNullOrWhiteSpace($win)) { $win = 'C:\Windows' }
    $candidates = New-Object System.Collections.Generic.List[string]
    if (-not [Environment]::Is64BitProcess) {
        # 32 位进程里必须走 Sysnative，否则会被重定向到 32 位 PowerShell
        $candidates.Add((Join-Path $win 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'))
    }
    $candidates.Add((Join-Path $win 'System32\WindowsPowerShell\v1.0\powershell.exe'))
    $candidates.Add((Join-Path $PSHOME 'powershell.exe'))
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }
    return 'powershell.exe'
}

# ---------------------------------------------------------------- 读写与校验

function Read-AllBytesRetry {
    param([string]$Path, [int]$Attempts = 4)
    $last = $null
    for ($i = 1; $i -le $Attempts; $i++) {
        try { return [IO.File]::ReadAllBytes($Path) }
        catch { $last = $_; Start-Sleep -Milliseconds (120 * $i) }
    }
    throw $last
}

function Get-HostsEncoding {
    param([byte[]]$Bytes)
    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) {
        return @{ Encoding = (New-Object Text.UTF8Encoding($true)); Offset = 3; Label = 'UTF-8 (BOM)' }
    }
    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE) {
        return @{ Encoding = [Text.Encoding]::Unicode; Offset = 2; Label = 'UTF-16 LE (BOM)' }
    }
    try {
        $utf8 = New-Object Text.UTF8Encoding($false, $true)
        $null = $utf8.GetString($Bytes)
        return @{ Encoding = $utf8; Offset = 0; Label = 'UTF-8' }
    } catch {
        return @{ Encoding = [Text.Encoding]::Default; Offset = 0; Label = ('ANSI/' + [Text.Encoding]::Default.WebName) }
    }
}

function New-HostsPayload {
    param([string]$Text, $Encoding)
    # hosts 在 Windows 上统一用 CRLF，避免混用换行导致某些程序解析异常
    $normalized = ($Text -replace "`r`n", "`n") -replace "`r", "`n"
    $normalized = $normalized -replace "`n", "`r`n"
    $body = $Encoding.GetBytes($normalized)
    $preamble = $Encoding.GetPreamble()
    $out = New-Object byte[] ($preamble.Length + $body.Length)
    if ($preamble.Length -gt 0) { [Array]::Copy($preamble, 0, $out, 0, $preamble.Length) }
    if ($body.Length -gt 0) { [Array]::Copy($body, 0, $out, $preamble.Length, $body.Length) }
    return $out
}

function Test-HostsText {
    param([string]$Text)
    $bad = New-Object System.Collections.Generic.List[int]
    $n = 0
    foreach ($line in ($Text -split "`r?`n")) {
        $n++
        $part = ($line -split '#', 2)[0].Trim()
        if (-not $part) { continue }
        $fields = $part -split '\s+'
        $ip = $null
        if ($fields.Count -lt 2 -or -not [Net.IPAddress]::TryParse($fields[0], [ref]$ip)) { $bad.Add($n) }
    }
    return $bad
}

function Write-HostsFile {
    param(
        [string]$Target,
        [byte[]]$Bytes,
        [byte[]]$OriginalBytes,
        [string]$Backup
    )
    $result = [ordered]@{ ok = $false; message = ''; backup = ''; verified = $false }
    $originalAttrs = $null
    $clearedReadOnly = $false
    $attrWarn = ''
    try {
        # hosts 常被安全策略设为只读，管理员也会因只读属性被拒绝写入：先临时清掉，写完再恢复
        if (Test-Path -LiteralPath $Target) {
            try {
                $originalAttrs = [IO.File]::GetAttributes($Target)
                if ((([int]$originalAttrs) -band ([int][IO.FileAttributes]::ReadOnly)) -ne 0) {
                    $newAttrs = [IO.FileAttributes]((([int]$originalAttrs) -bxor ([int][IO.FileAttributes]::ReadOnly)))
                    [IO.File]::SetAttributes($Target, $newAttrs)
                    $clearedReadOnly = $true
                }
            } catch {
                $attrWarn = '（清除只读属性失败：' + $_.Exception.Message + '）'
            }
        }
        if ($OriginalBytes -ne $null -and $Backup) {
            $dir = Split-Path -Parent $Backup
            if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
            [IO.File]::WriteAllBytes($Backup, $OriginalBytes)
            $result.backup = $Backup
        }
        $done = $false; $last = $null
        for ($i = 1; $i -le 4 -and -not $done; $i++) {
            try { [IO.File]::WriteAllBytes($Target, $Bytes); $done = $true }
            catch { $last = $_; Start-Sleep -Milliseconds (150 * $i) }
        }
        if (-not $done) { throw $last }
        $check = [IO.File]::ReadAllBytes($Target)
        $result.verified = ([Convert]::ToBase64String($check) -eq [Convert]::ToBase64String($Bytes))
        if (-not $result.verified) { throw '写入后回读校验不一致（可能有安全软件或同步程序改写了文件）。' }
        $result.ok = $true
        $result.message = '已写入并通过回读校验'
        if ($clearedReadOnly) { $result.message += '（已临时清除只读属性，稍后恢复）' }
    } catch {
        $result.message = $_.Exception.Message + $attrWarn
    } finally {
        if ($clearedReadOnly -and $null -ne $originalAttrs) {
            try { [IO.File]::SetAttributes($Target, $originalAttrs) } catch { }
        }
    }
    return [pscustomobject]$result
}

function Invoke-ElevatedWrite {
    param(
        [string]$Target,
        [byte[]]$Bytes,
        [byte[]]$OriginalBytes,
        [string]$Backup
    )
    $stamp = [guid]::NewGuid().ToString('N')
    $src = Join-Path $env:TEMP ("hosts-new-$stamp.txt")
    $res = Join-Path $env:TEMP ("hosts-result-$stamp.json")
    # 32 位进程拿到的可能是 Sysnative 路径，传给 64 位子进程前要换回 System32
    $Target = ConvertTo-NativeHostsPath $Target
    $result = [ordered]@{ ok = $false; message = ''; backup = ''; verified = $false; identity = '' }
    try {
        [IO.File]::WriteAllBytes($src, $Bytes)
        if (-not $OriginalBytes -and (Test-Path -LiteralPath $Target)) {
            $OriginalBytes = [IO.File]::ReadAllBytes($Target)
        }
        if (-not $Backup) {
            $Backup = Join-Path $script:BackupDir ('hosts-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '.bak')
        }
        $exe = Get-ElevatedPowerShellPath
        $argLine = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -ElevatedWrite -SourcePath "{1}" -TargetPath "{2}" -BackupPath "{3}" -ResultPath "{4}"' -f `
            $PSCommandPath, $src, $Target, $Backup, $res
        Write-Log ("提权写入 -> {0} {1}" -f $exe, $argLine)
        $proc = Start-Process -FilePath $exe -ArgumentList $argLine -Verb RunAs -PassThru -Wait
        if (Test-Path -LiteralPath $res) {
            $json = Get-Content -LiteralPath $res -Raw -Encoding UTF8 | ConvertFrom-Json
            $result.ok = [bool]$json.ok
            $result.message = [string]$json.message
            $result.backup = [string]$json.backup
            $result.verified = [bool]$json.verified
            $result.identity = [string]$json.identity
        } else {
            $result.message = ('提权进程没有返回结果（退出码 {0}）。可能被安全软件拦截，或被 UAC 拒绝。' -f $proc.ExitCode)
        }
        Write-Log ("提权写入结果 ok={0} msg={1} identity={2}" -f $result.ok, $result.message, $result.identity)
    } catch {
        $msg = $_.Exception.Message
        if ($msg -match '用户取消|cancelled|canceled|0x800704C7') {
            $msg = '已取消管理员授权，hosts 未修改。'
        }
        $result.message = $msg
        Write-Log ("提权写入调用异常：" + $msg)
    } finally {
        Remove-Item -LiteralPath $src -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $res -Force -ErrorAction SilentlyContinue
    }
    return [pscustomobject]$result
}

# ---------------------------------------------------------------- 诊断

function New-DiagnosticText {
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('==== Hosts 管理工具 诊断 ====')
    $lines.Add('时间        : ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $lines.Add(('系统        : {0} {1} (Build {2})' -f $os.Caption, $os.Version, $os.BuildNumber))
    } catch { }
    $lines.Add('进程位数    : ' + (Get-BitnessText) + ' / 系统 64 位：' + [Environment]::Is64BitOperatingSystem)
    $lines.Add('当前用户    : ' + (Get-CurrentIdentity))
    $lines.Add('管理员权限  : ' + (Test-Admin))
    $lines.Add('SystemRoot  : ' + $env:SystemRoot)
    $lines.Add('PowerShell  : ' + (Get-ElevatedPowerShellPath))
    $lines.Add('')
    $lines.Add('---- hosts 路径候选 ----')
    foreach ($p in @(Get-HostsPathCandidates)) {
        $exists = Test-Path -LiteralPath $p
        $line = ('{0}  存在={1}' -f $p, $exists)
        if ($exists) {
            try {
                $f = Get-Item -LiteralPath $p -Force
                $line += ('  大小={0}  修改={1}  属性={2}' -f $f.Length, $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'), $f.Attributes)
            } catch { }
        }
        $lines.Add($line)
    }
    $hp = Resolve-HostsPath
    $lines.Add('')
    $lines.Add('---- 实际使用 ----')
    $lines.Add('使用路径    : ' + $hp)
    if (Test-Path -LiteralPath $hp) {
        try { $b = Read-AllBytesRetry -Path $hp; $lines.Add('读取        : 成功，' + $b.Length + ' 字节') }
        catch { $lines.Add('读取        : 失败 - ' + $_.Exception.Message) }
        $isReadOnly = $false
        try {
            $attrs = [IO.File]::GetAttributes($hp)
            $isReadOnly = ((([int]$attrs) -band ([int][IO.FileAttributes]::ReadOnly)) -ne 0)
            $lines.Add('只读属性    : ' + $isReadOnly + '  (' + $attrs + ')')
        } catch { }
        try {
            $fs = [IO.File]::Open($hp, 'Open', 'ReadWrite', 'None')
            $fs.Close()
            $lines.Add('写权限      : 可以写入（当前进程身份）')
        } catch {
            $lines.Add('写权限      : 不能写入 - ' + $_.Exception.Message)
            if ($isReadOnly) { $lines.Add('原因提示    : 文件带只读属性，管理员也会被拒绝写入；v3.1 保存时会自动临时清除') }
        }
        try {
            $acl = Get-Acl -LiteralPath $hp
            $lines.Add('所有者      : ' + $acl.Owner)
            foreach ($ace in $acl.Access) {
                $lines.Add(('  {0,-6} {1,-48} {2}' -f $ace.AccessControlType, $ace.IdentityReference, $ace.FileSystemRights))
            }
        } catch { $lines.Add('ACL         : 读取失败 - ' + $_.Exception.Message) }
        try {
            $share = [IO.File]::Open($hp, 'Open', 'Read', 'None')
            $share.Close()
            $lines.Add('占用情况    : 未被独占锁定')
        } catch {
            $lines.Add('占用情况    : 可能被其他程序独占 - ' + $_.Exception.Message)
        }
    } else {
        $lines.Add('文件不存在  : ' + $hp)
    }
    $lines.Add('')
    $lines.Add('日志文件    : ' + $script:LogFile)
    $lines.Add('备份目录    : ' + $script:BackupDir)
    return ($lines -join "`r`n")
}

# ---------------------------------------------------------------- 提权子进程模式

if ($ElevatedWrite) {
    $payload = [ordered]@{
        ok = $false; message = ''; backup = ''; verified = $false
        identity = (Get-CurrentIdentity); bitness = (Get-BitnessText); target = $TargetPath
    }
    try {
        if (-not (Test-Path -LiteralPath $SourcePath)) { throw "临时文件不存在：$SourcePath" }
        $newBytes = [IO.File]::ReadAllBytes($SourcePath)
        $oldBytes = $null
        try { $oldBytes = [IO.File]::ReadAllBytes($TargetPath) } catch { }
        $r = Write-HostsFile -Target $TargetPath -Bytes $newBytes -OriginalBytes $oldBytes -Backup $BackupPath
        $payload.ok = $r.ok
        $payload.message = $r.message
        $payload.backup = $r.backup
        $payload.verified = $r.verified
        Write-Log ('[提权] 写入 {0} ok={1} {2}' -f $TargetPath, $r.ok, $r.message)
    } catch {
        $payload.message = $_.Exception.Message
        Write-Log ('[提权] 异常：' + $_.Exception.Message)
    }
    $json = $payload | ConvertTo-Json -Compress
    try { [IO.File]::WriteAllText($ResultPath, $json, (New-Object Text.UTF8Encoding($false))) } catch { }
    exit 0
}

# ---------------------------------------------------------------- 自检模式（诊断）

if ($SelfTest) {
    $report = New-DiagnosticText
    $extra = New-Object System.Collections.Generic.List[string]
    $extra.Add('')
    $extra.Add('---- 自检：写临时文件回环测试 ----')
    try {
        $hp = Resolve-HostsPath
        $tmpTarget = Join-Path $env:TEMP ('hosts-selftest-' + [guid]::NewGuid().ToString('N') + '.txt')
        Copy-Item -LiteralPath $hp -Destination $tmpTarget -Force -ErrorAction Stop
        $bytes = [IO.File]::ReadAllBytes($tmpTarget)
        $info = Get-HostsEncoding $bytes
        $text = $info.Encoding.GetString($bytes, $info.Offset, $bytes.Length - $info.Offset)
        $payload = New-HostsPayload -Text $text -Encoding $info.Encoding
        $r = Write-HostsFile -Target $tmpTarget -Bytes $payload -OriginalBytes $bytes -Backup ($tmpTarget + '.bak')
        $extra.Add(('编辑/编码 = {0}；写回 ok={1}；校验={2}；{3}' -f $info.Label, $r.ok, $r.verified, $r.message))
        Remove-Item -LiteralPath $tmpTarget, ($tmpTarget + '.bak') -Force -ErrorAction SilentlyContinue
    } catch {
        $extra.Add('自检失败：' + $_.Exception.Message)
    }
    $extra.Add('')
    $extra.Add('---- 提权写入能力测试（不改动真实 hosts）----')
    if ($env:HOSTSEDITOR_SKIP_ELEVATE -eq '1') {
        $extra.Add('已跳过（HOSTSEDITOR_SKIP_ELEVATE=1）')
    } else {
        try {
            $probe = Join-Path $env:TEMP ('hosts-probe-' + [guid]::NewGuid().ToString('N') + '.txt')
            [IO.File]::WriteAllText($probe, "probe`r`n")
            $bytes = [IO.File]::ReadAllBytes($probe)
            $r = Invoke-ElevatedWrite -Target $probe -Bytes $bytes -OriginalBytes $bytes -Backup ($probe + '.bak')
            $extra.Add(('提权子进程：ok={0}；身份={1}；{2}' -f $r.ok, $r.identity, $r.message))
            Remove-Item -LiteralPath $probe, ($probe + '.bak') -Force -ErrorAction SilentlyContinue
        } catch {
            $extra.Add('提权测试失败：' + $_.Exception.Message)
        }
    }
    $full = $report + "`r`n" + ($extra -join "`r`n")
    Write-Host $full
    $outFile = Join-Path $PSScriptRoot '诊断报告.txt'
    try { [IO.File]::WriteAllText($outFile, $full, (New-Object Text.UTF8Encoding($true))); Write-Host "`r`n报告已保存：$outFile" } catch { Write-Host "`r`n报告保存失败：$($_.Exception.Message)" }
    exit 0
}

# ---------------------------------------------------------------- 主界面

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:hostsPath = Resolve-HostsPath
$script:originalBytes = $null
$isAdmin = Test-Admin

Write-Log ('启动 v3.1：path={0} admin={1} bitness={2} user={3}' -f $script:hostsPath, $isAdmin, (Get-BitnessText), (Get-CurrentIdentity))

$form = New-Object Windows.Forms.Form
$form.Text = 'Hosts 管理工具 v3.1'
$form.Size = New-Object Drawing.Size(940, 680)
$form.MinimumSize = New-Object Drawing.Size(680, 480)
$form.StartPosition = 'CenterScreen'

$tip = New-Object Windows.Forms.Label
$tip.Dock = 'Top'
$tip.Height = 52
$tip.Padding = New-Object Windows.Forms.Padding(8, 8, 0, 0)
if ($isAdmin) {
    $tip.Text = "每行格式：IP地址 域名；以 # 开头的行为注释。当前为管理员权限，保存时直接写入并自动备份。`r`n文件：$($script:hostsPath)"
} else {
    $tip.Text = "每行格式：IP地址 域名；以 # 开头的行为注释。当前为普通权限：读取正常，保存时会弹出一次 UAC 授权。`r`n文件：$($script:hostsPath)"
}

$editor = New-Object Windows.Forms.TextBox
$editor.Multiline = $true
$editor.ScrollBars = 'Both'
$editor.AcceptsTab = $true
$editor.WordWrap = $false
$editor.Dock = 'Fill'
$editor.Font = New-Object Drawing.Font('Consolas', 11)

$status = New-Object Windows.Forms.Label
$status.Dock = 'Bottom'
$status.Height = 26
$status.Padding = New-Object Windows.Forms.Padding(8, 5, 0, 0)

$bar = New-Object Windows.Forms.FlowLayoutPanel
$bar.Dock = 'Bottom'
$bar.Height = 52
$bar.Padding = New-Object Windows.Forms.Padding(5)

function Add-Button {
    param([string]$Label, [scriptblock]$Handler)
    $b = New-Object Windows.Forms.Button
    $b.Text = $Label
    $b.AutoSize = $true
    $b.Height = 32
    $b.Add_Click($Handler)
    $bar.Controls.Add($b)
}

function Load-Hosts {
    try {
        $bytes = Read-AllBytesRetry -Path $script:hostsPath
        $script:originalBytes = $bytes
        $info = Get-HostsEncoding $bytes
        $script:EncodingInfo = $info
        $editor.Text = $info.Encoding.GetString($bytes, $info.Offset, $bytes.Length - $info.Offset)
        $editor.Modified = $false
        $status.Text = ('已读取：{0}（{1} 字节，{2}）' -f $script:hostsPath, $bytes.Length, $info.Label)
        Write-Log ('读取成功 {0} 字节 编码={1}' -f $bytes.Length, $info.Label)
    } catch {
        $status.Text = '读取失败'
        $msg = $_.Exception.Message
        Write-Log ('读取失败：' + $msg)
        $detail = "读取 hosts 失败：`r`n$msg`r`n`r`n当前路径：$($script:hostsPath)`r`n进程位数：$(Get-BitnessText)`r`n管理员：$isAdmin`r`n`r`n点击「诊断」可查看完整信息。"
        [Windows.Forms.MessageBox]::Show($detail, '读取失败', 'OK', 'Error') | Out-Null
    }
}

function Save-Hosts {
    $target = $script:hostsPath
    $current = $null
    if (-not (Test-Path -LiteralPath $target)) {
        $answer = [Windows.Forms.MessageBox]::Show("找不到文件：`r`n$target`r`n`r`n是否新建？", '文件不存在', 'YesNo', 'Warning')
        if ($answer -ne 'Yes') { return }
        $script:originalBytes = $null
    } else {
        try { $current = Read-AllBytesRetry -Path $target }
        catch {
            [Windows.Forms.MessageBox]::Show("读取当前文件失败，未做任何修改：`r`n$($_.Exception.Message)", '保存失败', 'OK', 'Error') | Out-Null
            return
        }
        if ($null -ne $script:originalBytes -and [Convert]::ToBase64String($current) -ne [Convert]::ToBase64String($script:originalBytes)) {
            [Windows.Forms.MessageBox]::Show('hosts 已被其他程序修改。请先复制当前编辑内容，再点「重新读取」，避免覆盖别人的修改。', '文件已更改', 'OK', 'Warning') | Out-Null
            return
        }
    }

    $bad = @(Test-HostsText -Text $editor.Text)
    if ($bad.Count -gt 0) {
        [Windows.Forms.MessageBox]::Show(('以下行缺少有效 IP 或域名：' + ($bad -join ', ') + '。请检查后再保存。'), '格式有误', 'OK', 'Warning') | Out-Null
        return
    }

    $info = $script:EncodingInfo
    if (-not $info) { $info = Get-HostsEncoding ([byte[]]@()) }
    $payload = New-HostsPayload -Text $editor.Text -Encoding $info.Encoding
    $backup = Join-Path $script:BackupDir ('hosts-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '.bak')

    $status.Text = '正在保存…'
    $form.Cursor = [Windows.Forms.Cursors]::WaitCursor
    try {
        if (Test-Admin) {
            $r = Write-HostsFile -Target $target -Bytes $payload -OriginalBytes $current -Backup $backup
        } else {
            $r = Invoke-ElevatedWrite -Target $target -Bytes $payload -OriginalBytes $current -Backup $backup
        }
    } finally {
        $form.Cursor = [Windows.Forms.Cursors]::Default
    }

    if ($r.ok) {
        try { $script:originalBytes = Read-AllBytesRetry -Path $target } catch { }
        $editor.Modified = $false
        $status.Text = '保存成功，备份：' + $r.backup
        $who = ''
        if ($r.PSObject.Properties['identity'] -and $r.identity) { $who = "`r`n写入身份：" + $r.identity }
        [Windows.Forms.MessageBox]::Show(("保存成功（已备份并回读校验）。`r`n备份：$($r.backup)$who"), '保存成功', 'OK', 'Information') | Out-Null
        try { & "$env:SystemRoot\System32\ipconfig.exe" /flushdns | Out-Null } catch { }
    } else {
        $status.Text = '保存失败'
        $hint = "`r`n`r`n常见原因：`r`n 1. 未获得管理员权限（UAC 被取消）；`r`n 2. hosts 带只读属性且当前身份无权清除；`r`n 3. 安全软件（如奇安信天擎/EDR）的 hosts 保护策略拦截；`r`n 4. hosts 被其他程序独占占用。`r`n可点「诊断」查看详细信息。"
        [Windows.Forms.MessageBox]::Show(("保存失败：`r`n" + $r.message + $hint), '保存失败', 'OK', 'Error') | Out-Null
    }
}

Add-Button '保存并备份' { Save-Hosts }
Add-Button '重新读取' {
    if ($editor.Modified -and [Windows.Forms.MessageBox]::Show('放弃未保存的修改并重新读取？', '确认', 'YesNo', 'Question') -ne 'Yes') { return }
    Load-Hosts
}
Add-Button '打开备份文件夹' {
    try {
        New-Item -ItemType Directory -Force -Path $script:BackupDir | Out-Null
        Start-Process explorer.exe $script:BackupDir
    } catch {
        [Windows.Forms.MessageBox]::Show($_.Exception.Message, '打开失败', 'OK', 'Error') | Out-Null
    }
}
Add-Button '刷新 DNS 缓存' {
    try {
        $out = & "$env:SystemRoot\System32\ipconfig.exe" /flushdns 2>&1
        if ($LASTEXITCODE -ne 0) { throw ($out -join "`n") }
        $status.Text = 'DNS 缓存已刷新'
        [Windows.Forms.MessageBox]::Show('DNS 缓存已刷新。', '完成', 'OK', 'Information') | Out-Null
    } catch {
        [Windows.Forms.MessageBox]::Show($_.Exception.Message, '刷新失败', 'OK', 'Error') | Out-Null
    }
}
Add-Button '以管理员身份重启' {
    if ($editor.Modified -and [Windows.Forms.MessageBox]::Show('有未保存的修改，仍要重启并提权吗？', '确认', 'YesNo', 'Question') -ne 'Yes') { return }
    try {
        $exe = Get-ElevatedPowerShellPath
        Start-Process -FilePath $exe -Verb RunAs -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $PSCommandPath)
        $form.Close()
    } catch {
        [Windows.Forms.MessageBox]::Show($_.Exception.Message, '提权失败', 'OK', 'Error') | Out-Null
    }
}
Add-Button '诊断' {
    $text = New-DiagnosticText
    Write-Log '打开诊断信息'
    [Windows.Forms.MessageBox]::Show($text, '诊断信息', 'OK', 'Information') | Out-Null
}

$form.Controls.Add($editor)
$form.Controls.Add($tip)
$form.Controls.Add($status)
$form.Controls.Add($bar)
$form.Add_FormClosing({
    param($sender, $e)
    if ($editor.Modified -and [Windows.Forms.MessageBox]::Show('还有未保存的修改，确定退出？', '确认', 'YesNo', 'Question') -ne 'Yes') { $e.Cancel = $true }
})

Load-Hosts
try { [void]$form.ShowDialog() } finally { Write-Log '退出' }
