#!/bin/bash
# ============================================
# MySQL 主从复制搭建脚本
# 主库：端口 3306，server_id=1
# 从库：端口 3307，server_id=2
# ============================================

echo "=== 1. 创建从库数据目录 ==="
sudo mkdir -p /var/lib/mysql_slave
sudo chown mysql:mysql /var/lib/mysql_slave

echo "=== 2. 初始化从库 ==="
sudo /usr/sbin/mysqld --initialize-insecure --user=mysql --datadir=/var/lib/mysql_slave

echo "=== 3. 启动从库 ==="
sudo /usr/sbin/mysqld \
  --user=mysql \
  --datadir=/var/lib/mysql_slave \
  --port=3307 \
  --server-id=2 \
  --socket=/var/run/mysqld/mysqld_slave.sock \
  --pid-file=/var/run/mysqld/mysqld_slave.pid \
  --daemonize

echo "=== 4. 请在主库执行以下 SQL ==="
cat << 'SQL'
CREATE USER 'repl'@'localhost' IDENTIFIED WITH mysql_native_password BY '<密码>';
GRANT REPLICATION SLAVE ON *.* TO 'repl'@'localhost';
FLUSH PRIVILEGES;
SHOW BINARY LOG STATUS\G
SQL

echo "=== 5. 请在从库执行以下 SQL（替换 File 和 Position）==="
cat << 'SQL'
CHANGE REPLICATION SOURCE TO
    SOURCE_HOST='localhost',
    SOURCE_PORT=3306,
    SOURCE_USER='repl',
    SOURCE_PASSWORD='<密码>',
    SOURCE_LOG_FILE='<主库File>',
    SOURCE_LOG_POS=<主库Position>;

START REPLICA;
SHOW REPLICA STATUS\G
SQL
