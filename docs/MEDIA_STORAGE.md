# 媒体存储接入

服务端默认使用本地磁盘存储，启动参数为 `--media-dir`（或环境变量
`ZZZ_MEDIA_DIR`）。服务端托管的图片会保留原图，并生成一个最长边不超过
640px 的 JPEG 缩略图。消息中的 `url` 指向原图，`thumbnail_url` 指向缩略图。

需要接入 S3、MinIO、Cloudflare R2 等对象存储时，实现
`server/internal/store.ObjectStorage` 接口，然后用
`media.NewObjectStore(metadataStore, objectStorage)` 注入到
`gateway.SetMediaUploader`。该适配层使用内容哈希作为对象 ID，并以
`<id>` 和 `<id>.thumb` 分别保存原图和缩略图；对象 URL 由适配器返回，因此
可以直接使用公开 URL 或带权限的签名 URL。业务层不绑定具体供应商 SDK。

当前生产部署继续使用本地磁盘。对象存储客户端和密钥应由部署层提供，不能
写入消息内容或提交到仓库。
