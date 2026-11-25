# Windows 企业终端运维 · 工具与排障作品集

金融行业驻场 IT 运维 6 年以上，负责约 100 人、150 台终端的 AD 域环境。这里收录我在日常运维中自己写的自动化工具，以及处理过的典型问题的排查过程。

> 所有内容已脱敏：公司名、域名、内网 IP、用户名等均已移除或替换。

## 技能概览

| 领域 | 内容 |
|---|---|
| 终端与域 | Windows 10/11 部署维护、AD 入域与账号权限、BitLocker、本地管理员组治理 |
| 自动化 | PowerShell（静默安装、提权与 UAC 处理、32/64 位重定向、中文编码兼容）、批处理 |
| 云桌面 | 深信服云桌面日常运维 |
| 排障方法 | 先取证再修改：事件日志、转储文件、驱动/设备清单 → 区分已确认根因与推测 |
| 网络与安全 | 企业代理/VPN/远程控制链路排查，终端安全软件（奇安信）兼容问题 |

## 工具

| 工具 | 说明 | 状态 |
|---|---|---|
| [Hosts 管理工具](tools/hosts-editor/) | PowerShell 图形界面 hosts 编辑器：按需提权写入、写前备份、写后回读校验、自带诊断报告 | ✅ 源码已收录 |
| [新机初始化脚本](tools/new-pc-init/) | 新机一键初始化：卸载 OneDrive、电源策略、桌面图标、常用软件静默安装 | ✅ 源码已收录（早期版本） |
| 新机一键部署（完整版） | 无人值守入域、本地管理员组、Office/办公软件/安全软件部署，全局容错；装机时间缩短约 1/3 | ⏳ 源码待补充 |
| [蓝屏/死机诊断一键采集](tools/bsod-collector/) | 双击自动提权，采集硬件、驱动、筛选驱动、蓝屏与硬件事件、转储，打包回传分析 | ✅ 源码已收录 |
| [本地管理员权限清理](tools/local-admin-cleanup/) | 基于 SID `S-1-5-32-544` 识别管理员组，兼容中英文系统，支持 `-WhatIf` 预览，可重复执行 | ✅ 源码已收录 |
| [安全的临时文件清理](tools/temp-cleanup/) | 删除前校验路径，只清 7 天前的临时文件和缩略图缓存，输出释放空间 | ✅ 源码已收录 |

## 案例

- [工作站蓝屏/死机远程取证](docs/case-studies/workstation-crash-forensics.md)：故障机不在身边时，如何一次采集到完整证据

## 排障记录

见 [docs/troubleshooting](docs/troubleshooting/)：

- [部署与脚本](docs/troubleshooting/deployment-and-scripting.md)：入域后加组报错 1789、PowerShell 5.1 兼容、中文脚本乱码、Win11 跳过联网、BitLocker
- [Office / Microsoft 365](docs/troubleshooting/office-m365.md)：0xCAA70004 登录失败、"缓存的凭据已过期"、Windows 生成凭据失败
- [Windows 系统](docs/troubleshooting/windows-system.md)：远程桌面"连接数有限"、干净启动 + 系统修复、休眠文件、显示异常、安装程序权限
- [Hosts 与终端安全](docs/troubleshooting/hosts-and-endpoint-security.md)：hosts 写入被拒绝的三种原因
- [企业代理与网络](docs/troubleshooting/proxy-and-network.md)：如何用证据判断流量是否真的走了代理

## 工作原则

1. **先诊断，再改动**：先拿日志、进程、配置这些实证，再动脚本或系统。
2. **区分证据等级**：已确认根因、候选原因、推测分开写。
3. **验证状态要说实话**：语法检查通过不等于部署成功，本机测试通过不等于全员可用。
4. **无人值守优先**：远程运维场景下，脚本要能自己处理失败，不能依赖人点确认。
