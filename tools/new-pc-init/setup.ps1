# 卸载 OneDrive
Write-Host "卸载 OneDrive..."
Start-Process "taskkill" -ArgumentList "/f /im OneDrive.exe" -Wait -ErrorAction SilentlyContinue
if ([Environment]::Is64BitOperatingSystem) {
    $OneDriveSetup = "$env:SystemRoot\SysWOW64\OneDriveSetup.exe"
} else {
    $OneDriveSetup = "$env:SystemRoot\System32\OneDriveSetup.exe"
}
if (Test-Path $OneDriveSetup) {
    Start-Process $OneDriveSetup "/uninstall" -Wait
}

# 关闭防火墙
Write-Host "关闭防火墙..."
Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled False

# 切换到高性能电源计划
$highPerf = "8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c"
powercfg -setactive $highPerf

# 设置高性能计划下，硬盘“永不关闭”
powercfg -setacvalueindex $highPerf SUB_DISK DISKIDLE 0
powercfg -setdcvalueindex $highPerf SUB_DISK DISKIDLE 0

# 设置高性能计划下，计算机“从不睡眠”
powercfg -setacvalueindex $highPerf SUB_SLEEP STANDBYIDLE 0
powercfg -setdcvalueindex $highPerf SUB_SLEEP STANDBYIDLE 0

# 应用设置
powercfg -setactive $highPerf
# 显示桌面图标：计算机、用户文件、控制面板、网络
$regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel"
Set-ItemProperty -Path $regPath -Name '{20D04FE0-3AEA-1069-A2D8-08002B30309D}' -Value 0   # 计算机
Set-ItemProperty -Path $regPath -Name '{59031a47-3f72-44a7-89c5-5595fe6b30ee}' -Value 0   # 用户文件
Set-ItemProperty -Path $regPath -Name '{5399E694-6CE5-4D6C-8FCE-1D8870FDCBA0}' -Value 0   # 控制面板
Set-ItemProperty -Path $regPath -Name '{F02C1A0D-BE21-4350-88B0-7367FC96EF3C}' -Value 0   # 网络

# 刷新桌面
$sig = '[DllImport("user32.dll")]public static extern int SendMessage(int hWnd, int hMsg, int wParam, int lParam);'
Add-Type -MemberDefinition $sig -Name 'Win32SendMessage' -Namespace Win32Functions
[Win32Functions.Win32SendMessage]::SendMessage(0xFFFF, 0x1A, 0, 0)

Write-Host "所有设置已完成：高性能电源、硬盘永不关闭、永不睡眠、桌面已显示常用图标。"
# 安装软件列表
$apps = @(
    @{name="Chrome浏览器"; url="https://dl.google.com/chrome/install/latest/chrome_installer.exe"; file="ChromeSetup.exe"},
    @{name="Everything"; url="https://www.voidtools.com/Everything-1.4.1.1024.x64-Setup.exe"; file="EverythingSetup.exe"}
)

foreach ($app in $apps) {
    Write-Host "正在下载安装 $($app.name)..."
    $filePath = "$env:TEMP\$($app.file)"
    Invoke-WebRequest -Uri $app.url -OutFile $filePath
    Start-Process $filePath -ArgumentList "/silent","/verysilent","/s" -Wait
}

Write-Host "全部完成！请检查软件是否已正确安装。"
