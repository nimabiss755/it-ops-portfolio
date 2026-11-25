# 诊断脚本：自动提权 -> 调用 HostsEditor.ps1 -SelfTest -> 生成“诊断报告.txt”
$ErrorActionPreference = 'Continue'
$root = $PSScriptRoot

$isAdmin = $false
try {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $isAdmin = (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} catch { }

if (-not $isAdmin) {
    Write-Host '诊断需要管理员权限，正在请求提权（请在 UAC 窗口点“是”）...'
    $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not [Environment]::Is64BitProcess) { $exe = Join-Path $env:SystemRoot 'Sysnative\WindowsPowerShell\v1.0\powershell.exe' }
    try {
        Start-Process -FilePath $exe -Verb RunAs -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $PSCommandPath)
    } catch {
        Write-Host ('提权失败或被取消：' + $_.Exception.Message)
        Read-Host '按回车关闭'
    }
    exit 0
}

& (Join-Path $root 'HostsEditor.ps1') -SelfTest
Write-Host ''
Read-Host '按回车关闭窗口'
