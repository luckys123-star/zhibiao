select yearweek(date_sub(curdate(), interval 1 week), 1);

# drop table if exists etl_datasync.pur_plan_prod_perf_salable_days_stat;
# create table etl_datasync.pur_plan_prod_perf_salable_days_stat as
# insert into etl_datasync.pur_plan_prod_perf_salable_days_stat
with 产品表现处理 as (select start_date,
                             country_category,
                             seller_name_new,
                             seller_sku_adj,
                             max(local_sku)                as sku,
                             max(afn_fulfillable_quantity) as afn_fulfillable_quantity
                      from etl_datasync.etl_dispose_lx_statistics_product_performance_2026
                      where start_date >= curdate() - interval 90 day
                      group by start_date, country_category, seller_name_new, seller_sku_adj),
     可售天数汇总 as (select country_category,
                             seller_name_new,
                             seller_sku_adj,
                             count(distinct case
                                                when start_date >=
                                                     curdate() - interval 90 day and
                                                     afn_fulfillable_quantity > 0
                                                    then start_date end) as r_90d_salable_days,
                             count(distinct case
                                                when start_date >=
                                                     curdate() - interval 30 day and
                                                     afn_fulfillable_quantity > 0
                                                    then start_date end) as r_30d_salable_days,
                             count(distinct case
                                                when start_date >=
                                                     curdate() - interval 14 day and
                                                     afn_fulfillable_quantity > 0
                                                    then start_date end) as r_14d_salable_days,
                             count(distinct case
                                                when start_date >=
                                                     curdate() - interval 7 day and
                                                     afn_fulfillable_quantity > 0
                                                    then start_date end) as r_7d_salable_days,
                             count(distinct case
                                                when start_date >=
                                                     curdate() - interval 3 day and
                                                     afn_fulfillable_quantity > 0
                                                    then start_date end) as r_3d_salable_days
                      from 产品表现处理
                      group by country_category, seller_name_new, seller_sku_adj)
select curdate()                            as sta_dt,-- as 数据日期,
       # date_format('2026-3-31', '%Y-%m-%d') as sta_dt,-- as 数据日期,
       country_category,                              -- as 国家类别,
       seller_name_new,                               -- as 新店铺,
       seller_sku_adj,                                -- as MSKU调整,
       r_90d_salable_days,                            -- as 近90天FBA可售天数,
       r_30d_salable_days,                            -- as 近30天FBA可售天数,
       r_14d_salable_days,                            -- as 近14天FBA可售天数,
       r_7d_salable_days,                             -- as 近7天FBA可售天数,
       r_3d_salable_days                              -- as 近3天FBA可售天数
from 可售天数汇总;

-- ========================================
-- 1. 创建临时表：识别自有品牌ASIN
-- ========================================
DROP TEMPORARY TABLE IF EXISTS opt_db.tmp_自有店铺品牌asin;
CREATE TEMPORARY TABLE opt_db.tmp_自有店铺品牌asin
(
    店铺名 VARCHAR(100),
    品牌名 VARCHAR(100),
    asin   VARCHAR(50),
    INDEX idx_shop_name (店铺名),
    INDEX idx_asin (asin),
    INDEX idx_shop_asin (店铺名, asin)
) ENGINE = InnoDB
AS
SELECT DISTINCT store.店铺名,
                store.品牌名,
                list.asin
FROM dwd_datasync.lx_sales_mws_listing list
         LEFT JOIN opt_db.store_brand_relation store
                   ON store.店铺名 = SUBSTRING_INDEX(list.seller_name, '-', 1)
                       AND store.品牌名 = list.seller_brand
WHERE store.店铺名 IS NOT NULL;

-- ========================================
-- 2. 创建临时表：asin到自有店铺的映射（去重后）
-- ========================================
DROP TEMPORARY TABLE IF EXISTS opt_db.tmp_asin_to_self_store;
CREATE TEMPORARY TABLE opt_db.tmp_asin_to_self_store (
                                                         asin VARCHAR(50) PRIMARY KEY,  -- 主键自动创建索引
                                                         self_store_name VARCHAR(100),
                                                         INDEX idx_self_store (self_store_name)
) ENGINE=InnoDB
AS
SELECT
    asin,
    MAX(店铺名) AS self_store_name
FROM opt_db.tmp_自有店铺品牌asin
GROUP BY asin;

-- ========================================
-- 3. 创建临时表：产品表现ASIN指标桥表（SKU+ASIN粒度）
--    源表同一SKU存在大量重复行，先压缩到SKU+ASIN粒度，同时保留ASIN供跟卖判断使用。
-- ========================================
DROP TEMPORARY TABLE IF EXISTS opt_db.tmp_prod_perf_sku_asin_metrics;
CREATE TEMPORARY TABLE opt_db.tmp_prod_perf_sku_asin_metrics AS
select
    max(list.cur_date)              as cur_date,
    list.country_category,
    list.seller_name_new,
    list.seller_sku_adj,
    list.asin,
    max(list.sales_90)              as sales_90,
    max(list.sales_30)              as sales_30,
    max(list.sales_14)              as sales_14,
    max(list.sales_7)               as sales_7,
    max(list.sales_3)               as sales_3,
    max(list.amount_30)             as amount_30,
    max(list.amount_14)             as amount_14,
    max(list.amount_7)              as amount_7,
    max(list.amount_3)              as amount_3,
    max(list.pprofit_30)            as pprofit_30,
    max(list.pprofit_14)            as pprofit_14,
    max(list.pprofit_7)             as pprofit_7,
    max(list.pprofit_3)             as pprofit_3,
    max(list.pprofit_ratio_30)      as pprofit_ratio_30,
    max(list.pprofit_ratio_14)      as pprofit_ratio_14,
    max(list.pprofit_ratio_7)       as pprofit_ratio_7,
    max(list.pprofit_ratio_3)       as pprofit_ratio_3
from etl_datasync.ops_weekly_rpt_prod_perf_interim as list
group by list.country_category,
         list.seller_name_new,
         list.seller_sku_adj,
         list.asin;

alter table opt_db.tmp_prod_perf_sku_asin_metrics
    add index idx_tmp_prod_perf_sku_asin_metrics_key (country_category(3), seller_name_new(64), seller_sku_adj(64)),
    add index idx_tmp_prod_perf_sku_asin_metrics_asin (seller_name_new(64), asin(30));

-- ========================================
-- 4. 创建临时表：产品表现指标表（SKU粒度）
--    销量/利润分段字段在重复行中一致，按SKU粒度取max后供日销和利润计算复用。
-- ========================================
DROP TEMPORARY TABLE IF EXISTS opt_db.tmp_prod_perf_sku_metrics;
CREATE TEMPORARY TABLE opt_db.tmp_prod_perf_sku_metrics AS
select
    max(list.cur_date)              as cur_date,
    list.country_category,
    list.seller_name_new,
    list.seller_sku_adj,
    max(list.sales_90)              as sales_90,
    max(list.sales_30)              as sales_30,
    max(list.sales_14)              as sales_14,
    max(list.sales_7)               as sales_7,
    max(list.sales_3)               as sales_3,
    max(list.amount_30)             as amount_30,
    max(list.amount_14)             as amount_14,
    max(list.amount_7)              as amount_7,
    max(list.amount_3)              as amount_3,
    max(list.pprofit_30)            as pprofit_30,
    max(list.pprofit_14)            as pprofit_14,
    max(list.pprofit_7)             as pprofit_7,
    max(list.pprofit_3)             as pprofit_3,
    max(list.pprofit_ratio_30)      as pprofit_ratio_30,
    max(list.pprofit_ratio_14)      as pprofit_ratio_14,
    max(list.pprofit_ratio_7)       as pprofit_ratio_7,
    max(list.pprofit_ratio_3)       as pprofit_ratio_3
