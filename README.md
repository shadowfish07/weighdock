# WeighDock

让体脂秤连上 Mac，称重记录自动同步到 Google Health。

一个轻量的 macOS 菜单栏应用。上秤后自动接收体重和估算体脂，保存在本机，也可以直接同步到你的 Google Health。不需要安卓手机常驻，不用部署服务器。

**目前仅支持：小米体脂秤 S400（国行）。**

## 能做什么

- 自动接收称重，查看历史记录和同步状态。
- 自动同步到 Google Health，断网后重试。
- 过滤体重变化过大的记录，阈值可调，也可以关闭。
- 数据保存在本机，同步直连 Google，不经过开发者服务器。

## 开始使用

当前提供源码，需要在 Mac 上自行构建，暂不提供安装包。准备好 Swift 6 工具链后运行（已在 Apple Silicon Mac 验证）：

```sh
git clone https://github.com/shadowfish07/weighdock.git
cd weighdock
./Scripts/build.sh
open build/WeighDock.app
```

## 首次设置

按应用引导完成三步：

1. **添加秤**：自行在本机按 [Xiaomi Cloud Tokens Extractor](https://github.com/PiotrMachowski/Xiaomi-cloud-tokens-extractor) 的指南运行，登录绑定该秤的米家账号并选择对应地区（国行通常为 `cn`），将同一台 S400 的 `MAC`、`BLE KEY` 分别填入原始 MAC、BLE Bind Key。`BLE KEY` 不是普通 `TOKEN`，请勿公开密钥。
2. **设置资料**：只记录体重可以跳过；估算体脂需填写身高、出生年份和性别。
3. **连接 Google**：使用自己的 OAuth 客户端，支持 JSON 导入或手填。详见 [Google Health 配置教程](docs/GoogleHealthSetup.md)。

不连接 Google，也能只用本地记录。

## 使用提醒

- Mac 需要保持唤醒，并在秤的蓝牙范围内。
- 目前只支持单秤、单人资料，不能自动识别家庭成员。
- 体脂为估算值，不保证与米家完全一致。

## 文档与反馈

[算法说明](docs/MiHomeCompatibilityStudy.md) · [问题反馈](https://github.com/shadowfish07/weighdock/issues) · [贡献指南](CONTRIBUTING.md) · [更新记录](CHANGELOG.md)

本项目采用 [GPL-3.0-or-later](LICENSE) 许可证；上游代码归属与许可见 [THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES.md)。
