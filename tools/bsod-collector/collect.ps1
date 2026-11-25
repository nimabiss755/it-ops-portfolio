param([switch]$Elevated)
$ErrorActionPreference = 'Continue'
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    try {
        Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f $PSCommandPath),'-Elevated') -Verb RunAs
        Write-Host '已请求管理员权限，请在弹出的窗口中选择“是”。'
    } catch { Write-Host "无法获取管理员权限或已取消：$($_.Exception.Message)" -ForegroundColor Red; Read-Host '按回车键退出' | Out-Null }
    exit
}
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$desktop = [Environment]::GetFolderPath('Desktop')
$folder = Join-Path $desktop "蓝屏诊断_$stamp"
$zip = "$folder.zip"
New-Item -ItemType Directory -Path $folder -ErrorAction Stop | Out-Null
$status = New-Object System.Collections.Generic.List[string]
function Collect($name, [scriptblock]$action) {
    Write-Host "正在采集：$name"
    try { & $action; $script:status.Add("成功：$name") } catch { $script:status.Add("失败：$name - $($_.Exception.Message)"); Write-Host "  失败：$($_.Exception.Message)" -ForegroundColor Yellow }
}
function Csv($data, $name) {
    $path = Join-Path $folder $name
    if (@($data).Count -eq 0) { '没有匹配记录。' | Out-File -LiteralPath $path -Encoding utf8 } else { $data | Export-Csv -LiteralPath $path -NoTypeInformation -Encoding utf8 }
}
$since = (Get-Date).AddDays(-7)
Collect '电脑和系统信息' {
    $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $bios = Get-CimInstance Win32_BIOS -ErrorAction Stop
    $cpu = Get-CimInstance Win32_Processor -ErrorAction Stop
    $data = @([pscustomobject]@{电脑名=$env:COMPUTERNAME;厂商=$cs.Manufacturer;型号=$cs.Model;操作系统=$os.Caption;版本=$os.Version;上次启动=$os.LastBootUpTime;内存GB=[math]::Round($cs.TotalPhysicalMemory/1GB,2);BIOS=$bios.SMBIOSBIOSVersion;BIOS日期=$bios.ReleaseDate;处理器=($cpu.Name -join '; ');采集时间=(Get-Date);日志开始时间=$since})
    Csv $data '01_系统信息.csv'
}
Collect '物理内存信息' { Csv @(Get-CimInstance Win32_PhysicalMemory -ErrorAction Stop | Select-Object Manufacturer,PartNumber,Capacity,Speed,ConfiguredClockSpeed,DeviceLocator) '02_内存.csv' }
Collect '所有设备及状态' { Csv @(Get-CimInstance Win32_PnPEntity -ErrorAction Stop | Select-Object Name,PNPClass,PNPDeviceID,Status,ConfigManagerErrorCode) '03_设备.csv' }
Collect '设备驱动信息' { Csv @(Get-CimInstance Win32_PnPSignedDriver -ErrorAction Stop | Select-Object DeviceName,DeviceID,DriverProviderName,DriverVersion,DriverDate,InfName,IsSigned) '04_设备驱动.csv' }
Collect '重点 PCIe 设备' {
    $devices = @(Get-CimInstance Win32_PnPEntity -ErrorAction Stop | Where-Object { $_.PNPDeviceID -match 'VEN_1002&DEV_AAE0|VEN_8086&DEV_A71D' } | Select-Object Name,PNPDeviceID,Status,ConfigManagerErrorCode)
    Csv $devices '05_重点PCIe设备.csv'
}
Collect '文件系统筛选驱动' {
    $output = & "$env:SystemRoot\System32\fltmc.exe" filters 2>&1
    if ($LASTEXITCODE -ne 0) { throw "fltmc 退出代码 $LASTEXITCODE；$output" }
    $output | Out-File -LiteralPath (Join-Path $folder '06_文件筛选驱动.txt') -Encoding utf8
}
Collect '物理磁盘状态' { Csv @(Get-PhysicalDisk -ErrorAction Stop | Select-Object FriendlyName,MediaType,HealthStatus,OperationalStatus,Size) '07_磁盘状态.csv' }
Collect '蓝屏与硬件事件（最近7天）' {
    $ids = @(17,18,19,20,41,46,1001,219,6008)
    $events = @(Get-WinEvent -FilterHashtable @{LogName='System'; StartTime=$since; Id=$ids} -ErrorAction Stop | Where-Object { ($_.ProviderName -eq 'Microsoft-Windows-WHEA-Logger') -or ($_.ProviderName -eq 'Microsoft-Windows-Kernel-Power' -and $_.Id -eq 41) -or ($_.ProviderName -eq 'Microsoft-Windows-WER-SystemErrorReporting' -and $_.Id -eq 1001) -or ($_.ProviderName -eq 'Microsoft-Windows-Kernel-PnP' -and $_.Id -eq 219) -or ($_.ProviderName -eq 'volmgr' -and $_.Id -eq 46) -or ($_.ProviderName -eq 'EventLog' -and $_.Id -eq 6008) } | Select-Object TimeCreated,ProviderName,Id,LevelDisplayName,Message)
    Csv $events '08_蓝屏和硬件事件.csv'
}
Collect '戴尔诊断相关事件（最近7天）' {
    $events = @(Get-WinEvent -FilterHashtable @{LogName='Application'; StartTime=$since} -ErrorAction Stop | Where-Object { $_.ProviderName -match 'Dell|SupportAssist|ePSA' } | Select-Object -First 200 TimeCreated,ProviderName,Id,LevelDisplayName,Message)
    Csv $events '09_戴尔诊断事件.csv'
}
Collect '转储与分页文件设置' {
    $crash = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl' -ErrorAction Stop
    $page = Get-CimInstance Win32_PageFileUsage -ErrorAction Stop
    @("CrashDumpEnabled=$($crash.CrashDumpEnabled) (0=无; 1=完整; 2=内核; 3=小型; 7=自动)","DumpFile=$($crash.DumpFile)","MinidumpDir=$($crash.MinidumpDir)","AutoReboot=$($crash.AutoReboot)","Overwrite=$($crash.Overwrite)",'',($page | Format-List Name,AllocatedBaseSize,CurrentUsage | Out-String)) | Out-File -LiteralPath (Join-Path $folder '10_转储设置.txt') -Encoding utf8
}
Collect '最近蓝屏转储' {
    $dumpDir=Join-Path $env:SystemRoot 'Minidump'
    $dumps=@(Get-ChildItem -LiteralPath $dumpDir -Filter '*.dmp' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 10)
    if ($dumps.Count -eq 0) { '未找到小型转储文件。' | Out-File -LiteralPath (Join-Path $folder '11_无小型转储.txt') -Encoding utf8; return }
    $target=Join-Path $folder 'Minidump'; New-Item -ItemType Directory -Path $target -Force | Out-Null
    foreach ($dump in $dumps) { Copy-Item -LiteralPath $dump.FullName -Destination $target -ErrorAction Stop }
}
$status.Add('注意：Dell 开机前硬件检测的结果不一定写入 Windows 日志。若 09 文件为空，请另行记录 F12 Diagnostics 的错误代码和验证代码。')
$status.Add('隐私提示：日志和转储可能包含电脑名、账户、文件路径、设备标识和内存内容。分享前请检查。')
$status | Out-File -LiteralPath (Join-Path $folder '00_采集结果.txt') -Encoding utf8
try {
    Compress-Archive -LiteralPath $folder -DestinationPath $zip -CompressionLevel Optimal -ErrorAction Stop
    Write-Host "`n采集完成。压缩包：$zip" -ForegroundColor Green
    Write-Host "原始文件夹：$folder"
    Write-Host '请先查看 00_采集结果.txt 中是否有失败项目。压缩包含设备、日志和转储信息，分享前请确认。'
} catch { Write-Host "打包失败：$($_.Exception.Message)。采集文件保存在：$folder" -ForegroundColor Red }
Read-Host '按回车键退出' | Out-Null
