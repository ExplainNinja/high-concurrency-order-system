#!/bin/bash
# ============================================
# 核心表定时备份脚本
# 由 crontab 每天 20:00 调用
# ============================================

# 备份 4 张核心表，压缩存储到 ~/backups/
mysqldump order_system users products orders order_details \
  | gzip > ~/backups/core_$(date +\%Y\%m\%d).sql.gz

# 清理 7 天前的旧备份
find ~/backups/ -name 'core_*.sql.gz' -mtime +7 -delete
