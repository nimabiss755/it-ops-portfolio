# 部署与脚本

## 入域后立刻把域账号加入本地管理员组，报错 1789

- **现象**：部署脚本执行 `Add-Computer` 入域后，紧接着把域账号加入本地 Administrators，报错 1789（此工作站和主域间的信任关系失败）
- **原因**：入域后还没重启，计算机与域控的安全通道尚未建立完成，无法解析域账号
- **处理**：把流程拆成两次运行：第一次只入域并重启；重启后用域管理员登录，第二次运行再把使用人加入本地管理员组，并按 SID 回查确认
- **备注**：这类"时序问题"在手工操作时不容易发现，只有写成脚本、步骤紧挨着执行时才会暴露。对应脚本：[tools/domain-join](../../tools/domain-join/)

## PowerShell 5.1 不支持 `Start-Process -UseShellExecute`

- **现象**：脚本在 PowerShell 7 测试正常，在 Win10/11 自带的 Windows PowerShell 5.1 上报参数不存在
- **原因**：`UseShellExecute` 是 `System.Diagnostics.ProcessStartInfo` 的属性，不是 5.1 中 `Start-Process` 的参数
- **处理**：按 5.1 能力编写；需要控制 ShellExecute 时直接构造 `ProcessStartInfo`。部署脚本里正是用 `UseShellExecute = false` 让安装包继承管理员令牌，避免二次弹 UAC
- **备注**：企业终端默认只有 5.1，部署脚本必须以 5.1 为准测试

## 中文脚本乱码、窗口一闪而过、`TerminatorExpectedAtEndOfString`

- **现象**：含中文的 .ps1 在 Win11 上运行时提示字符串未结束，或中文变乱码；.bat 双击后窗口一闪就关
- **原因**：Windows PowerShell 5.1 读取无 BOM 的 UTF-8 文件时会按系统 ANSI（GBK）解析，中文字节把引号"吃掉"；.bat 编码和代码页不匹配
- **处理**：.ps1 统一保存为 **UTF-8 with BOM + CRLF**；.bat 保存为 **ANSI + CRLF**（或 UTF-8 并在开头 `chcp 65001`）；生成脚本后立即做一次语法解析检查
- **备注**：看到 `TerminatorExpectedAtEndOfString` 优先怀疑编码，而不是代码逻辑

## 本地管理员组在不同语言系统里名字不同

- **现象**：脚本写死组名 `Administrators`，在部分系统上找不到组
- **原因**：组名随系统语言本地化（如「管理员」）
- **处理**：通过内置 SID `S-1-5-32-544` 解析组，不依赖名称

## 远程部署时无法点 UAC 确认

- **现象**：远程桌面装机时，每一步都弹 UAC 或安装向导，需要人工点击
- **处理**：以管理员身份一次性启动部署脚本；安装包全部使用静默参数；静默失败时检测安装向导窗口并发送回车兜底；缺失的安装包自动跳过并记录日志，关键步骤不因单点失败而中断

## Win11 安装时跳过联网

- **现象**：Win11 OOBE 强制要求联网登录微软账户
- **处理**：在联网界面按 `Ctrl+Shift+F10`（部分笔记本需加 Fn）打开命令行，启动任务管理器，结束 `networkconnectionflow.exe` 进程，即可跳过联网

## 关闭 BitLocker 后磁盘仍显示黄色感叹号

- **处理**：管理员命令行执行 `manage-bde -off C:` 解密，用 `manage-bde -status` 查看解密进度，完成后感叹号消失
- **备注**：新机出厂可能默认开启设备加密，入库前要统一检查
