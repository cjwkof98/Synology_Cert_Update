#!/bin/bash

# ==============================================================================
# 脚本名称: 群晖SSL证书自动更新脚本 v1.0
# 功能描述:
#   1. 自动比对新旧证书有效期，仅当新证书过期时间晚于旧证书时才更新
#   2. 完整日志记录（所有输出行均带时间戳，符合中国时间格式习惯）
#   3. 防并发执行，避免重复运行导致冲突
#   4. 强制root权限检查，确保安全执行
#   5. 自动备份旧证书，支持失败回滚机制
#   6. 更新后自动重启Nginx并检查服务状态
#   7. 更新成功输出新证书生效/失效时间及剩余天数
#   8. 自动日志滚动，防止日志文件过大
#
# 使用说明:
#   1. 修改DOMAIN变量为你的域名
#   2. 可根据系统性能调整NGINX_WAIT_TIME（秒）
#   3. 手动执行: sudo bash update_cert.sh
#   4. 定时任务: 0 3 1 * * /path/to/update_cert.sh
#
# 日志路径: /volume1/docker/lucky/script/cert_update.log
# 备份路径: /volume1/docker/lucky/cert_backup
# 日志配置: 最大10MB，保留5个历史文件
# Nginx等待: 默认5秒（可根据实际启动时间调整）
# ==============================================================================

# ==================== 配置区域 ====================
# 域名配置，请修改为你的实际域名
DOMAIN="domain.com"

# 证书相关路径
CERT_SRC_DIR="/volume1/docker/lucky/cert"
CERT_FILE="$CERT_SRC_DIR/${DOMAIN}.pem"
KEY_FILE="$CERT_SRC_DIR/${DOMAIN}.key"
CHAIN_FILE="$CERT_SRC_DIR/${DOMAIN}_issuerCertificate.crt"

# DEFAULT文件路径（存储证书目录随机值）
ARCHIVE_DEFAULT_FILE="/usr/syno/etc/certificate/_archive/DEFAULT"

# 证书目标目录（初始为空，脚本会自动读取并设置）
CERT_DEST_DIR=""

# 备份和日志路径
BACKUP_DIR="/volume1/docker/lucky/cert_backup"
LOG_DIR="/volume1/docker/lucky/script"
LOG_FILE="$LOG_DIR/cert_update.log"
LOCK_FILE="/tmp/cert_update.lock"

# 日志滚动配置
LOG_MAX_SIZE=10485760  # 10MB
LOG_BACKUP_COUNT=5

# Nginx启动等待时间（秒）
NGINX_WAIT_TIME=5

# ==================== 函数定义 ====================
# 日志函数：仅输出原始消息（时间戳由外部重定向统一添加）
log() {
    echo "$*"
}

# 日志滚动函数
rotate_log() {
    if [[ -f "$LOG_FILE" ]]; then
        local file_size
        if stat -f%z "$LOG_FILE" >/dev/null 2>&1; then
            file_size=$(stat -f%z "$LOG_FILE")
        else
            file_size=$(stat -c%s "$LOG_FILE")
        fi
        
        if [[ $file_size -gt $LOG_MAX_SIZE ]]; then
            log "日志文件达到10MB阈值，开始滚动..."
            
            if [[ -f "${LOG_FILE}.$LOG_BACKUP_COUNT.gz" ]]; then
                rm -f "${LOG_FILE}.$LOG_BACKUP_COUNT.gz"
            fi
            
            for i in $(seq $((LOG_BACKUP_COUNT - 1)) -1 1); do
                if [[ -f "${LOG_FILE}.$i.gz" ]]; then
                    mv "${LOG_FILE}.$i.gz" "${LOG_FILE}.$((i + 1)).gz"
                fi
            done
            
            if [[ -f "$LOG_FILE" ]]; then
                cp "$LOG_FILE" "${LOG_FILE}.1"
                gzip "${LOG_FILE}.1"
                > "$LOG_FILE"
                log "日志滚动完成，已创建 ${LOG_FILE}.1.gz"
            fi
        fi
    fi
}

# 格式化日期为中国人习惯的格式
format_date_chinese() {
    local date_str="$1"
    date -d "$date_str" "+%Y-%m-%d %H:%M:%S" 2>/dev/null
}

