# WeighDock 源码发布清单

项目：[shadowfish07/weighdock](https://github.com/shadowfish07/weighdock)。简介：“连接蓝牙体脂秤与 Google Health 的 macOS 工具。目前仅适配并验证小米 S400（国行），其他型号尚不支持。”

首发为0.3.1源码预览版，从经过审阅的干净源码建立独立历史，不含旧开发历史、凭据、个人数据或安装包。公开署名采用维护者 GitHub 用户名与 GitHub noreply 邮箱。发布源码不等于发行已公证二进制。

默认构建产物与应用显示名为WeighDock。现有安装的数据与凭据标识保持兼容，开发细节见[兼容性说明](Compatibility.md)。

## 每次发布前

- 复核当前文件、历史、归档成员、测试结果和许可证。已知格式扫描不能证明任意未知秘密不存在；公开测试向量及匿名夹具须保留明确来源。
- 保留GPL-3.0-or-later、Apache-2.0条款、作者、修改说明、固定上游版本及构建所需源码。许可兼容依据见[Apache说明](https://www.apache.org/licenses/GPL-compatibility.html)。
- 无共享OAuth客户端，不上传任何个人配置、令牌、记录、诊断或健康截图；用户自行配置Desktop OAuth。漏洞渠道见[SECURITY](../SECURITY.md)。
- 明确支持矩阵及验证边界；算法的S400 Pro来源不代表支持S400 Pro，更不代表支持所有蓝牙秤。
- 没有安装包、Release或远程tag时，不在文档暗示已有这些产物。CI须实际通过才标记成功。

## 本地生成干净源码

修改源码或文档后，先暂存新增／删除文件，再运行 `python3 Scripts/export-source.py --refresh-inventory` 更新当前清单。清单不收录其自身或 `SHA256SUMS`；校验和文件只对源文件和最终清单各计算一次，不对自身取摘要。提交前核对改动范围。

```sh
python3 Scripts/export-source.py release-prep/weighdock-0.3.1-source
cd release-prep/weighdock-0.3.1-source
./Scripts/test.sh
./Scripts/build.sh
```

这些导出命令仅用于已有 Git 开发检出的目录；解压后的源码可直接测试构建，不必再次导出。目标必须是项目 `release-prep/` 下尚不存在的目录，脚本不会覆盖。采用显式文件白名单、拒绝符号链接，只复制 Git 跟踪的公共源码。输出含逐文件 SHA-256 和来源提交 SHA，不含作者身份。导出会移除三处应用源文件的 DEBUG 交互检查分支，并排除 PreviewScenario、UI QA 打包脚本及原型；保留 Release 生产分支和自动测试所需的隔离服务。变换记录在 `EXPORT_MANIFEST.json`，不声称与开发树逐字节相同。

独立源码目录也会生成 `.build/` 和 `build/`。**最终发布归档只按导出清单打包**，绝不把测试后的整个目录一并压缩。`python3 Scripts/archive-source.py release-prep/weighdock-0.3.1-source` 会核对清单、拒绝任何未列出的文件，并生成匿名归档头的 `.tar.gz` 与 SHA-256。应在新导出的干净目录上运行，或只清理该隔离目录中新产生的构建目录，勿清理生产数据。

### 明确包含

- `Sources/`（无交互演示）、`Tests/`、`Resources/`、`Package.swift`。
- 最小 Vendor 源码、manifest 指定的测试路径及许可/归属；不含第三方演示 App。
- `Reference/` 固定上游原文、哈希与归属；最小匿名公开算法夹具。
- 构建/测试/离线算法对照/导出脚本、公开 README/CHANGELOG/贡献/安全/配置示例、CI/issue 模板、公开技术文档。

### 明确排除

`.git`、build/.build、.tools/node_modules、个人验证日志/截图、真实记录/资料/凭据、原型 design、交互 QA 工具。必要自动化测试不属于交互演示；不能为“清理测试”删掉质量保障。

## 首版建议与以后再做

首版建议：源码先发、固定来源、明确环境矩阵；远程 CI 成功后再称其通过；审查真实 issue 附件避免隐私泄漏。数据处理方式变更时同步更新[数据与隐私](Privacy.md)。

后续再考虑：Developer ID 和公证、可复现二进制/通用架构、更多系统及固件矩阵、长期唤醒测试、Google 共享客户端所需审核。暂不承诺自动获取密钥、多用户身份识别或免审核 OAuth。
