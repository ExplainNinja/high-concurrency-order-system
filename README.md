[Readme.md](https://github.com/user-attachments/files/32991317/Readme.md)
## 模块1：架构设计

### 1.1 数据库

- 数据库名：`order_system`
- 字符集：`utf8mb4`
- 排序规则：`utf8mb4_unicode_ci`

### 1.2 表结构

#### users（用户表）

| 字段 | 类型 | 约束 |
| :--- | :--- | :--- |
| id | INT | 主键，自增 |
| username | VARCHAR(50) | |
| phone | VARCHAR(20) | |
| register_time | DATETIME | |

#### products（商品表）

| 字段 | 类型 | 约束 |
| :--- | :--- | :--- |
| id | INT | 主键，自增 |
| product_name | VARCHAR(100) | |
| price | DECIMAL(10,2) | |
| stock | INT | |

#### orders（订单表）

| 字段 | 类型 | 约束 |
| :--- | :--- | :--- |
| id | INT | 主键，自增 |
| user_id | INT | |
| total_amount | DECIMAL(10,2) | |
| order_time | DATETIME | |
| status | TINYINT UNSIGNED | 非空，默认0，注释：0-待付款,1-已付款,2-已发货,3-已完成 |

#### order_details（订单详情表）

| 字段 | 类型 | 约束 |
| :--- | :--- | :--- |
| id | INT | 主键，自增 |
| order_id | INT | |
| product_id | INT | |
| quantity | INT | |
| price | DECIMAL(10,2) | |

### 1.3 设计说明

- **不设外键**：分区表不允许外键，且外键会拖慢批量写入。引用完整性由应用层保证。
- **暂不建索引**：先造数据，再根据慢查询逐条建索引。

---

## 模块2：数据生成

### 2.1 数据量

| 表 | 行数 | 生成方式 |
| :--- | :--- | :--- |
| users | 100,000 | 5 张数字表笛卡尔积 |
| products | 10,000 | 4 张数字表笛卡尔积 |
| orders | 1,000,000 | 6 张数字表笛卡尔积 |
| order_details | 2,000,000 | orders CROSS JOIN 2 行 |

### 2.2 关键参数

| 字段 | 范围 |
| :--- | :--- |
| user_id | 1 ~ 100000 |
| total_amount | 10 ~ 10000 |
| order_time | 过去 730 天内随机 |
| status | 0 ~ 4 随机 |
| product_id | 1 ~ 10000 |
| quantity | 1 ~ 5 |

### 2.3 造数技巧

- **笛卡尔积**：用 `UNION` 造出数字表（0~9），多张数字表做笛卡尔积，行数 = 10^表数。
- **唯一序号**：`a.n + b.n*10 + c.n*100 + d.n*1000 + e.n*10000 + 1`
- **随机值**：`FLOOR(1 + RAND()*N)`、`ROUND(10 + RAND()*990, 2)`
- **随机时间**：`DATE_SUB(NOW(), INTERVAL FLOOR(RAND()*730) DAY)`

**造数示例（以 orders 为例）**

```sql
INSERT INTO orders (user_id, total_amount, order_time, status)
SELECT
    FLOOR(RAND()*100000 + 1) AS user_id,
    ROUND(RAND()*9990 + 10, 2) AS total_amount,
    DATE_SUB(NOW(), INTERVAL FLOOR(RAND()*730) DAY) AS order_time,
    FLOOR(RAND()*5) AS status
FROM
    (SELECT 0 n UNION SELECT 1 UNION ... UNION SELECT 9) a,
    (SELECT 0 n UNION SELECT 1 UNION ... UNION SELECT 9) b,
    (SELECT 0 n UNION SELECT 1 UNION ... UNION SELECT 9) c,
    (SELECT 0 n UNION SELECT 1 UNION ... UNION SELECT 9) d,
    (SELECT 0 n UNION SELECT 1 UNION ... UNION SELECT 9) e,
    (SELECT 0 n UNION SELECT 1 UNION ... UNION SELECT 9) f;
```

---

## 模块3：慢查询优化

### 3.1 查询1：用户消费能力分析（高频）

**业务场景**：运营查看每个用户的消费画像，筛选高价值用户。

**SQL：**

```sql
SELECT 
    u.id AS user_id,
    u.username,
    COUNT(o.id) AS total_orders,
    SUM(o.total_amount) AS total_amount,
    AVG(o.total_amount) AS avg_amount,
    ROUND(SUM(CASE WHEN o.status = 3 THEN 1 ELSE 0 END) / COUNT(*), 2) AS completed_rate
FROM orders o
JOIN users u ON u.id = o.user_id
WHERE o.order_time > '2025-01-01'
GROUP BY u.id, u.username
HAVING SUM(o.total_amount) > 5000
ORDER BY total_amount DESC;
```

**优化前：**

| 指标 | 值 |
| :--- | :--- |
| 执行时间 | 3.74 秒 |
| type | ALL |
| key | NULL |
| rows | 998002 |
| Extra | Using where; Using temporary; Using filesort |

**优化方案**：建立联合索引 (order_time, user_id, total_amount, status)

**优化后：**

| 指标 | 值 |
| :--- | :--- |
| 执行时间 | 3.57 秒 |
| type | range |
| key | idx_time_user_amount_status |
| rows | 499001 |
| Extra | Using where; Using index; Using temporary; Using filesort |

**结论**：索引消除了回表（Using index），扫描行数从 99.8 万降至 49.9 万。但返回近 10 万行，filesort 开销大，整体提升有限。该查询为低频报表，可接受。

### 3.2 查询2：用户最近订单详情查询（高频）

**业务场景**：用户打开 APP 查看最近 3 个月的订单详情。

**SQL：**

```sql
SELECT 
    o.id AS order_id,
    o.order_time,
    o.total_amount,
    p.product_name,
    od.quantity,
    od.price
FROM orders o
JOIN order_details od ON o.id = od.order_id
JOIN products p ON p.id = od.product_id
WHERE o.user_id = 17302
  AND o.order_time >= DATE_SUB(NOW(), INTERVAL 3 MONTH)
  AND o.status = 3
ORDER BY o.order_time DESC;
```

**优化前：**

| 表 | type | key | rows | Extra |
| :--- | :--- | :--- | :--- | :--- |
| orders | eq_ref | PRIMARY | 1 | Using where |
| order_details | ALL | NULL | 1995000 | Using temporary; Using filesort |
| products | eq_ref | PRIMARY | 1 | NULL |

**问题**：order_details 全表扫描 199 万行。

**优化方案：**

- 建立 orders(user_id, order_time, status) 索引
- 建立 order_details(order_id) 索引

**优化后：**

| 表 | type | key | rows | Extra |
| :--- | :--- | :--- | :--- | :--- |
| orders | range | idx_user_time_status | 5 | Using index condition; Backward index scan |
| order_details | ref | idx_order_id | 1 | Using where |
| products | eq_ref | PRIMARY | 1 | NULL |

**优化前后对比：**

| 指标 | 优化前 | 优化后 |
| :--- | :--- | :--- |
| 执行时间 | 2.60 秒 | 0.00 秒 |
| 驱动表 | order_details | orders |
| 扫描行数 | 199 万 | 5 |

**结论**：驱动表改变，扫描量从 199 万降到 5 行，Backward index scan 消除了 filesort。优化效果显著。

### 3.3 查询3：用户消费分层统计（低频）

**业务场景**：运营按消费能力对用户分层，用于精准营销。

**SQL：**

```sql
SELECT
    CASE
        WHEN user_total < 5000 THEN '低'
        WHEN user_total <= 20000 THEN '中'
        ELSE '高'
    END AS level,
    COUNT(user_id) AS user_count,
    SUM(user_total) AS total_amount,
    ROUND(AVG(user_total), 2) AS avg_amount
FROM (
    SELECT user_id, SUM(total_amount) AS user_total
    FROM orders
    WHERE status = 3
    GROUP BY user_id
) AS t
GROUP BY level
ORDER BY FIELD(level, '高', '中', '低');
```

**执行计划：**

| 指标 | 值 |
| :--- | :--- |
| 执行时间 | 1.92 秒 |
| type | index（全索引扫描） |
| key | idx_user_time_status |
| rows | 998002 |
| Extra | Using where; Using temporary; Using filesort |

**决策**：不建新索引。

**理由：**

- 查询频率低（月度/季度分析），1.92 秒可接受。
- 建 (status, user_id, total_amount) 索引会拖慢高频写入。
- 工程判断：不是所有慢查询都要建索引，低频查询可接受全表扫描。

### 3.4 查询4：月度交易趋势分析（低频）

**业务场景**：运营查看过去 12 个月每月的交易趋势。

**SQL：**

```sql
SELECT 
    DATE_FORMAT(order_time, '%Y-%m') AS month,
    COUNT(id) AS order_count,
    SUM(total_amount) AS total_amount,
    ROUND(AVG(total_amount), 2) AS avg_amount
FROM orders
WHERE status = 3
  AND order_time >= DATE_SUB(NOW(), INTERVAL 12 MONTH)
GROUP BY DATE_FORMAT(order_time, '%Y-%m')
ORDER BY month ASC;
```

**执行计划：**

| 指标 | 值 |
| :--- | :--- |
| 执行时间 | 0.3 秒 |
| type | range |
| key | idx_time_user_amount_status |
| rows | 499001 |
| Extra | Using where; Using index; Using temporary; Using filesort |

**决策**：不建新索引。

**理由：**

- 查询频率低（月度报表），0.3 秒已足够快。
- 现有覆盖索引已避免回表。
- GROUP BY 用了 DATE_FORMAT 计算表达式，临时表和排序是固有开销，索引消除不了。

### 3.5 索引汇总

| 表 | 索引 | 用途 |
| :--- | :--- | :--- |
| orders | idx_time_user_amount_status | 查询1、查询4 |
| orders | idx_user_time_status | 查询2 |
| order_details | idx_order_id | 查询2 |
| users | uk_phone | 登录查询、防重复注册 |
| products | idx_product_name | 商品名前缀搜索 |

**已考虑但未建的索引：**

| 索引 | 原因 |
| :--- | :--- |
| orders(status, user_id, total_amount) | 查询3 为低频报表，1.92 秒可接受，避免拖慢写入 |
| order_details(product_id) | "反查商品订单"非真实高频需求，不建 |

### 3.6 工程判断总结

不是所有慢查询都要建索引。判断标准：

| 维度 | 该建索引 | 不该建索引 |
| :--- | :--- | :--- |
| 查询频率 | 高频（每秒多次） | 低频（每天/每周一次） |
| 扫描量 | 百万级以上 | 万级以下 |
| 写入影响 | 写入频率低 | 写入频率高 |
| 返回行数 | 少量 | 大量（排序代价高） |

**核心原则**：索引有代价（写入变慢、占磁盘、增加优化器负担），需要在"查询性能"和"写入性能"之间权衡。

---

## 模块4：事务与锁

### 4.1 实验1：行锁等待

**场景**：两个事务同时更新同一行，观察锁等待。

**窗口A：**

```sql
START TRANSACTION;
UPDATE products SET stock = stock - 1 WHERE id = 1;
-- 不提交
```

**窗口B：**

```sql
START TRANSACTION;
UPDATE products SET stock = stock - 1 WHERE id = 1;
-- 卡住，等待窗口A释放锁
```

**窗口A：**

```sql
COMMIT;
-- 窗口B 立刻完成
```

**结果：**

| 步骤 | 现象 |
| :--- | :--- |
| 窗口A 更新 id=1，不提交 | 持有行锁 |
| 窗口B 更新 id=1 | 卡住，等待锁 |
| 窗口A COMMIT | 释放锁 |
| 窗口B 立刻完成 | 拿到锁，执行成功 |
| 最终库存 | 301 → 299（两次扣减） |

**结论**：InnoDB 的行锁在写-写冲突时生效，后到的事务必须等待先到的事务提交或回滚。

### 4.2 实验2：死锁复现

**场景**：两个事务互相等对方释放锁，形成循环等待。

**窗口A：**

```sql
START TRANSACTION;
UPDATE products SET stock = stock - 1 WHERE id = 1;
-- 不提交
```

**窗口B：**

```sql
START TRANSACTION;
UPDATE products SET stock = stock - 1 WHERE id = 2;
-- 不提交
```

**窗口A：**

```sql
UPDATE products SET stock = stock - 1 WHERE id = 2;
-- 卡住，等窗口B释放 id=2 的锁
```

**窗口B：**

```sql
UPDATE products SET stock = stock - 1 WHERE id = 1;
-- 死锁！MySQL 报错并回滚其中一个事务
```

**报错信息：**

```text
ERROR 1213 (40001): Deadlock found when trying to get lock; try restarting transaction
```

**结果：**

| 步骤 | 窗口A | 窗口B |
| :--- | :--- | :--- |
| 1 | 锁 id=1 | 锁 id=2 |
| 2 | 抢 id=2 → 卡住 | 抢 id=1 → 卡住 |
| 3 | 等待 | MySQL 报错 1213，回滚事务B |

**结论：**

- InnoDB 自动检测死锁，回滚其中一个事务（通常是修改行数少或后启动的），避免永久阻塞。
- 死锁不是"错误"，是并发系统的正常现象。关键是应用层要能捕获 1213 错误并重试。

### 4.3 核心知识点

| 概念 | 说明 |
| :--- | :--- |
| 行锁 | InnoDB 默认使用行级锁，写-写冲突时后到的事务等待 |
| 死锁 | 两个事务互相等对方释放锁，形成循环等待 |
| 死锁检测 | InnoDB 自动检测，回滚代价较小的事务 |
| 隐式提交 | 再次执行 START TRANSACTION 会隐式提交前一个事务 |
| ROLLBACK 范围 | 只回滚当前活跃事务，已 COMMIT 的无法回滚 |

---

## 模块5：分区表

### 5.1 为什么需要分区表

订单表 `orders` 有 100 万行，随着业务增长会持续膨胀。如果所有数据都堆在一个物理文件里：

- 查询特定年份的订单时，仍要扫描大量无关数据。
- 删除历史数据（比如 2024 年）需要 `DELETE` 逐行删除，极慢。

**分区表的核心价值**：把一张大表在物理层面拆成多个小文件，按规则存放不同范围的数据。

### 5.2 分区实现

**第一步：改主键**

分区列必须包含在主键中，所以先把主键从 `(id)` 改为 `(id, order_time)`：

```sql
ALTER TABLE orders DROP PRIMARY KEY, ADD PRIMARY KEY (id, order_time);
```

耗时：3.60 秒（100 万行）

**第二步：创建 RANGE 分区**

```sql
ALTER TABLE orders
PARTITION BY RANGE (YEAR(order_time)) (
    PARTITION p2024 VALUES LESS THAN (2025),
    PARTITION p2025 VALUES LESS THAN (2026),
    PARTITION p2026 VALUES LESS THAN (2027),
    PARTITION p_future VALUES LESS THAN MAXVALUE
);
```

耗时：6.79 秒（100 万行）

**分区数据分布（删除前）：**

| 分区 | 行数 |
| :--- | :--- |
| p2024 | 134748 |
| p2025 | 499592 |
| p2026 | 364844 |
| p_future | 0 |

### 5.3 分区剪枝验证

```sql
EXPLAIN SELECT * FROM orders WHERE order_time BETWEEN '2025-01-01' AND '2025-12-31';
```

结果：partitions 列只显示 p2025，其他分区被自动跳过。

**结论**：MySQL 根据 WHERE 中的分区键，自动定位到相关分区，不扫描无关分区。

### 5.4 DROP PARTITION 实验

**删除前：**

| 指标 | 值 |
| :--- | :--- |
| 总行数 | 1,000,000 |
| 分区分布 | p2024: 134748, p2025: 499592, p2026: 364844, p_future: 0 |

**执行删除：**

```sql
ALTER TABLE orders DROP PARTITION p2024;
```

耗时：0.05 秒

**删除后：**

| 指标 | 值 |
| :--- | :--- |
| 总行数 | 865,499 |
| 减少行数 | 134,501 |
| 分区分布 | p2025: 499592, p2026: 364844, p_future: 0 |

**普通表 vs 分区表删除对比：**

| 方式 | 命令 | 特点 |
| :--- | :--- | :--- |
| 普通表 | DELETE FROM orders WHERE order_time < '2025-01-01' | 逐行删除，产生大量 binlog，数据量大时极慢 |
| 分区表 | ALTER TABLE orders DROP PARTITION p2024 | 直接删物理文件，0.05 秒完成，几乎不产生 binlog |

### 5.5 分区表的不足

| 不足 | 说明 |
| :--- | :--- |
| 分区键必须包含在主键或唯一索引中 | 硬性限制，1503 错误 |
| 不支持外键 | 分区表无法建外键 |
| 索引是局部索引 | 每个分区独立维护，跨分区查询时索引不能全局使用 |
| 查询必须命中分区键才能剪枝 | 否则会扫描所有分区，反而更慢 |
| 分区数量有上限 | MySQL 单表分区上限约 8192 个 |
| DDL 操作锁表 | ALTER TABLE ... PARTITION 代价高 |
| 分区键不能是动态函数 | 只能按固定 RANGE / LIST 分区 |

### 5.6 核心知识点

| 概念 | 说明 |
| :--- | :--- |
| 分区剪枝 | MySQL 根据 WHERE 中的分区键，自动跳过无关分区 |
| 物理分离，逻辑统一 | 对应用透明，查询写法不变，但底层是多文件 |
| DROP PARTITION | 删除整个分区，毫秒级，不产生大量 binlog |
| DDL 不可回滚 | ALTER TABLE 是 DDL，不能被事务回滚 |
| TABLE_ROWS 是估算值 | information_schema.partitions 里的行数是估算，非精确 |

生产环境上，分区表加索引是高风险操作，必须安排在业务低峰期。

---

## 模块6：自动化逻辑

### 6.1 存储过程：每日订单汇总

**业务场景**：每天统计当天的订单数据，写入 `order_daily_summary` 汇总表。

**需求：**

- 输入一个日期
- 统计该日期 `status = 3` 的订单数、总金额、平均金额
- 如果该日期已有记录 → `UPDATE`
- 如果没有 → `INSERT`

**关键代码：**

```sql
DELIMITER //

CREATE PROCEDURE calc_daily_summary(IN stat_date DATE)
BEGIN
    DECLARE v_count INT;
    DECLARE v_total DECIMAL(15,2);
    DECLARE v_avg DECIMAL(10,2);
    DECLARE v_exists INT;

    SELECT COUNT(*), SUM(total_amount), AVG(total_amount)
    INTO v_count, v_total, v_avg
    FROM orders
    WHERE DATE(order_time) = stat_date AND status = 3;

    SELECT COUNT(*) INTO v_exists
    FROM order_daily_summary
    WHERE summary_date = stat_date;

    IF v_exists > 0 THEN
        UPDATE order_daily_summary
        SET order_count = v_count, total_amount = v_total, avg_amount = v_avg
        WHERE summary_date = stat_date;
    ELSE
        INSERT INTO order_daily_summary (summary_date, order_count, total_amount, avg_amount)
        VALUES (stat_date, v_count, v_total, v_avg);
    END IF;
END //

DELIMITER ;
```

**判断过程：**

- 先用 SELECT ... INTO 统计出订单数、总金额、平均金额，暂存到变量。
- 用 SELECT COUNT(*) INTO v_exists 检查汇总表里是否已有该日期的记录。
- 用 IF v_exists > 0 判断：有则 UPDATE，无则 INSERT。

**调用与验证：**

```sql
CALL calc_daily_summary('2025-06-15');
SELECT * FROM order_daily_summary;
```

**结果：**

| 日期 | 订单数 | 总金额 | 平均金额 |
| :--- | :--- | :--- | :--- |
| 2025-06-15 | 284 | 1372386.38 | 4832.35 |

二次调用同一日期，验证 UPDATE 分支生效，表中仍只有 1 行，未重复插入。

**踩坑记录：**

- WHERE DATE(order_time) stat_date 缺少等号 =，语法错误。
- 在 MySQL 命令行逐行执行存储过程体，导致 DECLARE 被单独执行报错。需要用 DELIMITER // 包裹整段。

### 6.2 触发器：订单状态变更日志

**业务场景**：订单状态变更时（如从"已付款"变成"已发货"），自动写日志。

**需求：**

- AFTER UPDATE ON orders
- 只有 status 变化时才记录
- 记录订单 ID、旧状态、新状态、变更时间

```sql
DELIMITER //

CREATE TRIGGER trg_order_status_change
AFTER UPDATE ON orders
FOR EACH ROW
BEGIN
    IF OLD.status != NEW.status THEN
        INSERT INTO order_status_log (order_id, old_status, new_status, change_time)
        VALUES (NEW.id, OLD.status, NEW.status, NOW());
    END IF;
END //

DELIMITER ;
```

**核心理解：**

- OLD 是更新前的整行，NEW 是更新后的整行。
- OLD.status = 旧状态，NEW.status = 新状态。
- NEW.id = 订单 ID（即使 id 没被改动，NEW.id 依然有效）。

**测试：**

```sql
SELECT id, status FROM orders WHERE id = 100;   -- 状态 = 2
UPDATE orders SET status = 3 WHERE id = 100;
SELECT * FROM order_status_log;
```

**结果：**

| order_id | old_status | new_status | change_time |
| :--- | :--- | :--- | :--- |
| 100 | 2 | 3 | 2026-09-28 20:12:11 |

**踩坑记录：**

- 写成 FOR status CHANGE，正确写法是 FOR EACH ROW。
- NEW.order_id、OLD.old_status、NEW.new_status 都是错的。NEW 和 OLD 后面跟的是 orders 表的真实列名（id、status）。

### 6.3 游标：逐行处理 vs 单条 SQL

**业务场景**：给所有用户评定消费等级，写入 user_level_summary。

**等级规则：**

| 总消费 | 等级 |
| :--- | :--- |
| > 20000 | 高 |
| 5000 ~ 20000 | 中 |
| < 5000 | 低 |

**方案一：游标逐行处理**

用游标遍历 10 万用户，逐个判断等级、插入汇总表。

```sql
DELIMITER //

CREATE PROCEDURE calc_user_levels()
BEGIN
    DECLARE v_user_id INT;
    DECLARE v_order_count INT;
    DECLARE v_total_amount DECIMAL(15,2);
    DECLARE level VARCHAR(10);
    DECLARE done INT DEFAULT 0;

    DECLARE cur CURSOR FOR
        SELECT user_id, COUNT(*), SUM(total_amount)
        FROM orders
        WHERE status = 3
        GROUP BY user_id;

    DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = 1;

    OPEN cur;

    read_loop: LOOP
        FETCH cur INTO v_user_id, v_order_count, v_total_amount;
        IF done THEN LEAVE read_loop; END IF;

        IF v_total_amount > 20000 THEN
            SET level = '高';
        ELSEIF v_total_amount > 5000 THEN
            SET level = '中';
        ELSE
            SET level = '低';
        END IF;

        INSERT INTO user_level_summary (user_id, total_orders, total_amount, level)
        VALUES (v_user_id, v_order_count, v_total_amount, level);
    END LOOP;

    CLOSE cur;
END //

DELIMITER ;
```

执行结果：CALL calc_user_levels(); 卡住数分钟未完成。

卡住原因：10 万个用户 → 游标循环 10 万次 → 每次一次单行 INSERT → 10 万次单行插入，性能极差。

```sql
TRUNCATE TABLE user_level_summary;

INSERT INTO user_level_summary (user_id, total_orders, total_amount, level)
SELECT 
    user_id,
    COUNT(*) AS total_orders,
    SUM(total_amount) AS total_amount,
    CASE
        WHEN SUM(total_amount) > 20000 THEN '高'
        WHEN SUM(total_amount) > 5000 THEN '中'
        ELSE '低'
    END AS level
FROM orders
WHERE status = 3
GROUP BY user_id;
```

执行结果：2.47 秒，插入 82,220 行。

**等级分布：**

| 等级 | 用户数 |
| :--- | :--- |
| 中 | 54,627 |
| 低 | 19,074 |
| 高 | 8,519 |
| 合计 | 82,220 |

**数据修正过程：**

- 第一次验证时，分组统计总数 = 129,888 行，但 INSERT 只插入 82,220 行。差额 47,668 行是游标卡住前已经插入的残留数据。

**修正方式：**

```sql
TRUNCATE TABLE user_level_summary;
```

清空后重新执行 INSERT，数据一致，总计 82,220 行。

**结论：**

| 方案 | 耗时 | 可扩展性 |
| :--- | :--- | :--- |
| 游标逐行处理 | 卡住数分钟 | ❌ 数据量越大越慢 |
| 单条 SQL 批量处理 | 2.47 秒 | ✅ 一次批量插入 |

- 能用一条 SQL 解决的批量处理，绝不用游标。
- 游标只用于"必须逐行处理不同逻辑"的场景（如每行调用外部系统、动态 SQL）。
- 游标适用于低频、小批量的场景，不适合大批量数据。

**踩坑记录：**

- 游标逻辑正确，但 10 万次单行 INSERT 导致性能崩溃。
- INSERT 时用了 VALUES(IF ... THEN ...)，语法错误。应该先用 IF 算出 level 变量，再放入 INSERT。
- ELSE IF 写成了两个词，应该是 ELSEIF。
- 游标卡住时已插入部分数据，导致第二次验证数据重复，用 TRUNCATE 清理后重跑。

### 6.4 模块总结

| 知识点 | 状态 | 核心理解 |
| :--- | :--- | :--- |
| 存储过程 | ✅ | IN/OUT 参数、DECLARE、IF 判断、SELECT INTO |
| 触发器 | ✅ | OLD/NEW 行对象、AFTER UPDATE、条件判断 |
| 游标 | ✅ | 逐行处理语法、HANDLER、LOOP，但要避免滥用 |

**最终结论**：自动化逻辑优先用 SQL（CASE WHEN + INSERT ... SELECT），游标是"最后手段"。

---

## 模块7：备份与恢复

### 7.1 完整备份

#### 需求

备份 `order_system` 数据库全部 7 张表的结构和数据，压缩存储，文件名带日期。

#### 当前数据量

| 表 | 行数 |
| :--- | ---: |
| orders | 865,499 |
| order_details | 2,000,000 |
| order_daily_summary | — |
| order_status_log | — |
| products | 10,000 |
| user_level_summary | 82,220 |
| users | 100,000 |

#### 执行

```bash
sudo mysqldump order_system | gzip > ~/backups/order_system_full_$(date +\%Y\%m\%d).sql.gz
```

**结果：**

| 文件 | 大小 |
| :--- | :--- |
| order_system_full_20260929.sql.gz | 33 MB |

### 7.2 恢复验证

**创建目标库**

```bash
sudo mysql -e 'CREATE DATABASE IF NOT EXISTS order_system_restore;'
```

**执行恢复**

```bash
gunzip < ~/backups/order_system_full_20260929.sql.gz | sudo mysql order_system_restore
```

**验证**

```bash
sudo mysql -e "USE order_system_restore; SHOW TABLES; SELECT COUNT(*) FROM orders; SELECT COUNT(*) FROM order_details;"
```

**数据对比**

| 表 | 原库 | 恢复库 | 一致 |
| :--- | :--- | :--- | :--- |
| orders | 865,499 | 865,499 | ✅ |
| order_details | 2,000,000 | 2,000,000 | ✅ |
| 其他 5 张表 | — | 全部恢复 | ✅ |

### 7.3 命令汇总

| 操作 | 命令 |
| :--- | :--- |
| 备份 | mysqldump 库名 \| gzip > 文件.sql.gz |
| 恢复 | gunzip < 文件.sql.gz \| mysql 目标库 |

### 7.4 问题记录

| 问题 | 原因 | 修正 |
| :--- | :--- | :--- |
| 恢复命令顺序错误 | 写成 文件.gz > gunzip \| mysql，文件名被当成命令 | 正确顺序：gunzip < 文件.gz \| mysql 目标库 |

**关于 gunzip < 文件.gz 与 gunzip 文件.gz 的区别**

| 写法 | 行为 | 中间文件 |
| :--- | :--- | :--- |
| gunzip 文件.gz | 解压生成 文件.sql，原 .gz 被删除 | 有 |
| gunzip < 文件.gz | 从标准输入读取，解压后输出到标准输出 | 无 |

恢复时使用 gunzip < 文件.gz | mysql，边解压边导入，不产生中间文件。

### 7.5 备份文件清单

| 文件 | 用途 | 大小 |
| :--- | :--- | :--- |
| orders_before_partition_20260928.sql.gz | 分区操作前的 orders 表备份 | 12 MB |
| order_system_full_20260929.sql.gz | 全库完整备份 | 33 MB |

---

## 模块8：定时备份

### 8.1 需求

- 每天 20:00 自动备份 `order_system` 的 4 张核心表（users、products、orders、order_details）
- 压缩存储到 `~/backups/`
- 文件名带日期：`core_日期.sql.gz`
- 自动清理 7 天前的旧备份

### 8.2 权限配置

**问题**：cron 以普通用户身份运行，没有 MySQL 权限，且无法交互输入密码。

**解决**：

1. 在 MySQL 里创建专用用户，授予 `order_system.*` 权限。
2. 创建 `~/.my.cnf`，存储账号密码：

```text
[client]
user=<MySQL用户名>
password=<MySQL密码>
```

3. 设置权限：`chmod 600 ~/.my.cnf`，防止密码泄露。

**安全说明**：

- `.my.cnf` 权限为 `600`，仅 owner 可读写。
- 该文件不纳入 Git 版本控制。
- README 中不出现任何真实密码。

### 8.3 crontab 配置

```bash
crontab -e
```

写入：

```text
0 20 * * * mysqldump order_system users products orders order_details | gzip > ~/backups/core_$(date +\%Y\%m\%d).sql.gz && find ~/backups/ -name 'core_*.sql.gz' -mtime +7 -delete
```

**命令拆解：**

| 部分 | 作用 |
| :--- | :--- |
| 0 20 * * * | 每天 20:00 执行 |
| mysqldump ... | 备份 4 张核心表 |
| \| gzip > ... | 压缩存储 |
| && | 前一个成功后才执行下一个 |
| find ... -mtime +7 -delete | 删除 7 天前的旧备份 |

### 8.4 测试结果

| 测试 | 结果 |
| :--- | :--- |
| 手动备份（指定账号密码） | ✅ 生成 33MB 文件 |
| 免密备份（.my.cnf 生效） | ✅ 无需输入密码 |
| 定时任务 | 待 20:00 自动执行验证 |

### 8.5 待办

- [ ] 20:00 后检查 ~/backups/ 是否有 core_日期.sql.gz 生成
- [ ] 验证 7 天后旧文件是否被自动清理
出现了
yyn@DESKTOP-KVNP01U:~$ ls -lh ~/backups/
total 77M
-rw-rw-r-- 1 yyn yyn 33M Sep 29 20:00 core_20260929.sql.gz
-rw-r--r-- 1 yyn yyn 33M Sep 29 13:47 order_system_full_20260929.sql.gz
-rw-r--r-- 1 yyn yyn 12M Sep 28 15:56 orders_before_partition_20260928.sql.gz

---

## 模块9：主从复制

### 9.1 环境规划

| 角色 | 端口 | server_id | 数据目录 | socket |
| :--- | :--- | :--- | :--- | :--- |
| 主库 | 3306 | 1 | /var/lib/mysql | /var/run/mysqld/mysqld.sock |
| 从库 | 3307 | 2 | /var/lib/mysql_slave | /var/run/mysqld/mysqld_slave.sock |

### 9.2 搭建步骤

**第一步：创建从库数据目录**

```bash
sudo mkdir -p /var/lib/mysql_slave
sudo chown mysql:mysql /var/lib/mysql_slave

第二步：初始化从库

bash
sudo /usr/sbin/mysqld --initialize-insecure --user=mysql --datadir=/var/lib/mysql_slave

第三步：启动从库

bash
sudo /usr/sbin/mysqld --user=mysql --datadir=/var/lib/mysql_slave --port=3307 --server-id=2 --socket=/var/run/mysqld/mysqld_slave.sock --pid-file=/var/run/mysqld/mysqld_slave.pid --daemonize
第四步：主库创建复制用户

sql
CREATE USER 'repl'@'localhost' IDENTIFIED WITH mysql_native_password BY '<密码>';
GRANT REPLICATION SLAVE ON *.* TO 'repl'@'localhost';
FLUSH PRIVILEGES;
第五步：获取主库 binlog 位置

sql
SHOW BINARY LOG STATUS\G
（MySQL 8.4 用 SHOW BINARY LOG STATUS，旧版本是 SHOW MASTER STATUS）

记录 File 和 Position。

第六步：从库配置主从连接

sql
CHANGE REPLICATION SOURCE TO
    SOURCE_HOST='localhost',
    SOURCE_PORT=3306,
    SOURCE_USER='repl',
    SOURCE_PASSWORD='<密码>',
    SOURCE_LOG_FILE='binlog.000021',
    SOURCE_LOG_POS=67179313;
（MySQL 8.4 用 CHANGE REPLICATION SOURCE TO，旧版本是 CHANGE MASTER TO）

第七步：启动复制

sql
START REPLICA;
（MySQL 8.4 用 START REPLICA，旧版本是 START SLAVE）

第八步：查看复制状态

sql
SHOW REPLICA STATUS\G
9.3 复制状态验证
指标	值	说明
Replica_IO_Running	Yes	IO 线程正常，正在拉取主库 binlog
Replica_SQL_Running	Yes	SQL 线程正常，正在执行 relay log
Seconds_Behind_Source	0	零延迟，完全同步
Last_Errno	0	无错误
9.4 数据同步验证
主库执行：

sql
CREATE DATABASE IF NOT EXISTS repl_test;
USE repl_test;
CREATE TABLE test_table (id INT PRIMARY KEY AUTO_INCREMENT, msg VARCHAR(50));
INSERT INTO test_table (msg) VALUES ('hello from master');
从库验证：

sql
SHOW DATABASES;          -- 能看到 repl_test
USE repl_test;
SELECT * FROM test_table;  -- 能看到 hello from master
结果：从库自动同步了主库的建库、建表、插入操作。

9.5 主从复制原理
text
主库                         从库
─────                       ─────
1. 写操作
2. 写入 binlog
         ──────────────→  3. IO 线程拉取 binlog，写入 relay log
                          4. SQL 线程读取 relay log，执行 SQL
                          5. 数据同步完成
9.6 踩坑记录
问题	原因	修正
SHOW MASTER STATUS 报语法错误	MySQL 8.4 已弃用该命令	改用 SHOW BINARY LOG STATUS
命令名与旧版本不同	MySQL 8.4 用 source/replica 术语	CHANGE MASTER TO → CHANGE REPLICATION SOURCE TO；START SLAVE → START REPLICA
9.7 核心知识点
概念	说明
binlog	主库的二进制日志，记录所有写操作
relay log	从库的中继日志，暂存从主库拉取的 binlog
IO 线程	从库线程，负责从主库拉取 binlog 写入 relay log
SQL 线程	从库线程，负责读取 relay log 并执行
主从延迟	从库执行速度慢于主库写入速度时产生的数据延迟
异步复制	MySQL 默认模式，主库不等从库确认就返回
半同步复制	主库等至少一个从库确认收到 binlog 才返回，减少数据丢失风险