# 获取证书过期时间
get_cert_enddate() {
    local cert_file="$1"
    openssl x509 -noout -enddate -in "$cert_file" 2>/dev/null | cut -d= -f2
}

# 获取证书生效时间
get_cert_startdate() {
    local cert_file="$1"
    openssl x509 -noout -startdate -in "$cert_file" 2>/dev/null | cut -d= -f2
}

# 将日期字符串转换为时间戳
date_to_timestamp() {
    local date_str="$1"
    date -d "$date_str" +%s 2>/dev/null
}

# 检查文件是否存在
check_file_exists() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        log "错误：文件不存在: $file"
        exit 1
    fi
}

# ==================== 主逻辑 ====================
# 设置输出重定向：统一为所有输出添加时间戳并记录到日志文件
# 关键点：所有输出（包括log函数调用和命令输出）都只经过一次时间戳处理
exec > >(while IFS= read -r line; do 
    # 只为非空行添加时间戳，空行保持原样
    if [[ -n "$line" && ! "$line" =~ ^[[:space:]]*$ ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $line"
    else
        echo "$line"
    fi
done | tee -a "$LOG_FILE") 2>&1

# 执行日志滚动检查
rotate_log

log "========== 开始执行证书更新脚本 =========="

# 权限检查：确保以root权限运行
if [[ $EUID -ne 0 ]]; then
    log "错误：需要root权限运行此脚本，请使用sudo或root用户执行"
    exit 1
fi

# 防并发执行：检查锁文件
if [[ -f "$LOCK_FILE" ]]; then
    log "错误：脚本正在运行中（锁文件存在），请稍后再试"
    exit 1
fi

# 创建锁文件，并确保脚本退出时删除
trap 'rm -f "$LOCK_FILE"; log "脚本结束运行，已释放锁"; echo "" ' EXIT
touch "$LOCK_FILE"
log "已创建锁文件，防止重复执行"

# 自动获取证书目标目录
log "正在自动获取证书目标目录..."
if [[ -f "$ARCHIVE_DEFAULT_FILE" ]]; then
    # 读取DEFAULT文件内容并去除空白字符
    CERT_RANDOM_VALUE=$(cat "$ARCHIVE_DEFAULT_FILE" | tr -d '[:space:]')
    
    if [[ -z "$CERT_RANDOM_VALUE" ]]; then
        log "错误：DEFAULT文件内容为空，无法获取随机值"
        exit 1
    fi
    
    CERT_DEST_DIR="/usr/syno/etc/certificate/_archive/${CERT_RANDOM_VALUE}"
    log "检测到证书目录随机值: $CERT_RANDOM_VALUE"
    log "证书目标目录: $CERT_DEST_DIR"
    
    if [[ ! -d "$CERT_DEST_DIR" ]]; then
        log "错误：证书目标目录不存在: $CERT_DEST_DIR"
        log "请检查DEFAULT文件内容或手动创建目录"
        exit 1
    fi
else
    log "错误：DEFAULT文件不存在: $ARCHIVE_DEFAULT_FILE"
    log "请确认群晖系统版本或手动指定CERT_DEST_DIR"
    exit 1
fi

# 检查证书文件
check_file_exists "$CERT_FILE"
check_file_exists "$KEY_FILE"
check_file_exists "$CHAIN_FILE"

# 备份旧证书
mkdir -p "$BACKUP_DIR"
TIMESTAMP=$(date +%Y%m%d%H%M%S)
BACKUP_CERT="$BACKUP_DIR/cert.pem.$TIMESTAMP"
BACKUP_KEY="$BACKUP_DIR/privkey.pem.$TIMESTAMP"
BACKUP_CHAIN="$BACKUP_DIR/fullchain.pem.$TIMESTAMP"

# 检查新旧证书有效期
if [[ -f "$CERT_DEST_DIR/cert.pem" ]]; then
    old_cert_enddate=$(get_cert_enddate "$CERT_DEST_DIR/cert.pem")
    new_cert_enddate=$(get_cert_enddate "$CERT_FILE")
    
    if [[ -z "$old_cert_enddate" || -z "$new_cert_enddate" ]]; then
        log "错误：无法获取证书过期时间"
        exit 1
    fi
    
    # 转换为中文格式
    old_cert_enddate_fmt=$(format_date_chinese "$old_cert_enddate")
    new_cert_enddate_fmt=$(format_date_chinese "$new_cert_enddate")
    
    # 转换为时间戳进行比较
    old_cert_endtimestamp=$(date_to_timestamp "$old_cert_enddate")
    new_cert_endtimestamp=$(date_to_timestamp "$new_cert_enddate")
    
    # 比较过期时间
    if [[ $new_cert_endtimestamp -le $old_cert_endtimestamp ]]; then
        log "当前证书过期时间: $old_cert_enddate_fmt"
        log "新证书过期时间: $new_cert_enddate_fmt"
        log "新证书过期时间不晚于当前证书，无需更新，退出"
        exit 0
    fi
    
    log "证书过期时间比对通过"
    log "旧证书过期时间: $old_cert_enddate_fmt"
    log "新证书过期时间: $new_cert_enddate_fmt"
fi

# 如果旧证书存在则备份
if [[ -f "$CERT_DEST_DIR/cert.pem" ]]; then
    cp "$CERT_DEST_DIR/cert.pem" "$BACKUP_CERT"
    cp "$CERT_DEST_DIR/privkey.pem" "$BACKUP_KEY"
    cp "$CERT_DEST_DIR/fullchain.pem" "$BACKUP_CHAIN"
    log "已备份旧证书到 $BACKUP_DIR"
else
    log "警告：旧证书文件不存在，可能是首次部署"
fi

# 更新证书
log "开始更新证书文件"
cp "$CERT_FILE" "$CERT_DEST_DIR/cert.pem"
cp "$KEY_FILE" "$CERT_DEST_DIR/privkey.pem"
cat "$CERT_FILE" "$CHAIN_FILE" > "$CERT_DEST_DIR/fullchain.pem"
log "证书文件复制完成"

# 重启群晖Web服务
log "正在重启Nginx服务..."
synow3tool --gen-all
synow3tool --nginx=reload
synow3tool --get-nginx-mod
ng_result=$?
log "Nginx运行状态码为: ${ng_result}"

# 等待Nginx完全启动
log "等待Nginx服务启动完成（${NGINX_WAIT_TIME}秒）..."
sleep "$NGINX_WAIT_TIME"

# 检查Nginx状态，失败则回滚
if ! synow3tool --get-nginx-mod | grep -q "in normal"; then
    log "错误：Nginx重启失败，服务状态异常，开始回滚证书"
    
    # 恢复备份的旧证书
    if [[ -f "$BACKUP_CERT" ]]; then
        cp "$BACKUP_CERT" "$CERT_DEST_DIR/cert.pem"
        cp "$BACKUP_KEY" "$CERT_DEST_DIR/privkey.pem"
        cp "$BACKUP_CHAIN" "$CERT_DEST_DIR/fullchain.pem"
        synow3tool --gen-all
        synow3tool --nginx=reload
        log "已回滚到旧证书，请检查新证书文件是否正确"
    else
        log "严重错误：Nginx启动失败且没有备份证书可回滚"
    fi
    
    exit 1
fi

log "Nginx服务重启成功"

# 获取并打印新证书信息
new_cert_startdate=$(get_cert_startdate "$CERT_DEST_DIR/cert.pem")
new_cert_enddate=$(get_cert_enddate "$CERT_DEST_DIR/cert.pem")

# 转换为中文格式
new_cert_startdate_fmt=$(format_date_chinese "$new_cert_startdate")
new_cert_enddate_fmt=$(format_date_chinese "$new_cert_enddate")

log "证书更新成功！"
log "域名: $DOMAIN"
log "新证书生效时间: $new_cert_startdate_fmt"
log "新证书失效时间: $new_cert_enddate_fmt"

# 计算并显示剩余天数
days_left=$(( ( $(date_to_timestamp "$new_cert_enddate") - $(date +%s) ) / 86400 ))
log "证书剩余有效期: ${days_left} 天"

log "========== 证书更新脚本执行完成 =========="
