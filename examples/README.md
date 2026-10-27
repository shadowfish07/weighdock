# 无凭据示例

`desktop-oauth.example.json` 仅说明应用接受的Desktop结构，两个空值**不能连接或通过校验**。请在自己的Cloud项目创建Desktop客户端，直接使用Google下载的原始JSON；不要在此目录填写真实值、提交或分享文件。

程序只解析installed.client_id和client_secret，固定授权端点不从文件读取。设备MAC/Bind Key在本机界面填写，没有设备配置文件导入功能。个人资料和过滤设置也由界面单独保存，无需创建额外配置文件。