from opt_db.tmp_prod_perf_sku_asin_metrics as list
group by list.country_category,
         list.seller_name_new,
         list.seller_sku_adj;

alter table opt_db.tmp_prod_perf_sku_metrics
    add index idx_tmp_prod_perf_sku_metrics (country_category(3), seller_name_new(64), seller_sku_adj(64));

-- ========================================
-- 5. 创建临时表：原始品牌店铺销量
-- ========================================
DROP TEMPORARY TABLE IF EXISTS opt_db.tmp_origin_sales_all;
CREATE TEMPORARY TABLE opt_db.tmp_origin_sales_all (
                                                       asin VARCHAR(50),
                                                       self_store_name VARCHAR(100),
                                                       sales_3 DECIMAL(12,2),
                                                       sales_7 DECIMAL(12,2),
                                                       sales_14 DECIMAL(12,2),
                                                       sales_30 DECIMAL(12,2),
                                                       INDEX (asin, self_store_name),  -- 复合主键
                                                       INDEX idx_asin (asin),
                                                       INDEX idx_self_store (self_store_name)
) ENGINE=InnoDB
AS
SELECT
    target.asin,
    target.self_store_name,
    max(metrics.sales_3)  as sales_3,
    max(metrics.sales_7)  as sales_7,
    max(metrics.sales_14) as sales_14,
    max(metrics.sales_30) as sales_30
FROM opt_db.tmp_asin_to_self_store target
         LEFT JOIN opt_db.tmp_prod_perf_sku_asin_metrics origin
                   ON origin.asin = target.asin
                       AND origin.seller_name_new = target.self_store_name
         LEFT JOIN opt_db.tmp_prod_perf_sku_metrics metrics
                   ON origin.country_category = metrics.country_category
                       AND origin.seller_name_new = metrics.seller_name_new
                       AND origin.seller_sku_adj = metrics.seller_sku_adj
GROUP BY target.asin,
         target.self_store_name;

-- ========================================
-- 6. 创建临时表：SKU级跟卖标记和原始品牌店铺销量
-- ========================================
DROP TEMPORARY TABLE IF EXISTS opt_db.tmp_prod_perf_follow_origin;
CREATE TEMPORARY TABLE opt_db.tmp_prod_perf_follow_origin AS
select
    bridge.country_category,
    bridge.seller_name_new,
    bridge.seller_sku_adj,
    max(case when self_asin.asin is not null then 1 else 0 end) as fllow_flag,
    max(case when self_asin.asin is null then origin.sales_3 else null end)  as origin_sales_3d,
    max(case when self_asin.asin is null then origin.sales_7 else null end)  as origin_sales_7d,
    max(case when self_asin.asin is null then origin.sales_14 else null end) as origin_sales_14d,
    max(case when self_asin.asin is null then origin.sales_30 else null end) as origin_sales_30d
from opt_db.tmp_prod_perf_sku_asin_metrics as bridge
         left join opt_db.tmp_自有店铺品牌asin as self_asin
                   on bridge.seller_name_new = self_asin.店铺名
                       and bridge.asin = self_asin.asin
         left join opt_db.tmp_origin_sales_all as origin
                   on origin.asin = bridge.asin
                       and self_asin.asin is null
group by bridge.country_category,
         bridge.seller_name_new,
         bridge.seller_sku_adj;

alter table opt_db.tmp_prod_perf_follow_origin
    add index idx_tmp_prod_perf_follow_origin (country_category(3), seller_name_new(64), seller_sku_adj(64));


drop temporary table if exists opt_db.tmp_pur_plan_wd_current;
create temporary table opt_db.tmp_pur_plan_wd_current as
select new_old_product,
       country_category,
       seller_name_new,
       seller_sku_adj,
       principal,
       sales_team_1,
       max_sku,
       max_local_name,
       global_tags,
       max_brand_name,
       abcd_category,
       gp_margin_range,
       predict_abcd_category,
       pre_1m_predict_abcd_category,
       pre_1q_predict_abcd_category,
       max_cg_transport_costs,
       max_cg_price,
       max_cg_box_pcs,
       max_receiving_time,
       receiving_cnt,
       stockout_status
from dws_datasync.ops_weekly_rpt_prod_perf_data_2026
where year_week = yearweek(date_sub(curdate(), interval 1 week), 1)
  and seller_name_new not in ('gushili', 'Joochees','ouhao', 'pingter');

alter table opt_db.tmp_pur_plan_wd_current
    add index idx_tmp_pur_plan_wd_current (country_category(3), seller_name_new(64), seller_sku_adj(64));

drop temporary table if exists opt_db.tmp_pur_plan_fba_current;
create temporary table opt_db.tmp_pur_plan_fba_current as
select country_category,
       seller_name_new,
       seller_sku_adj,
       available_total,
       stock_up_num
from etl_datasync.ops_weekly_rpt_fba_inv_detail_basic_data
where dt_week = yearweek(date_sub(curdate(), interval 0 week), 1);

alter table opt_db.tmp_pur_plan_fba_current
    add index idx_tmp_pur_plan_fba_current (country_category(3), seller_name_new(64), seller_sku_adj(64));

drop temporary table if exists opt_db.tmp_pur_plan_replenish_sug_current;
create temporary table opt_db.tmp_pur_plan_replenish_sug_current as
select country_category,
       seller_name_new,
       seller_sku_adj,
       local_quantity,
       sc_quantity_purchase_plan
from etl_datasync.ops_weekly_rpt_replenish_sug_basic_data
where dt_week = yearweek(date_sub(curdate(), interval 0 week), 1);

alter table opt_db.tmp_pur_plan_replenish_sug_current
    add index idx_tmp_pur_plan_replenish_sug_current (country_category(3), seller_name_new(64), seller_sku_adj(64));

drop temporary table if exists opt_db.tmp_pur_plan_salable_days_current;
create temporary table opt_db.tmp_pur_plan_salable_days_current as
select country_category,
       seller_name_new,
       seller_sku_adj,
       r_90d_salable_days,
       r_30d_salable_days,
       r_14d_salable_days,
       r_7d_salable_days,
       r_3d_salable_days
from etl_datasync.pur_plan_prod_perf_salable_days_stat
where sta_dt = curdate() - 1;

alter table opt_db.tmp_pur_plan_salable_days_current
    add index idx_tmp_pur_plan_salable_days_current (country_category(3), seller_name_new(64), seller_sku_adj(64));

