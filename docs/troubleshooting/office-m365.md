# Office / Microsoft 365

## 登录报错 0xCAA70004

- **现象**：Office 登录公司账户时，输入邮箱后长时间转圈，然后报 0xCAA70004；改 DNS、换网络、重装系统都无效
- **原因**：现代身份验证（ADAL / Modern Authentication）流程在本环境下失败
- **处理**：在 `HKCU\SOFTWARE\Microsoft\Office\16.0\Common\Identity` 下新建 DWORD `EnableADAL` = `0`，重启后改用账号密码方式登录
- **备注**：如果之后提示"组织中的其他账户已经登录此计算机"，先删除 `Identity` 整个键，重启并打开一次 Word 初始化配置，再重新添加 `EnableADAL`。该方法参考了网络上的排查文章，按本环境验证有效

## 一直提示"缓存的凭据已过期，无法保存修改"

- **现象**：Word / Excel / PowerPoint 反复弹出凭据过期警告，退出重登账号也无效
- **原因**：OneDrive 的「使用 Office 应用程序同步我打开的 Office 文件」协作功能在同步挂起时触发警告
- **处理**：OneDrive「设置 → Office」中取消勾选该选项，重启 Office
- **备注**：工作或学校账户可能看不到该选项卡，说明此设置由管理员策略控制

## Windows 生成凭据失败，但 Office 已登录

- **现象**：Office 365 账号已登录成功，但提示 Windows 生成凭据失败
- **处理**：如果不需要把账号加到 Windows，登录时选择「否，只登录此应用」；需要修复系统时依次执行 `DISM /Online /Cleanup-Image /RestoreHealth` 和 `sfc /scannow`
