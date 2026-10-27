# WeighDock

连接蓝牙体脂秤与 Google Health 的 macOS 菜单栏工具，负责本地保存及经你授权后的直接同步。**目前仅适配并验证小米 S400（国行），其他型号尚不支持。** 当前 S400 适配接收加密 BLE 广播，保存体重与米家兼容体脂估算；没有安卓伴随进程、开发者健康数据中转服务器、广告或遥测。

**WeighDock 是本开源项目名称。** 当前构建目标仍为 `S400Menu`，应用内显示“S400 体重同步”；内部名称沿用以保持现有安装兼容，不表示新增设备支持。bundle ID、Keychain service、存储位置和用户自己的 OAuth 客户端保持原有口径。

[GitHub 仓库](https://github.com/shadowfish07/weighdock) · [问题反馈](https://github.com/shadowfish07/weighdock/issues) · [构建与测试](https://github.com/shadowfish07/weighdock/actions)

**当前版本 0.3.1，定位为自行构建的源码预览版。** 当前 S400 适配需要你自己的设备原始 MAC、BLE Bind Key，以及 Google Cloud Desktop OAuth 客户端。本项目不自动获取这些资料，也不附带共享客户端。与小米、Google 无官方隶属或认证关系。

## 当前设备支持

| 设备 | 状态与边界 |
|---|---|
| 小米 S400（国行） | 当前唯一适配；已有实机接收观察及使用者端到端跑通反馈，未覆盖全部固件 |
| 小米 S400 Pro | 尚不支持、未实机验证；体脂公式的 S400 Pro 来源不等于已适配其蓝牙协议 |
| 小米其他型号 | 尚不支持；不能通过换设备 MAC／Bind Key 直接启用 |
| 其他品牌蓝牙秤 | 尚不支持；没有通用蓝牙秤自动识别或插件入口 |

### 后续设备适配边界

本地记录、去重、同步队列和 Google Health 写入可作为后续适配的公共基础；当前接收入口和解码流程仍专用于 S400。新型号需要单独核实广播或 GATT 通信方式、认证／密钥要求、协议及字段单位、稳定称重与会话边界，再接入测量模型。体脂应按设备的原始结论或经验证的对应算法处理，不能将现有米家兼容公式泛用于所有秤。

新增支持还需要注明来源与许可的协议夹具、离线回归以及明确型号／固件的实机验证，再更新上表。当前未重构适配框架，也未实现或承诺其他型号支持。

## 已实现

- 三步首次配置；日常概览、记录、设置；仅体重或可选体脂资料，资料可独立修改。
- 设备解密认证、双包合并、去重、原子保存；断网退避重试，两项部分成功只处理未完成项。
- OAuth JSON 导入或手填；系统浏览器、PKCE、随机端口 loopback。连接与开启同步分开确认。
- 默认开启 10% 体重变化检测，可关闭或调整为整数 1–50%。过滤项只留本地记录，不生成上传项、不改变基线，改设置不会补传它们。
- Keychain 后台串行恢复。界面先启动；系统操作未返回时显示等待，不反复读取、不误判首次配置。

**只支持一台秤和一份用户资料。体重过滤不是身份识别**，体重接近的其他人仍可能记入同一资料。Mac 必须在蓝牙范围内并保持唤醒；锁屏可接收，睡眠期间不能接收，也无法补回未收到的广播。

## 环境与验证范围

| 项目 | 状态 |
|---|---|
| 本地验证环境 | macOS 26.5.1、Apple Silicon arm64、Command Line Tools / Swift 6.3.2 |
| 应用部署目标 | macOS 13；最低版本运行尚未独立验证 |
| 自动化测试 | Swift Testing，运行需 macOS 14+ 和 Swift 6 工具链；119 项离线回归 |
| 远程 CI | macOS 15.7.9 / arm64 / Xcode 16.4 / Swift 6.1.2；119 项测试、Release 构建与签名通过 |
| Intel、其他系统／工具链配置 | 尚未验证；CI 不覆盖真实蓝牙、OAuth 或界面操作 |
| 签名与分发 | 本机 ad-hoc 签名；没有 Developer ID、公证或通用二进制发行承诺 |

维护者已观察原生界面、BLE 扫描及既有授权恢复。使用者反馈 0.3.1 的真实称重到 Google 链路跑通；这属于用户反馈，不是本项目自动化测试独立观测的云端写入。长期锁屏、睡眠恢复和不同固件仍需更多验证。远程构建与离线测试已通过[首轮 GitHub Actions](https://github.com/shadowfish07/weighdock/actions/runs/40539022069)，不将托管 runner 的成功当作实机或云端健康数据验证。

## 从源码构建

安装 Apple Command Line Tools（或自行选择的完整 Xcode 工具链），确认 `xcode-select -p`、`swift --version` 正常；不需要第三方包管理器。依赖源码及许可已固定保存在 `Vendor/`，Swift 包依赖均为本地路径。

解压源码包或进入克隆目录后：

```sh
./Scripts/test.sh
./Scripts/build.sh
codesign --verify --deep --strict build/S400Menu.app
```

测试只用合成数据、匿名公开夹具、内存凭据和拦截网络，不需要设备、Google 账号、Keychain 条目或任何 CI secret。测试框架可能提示 macOS 14 与部署目标 13 的链接差异；应用 Release 不链接该测试框架。

构建不会启动应用。自行检查构建结果后，可运行：

```sh
open build/S400Menu.app
```

不要同时运行两个接收／同步实例。更新已有安装时，先正常退出旧版再打开新包；不要覆盖正在运行的应用包。脚本可接收一个新的输出路径，例如 `./Scripts/build.sh "$PWD/build/S400Menu-next.app"`，该路径会被构建脚本重新生成，请勿指向资料目录。

首发源码包不含原型或交互演示入口；必要的测试隔离服务仍保留。构建测试不会更改你正在运行的安装、登录项或系统睡眠设置。

## 首次设备配置

1. 在应用内添加自己的 S400，填写**原始设备 MAC**和 32 位十六进制 **BLE Bind Key**。CoreBluetooth UUID 不能代替原始 MAC。请使用自己已有的合法配对资料；本项目不提供自动提取密钥的流程。不要将凭据发到 issue、聊天或截图。
2. 点击“保存并继续”即将设备凭据保存在本机钥匙串并开始接收；系统蓝牙提示由你亲自处理。
3. 选择“仅体重”可跳过个人资料；选择体脂估算时填写出生年份、身高与公式性别，之后可在设置独立修改。新资料不重算旧记录。
4. Google 可暂不连接；称重先保存本机。需要同步时按下节准备自己的客户端。

## Google Health：自带 Desktop OAuth

完整步骤、常见失败及官方资料见 [Google 配置指南](docs/GoogleHealthSetup.md)。简要顺序：

1. 在 Google Health 移动应用为目标 Google 账号创建或关联 Health profile。
2. 自行创建／选择 Google Cloud 项目，启用 **Google Health API**。
3. 配置 Google Auth Platform 的品牌、受众、联系信息及所需网址；Testing 阶段将自己的账号加入测试用户。使用自己有权使用、与实际应用一致的品牌资料，不复制他人的账号或项目配置。
4. 在 Data Access 中只添加下面的只写 scope；在 Clients 中创建 **Desktop app**，不是 Web application。
5. 下载该客户端 JSON，在应用“OAuth 客户端”导入；或手填 Client ID 和 Client Secret。模板在 [examples/](examples/README.md)，空模板不能用于连接。
6. 确认 Health profile 已开通，点击“在浏览器中连接”，核对 Google 账号和权限，由你完成授权。
7. 回到应用后**另行确认开启自动同步**。此时会处理已有未完成的真实称重；以后可独立暂停接收或同步。

唯一 scope：

```text
https://www.googleapis.com/auth/googlehealth.health_metrics_and_measurements.writeonly
```

不请求读取健康历史、邮箱、profile 或设备列表。OAuth 成功不等于 Health profile 已关联，也不等于首次写入已成功。Desktop app 是 public client，Client Secret 不能作为可靠保密边界；用户令牌与设备密钥仍须严格保密。[官方 Desktop OAuth](https://developers.google.com/identity/protocols/oauth2/native-app)

Testing 的 refresh token 通常 7 天到期；In production 一般无这一固定期限，仍可能撤销或失效。公开共享客户端涉及审核、配额和安全审查，**本源码不附带这类资格，也不保证 Google 验证通过**。用户自带客户端同样必须遵守 Google 适用规则。[Google Health setup](https://developers.google.com/health/setup)

## 数据流与控制

```text
S400 加密广播 → Mac 认证/解密 → 双频合并/体脂估算 → 本地 JSON
                                             └→ 偏差排除：只记本地
本地未完成的有效项 → 用户单独开启同步 → Google Health（体重/有效体脂/时间/稳定ID）
```

- MAC/Bind Key、OAuth 客户端和授权状态存放在 Keychain；出生年份／身高／公式性别、过滤规则和开关在应用偏好设置。
- 体重、阻抗、体脂及算法版本、过滤元数据、时间、ID、同步进度在 `~/Library/Application Support/S400Menu/measurements.json`。目录／文件权限设为 0700／0600，原子写入；这是本地 JSON，**没有应用层加密**。
- 上传只含体重（克）或有效体脂（百分比）、采样时间／UTC 偏移和记录名。阻抗、个人资料、MAC、Bind Key 不在健康数据请求中。OAuth 信息仅按授权协议与 Google 交换。
- 界面按“次称重”显示待同步；体重和体脂保留独立进度，待检查与过滤项单独区分。
- 暂停会停止后续请求；在途请求可能完成。Google“断开连接”暂停同步并移除本机授权，保留已单独保存的客户端配置、记录和云端数据（旧版仅随授权保存的客户端可能需重新导入）；Google 侧撤销须在账号第三方连接中操作。
- 当前没有真实历史删除 UI、云端删除 API、设备凭据删除按钮或登录项。更换设备不删历史。清理本地记录前须自行退出应用并备份，且会同时清除本地队列进度；卸载或清本机文件不删除已上传数据。
- 应用不输出健康值、原始广播、MAC、密钥或服务错误正文；SDK 详细网络日志默认关闭。请勿把系统诊断或真实记录直接贴到公开 issue。

[本地隐私政策草稿](website/privacy/index.html) 描述当前处理方式；网页内容需要单独发布，本源码发布不会自动更新外部网站。

## 算法与已知限制

新称重使用 BodyMiScale 2026.10.4 固定提交的“米家兼容”体脂子集，转写来源是 **S400 Pro 固件**；不能宣传为普通 S400 官方逆向、与米家逐位一致或临床体脂测量。采用公开公式层的 0.1% 舍入和 3–55% 夹限，不套用 Home Assistant 外层 5% 下限。

年龄沿用测量年份减出生年份；仅接受成人及现有身高／体重／BMI／双频阻抗／接触门槛。缺输入只记体重，不用0%替代。体脂使用较大一频作为 Z50；阻抗历史平滑尚未实现，公开样本有已知差异。详细来源、单位、匿名对照和误差见 [公式对照](docs/MiHomeCompatibilityStudy.md)。历史值及已成功上传项不重算或重排。

自行构建的 ad-hoc 签名可能引起系统重新确认蓝牙或钥匙串访问；请亲自核对提示，不修改钥匙串访问控制或绕过系统安全机制。

其他限制：90秒内相同广播／测量可能被合并；缺第二频可在10秒后仅保存体重；不能自动识别多用户。429/5xx/断网有持久退避，401/403暂停，409或不明确结果保留待检查。异步 Operation 查询路径与只写 scope 的普遍兼容性未形成完整云端矩阵；不能将HTTP200直接视作写入完成。

## 贡献、许可与发布

见 [CONTRIBUTING](CONTRIBUTING.md)、[SECURITY](SECURITY.md)、[CHANGELOG](CHANGELOG.md) 和 [发布清单](docs/ReleaseChecklist.md)。漏洞或凭据泄漏不要提交公开 issue。

项目整体 **GPL-3.0-or-later**。openScale 协议／聚合改编仍保留 GPL 归属；BodyMiScale 子集和 Google SDK 保留 Apache-2.0 许可。改写公式不消除协议代码的许可来源。完整条款、固定版本与修改说明在 [LICENSE](LICENSE)、[THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES.md) 和 `Reference/`。源码首发不代表已取得 Developer ID、公证或 App Store 审核。
