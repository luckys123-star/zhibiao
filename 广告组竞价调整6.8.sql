-- ============================================================
-- 广告组竞价决策SQL v7 — 时间段汇总版（手动/自动数据源分离）
-- 数据库: ods_datasync / opt_db
-- 更新日期: 2026-06-06
--
-- 核心变更：
--   1. 时间段汇总：整个时间段聚合，不按天输出，去掉 report_date
--   2. 广告活动过滤：只取 state='enabled' 的广告活动
--   3. 数据源分离：
--      - 手动投放：指标从 lx_advertising_sp_keyword_reports 取
--      - 自动投放：指标从 lx_advertising_sp_query_word_reports 取
--   4. 匹配方式：手动用 match_type，自动固定'用户搜索词'
--   5. 调整关键词：手动用 keyword_text，自动用 query
--   6. 保留原决策逻辑
--   7. 最终输出按 profile_id, campaign_id, ad_group_id 排序
-- ============================================================

USE opt_db;

SET @start_date = DATE_FORMAT(DATE_SUB(CURDATE(), INTERVAL 8 DAY), '%Y-%m-%d');
SET @end_date = DATE_FORMAT(DATE_SUB(CURDATE(), INTERVAL 2 DAY), '%Y-%m-%d');

-- ============================================================
-- 第0步：清理临时表
-- ============================================================
DROP TEMPORARY TABLE IF EXISTS tmp_campaigns;
DROP TEMPORARY TABLE IF EXISTS tmp_ad_groups;
DROP TEMPORARY TABLE IF EXISTS tmp_keyword_period;
DROP TEMPORARY TABLE IF EXISTS tmp_query_period;
DROP TEMPORARY TABLE IF EXISTS tmp_period_union;
DROP TEMPORARY TABLE IF EXISTS tmp_enriched;
DROP TEMPORARY TABLE IF EXISTS tmp_combined;
DROP TEMPORARY TABLE IF EXISTS tmp_decision;

-- ============================================================
-- 第1步：创建过滤后的广告活动临时表 + 索引（只取 enabled）
-- ============================================================
CREATE TEMPORARY TABLE tmp_campaigns AS
SELECT campaign_id,
       profile_id,
       name AS campaign_name,
       targeting_type
FROM ods_datasync.lx_advertising_sp_campaigns
WHERE state = 'enabled';

CREATE INDEX idx_tmp_campaigns_id ON tmp_campaigns (campaign_id, profile_id, targeting_type);

-- ============================================================
-- 第2步：创建过滤后的广告组临时表 + 索引
-- 只保留 enabled 广告活动下的广告组，避免 JOIN 后 campaign_name 为空
-- ============================================================
CREATE TEMPORARY TABLE tmp_ad_groups AS
SELECT ad_group_id,
       campaign_id,
       profile_id,
       seller_name,
       name AS ad_group_name,
       default_bid
FROM ods_datasync.lx_advertising_sp_ad_groups
WHERE campaign_id IN (SELECT campaign_id FROM tmp_campaigns);

CREATE INDEX idx_tmp_ad_groups_id ON tmp_ad_groups (ad_group_id, campaign_id, profile_id);
CREATE INDEX idx_tmp_ad_groups_campaign ON tmp_ad_groups (campaign_id, profile_id);

-- ============================================================
-- 第3步：手动投放周期汇总（从关键词报告按时间段聚合）+ 索引
-- ============================================================
CREATE TEMPORARY TABLE tmp_keyword_period AS
SELECT profile_id,
       campaign_id,
       ad_group_id,
       keyword_text,
       match_type,
       SUM(impressions)    AS impressions,
       SUM(clicks)         AS clicks,
       SUM(cost)           AS cost,
       SUM(orders_7d)      AS orders_7d,
       SUM(same_orders_7d) AS same_orders_7d,
       SUM(sales_7d)       AS sales_7d,
       SUM(same_sales_7d)  AS same_sales_7d
