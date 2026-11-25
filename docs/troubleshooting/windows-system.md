# Windows 系统

## 远程桌面提示"与此计算机的连接数是有限的"

- **现象**：用户远程连接自己的电脑时被拒绝
- **原因**：电脑非正常关机，之前的远程会话没有正常注销
- **处理**：连续 3 次非正常启动进入 WinRE → 安全模式，用本地账户登录，关闭远程控制后重启，再恢复正常

## 无法定位的软件冲突：干净启动 + 系统修复

1. 卸载第三方杀毒和系统优化软件
2. `msconfig` →「服务」勾选「隐藏所有 Microsoft 服务」→ 全部禁用；任务管理器禁用所有启动项；重启
3. 管理员 PowerShell 依次执行：
   ```
   Dism /Online /Cleanup-Image /ScanHealth
   Dism /Online /Cleanup-Image /CheckHealth
   Dism /Online /Cleanup-Image /RestoreHealth
   sfc /scannow
   ```
4. 重启验证，问题消失后再逐个恢复服务，定位冲突源

## C 盘空间被休眠文件占用

- **处理**：管理员命令行执行 `powercfg -h off`，删除与内存同等大小的 `hiberfil.sys`；需要恢复时执行 `powercfg -h on`

## 窗口全屏后上半部分显示不出来

- **排查方向**：调整「显示设置 → 缩放与布局」的缩放倍率；排查第三方桌面整理工具（如电脑管家的桌面收纳功能）

## 软件安装时提示"必须重启才能关闭用户账户控制"

- **原因**：安装程序要求关闭 UAC 才能写入
- **处理**：以管理员身份安装；确实必须关闭时，将 `HKLM\Software\Microsoft\Windows\CurrentVersion\Policies\System\EnableLUA` 改为 `0` 并重启
- **备注**：关闭 UAC 会降低终端安全性，安装完成后应恢复为 `1`

## 换机迁移时的用户数据位置

| 数据 | 路径 |
|---|---|
| 微信聊天记录 | `%USERPROFILE%\Documents\WeChat Files\`（可能被重定向到 D 盘） |
| Chrome 用户数据 / 书签 | `%LOCALAPPDATA%\Google\Chrome\User Data\Default\Bookmarks` |
| Outlook 数据文件 | `%LOCALAPPDATA%\Microsoft\Outlook` |