drop temporary table if exists opt_db.tmp_pur_plan_pre_daily_sales;
create temporary table opt_db.tmp_pur_plan_pre_daily_sales as
select spb.country_category,
       spb.seller_name_new,
       spb.seller_sku_adj,
       spb.sales_90 as sales_90d,
       case
           when ks.r_30d_salable_days >= 7
               then case
                        when ks.r_3d_salable_days > 0
                            then coalesce(spb.sales_3, 0) / ks.r_3d_salable_days
                        else 0 end
           else coalesce(spb.sales_3, 0) / greatest(coalesce(ks.r_3d_salable_days, 0), 2)
           end as adjusted_daily_sales_3d,
       case
           when ks.r_30d_salable_days >= 7
               then case
                        when ks.r_7d_salable_days >= 7
                            then coalesce(spb.sales_7, 0) / ks.r_7d_salable_days
                        else least(
                                case
                                    when ks.r_7d_salable_days > 0
                                        then coalesce(spb.sales_7, 0) / ks.r_7d_salable_days
                                    else 0 end,
                                (case
                                     when ks.r_7d_salable_days > 0
                                         then coalesce(spb.sales_7, 0) / ks.r_7d_salable_days
                                     else 0 end) *
                                (ks.r_7d_salable_days / (ks.r_7d_salable_days + 3)) +
                                (coalesce(spb.sales_30, 0) / ks.r_30d_salable_days) *
                                (1 - ks.r_7d_salable_days / (ks.r_7d_salable_days + 3))
                             )
               end
           else coalesce(spb.sales_7, 0) / greatest(coalesce(ks.r_7d_salable_days, 0), 3)
           end as adjusted_daily_sales_7d,
       case
           when ks.r_30d_salable_days >= 7
               then case
                        when ks.r_14d_salable_days >= 14
                            then coalesce(spb.sales_14, 0) / ks.r_14d_salable_days
                        else least(
                                case
                                    when ks.r_14d_salable_days > 0
                                        then coalesce(spb.sales_14, 0) / ks.r_14d_salable_days
                                    else 0 end,
                                (case
                                     when ks.r_14d_salable_days > 0
                                         then coalesce(spb.sales_14, 0) / ks.r_14d_salable_days
                                     else 0 end) *
                                (ks.r_14d_salable_days / (ks.r_14d_salable_days + 7)) +
                                (coalesce(spb.sales_30, 0) / ks.r_30d_salable_days) *
                                (1 - ks.r_14d_salable_days / (ks.r_14d_salable_days + 7))
                             )
               end
           else coalesce(spb.sales_14, 0) / greatest(coalesce(ks.r_14d_salable_days, 0), 7)
           end as adjusted_daily_sales_14d,
       case
           when ks.r_30d_salable_days >= 7
               then coalesce(spb.sales_30, 0) / ks.r_30d_salable_days
           else coalesce(spb.sales_30, 0) / greatest(coalesce(ks.r_30d_salable_days, 0), 15)
           end as adjusted_daily_sales_30d
from opt_db.tmp_prod_perf_sku_metrics as spb
         left join opt_db.tmp_pur_plan_salable_days_current as ks
                   on spb.country_category = ks.country_category
                       and spb.seller_name_new = ks.seller_name_new
                       and spb.seller_sku_adj = ks.seller_sku_adj;

alter table opt_db.tmp_pur_plan_pre_daily_sales
    add index idx_tmp_pur_plan_pre_daily_sales (country_category(3), seller_name_new(64), seller_sku_adj(64));

drop temporary table if exists opt_db.tmp_pur_plan_replenish_candidates;
create temporary table opt_db.tmp_pur_plan_replenish_candidates as
select *
from (select pre_calc.*,
             case
                 when pre_calc.pre_normal_replenish_need_qty < pre_calc.pre_replenish_trigger_qty
                     and pre_calc.pre_r_30d_salable_days < 15
                     and pre_calc.hist_90d_instock_days >= 15
                     and pre_calc.hist_90d_instock_daily_sales > 1.5
                     and pre_calc.history_recovery_need_qty >= pre_calc.pre_replenish_trigger_qty
                     then 1
                 else 0
                 end as history_recovery_flag
      from (select pre_base.*,
                   pre_replenish_comp_months * 30 * coalesce(pre_daily_avg_sales, 0)
                       - pre_available_total
                       - pre_stock_up_num
                       - pre_local_quantity
                       - pre_sc_quantity_purchase_plan as pre_normal_replenish_need_qty,
                   hist_90d_instock_daily_sales * 120
                       - pre_available_total
                       - pre_stock_up_num
                       - pre_local_quantity
                       - pre_sc_quantity_purchase_plan as history_recovery_need_qty
            from (select wd.*,
                         case
                             when wd.country_category in ('英国站', '欧洲站') then 4
                             when wd.country_category = '北美站' then 4
                             end                                    as pre_replenish_comp_months,
                         case
                             when (wd.max_brand_name like '%2025%' and (wd.receiving_cnt <= 1 or wd.receiving_cnt is null))
                                 or (wd.max_brand_name like '%2026%' and (wd.receiving_cnt <= 1 or wd.receiving_cnt is null))
                                 then coalesce(pds.adjusted_daily_sales_3d, 0) * 0.5 +
                                      coalesce(pds.adjusted_daily_sales_7d, 0) * 0.5
                             else coalesce(pds.adjusted_daily_sales_7d, 0) * 0.6 +
                                  coalesce(pds.adjusted_daily_sales_14d, 0) * 0.2 +
                                  coalesce(pds.adjusted_daily_sales_30d, 0) * 0.2
                             end                                    as pre_daily_avg_sales,
                         coalesce(fbad.available_total, 0)          as pre_available_total,
                         coalesce(fbad.stock_up_num, 0)             as pre_stock_up_num,
                         coalesce(bsd.local_quantity, 0)            as pre_local_quantity,
                         coalesce(bsd.sc_quantity_purchase_plan, 0) as pre_sc_quantity_purchase_plan,
                         coalesce(ks.r_30d_salable_days, 0)         as pre_r_30d_salable_days,
                         coalesce(ks.r_90d_salable_days, 0)         as hist_90d_instock_days,
                         coalesce(pds.sales_90d, 0)                 as hist_90d_instock_sales,
                         case
                             when coalesce(ks.r_90d_salable_days, 0) > 0
                                 then coalesce(pds.sales_90d, 0) / ks.r_90d_salable_days
                             else 0
                             end                                    as hist_90d_instock_daily_sales,
                         case
                             when coalesce(wd.max_cg_box_pcs, 0) > 0 then wd.max_cg_box_pcs
                             else 50
                             end                                    as pre_replenish_trigger_qty
                  from opt_db.tmp_pur_plan_wd_current as wd
                           left join opt_db.tmp_pur_plan_fba_current as fbad
                                     on wd.country_category = fbad.country_category
                                         and wd.seller_name_new = fbad.seller_name_new
                                         and wd.seller_sku_adj = fbad.seller_sku_adj
                           left join opt_db.tmp_pur_plan_replenish_sug_current as bsd
                                     on wd.country_category = bsd.country_category
                                         and wd.seller_name_new = bsd.seller_name_new
                                         and wd.seller_sku_adj = bsd.seller_sku_adj
                           left join opt_db.tmp_pur_plan_salable_days_current as ks
                                     on wd.country_category = ks.country_category
                                         and wd.seller_name_new = ks.seller_name_new
                                         and wd.seller_sku_adj = ks.seller_sku_adj
                           left join opt_db.tmp_pur_plan_pre_daily_sales as pds
                                     on wd.country_category = pds.country_category
                                         and wd.seller_name_new = pds.seller_name_new
                                         and wd.seller_sku_adj = pds.seller_sku_adj) as pre_base) as pre_calc) as pre
where pre_normal_replenish_need_qty >= pre_replenish_trigger_qty
   or history_recovery_flag = 1;

alter table opt_db.tmp_pur_plan_replenish_candidates
    add index idx_tmp_replenish_candidates (country_category(3), seller_name_new(64), seller_sku_adj(64));

drop temporary table if exists opt_db.tmp_pur_plan_replenish_candidates_profit;
create temporary table opt_db.tmp_pur_plan_replenish_candidates_profit as
select *
from opt_db.tmp_pur_plan_replenish_candidates;

