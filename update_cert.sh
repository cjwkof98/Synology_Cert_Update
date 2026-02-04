#!/bin/bash
#  power_guard.sh  ——  群晖断电关机 + 来电PushPlus通知（含断电时间记录 & 启动延迟）
#  所有参数直接改下面 9 行
GATEWAY="192.168.x.x"
INTERVAL=120         # 正常检测间隔（秒）
FAST_INTERVAL=60     # 网络异常时快速检测间隔（秒）
FAIL_COUNT=3
SHUTDOWN_DELAY=10
# PushPlus通知配置（在 https://www.pushplus.plus/  获取token）
PUSHPLUS_TOKEN="TOKEN_XXX"
STARTUP_DELAY=100     # 启动后延迟时间（秒），避免启动时网络未就绪
ENABLED=yes

# ----------- 以下勿动 -----------
DIR="$(cd "$(dirname "$0")" && pwd)"
LOG="$DIR/power_guard.log"
LOCK="$DIR/power_guard.lock"
MARK="$DIR/power_guard_down"
FAILURE_TIME_FILE="$DIR/power_failure_time"

# 日志函数：带轮转和自动截断
log(){
  if [ -f "$LOG" ] && [ "$(stat -c%s "$LOG" 2>/dev/null || echo 0)" -gt 1048576 ]; then
    tail -n 500 "$LOG" > "${LOG}.tmp" 2>/dev/null && mv "${LOG}.tmp" "$LOG"
    echo "[$(date '+%F %T')] === 日志文件超过1MB，已轮转截断 ===" >> "$LOG"
  fi
  echo "[$(date '+%F %T')] $*" >> "$LOG"
}

# PushPlus通知函数（含断电时间）
send_notification(){
  [ -z "$PUSHPLUS_TOKEN" ] && { log "警告：PUSHPLUS_TOKEN未设置，跳过通知发送"; return 1; }
  
  local TITLE="【群晖断电恢复】"
  local RECOVERY_TIME=$(date '+%F %T')
  local FAILURE_TIME="未知"
  
  if [ -f "$FAILURE_TIME_FILE" ] && [ -s "$FAILURE_TIME_FILE" ]; then
    FAILURE_TIME=$(cat "$FAILURE_TIME_FILE" 2>/dev/null)
  fi
  
  local CONTENT="[$HOSTNAME] 市电已恢复！<br/>断电时间：$FAILURE_TIME<br/>恢复时间：$RECOVERY_TIME"
  local URL="https://www.pushplus.plus/send "
  
  curl -s -G "$URL" \
       --data-urlencode "token=$PUSHPLUS_TOKEN" \
       --data-urlencode "title=$TITLE" \
       --data-urlencode "content=$CONTENT" \
       --data-urlencode "template=html" \
       --connect-timeout 10 \
       --max-time 30 \
       >> "$LOG" 2>&1
  
  if [ $? -eq 0 ]; then
    log "来电通知已通过PushPlus发送（断电时间：$FAILURE_TIME）"
    return 0
  else
    log "错误：PushPlus通知发送失败（网络或配置问题）"
    return 1
  fi
}

# Ping测试函数
ping_test(){
  if ping -c1 -W3 "$GATEWAY" &>/dev/null; then
    return 0
  else
    log "网关检测：$GATEWAY 不可达"
    return 1
  fi
}

# 关机函数
do_shutdown(){
  log "=== 断电条件已满足（连续失败≥$FAIL_COUNT次）==="
  log "系统将在 ${SHUTDOWN_DELAY}秒 后通过DSM专用命令关机..."
  
  date '+%F %T' > "$FAILURE_TIME_FILE"
  log "已记录断电时间：$(cat "$FAILURE_TIME_FILE")"
  
  touch "$MARK"
  sleep "$SHUTDOWN_DELAY"
  log "执行关机命令：/usr/syno/sbin/synopoweroff"
  /usr/syno/sbin/synopoweroff >> "$LOG" 2>&1
  
  if [ $? -ne 0 ]; then
    log "警告：synopoweroff失败，尝试使用poweroff命令"
    poweroff >> "$LOG" 2>&1
  fi
}

# 单例检查：使用 flock 锁定文件
(
  flock -n 200 || {
    log "错误：PowerGuard 已在运行（锁文件占用：$LOCK）"
    exit 1
  }
  
  # 主循环
  main(){
    local fail=0
    
    log "================================"
    log "PowerGuard 守护进程启动"
    log "工作目录：$DIR"
    log "监控网关：$GATEWAY"
    log "正常间隔：${INTERVAL}秒 | 快速间隔：${FAST_INTERVAL}秒"
    log "失败阈值：${FAIL_COUNT}次"
    log "关机延迟：${SHUTDOWN_DELAY}秒"
    log "启动延迟：${STARTUP_DELAY}秒"
    
    if [ -n "$PUSHPLUS_TOKEN" ]; then
      if curl --version &>/dev/null; then
        log "通知服务检查：curl命令可用，PushPlus通知已配置"
      else
        log "错误：curl命令不可用，通知功能将失效"
      fi
    else
      log "通知未启用（PUSHPLUS_TOKEN为空）"
    fi
    
    # 启动延迟
    log "启动延迟 ${STARTUP_DELAY} 秒后开始检测..."
    sleep "$STARTUP_DELAY"
    log "启动延迟结束，开始正常监控"
    
    # 主循环
    while :; do
      # 动态选择检测间隔
      local current_interval
      if [ $fail -gt 0 ]; then
        current_interval="$FAST_INTERVAL"
      else
        current_interval="$INTERVAL"
      fi
      
      sleep "$current_interval"
      
      if [ "$ENABLED" = "no" ]; then
        log "ENABLED=no，跳过本轮检测"
        continue
      fi
      
      if ping_test; then
        # ping成功
        if [ $fail -ge "$FAIL_COUNT" ]; then
          log "网络已恢复，关机序列已取消"
        fi
        
        fail=0
        
        # 如果存在断电标记文件，发送来电通知
        if [ -f "$MARK" ]; then
          send_notification
          rm -f "$MARK"
        fi
      else
        # ping失败
        fail=$((fail+1))
        log "连续失败 $fail/$FAIL_COUNT 次"
        
        if [ $fail -ge "$FAIL_COUNT" ]; then
          do_shutdown
        fi
      fi
    done
  }
  
  # 捕获所有输出到日志并运行主函数
  main >> "$LOG" 2>&1
  
) 200>"$LOCK"

# 脚本正常结束时清理（但实际上主函数是无限循环，这里很少执行）
rm -f "$LOCK"