FROM ods_datasync.lx_advertising_sp_keyword_reports
WHERE report_date BETWEEN @start_date AND @end_date
GROUP BY profile_id, campaign_id, ad_group_id, keyword_text, match_type;

CREATE INDEX idx_tmp_keyword_period ON tmp_keyword_period (profile_id, campaign_id, ad_group_id);
-- ============================================================
-- 第4步：自动投放周期汇总（从搜索词报告按时间段聚合）+ 索引
-- ============================================================
CREATE TEMPORARY TABLE tmp_query_period AS
SELECT profile_id,
       campaign_id,
       ad_group_id,
        null               as keyword_text,
       CASE
           WHEN target_text LIKE '%queryHighRelMatches%' THEN 'close-match'
           WHEN target_text LIKE '%queryBroadRelMatches%' THEN 'loose-match'
           WHEN target_text LIKE '%asinSubstituteRelated%' THEN 'substitutes'
           WHEN target_text LIKE '%asinAccessoryRelated%' THEN 'complements'
           ELSE '未知定位组'
           END AS match_type,
       SUM(impressions)    AS impressions,
       SUM(clicks)         AS clicks,
       SUM(cost)           AS cost,
       SUM(orders_7d)      AS orders_7d,
       SUM(same_orders_7d) AS same_orders_7d,
       SUM(sales_7d)       AS sales_7d,
       SUM(same_sales_7d)  AS same_sales_7d
FROM ods_datasync.lx_advertising_sp_query_word_reports
WHERE report_date BETWEEN @start_date AND @end_date
GROUP BY profile_id, campaign_id, ad_group_id,keyword_text,target_text;
CREATE INDEX idx_tmp_query_period ON tmp_query_period (profile_id, campaign_id, ad_group_id);

-- ============================================================
-- 第5步：合并手动+自动周期数据 + 索引
-- ============================================================
CREATE TEMPORARY TABLE tmp_period_union AS
SELECT *
FROM tmp_keyword_period
UNION ALL
SELECT *
FROM tmp_query_period;

CREATE INDEX idx_tmp_period_union ON tmp_period_union (profile_id, campaign_id, ad_group_id);

-- ============================================================
-- 第6步：JOIN广告活动/广告组信息，补充名称和默认竞价
-- ============================================================
CREATE TEMPORARY TABLE tmp_enriched AS
SELECT g.seller_name   AS `店铺名称`,
       d.profile_id,
       d.campaign_id,
       d.ad_group_id,
       c.campaign_name AS `广告活动`,
       g.ad_group_name AS `广告组`,
       CASE
           WHEN c.targeting_type = 'manual' THEN '手动投放'
           WHEN c.targeting_type = 'auto' THEN '自动投放'
           END         AS `投放类型`,
       d.keyword_text
                       AS `调整关键词`,
       d.match_type    AS `匹配方式`,
       d.impressions,
       d.clicks,
       d.cost,
       d.orders_7d,
       d.same_orders_7d,
       d.sales_7d,
       d.same_sales_7d,
       g.default_bid
FROM tmp_period_union d
         LEFT JOIN tmp_campaigns c
                   ON c.campaign_id = d.campaign_id
                       AND c.profile_id = d.profile_id
         LEFT JOIN tmp_ad_groups g
                   ON g.ad_group_id = d.ad_group_id
                       AND g.campaign_id = d.campaign_id
                       AND g.profile_id = d.profile_id
where c.profile_id is not null
  and g.profile_id is not null
  and ((c.targeting_type = 'manual' and d.match_type in ('PHRASE','BROAD','EXACT'))
    or (c.targeting_type = 'auto' and d.match_type not in ('PHRASE','BROAD','EXACT')))
;
CREATE INDEX idx_tmp_enriched ON tmp_enriched (profile_id, campaign_id, ad_group_id);