alter table opt_db.tmp_pur_plan_replenish_candidates_profit
    add index idx_tmp_replenish_candidates_profit (country_category(3), seller_name_new(64), seller_sku_adj(64));

drop temporary table if exists opt_db.tmp_pur_plan_replenish_candidates_hist_2024;
create temporary table opt_db.tmp_pur_plan_replenish_candidates_hist_2024 as
select *
from opt_db.tmp_pur_plan_replenish_candidates;

alter table opt_db.tmp_pur_plan_replenish_candidates_hist_2024
    add index idx_tmp_replenish_candidates_hist_2024 (country_category(3), seller_name_new(64), seller_sku_adj(64));

drop temporary table if exists opt_db.tmp_pur_plan_replenish_candidates_hist_2025;
create temporary table opt_db.tmp_pur_plan_replenish_candidates_hist_2025 as
select *
from opt_db.tmp_pur_plan_replenish_candidates;

alter table opt_db.tmp_pur_plan_replenish_candidates_hist_2025
    add index idx_tmp_replenish_candidates_hist_2025 (country_category(3), seller_name_new(64), seller_sku_adj(64));

drop temporary table if exists opt_db.tmp_pur_plan_hist_daily;
create temporary table opt_db.tmp_pur_plan_hist_daily as
select start_date,
       country_category,
       seller_name_new,
       seller_sku_adj,
       sum(day_volume)               as day_volume,
       max(afn_fulfillable_quantity) as afn_fulfillable_quantity
from (select t.start_date,
             t.country_category,
             t.seller_name_new,
             t.seller_sku_adj,
             sum(coalesce(t.volume, 0))                   as day_volume,
             max(coalesce(t.afn_fulfillable_quantity, 0)) as afn_fulfillable_quantity
      from etl_datasync.etl_dispose_lx_statistics_product_performance_2024 as t
               join opt_db.tmp_pur_plan_replenish_candidates_hist_2024 as c
                    on t.country_category = c.country_category
                        and t.seller_name_new = c.seller_name_new
                        and t.seller_sku_adj = c.seller_sku_adj
      where date_sub(date_sub(curdate(), interval 1 year), interval 90 day) <= '2024-12-31'
        and date_add(date_sub(curdate(), interval 1 year), interval 90 day) >= '2024-01-01'
        and t.start_date >= date_sub(date_sub(curdate(), interval 1 year), interval 90 day)
        and t.start_date <= date_add(date_sub(curdate(), interval 1 year), interval 90 day)
      group by t.start_date,
               t.country_category,
               t.seller_name_new,
               t.seller_sku_adj
      union all
      select t.start_date,
             t.country_category,
             t.seller_name_new,
             t.seller_sku_adj,
             sum(coalesce(t.volume, 0))                   as day_volume,
             max(coalesce(t.afn_fulfillable_quantity, 0)) as afn_fulfillable_quantity
      from etl_datasync.etl_dispose_lx_statistics_product_performance_2025 as t
               join opt_db.tmp_pur_plan_replenish_candidates_hist_2025 as c
                    on t.country_category = c.country_category
                        and t.seller_name_new = c.seller_name_new
                        and t.seller_sku_adj = c.seller_sku_adj
      where date_sub(date_sub(curdate(), interval 1 year), interval 90 day) <= '2025-12-31'
        and date_add(date_sub(curdate(), interval 1 year), interval 90 day) >= '2025-01-01'
        and t.start_date >= date_sub(date_sub(curdate(), interval 1 year), interval 90 day)
        and t.start_date <= date_add(date_sub(curdate(), interval 1 year), interval 90 day)
      group by t.start_date,
               t.country_category,
               t.seller_name_new,
               t.seller_sku_adj) as hist
group by start_date,
         country_category,
         seller_name_new,
         seller_sku_adj;

alter table opt_db.tmp_pur_plan_hist_daily
    add index idx_tmp_hist_daily (country_category(3), seller_name_new(64), seller_sku_adj(64), start_date);

drop temporary table if exists opt_db.tmp_pur_plan_hist_daily_future;
create temporary table opt_db.tmp_pur_plan_hist_daily_future as
select *
from opt_db.tmp_pur_plan_hist_daily;

alter table opt_db.tmp_pur_plan_hist_daily_future
    add index idx_tmp_hist_daily_future (country_category(3), seller_name_new(64), seller_sku_adj(64), start_date);

drop temporary table if exists opt_db.tmp_pur_plan_hist_daily_prev;
create temporary table opt_db.tmp_pur_plan_hist_daily_prev as
select *
from opt_db.tmp_pur_plan_hist_daily;

alter table opt_db.tmp_pur_plan_hist_daily_prev
    add index idx_tmp_hist_daily_prev (country_category(3), seller_name_new(64), seller_sku_adj(64), start_date);

-- 清理临时表
drop temporary table if exists opt_db.tmp_lx_orders_profit_rate_base;
drop temporary table if exists opt_db.tmp_lx_orders_selected_country;
drop temporary table if exists opt_db.tmp_lx_orders_profit_rate_result;


-- 基础订单临时表：最近 90 天
create temporary table opt_db.tmp_lx_orders_profit_rate_base as
select
    create_time,
    country,
    amazon_order_id,
    cast(
            case
                when locate('-', seller_name) > 0
                    then left(seller_name, locate('-', seller_name) - 1)
                else seller_name
                end as char(100)
    ) as seller_name_new,

    cast(
            if(
                    length(substring_index(seller_sku, ',', 1)) > 16,
                    replace(
                            substring_index(substring_index(seller_sku, ',', 1), '-', 1),
                            'amzn.gr.',
                            ''
                    ),
                    substring_index(seller_sku, ',', 1)
            ) as char(100)
    ) as seller_sku_adj,

    cast(
            case
                when country = '英国' then '英国站'
                when country in ('美国', '加拿大', '巴西', '墨西哥') then '北美站'
                else '欧洲站'
                end as char(20)
    ) as country_category,

    sales_price_amount,
    profit
from dwd_datasync.lx_sales_mws_orders_detail
where create_time >= date_sub(current_date(), interval 90 day)
;
create index idx_tmp_base_dim_country_time
    on opt_db.tmp_lx_orders_profit_rate_base
        (
         seller_name_new,
         seller_sku_adj,
         country_category,
         country,
         create_time
            );
-- 选出每个 seller_name_new + seller_sku_adj + country_category 下的最佳 country
create temporary table opt_db.tmp_lx_orders_selected_country as
select
    seller_name_new,
    seller_sku_adj,
    country_category,
    country as best_country
from (
         select
             t.*,
             row_number() over (
                 partition by seller_name_new, seller_sku_adj, country_category
                 order by profit_rate_5 desc, sales_price_amount_5 desc, profit_5 desc, country
                 ) as country_rank
         from (
                  select
                      seller_name_new,
                      seller_sku_adj,
                      country_category,
                      country,
                      count(*) as order_cnt_5,
                      sum(sales_price_amount) as sales_price_amount_5,
                      sum(profit) as profit_5,
                      sum(profit) / sum(sales_price_amount) as profit_rate_5
                  from (
                           select
                               b.*,
                               row_number() over (
                                   partition by seller_name_new, seller_sku_adj, country_category, country
                                   order by create_time desc, amazon_order_id desc
                                   ) as rn_5
                           from opt_db.tmp_lx_orders_profit_rate_base b
                       ) r
                  where rn_5 <= 5
                  group by
                      seller_name_new,
                      seller_sku_adj,
                      country_category,
                      country
                  having count(*) = 5
                     and sum(sales_price_amount) <> 0
              ) t
     ) x
