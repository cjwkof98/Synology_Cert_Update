# Synology_Cert_Update
群晖NAS证书自动更新

## 脚本名称: 群晖SSL证书自动更新脚本
### 功能描述:
0.  主要配合Lucky使用，用Lucky申请证书，群晖同步Lucky的证书
1.  自动比对新旧证书有效期，仅当新证书过期时间晚于旧证书时才更新
2.  完整日志记录（带时间戳，符合中国时间格式习惯）
3.  防并发执行，避免重复运行导致冲突
4.  强制root权限检查，确保安全执行
5.  自动备份旧证书，支持失败回滚机制
6.  更新后自动重启Nginx并检查服务状态
7.  更新成功输出新证书生效/失效时间及剩余天数
8.  自动日志滚动，防止日志文件过大

### 使用说明:
1.  修改DOMAIN变量为你的域名
2.  可根据系统性能调整NGINX_WAIT_TIME（秒）
3.  手动执行: sudo bash update_cert.sh
4.  加入群晖自带的计划任务（需 root 执行权限），或使用 cron 定时任务: 0 3 1 * * /path/to/cert_update.sh

### 配置说明
-  日志路径: /volume1/docker/lucky/script/cert_update.log
-  备份路径: /volume1/docker/lucky/cert_backup
-  日志配置: 最大10MB，保留5个历史文件
-  Nginx等待: 默认5秒（可根据实际启动时间调整）
