# 应用改名与兼容性

用户可见名称、默认构建包和可执行文件统一为 `WeighDock`／`WeighDock.app`。Swift 内部模块与源码目录 `S400Menu` 暂留，供现有测试和代码引用使用，不影响应用显示名。S400 协议类型和设备名称表示实际适配的型号。

以下标识保持不变，不能只为品牌统一而替换：

| 用途 | 保留值 |
|---|---|
| Bundle identifier／偏好设置域 | `local.S400Menu` |
| Keychain service | `local.S400Menu.credentials` |
| 测量文件 | `~/Library/Application Support/S400Menu/measurements.json` |

改名不包含数据迁移、历史重算、队列重建、凭据清理或重新 OAuth；过滤和同步设置仍由原偏好设置域读取。历史版权／归属中的原项目名称保留，不能为显示名修改第三方许可。

自行构建的 ad-hoc 签名或应用路径变化可能引起 macOS 对既有蓝牙／钥匙串访问重新确认。这与增加 OAuth scope 或修改钥匙串 ACL 不同；不要绕过系统提示。更新时先正常退出旧实例，再打开新版，避免两份接收／同步进程同时运行。构建脚本不会启动应用或替换运行中的安装。