where country_rank = 1
;
create index idx_tmp_selected_country
    on opt_db.tmp_lx_orders_selected_country
        (
         seller_name_new,
         seller_sku_adj,
         country_category,
         best_country
            );
-- 最终结果表：最佳 country 最近最多 20 单的汇总毛利率
create temporary table opt_db.tmp_lx_orders_profit_rate_result as
select
    seller_name_new,
    seller_sku_adj,
    country_category,
    best_country,
    count(*) as order_cnt_20,
    round(sum(profit) / sum(sales_price_amount), 2) as final_profit_rate
from (
         select
             b.*,
             sc.best_country,
             row_number() over (
                 partition by b.seller_name_new, b.seller_sku_adj, b.country_category
                 order by b.create_time desc, b.amazon_order_id desc
                 ) as rn_20
         from opt_db.tmp_lx_orders_profit_rate_base b
                  inner join opt_db.tmp_lx_orders_selected_country sc
                             on b.seller_name_new = sc.seller_name_new
                                 and b.seller_sku_adj = sc.seller_sku_adj
                                 and b.country_category = sc.country_category
                                 and b.country = sc.best_country
     ) t
where rn_20 <= 20
group by
    seller_name_new,
    seller_sku_adj,
    country_category,
    best_country
having sum(sales_price_amount) <> 0;
# drop table if exists app_datasync.app_pur_plan_replenish_data;
# create table app_datasync.app_pur_plan_replenish_data
# insert into app_datasync.app_pur_plan_replenish_data
with listing数据 as (select new_old_product,
                            seller_sku,
                            max_fnsku,
                            max_asin,
                            max_sku,
                            group_concat(distinct concat(marketplace, ':', status) separator ',') as marketplace_status,
                            group_concat(distinct seller_name separator ',')                      as seller_name_concat,
                            onsale_sites,
                            unsale_sites,
                            sales_status,
                            '汇总'                                                                as marketplace_concat,
                            case
                                when country_category = '北美站' then concat(seller_name_ue, '-US')
                                when country_category = '英国站' then concat(seller_name_ue, '-UK')
                                else concat(seller_name_ue, '-DE')
                                end                                                               as seller_name_copy,
                            seller_name_ue,
                            seller_name_new,
                            country_category,
                            principal,
                            sales_team_1
                     from etl_datasync.ops_rpt_listing_prod_basic_data
                     group by new_old_product, seller_sku, max_fnsku, max_asin, max_sku, onsale_sites, unsale_sites,
                              sales_status, marketplace_concat,
                              seller_name_copy, seller_name_ue, seller_name_new, country_category, principal,
                              sales_team_1),
     fba库存数 as (select *
                   from etl_datasync.ops_weekly_rpt_fba_inv_detail_basic_data
                   where dt_week = yearweek(date_sub(curdate(), interval 0 week), 1)),
     补货建议数据 as (select *
                      from etl_datasync.ops_weekly_rpt_replenish_sug_basic_data
                      where dt_week = yearweek(date_sub(curdate(), interval 0 week), 1)),
     可售天数统计 as (select *
                      from etl_datasync.pur_plan_prod_perf_salable_days_stat
                      where sta_dt = curdate()-1),
     分段产品表现 as (select list.country_category,
                             list.seller_name_new,
                             list.seller_sku_adj,
                             list.sales_90         as sales_90d,
                             list.sales_30         as sales_30d,
                             list.sales_14         as sales_14d,
                             list.sales_7          as sales_7d,
                             list.sales_3          as sales_3d,
                             list.amount_30        as amount_30d,
                             list.amount_14        as amount_14d,
                             list.amount_7         as amount_7d,
                             list.amount_3         as amount_3d,
                             list.pprofit_30       as pprofit_30d,
                             list.pprofit_14       as pprofit_14d,
                             list.pprofit_7        as pprofit_7d,
                             list.pprofit_3        as pprofit_3d,
                             list.pprofit_ratio_30 as pprofit_ratio_30d,
                             list.pprofit_ratio_14 as pprofit_ratio_14d,
                             list.pprofit_ratio_7  as pprofit_ratio_7d,
                             list.pprofit_ratio_3  as pprofit_ratio_3d,
                             coalesce(follow_origin.fllow_flag, 0) as fllow_flag,
                             follow_origin.origin_sales_3d,
                             follow_origin.origin_sales_7d,
                             follow_origin.origin_sales_14d,
                             follow_origin.origin_sales_30d
                      from opt_db.tmp_prod_perf_sku_metrics list
                               left join opt_db.tmp_prod_perf_follow_origin as follow_origin
                                         on list.country_category = follow_origin.country_category
                                             and list.seller_name_new = follow_origin.seller_name_new
                                             and list.seller_sku_adj = follow_origin.seller_sku_adj),
     分段结算利润 as (select distinct sps.cur_date,
                                      sps.country_category,
                                      sps.seller_name_new,
                                      sps.seller_sku_adj,
                                      sps.amount_30        as gamount_30d,
                                      sps.amount_14        as gamount_14d,
                                      sps.amount_7         as gamount_7d,
                                      sps.amount_3         as gamount_3d,
                                      sps.gprofit_30       as gprofit_30d,
                                      sps.gprofit_14       as gprofit_14d,
                                      sps.gprofit_7        as gprofit_7d,
                                      sps.gprofit_3        as gprofit_3d,
                                      sps.gprofit_ratio_30 as gprofit_ratio_30d,
                                      sps.gprofit_ratio_14 as gprofit_ratio_14d,
                                      sps.gprofit_ratio_7  as gprofit_ratio_7d,
                                      sps.gprofit_ratio_3  as gprofit_ratio_3d
                      from etl_datasync.ops_weekly_rpt_settlement_profit_interim as sps
                               join opt_db.tmp_pur_plan_replenish_candidates_profit as c
                                    on sps.country_category = c.country_category
                                        and sps.seller_name_new = c.seller_name_new
                                        and sps.seller_sku_adj = c.seller_sku_adj),
     原始订单毛利率 as (select *
                        from opt_db.tmp_lx_orders_profit_rate_result),
     params as (select curdate() as stat_date,
                       90        as window_days,
                       45        as min_valid_instock_days),
     date_range as (select date_sub(stat_date, interval 1 year)                                     as last_year_stat_date,
                           date_sub(date_sub(stat_date, interval 1 year), interval window_days day) as prev_start_date,
                           date_add(date_sub(stat_date, interval 1 year), interval window_days day) as future_end_date,
                           min_valid_instock_days
                    from params),
     -- 后窗口：统计有货天数N，以及后窗口“有货日销量”
     future_stat as (select h.country_category,
                            h.seller_name_new,
                            h.seller_sku_adj,
                            sum(case when h.afn_fulfillable_quantity <> 0 then 1 else 0 end)            as future_instock_days,
                            sum(case when h.afn_fulfillable_quantity <> 0 then h.day_volume else 0 end) as future_instock_sales
                     from opt_db.tmp_pur_plan_hist_daily_future h
                              join date_range d
                                   on h.start_date >= d.last_year_stat_date
                                       and h.start_date <= d.future_end_date
                     group by h.country_category,
                              h.seller_name_new,
                              h.seller_sku_adj),
     -- 前窗口：固定窗口为90天
     prev_stat as (select h.country_category,
                          h.seller_name_new,
                          h.seller_sku_adj,
                          sum(case when h.afn_fulfillable_quantity <> 0 then 1 else 0 end)            as prev_instock_days,
                          sum(case when h.afn_fulfillable_quantity <> 0 then h.day_volume else 0 end) as prev_matched_sales
                   from opt_db.tmp_pur_plan_hist_daily_prev h
                            join date_range d
                                 on h.start_date >= d.prev_start_date
                                     and h.start_date <= d.last_year_stat_date
                   group by h.country_category,
                            h.seller_name_new,
                            h.seller_sku_adj),
     ratio_base as (select f.country_category,
                           f.seller_name_new,
                           f.seller_sku_adj,
                           f.future_instock_days,
                           f.future_instock_sales,
                           p.prev_instock_days,
                           p.prev_matched_sales,
                           case
                               when f.future_instock_days = 0 then null
                               when f.future_instock_days < (select window_days from params)
                                   then f.future_instock_sales / f.future_instock_days *
                                        (select window_days from params)
                               else f.future_instock_sales
                               end as future_instock_sales_adj,

                           case
                               when p.prev_instock_days = 0 then null
                               when p.prev_instock_days < (select window_days from params)
                                   then p.prev_matched_sales / p.prev_instock_days * (select window_days from params)
                               else p.prev_matched_sales
                               end as prev_matched_sales_adj
                    from future_stat f
                             left join prev_stat p
                                       on f.country_category = p.country_category
                                           and f.seller_name_new = p.seller_name_new
                                           and f.seller_sku_adj = p.seller_sku_adj),
     环比比率 as (select *,
                         least(
                                 greatest(
                                         case
                                             when future_instock_days < (select min_valid_instock_days from date_range) then null
                                             when prev_instock_days < (select min_valid_instock_days from date_range) then null
                                             when prev_matched_sales_adj is null or prev_matched_sales_adj = 0 then null
                                             else ((future_instock_sales_adj - prev_matched_sales_adj)
                                                 / greatest(prev_matched_sales_adj, 30))
                                                 * least(prev_matched_sales_adj / 50.0, 1.0)
                                             end,
                                         -0.5),
                                 1.5) as sales_change_rate_adj
                  #                          case
#                              when future_instock_days < (select min_valid_instock_days from date_range) then null
#                              when prev_matched_sales_adj is null or prev_matched_sales_adj = 0 then null
#                              else (future_instock_sales_adj - prev_matched_sales_adj) / prev_matched_sales_adj
#                              end as sales_change_rate_adj
                  from ratio_base),
     联结 as (select wd.new_old_product,
                     wd.seller_sku_adj,
                     ld.max_fnsku,
                     ld.max_asin,
                     wd.max_sku,
                     ld.marketplace_status,
                     ld.seller_name_concat,
                     ld.onsale_sites,
                     ld.unsale_sites,
                     ld.sales_status,
                     ld.marketplace_concat,
                     ld.seller_name_copy,
                     ld.seller_name_ue,
                     ld.seller_name_new,
                     ld.country_category,
                     wd.max_local_name,
                     wd.max_brand_name,
                     ld.principal,
                     ld.sales_team_1,
                     wd.max_receiving_time,
                     wd.receiving_cnt,
                     wd.max_cg_box_pcs,
                     wd.max_cg_price,
                     wd.max_cg_transport_costs,
                     wd.stockout_status,
                     wd.pre_daily_avg_sales,
                     wd.pre_normal_replenish_need_qty,
                     wd.pre_replenish_trigger_qty,
                     wd.hist_90d_instock_days,
                     wd.hist_90d_instock_sales,
                     wd.hist_90d_instock_daily_sales,
                     wd.history_recovery_need_qty,
                     wd.history_recovery_flag,
                     wd.abcd_category,                                               -- 本周结算abcd分类
                     wd.gp_margin_range,                                             -- 本周结算毛利率区间
                     wd.predict_abcd_category,                                       -- 本周订单利润分类
                     wd.pre_1m_predict_abcd_category,                                -- 前1个月订单利润分类
                     wd.pre_1q_predict_abcd_category,-- 前1季度订单利润分类
                     coalesce(fbad.total + bsd.local_quantity, 0) as fba_local_quantity,
                     fbad.total,
                     fbad.available_total,
                     fbad.afn_fulfillable_quantity,
                     fbad.stock_up_num,
                     fbad.afn_unsellable_quantity,
                     bsd.sc_quantity_local_valid,
                     bsd.sc_quantity_purchase_shipping,
                     bsd.sc_quantity_purchase_plan,
                     bsd.sc_quantity_local_qc,
                     bsd.local_quantity,
                     gp.final_profit_rate,
                     ks.r_90d_salable_days,
                     ks.r_30d_salable_days,
                     ks.r_14d_salable_days,
                     ks.r_7d_salable_days,
                     ks.r_3d_salable_days,
                     spb.sales_90d,
                     -- 如果是自主产品，可以直接使用现销售额，  如果是跟卖产品，需要使用现销售额加原销售额
                     case    when spb.fllow_flag = 1 then spb.sales_30d
                             when spb.fllow_flag = 0 then coalesce(spb.sales_30d, 0) + coalesce(spb.origin_sales_30d, 0)
                         end as final_sales_30d,
                     case    when spb.fllow_flag = 1 then spb.sales_14d
                             when spb.fllow_flag = 0 then coalesce(spb.sales_14d, 0) + coalesce(spb.origin_sales_14d, 0)
                         end as final_sales_14d,
                     case    when spb.fllow_flag = 1 then spb.sales_7d
                             when spb.fllow_flag = 0 then coalesce(spb.sales_7d, 0) + coalesce(spb.origin_sales_7d, 0)
                         end as final_sales_7d,
                     case    when spb.fllow_flag = 1 then spb.sales_3d
                             when spb.fllow_flag = 0 then coalesce(spb.sales_3d, 0) + coalesce(spb.origin_sales_3d, 0)
                         end as final_sales_3d,
                     --

                     spb.fllow_flag,
                     spb.origin_sales_30d,
                     spb.origin_sales_14d,
                     spb.origin_sales_7d,
                     spb.origin_sales_3d,
                     spb.sales_30d,
                     spb.sales_14d,
                     spb.sales_7d,
                     spb.sales_3d,
                     spb.amount_30d,
                     spb.amount_14d,
                     spb.amount_7d,
                     spb.amount_3d,
                     spb.pprofit_30d,
                     spb.pprofit_14d,
                     spb.pprofit_7d,
                     spb.pprofit_3d,
                     spb.pprofit_ratio_30d,
                     spb.pprofit_ratio_14d,
                     spb.pprofit_ratio_7d,
                     spb.pprofit_ratio_3d,
                     sps.gamount_30d,
                     sps.gamount_14d,
                     sps.gamount_7d,
                     sps.gamount_3d,
                     sps.gprofit_30d,
                     sps.gprofit_14d,
                     sps.gprofit_7d,
                     sps.gprofit_3d,
                     sps.gprofit_ratio_30d,
                     sps.gprofit_ratio_14d,
                     sps.gprofit_ratio_7d,
                     sps.gprofit_ratio_3d,
                     hrb.sales_change_rate_adj,
                     -- 环比比率修正
                     case
                         when hrb.sales_change_rate_adj is null then 1
                         when 1 + hrb.sales_change_rate_adj < 0 then 1
                         else 1 + hrb.sales_change_rate_adj
                         end                                      as sales_adj_factor,
#                         case
#                          when hrb.sales_change_rate_used is null then 1
#                          when 1 + hrb.sales_change_rate_used < 0 then 1
#                          else 1 + hrb.sales_change_rate_used
#                          end                                      as sales_adj_factor_usd,
                     -- 判断对补货来说的是新品还是老品
                     case
                         when max_brand_name like '%2025%' and (wd.receiving_cnt <= 1 or wd.receiving_cnt is null)
                             then '2025新品'
                         when max_brand_name like '%2026%' and (wd.receiving_cnt <= 1 or wd.receiving_cnt is null)
                             then '2026新品'
                         else '老品'
                         end                                      as new_old_prod_jg -- 补货新老品判断

              from opt_db.tmp_pur_plan_replenish_candidates as wd
                       left join listing数据 as ld
                                 on wd.country_category = ld.country_category
                                     and wd.seller_name_new = ld.seller_name_new
                                     and wd.seller_sku_adj = ld.seller_sku
                       left join fba库存数 as fbad
                                 on wd.country_category = fbad.country_category
                                     and wd.seller_name_new = fbad.seller_name_new
                                     and wd.seller_sku_adj = fbad.seller_sku_adj
                       left join 补货建议数据 as bsd
                                 on wd.country_category = bsd.country_category
                                     and wd.seller_name_new = bsd.seller_name_new
                                     and wd.seller_sku_adj = bsd.seller_sku_adj
                       left join 可售天数统计 as ks
                                 on wd.country_category = ks.country_category
                                     and wd.seller_name_new = ks.seller_name_new
                                     and wd.seller_sku_adj = ks.seller_sku_adj
                       left join 分段产品表现 as spb
                                 on wd.country_category = spb.country_category
                                     and wd.seller_name_new = spb.seller_name_new
                                     and wd.seller_sku_adj = spb.seller_sku_adj
                       left join 分段结算利润 as sps
                                 on wd.country_category = sps.country_category
                                     and wd.seller_name_new = sps.seller_name_new
                                     and wd.seller_sku_adj = sps.seller_sku_adj
                       left join 环比比率 as hrb
                                 on wd.country_category = hrb.country_category
                                     and wd.seller_name_new = hrb.seller_name_new
                                     and wd.seller_sku_adj = hrb.seller_sku_adj
                       left join 原始订单毛利率 as gp
                                 on wd.country_category = gp.country_category
                                     and wd.seller_sku_adj = gp.seller_sku_adj
                                     and wd.seller_name_new = gp.seller_name_new
     ),
     日销修正明细 as (select *,
                             case
                                 when r_30d_salable_days >= 7
                                     then case
                                              when r_3d_salable_days > 0 then coalesce(final_sales_3d, 0) / r_3d_salable_days
                                              else 0 end
                                 else coalesce(final_sales_3d, 0) / greatest(coalesce(r_3d_salable_days, 0), 2)
                                 end as adjusted_daily_sales_3d,
                             case
                                 when r_30d_salable_days >= 7
                                     then case
                                              when r_7d_salable_days >= 7
                                                  then coalesce(final_sales_7d, 0) / r_7d_salable_days
                                              else least(
                                                      case
                                                          when r_7d_salable_days > 0 then coalesce(final_sales_7d, 0) / r_7d_salable_days
                                                          else 0 end,
                                                      (case
                                                           when r_7d_salable_days > 0 then coalesce(final_sales_7d, 0) / r_7d_salable_days
                                                           else 0 end) *
                                                      (r_7d_salable_days / (r_7d_salable_days + 3)) +
                                                      (coalesce(final_sales_30d, 0) / r_30d_salable_days) *
                                                      (1 - r_7d_salable_days / (r_7d_salable_days + 3))
                                                   )
                                     end
                                 else coalesce(final_sales_7d, 0) / greatest(coalesce(r_7d_salable_days, 0), 3)
                                 end as adjusted_daily_sales_7d,
                             case
                                 when r_30d_salable_days >= 7
                                     then case
                                              when r_14d_salable_days >= 14
                                                  then coalesce(final_sales_14d, 0) / r_14d_salable_days
                                              else least(
                                                      case
                                                          when r_14d_salable_days > 0 then coalesce(final_sales_14d, 0) / r_14d_salable_days
                                                          else 0 end,
                                                      (case
                                                           when r_14d_salable_days > 0 then coalesce(final_sales_14d, 0) / r_14d_salable_days
                                                           else 0 end) *
                                                      (r_14d_salable_days / (r_14d_salable_days + 7)) +
                                                      (coalesce(final_sales_30d, 0) / r_30d_salable_days) *
                                                      (1 - r_14d_salable_days / (r_14d_salable_days + 7))
                                                   )
                                     end
                                 else coalesce(final_sales_14d, 0) / greatest(coalesce(r_14d_salable_days, 0), 7)
                                 end as adjusted_daily_sales_14d,
                             case
                                 when r_30d_salable_days >= 7
                                     then coalesce(final_sales_30d, 0) / r_30d_salable_days
                                 else coalesce(final_sales_30d, 0) / greatest(coalesce(r_30d_salable_days, 0), 15)
                                 end as adjusted_daily_sales_30d
                      from 联结),
     日均销量计算 as (select distinct *,
                                      -- 日均销量计算逻辑说明
                                      -- 老品比例：7天销量40%，14天销量30%，30天销量30%；新品比例：3天销量50%，7天销量50%（20251027以前逻辑）
                                      -- 老品比例：7天销量60%，14天销量20%，30天销量20%；新品比例：3天销量20%，7天销量50%（20251027(含)以后逻辑）
                                      -- 老品比例：7天销量40%，14天销量30%，30天销量30%；新品比例：3天销量20%，7天销量50%（20251208(含)以后逻辑）
                                      -- 老品比例：7天销量60%，14天销量20%，30天销量20%；新品比例：3天销量50%，7天销量50%（20251208(含)以后逻辑）

                                      case
                                          when new_old_prod_jg in ('2025新品', '2026新品')
                                              then coalesce(adjusted_daily_sales_3d, 0) * 0.5 +
                                                   coalesce(adjusted_daily_sales_7d, 0) * 0.5
                                          when new_old_prod_jg = '老品'
                                              then coalesce(adjusted_daily_sales_7d, 0) * 0.6 +
                                                   coalesce(adjusted_daily_sales_14d, 0) * 0.2 +
                                                   coalesce(adjusted_daily_sales_30d, 0) * 0.2
                                          end as daily_avg_sales -- 日均销量计算
                      from 日销修正明细),
     补货月数 as (select *,
                         -- 20260104，调整补足月数，统一补足4个月
                         case
                             when country_category in ('英国站', '欧洲站') then 4
                             when country_category in ('英国站', '欧洲站') then 4
                             when country_category = '北美站' then 4
                             end as replenish_comp_months -- 补足月数
                  from 日均销量计算),
     补货数量计算 as (select *,
                             replenish_comp_months * 30 * coalesce(daily_avg_sales, 0)
                                 - coalesce(available_total, 0)
                                 - coalesce(local_quantity, 0)
                                 - coalesce(stock_up_num, 0)
                                 - coalesce(sc_quantity_purchase_plan, 0)                  as replenish_need_qty,
                             case
                                 when coalesce(max_cg_box_pcs, 0) > 0 then max_cg_box_pcs
                                 else 50
                                 end                                                       as replenish_trigger_qty,
                             case
                                 when daily_avg_sales = 0 or daily_avg_sales is null then null
                                 else fba_local_quantity / daily_avg_sales end                 as salable_days,                  -- 可售天数计算
                             60 * daily_avg_sales - fba_local_quantity                         as 60d_stocko_qty,                -- 60天缺货数量
                             90 * daily_avg_sales - fba_local_quantity                         as 90d_stocko_qty,                -- 90天缺货数量
                             180 * daily_avg_sales - fba_local_quantity                        as 180d_stocko_qty,               -- 180天缺货数量
                             (replenish_comp_months * 30 * coalesce(daily_avg_sales, 0) - coalesce(available_total, 0) - coalesce(local_quantity, 0) - coalesce(stock_up_num, 0)- coalesce(sc_quantity_purchase_plan, 0)) as replenish_dur_calc_stocko_qty, -- 按补货时长计算缺货数量
                             -- 添加环比比例结算逻辑
                             case
                                 when coalesce(history_recovery_flag, 0) = 1
                                     then case
                                              when coalesce(max_cg_box_pcs, 0) > 0 then max_cg_box_pcs
                                              else 50
                                     end
                                 when ((replenish_comp_months * 30 * coalesce(daily_avg_sales, 0) - coalesce(available_total, 0) - coalesce(local_quantity, 0) - coalesce(stock_up_num, 0) - coalesce(sc_quantity_purchase_plan, 0))) > 0 and
                                      max_cg_box_pcs > 0
                                     then
                                     round(((replenish_comp_months * 30 * coalesce(daily_avg_sales, 0) - coalesce(available_total, 0) - coalesce(local_quantity, 0) - coalesce(stock_up_num, 0) - coalesce(sc_quantity_purchase_plan, 0))) *
                                           (sales_adj_factor) /
                                           max_cg_box_pcs,
                                           0) * max_cg_box_pcs
                                 when ((replenish_comp_months * 30 * coalesce(daily_avg_sales, 0) - coalesce(available_total, 0) - coalesce(local_quantity, 0) - coalesce(stock_up_num, 0) - coalesce(sc_quantity_purchase_plan, 0))) > 0 and
                                      (max_cg_box_pcs = 0 or max_cg_box_pcs is null)
                                     then round(((replenish_comp_months * 30 * coalesce(daily_avg_sales, 0) - coalesce(available_total, 0) - coalesce(local_quantity, 0) - coalesce(stock_up_num, 0) - coalesce(sc_quantity_purchase_plan, 0))) *
                                                (sales_adj_factor), 0)
                                 else round(((replenish_comp_months * 30 * coalesce(daily_avg_sales, 0) - coalesce(available_total, 0) - coalesce(local_quantity, 0) - coalesce(stock_up_num, 0) - coalesce(sc_quantity_purchase_plan, 0))) *
                                            (sales_adj_factor), 0)
                                 end                                                           as replenish_qty, -- 补货数量计算
                             case
                                 when coalesce(history_recovery_flag, 0) = 1
                                     then case
                                              when coalesce(max_cg_box_pcs, 0) > 0 then 1
                                              else 0
                                     end
                                 when ((replenish_comp_months * 30 * coalesce(daily_avg_sales, 0) - coalesce(available_total, 0) - coalesce(local_quantity, 0) - coalesce(stock_up_num, 0) - coalesce(sc_quantity_purchase_plan, 0))) > 0 and
                                      max_cg_box_pcs > 0
                                     then
                                     round(((replenish_comp_months * 30 * coalesce(daily_avg_sales, 0) - coalesce(available_total, 0) - coalesce(stock_up_num, 0) - coalesce(local_quantity, 0) - coalesce(sc_quantity_purchase_plan, 0))) *
                                           (sales_adj_factor) /
                                           max_cg_box_pcs, 0)
                                 when ((replenish_comp_months * 30 * coalesce(daily_avg_sales, 0) - coalesce(available_total, 0)- coalesce(stock_up_num, 0) - coalesce(local_quantity, 0) - coalesce(sc_quantity_purchase_plan, 0))) > 0 and
                                      (max_cg_box_pcs = 0 or max_cg_box_pcs is null)
                                     then 0
                                 else null
                                 end                                                           as replenish_box_qty              -- 补货箱数计算
                      from 补货月数)