-- ============================================================
-- 第7步：计算衍生指标（ACOS、CTR、CVR等）——基于整个时间段汇总值
-- ============================================================
CREATE TEMPORARY TABLE tmp_combined AS
SELECT `店铺名称`,
       profile_id,
       campaign_id,
       ad_group_id,
       `广告活动`,
       `广告组`,
       `投放类型`,
       `调整关键词`,
       `匹配方式`,
       impressions,
       clicks,
       cost,
       orders_7d,
       same_orders_7d,
       sales_7d,
       same_sales_7d,
       default_bid,
       CASE
           WHEN sales_7d > 0
               THEN (sales_7d - same_sales_7d) / sales_7d * 100
           ELSE 0
           END            AS brand_halo,
       CASE
           WHEN impressions > 0
               THEN clicks / impressions * 100
           ELSE 0
           END            AS ctr_pct,
       CASE
           WHEN clicks > 0
               THEN same_orders_7d / clicks * 100
           ELSE 0
           END            AS cvr_direct_pct,
       CASE
           WHEN sales_7d > 0
               THEN cost / sales_7d * 100
           ELSE NULL
           END            AS acos,
       CASE
           WHEN same_sales_7d > 0
               THEN cost / same_sales_7d * 100
           ELSE NULL
           END            AS acos_direct_pct,
       ROUND(cost / 7, 2) AS daily_avg_cost
FROM tmp_enriched;

CREATE INDEX idx_tmp_combined ON tmp_combined (profile_id, campaign_id, ad_group_id);

-- ============================================================
-- 第8步：决策逻辑计算
-- ============================================================
CREATE TEMPORARY TABLE tmp_decision AS
SELECT *,
       CASE
           WHEN clicks >= 50 AND same_orders_7d = 0 AND cost >= 20 THEN 1
           WHEN impressions = 0 AND cost > 0 THEN 1
           ELSE 0
           END AS is_stop,
       CASE
           WHEN clicks >= 50 AND same_orders_7d = 0 AND cost >= 20 THEN NULL
           WHEN impressions = 0 AND cost > 0 THEN NULL
           WHEN clicks > 20 AND same_orders_7d = 0 THEN -50
           WHEN acos > 60 THEN -40
           WHEN acos > 40 THEN -30
           WHEN acos > 30 THEN -20
           WHEN acos > 20 THEN -10
           WHEN same_orders_7d >= 3 AND clicks >= 5 AND cvr_direct_pct >= 15 THEN 30
           WHEN acos < 15 AND ctr_pct > 0.9 AND cvr_direct_pct > 12 THEN 30
           WHEN acos < 20 AND cvr_direct_pct > 10 THEN 20
           WHEN acos < 20 AND cvr_direct_pct > 8 THEN 10
           WHEN acos < 20 AND ctr_pct > 0.9 AND cvr_direct_pct < 5 THEN 5
           WHEN sales_7d > 0 AND acos < 20 THEN 0
           WHEN cost > 0 AND sales_7d = 0 THEN 0
           ELSE 0
           END AS adjust_pct
FROM tmp_combined;

CREATE INDEX idx_tmp_decision ON tmp_decision (profile_id, campaign_id, ad_group_id);

-- ============================================================
-- 第9步：最终输出（时间段汇总，不含 report_date）
-- ============================================================
SELECT profile_id,
       campaign_id,
       ad_group_id,
       `店铺名称`,
       `广告活动`,
       `广告组`,
       `投放类型`,
       `调整关键词`,
       `匹配方式`,
       CASE
           WHEN is_stop = 1 THEN '停掉'
           WHEN adjust_pct > 0 THEN CONCAT('增加', adjust_pct, '%')
           WHEN adjust_pct < 0 THEN CONCAT('降低', ABS(adjust_pct), '%')
           ELSE '维持不变'
           END AS `目标竞价`
FROM tmp_decision
ORDER BY profile_id, campaign_id, ad_group_id;
