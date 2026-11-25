# 本地管理员权限清理

把指定的域账号、本地账号从本机 Administrators 组中移除，并禁用指定的本地账号。用于权限合规整改：员工电脑不应保留多余的管理员账户。

## 设计要点

- **按 SID 识别管理员组**：用内置 SID `S-1-5-32-544` 解析组名，中文系统（「管理员」）和英文系统（「Administrators」）都能用
- **按 AdsPath 精确匹配成员**：比较 `WinNT://<域或计算机名>/<用户名>`，避免同名账号误删
- **支持预览**：`[CmdletBinding(SupportsShouldProcess)]`，可用 `-WhatIf` 只看会做什么而不执行，默认 `ConfirmImpact = High` 会逐项确认
- **幂等**：已经不在组里、已经禁用的账号会提示「No change」并跳过，可重复执行
- **双击入口**：`双击执行.cmd` 用 `net session` 检测是否已提权，未提权时自动以管理员身份重新启动

## 使用

```powershell
# 预览，不做任何修改
.\Remove-LocalAdministrators.ps1 -WhatIf

# 执行（逐项确认）
.\Remove-LocalAdministrators.ps1
```

或直接双击 `双击执行.cmd`（不再逐项确认）。

## 配置

目标账号写在脚本的 `$targets` 数组和禁用账号的部分中，示例值为 `CONTOSO\Administrator` 和本地账号 `olduser`，使用前请改成实际账号。

> 注意：脚本会禁用账号。执行前请确认机器上还有其他可用的管理员账户，避免把自己锁在外面。
