# 自带 Google Health Desktop OAuth 客户端

本项目不提供共享 OAuth 客户端。下面操作由使用者在自己的 Google Cloud 项目与账号中完成；应用和构建脚本不会替你创建项目、接受条款或授予持久访问。控制台名称可能变化，以 Google 当前页面为准。

## 1. 准备账号与项目

- 先在 Google Health 移动应用登录目标 Google 账号，创建或关联 Health profile。仅完成普通 Google 登录不代表 profile 已就绪。
- 在 Google Cloud Console 创建或选择你有权管理的项目，并启用 **Google Health API**。
- Google Auth Platform 的 Branding / Audience 填入真实的应用和联系方式；若要求首页、隐私政策或授权域，使用你有权使用且与实际数据处理一致的资料。不要复制维护者客户端或将私人地址填进源码。
- 个人外部测试可保持 Testing，并在 Test users 添加实际要授权的账号。具体审核和资格以 Google 要求为准，不通过反复创建项目绕过限制。

## 2. 精确 scope 与客户端类型

在 Data Access 加入唯一权限：

```
https://www.googleapis.com/auth/googlehealth.health_metrics_and_measurements.writeonly
```

应用不需要健康历史、邮箱、账号 profile 或设备列表读取权限。Google 通用 setup 的快捷示例可能面向 Web Server；**本程序应在 Clients 手动创建 Desktop app**，不是 Web application，支持情况见[Health 注册类型](https://developers.google.com/health/migration/data-access)与[Desktop OAuth](https://developers.google.com/identity/protocols/oauth2/native-app)。

应用使用随机端口 `http://127.0.0.1:<port>/` 回调，state 和 PKCE 由 AppAuth 管理。不要改成 Google 的 Web Server 示例重定向地址、手动复制授权码或自定义远程回调。JSON 内的 auth/token URI 和 redirect_uris 不会替换程序固定的 Google 端点。

下载 Desktop 客户端 JSON。应用只接受顶层 `installed`，明确拒绝 `web`、歧义结构、坏类型和超过64KiB的文件；或直接手填 Client ID 与 Client Secret。桌面程序是 public client，不能依靠嵌入的 Secret 保密；仍不要提交你自己的配置，更不能公开 access/refresh token。[官方说明](https://developers.google.com/identity/protocols/oauth2/native-app)

## 3. 本机连接与上传确认

1. 在设置“OAuth 客户端”选择“JSON 导入”或“手动填写”。保存只写入本机 Keychain，不会开始 OAuth 或上传。
2. 点击连接，确认目标账号已开通 Google Health，再点击“在浏览器中连接”。在系统浏览器核对账号、应用身份和只写权限，由你完成授权。
3. 返回后，单独选择“开启自动同步”并确认。已有未完成真实记录可能开始处理；授权成功不等于已写入成功。
4. 在记录详情查看两项独立进度。暂停可停止后续请求；已经到达服务器的请求可能完成。

Testing refresh token通常7天到期；Production一般没有这一固定期限，但撤销、长期未用或策略变化仍会失效。Health官方对未验证客户端有用户上限，超过100用户有安全审查要求；单纯改成Production不代表审核完成。[官方 setup](https://developers.google.com/health/setup)

## 常见状态

| 状态 | 检查方法 |
|---|---|
| JSON不被接受 | 是否下载了Desktop的installed JSON；不要编辑成web格式或贴入真实内容求助 |
| 浏览器授权未完成 | 检查同一项目的API、受众测试账号及scope；取消后可明确重试，不需要把回调URL发给别人 |
| OAuth成功但写入失败 | 检查Health profile关联、API和权限；应用不额外调用需要readonly的identity接口 |
| 401/403／需要重新连接 | 可能授权失效或API权限不足；由你核实后操作，应用不会自动扩scope |
| 钥匙串仍未响应 | 这是系统调用尚未返回，不等于未授权。UI保持响应；停止等待不取消底层调用，返回前不能重试 |
| 待检查／409／Operation不明确 | 应用保留进度而非把它假定成功；不要删历史或反复重建相同数据来掩盖问题 |

“断开连接”移除本机授权并暂停，不能撤销Google侧授权或删除云端数据。完整撤销请在[Google账号第三方连接](https://myaccount.google.com/connections)操作。项目没有真实Google沙箱，离线测试不会向真实账号发送夹具。

资料核对日期：2026-10-27。本文不是对Google审核结果的承诺。
