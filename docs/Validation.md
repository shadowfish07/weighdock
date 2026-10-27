# 0.3.1 验证范围

## 已验证

- 本地 macOS 26.5.1 / Apple Silicon / Swift 6.3.2 Command Line Tools。
- [首轮 GitHub Actions](https://github.com/shadowfish07/weighdock/actions/runs/40539022069)（初始公开提交 `3fcbb87`）成功：macOS 15.7.9 / arm64 / Xcode 16.4 / Swift 6.1.2，119项离线测试、Release构建、ad-hoc签名与13项算法参考通过。这是托管runner构建测试，不是真实蓝牙／OAuth／界面或云端写入验证。
- 119 项 Swift Testing 回归、12 个 suite：协议解密与认证、双包合并/过期、体重过滤/重启/边界、存储兼容及失败闭锁、独立指标重试、OAuth 配置校验、Keychain 串行等待/取消/晚到结果、授权持久化、资料与向导路径、算法兼容。
- 全部使用合成数据、最小匿名公开夹具或内存服务；Google SDK 持久化测试拒绝真实网络请求。不接触生产 Keychain 或测量文件。
- Release 构建、Info.plist、ad-hoc 严格签名、依赖 privacy manifest 与许可随包检查。
- 开发阶段隔离界面检查：首次/已配置、记录/设置/帮助、JSON 和手填、阈值及凭据等待/失败/取消。真实界面观察确认设置可交互、BLE 扫描状态、既有授权恢复和单实例。没有为这些检查制造上传。
- 使用者反馈真实称重到 Google Health 链路已跑通；这不是自动化测试独立确认的云端写入。

## 尚未验证或不能据此推导

- Intel、macOS 13 最低部署目标及其他系统／Xcode版本矩阵；macOS15的真实蓝牙／OAuth／界面操作未实测。测试运行本身需要 macOS 14+ / Swift 6 工具链。
- Developer ID、公证、Gatekeeper 下载分发体验。
- 长期锁屏、睡眠唤醒、不同设备固件、多用户或相邻称重平滑与米家逐位一致性。
- Google 全部错误/Operation 查询与只写 scope 的云端矩阵；OAuth 成功、HTTP 200 或本地开关均不能替代云端完成状态。
- 公开夹具的兼容性不证明临床体脂准确度。算法分析见 [对照报告](MiHomeCompatibilityStudy.md)。

2026-10-27 本地发布准备还从白名单新导出目录重跑：119项/12 suites通过，Release构建及严格ad-hoc签名、7项许可/归属文件和4个SDK privacy manifest检查通过；未启动该构建。测试链接出现部署目标13与Testing.framework最低14的已知警告，Release无该警告。导出器分支筛选、归档多余文件/篡改/覆盖拒绝与匿名归档头检查通过。版本中的 CI 仅做离线构建测试，不索取秘密或发送健康数据。