-- 最终查询
select curdate()                                               as cur_date,                       -- 当天时间
       new_old_product,
       seller_sku_adj,
       max_fnsku,
       max_asin,
       max_sku,
       marketplace_status,
       seller_name_concat,
       onsale_sites,
       unsale_sites,
       sales_status,
       marketplace_concat,
       seller_name_copy,
       seller_name_ue,
       seller_name_new,
       country_category,
       max_local_name,
       max_brand_name,
       principal,
       sales_team_1,
       max_receiving_time,
       receiving_cnt,
       max_cg_box_pcs,
       max_cg_price,
       max_cg_transport_costs,
       stockout_status,
       pre_daily_avg_sales,
       pre_normal_replenish_need_qty,
       pre_replenish_trigger_qty,
       hist_90d_instock_days,
       hist_90d_instock_sales,
       hist_90d_instock_daily_sales,
       history_recovery_need_qty,
       history_recovery_flag,
       abcd_category,
       gp_margin_range,
       predict_abcd_category,
       pre_1m_predict_abcd_category,
       pre_1q_predict_abcd_category,
       fba_local_quantity,
       total,
       available_total,
       afn_fulfillable_quantity,
       stock_up_num,
       afn_unsellable_quantity,
       sc_quantity_local_valid,
       sc_quantity_purchase_shipping,
       sc_quantity_purchase_plan,
       sc_quantity_local_qc,
       local_quantity,
       r_90d_salable_days,
       r_30d_salable_days,
       r_14d_salable_days,
       r_7d_salable_days,
       r_3d_salable_days,
       sales_90d,
       final_sales_30d,
       final_sales_14d,
       final_sales_7d,
       final_sales_3d,
       amount_30d,
       amount_14d,
       amount_7d,
       amount_3d,
       pprofit_30d,
       pprofit_14d,
       pprofit_7d,
       pprofit_3d,
       pprofit_ratio_30d,
       pprofit_ratio_14d,
       pprofit_ratio_7d,
       pprofit_ratio_3d,
       gamount_30d,
       gamount_14d,
       gamount_7d,
       gamount_3d,
       gprofit_30d,
       gprofit_14d,
       gprofit_7d,
       gprofit_3d,
       gprofit_ratio_30d,
       gprofit_ratio_14d,
       gprofit_ratio_7d,
       gprofit_ratio_3d,
       new_old_prod_jg,
       daily_avg_sales,
       replenish_comp_months,
       salable_days,
       `60d_stocko_qty`,
       `90d_stocko_qty`,
       `180d_stocko_qty`,
       replenish_dur_calc_stocko_qty,
       replenish_need_qty,
       replenish_trigger_qty,
       sales_change_rate_adj,
       sales_adj_factor,
       final_profit_rate,
       replenish_qty,
       replenish_box_qty,
       (max_cg_price + max_cg_transport_costs) * replenish_qty as replenish_cost,                 -- 补货货值计算
       case
           when sales_30d = 0 or sales_30d is null then null
           else available_total / sales_30d end                as amz_instock_sales_ratio,        -- 在亚马逊库销比
       case
           when sales_30d = 0 or sales_30d is null then null
           else fba_local_quantity / sales_30d end             as instock_intrans_pur_sales_ratio,-- 在库_在途_采购库销比
       fllow_flag,
       history_recovery_flag
from 补货数量计算
#where seller_sku_adj in ('YY040a', 'QP0102a', 'MYT1105a', 'MQ047b', 'JZL030a', 'DY-050d')
where (replenish_need_qty >= replenish_trigger_qty
    and replenish_qty >= 90)
   or coalesce(history_recovery_flag, 0) = 1;














