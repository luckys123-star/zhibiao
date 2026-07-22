
-- listing数据
drop table if exists etl_datasync.ops_rpt_listing_prod_basic_data;
create table if not exists etl_datasync.ops_rpt_listing_prod_basic_data
with listing_joined as (
    select sml.create_time,
           sml.seller_sku,
           sml.asin,
           sml.fnsku,
           sml.local_sku,
           sml.seller_name,
           sml.marketplace,
           sml.local_name,
           sml.status,
           sml.seller_brand,
           sml.global_tags,
           sml.review_num,
           sml.last_star,
           sml.currency_code,
           sml.first_order_time,
           sml.small_rank,
           sml.spu,
           sml.country_category,
           sml.seller_name_ue,
           sml.seller_name_new,
           sml.country_code,
           sml.org_currency_icon,
           sml.price,
           sml.principal,
           sml.sales_team_1,
           plpi.tag_name,
           plpi.brand_name,
           plpi.category_name,
           plpi.product_developer,
           plpi.cg_price,
           plpi.cg_box_pcs,
           plpi.cg_transport_costs
    from etl_datasync.etl_dispose_lx_sales_mws_listing as sml
    left join etl_datasync.etl_dispose_lx_product_local_product_info as plpi
      on sml.seller_sku = plpi.seller_sku
     and sml.marketplace = plpi.country
     and sml.seller_name_new = plpi.seller_name_new
     and sml.local_sku = plpi.local_sku
    where sml.seller_name_new not regexp 'baihuiyi|Yuanoboo|Bailboo|Qianytyy'
),
listing_aggregated as (
    -- 按业务键聚合，替代原来 20+ 个窗口函数；只算一次
    select country_category,
           seller_name_new,
           seller_sku,
           count(case when status = '在售' then 1 end) as onsale_sites,
           count(case when status = '停售' then 1 end) as unsale_sites,
           max(local_sku)   as max_sku,
           max(fnsku)       as max_fnsku,
           max(asin)        as max_asin,
           max(local_name)  as max_local_name,
           max(spu)         as max_spu,
           max(tag_name)    as max_tag_name,
           max(case
                   when tag_name = '2024 十月开发新品,emag平台产品'
                       then '2024 十月开发新品'
                   when tag_name = '2024 十一月开发新品,emag平台产品'
                       then '2024 十一月开发新品'
                   when tag_name = '2025 八月开发新品,2025 九月开发新品'
                       then '2025 八月开发新品'
                   else tag_name
               end)             as max_product_dev_time,
           max(brand_name)         as max_brand_name,
           max(category_name)      as max_category_name,
           max(product_developer)  as max_product_developer,
           max(cg_box_pcs)         as max_cg_box_pcs,
           max(cg_price)           as max_cg_price,
           max(cg_transport_costs) as max_cg_transport_costs
    from listing_joined
    group by country_category, seller_name_new, seller_sku
),
listing_产品基础数据 as (
    -- left join 聚合结果回原明细，保持原行数不变
    select distinct lj.*,
           la.onsale_sites,
           la.unsale_sites,
           la.max_sku,
           la.max_fnsku,
           la.max_asin,
           la.max_local_name,
           la.max_spu,
           la.max_tag_name,
           la.max_product_dev_time,
           la.max_brand_name,
           la.max_category_name,
           la.max_product_developer,
           la.max_cg_box_pcs,
           la.max_cg_price,
           la.max_cg_transport_costs
    from listing_joined as lj
    left join listing_aggregated as la
      on lj.country_category = la.country_category
     and lj.seller_name_new = la.seller_name_new
     and lj.seller_sku = la.seller_sku
),
汇率 as (
    select *
    from dwd_datasync.lx_basic_currency
    where date = date_format(curdate(), '%Y-%m')
)
select lpd.*,
       round(lpd.price * hl.rate_org, 2)                                             as price_cny,
       round(avg(lpd.price * hl.rate_org)
                 over (partition by country_category, seller_name_new, seller_sku), 2) as avg_price_cny,
       max(case
               when onsale_sites = 0 then '停售中'
               else '在售中' end)
           over (partition by country_category, seller_name_new, seller_sku)           as sales_status,
       max(case
               when max_product_dev_time regexp '2027|2026|2025|2024 十月|2024 十一月|2024 十二月'
                   then '新品'
               else '老品' end)
           over (partition by country_category, seller_name_new, seller_sku)           as new_old_product
from listing_产品基础数据 as lpd
left join 汇率 as hl on lpd.org_currency_icon = hl.name;


-- fab库存明细，优化，只取上周周末和当天的数据
drop table if exists etl_datasync.ops_weekly_rpt_fba_inv_detail_basic_data;
create table if not exists etl_datasync.ops_weekly_rpt_fba_inv_detail_basic_data
with inventory_value as (
    select distinct *
    from etl_datasync.etl_dispose_lx_storage_fba_warehouse_detail
    where (
        create_time >= date_sub(date_sub(curdate(), interval weekday(curdate()) day), interval 1 day)
        and create_time < date_sub(curdate(), interval weekday(curdate()) day)
    )
    or (
        create_time >= curdate()
        and create_time < date_add(curdate(), interval 1 day)
    )
),
month_end_data as (
    select year(iv.create_time)                                           as dt_year,
           month(iv.create_time)                                          as dt_month,
           yearweek(iv.create_time, 1)                                    as dt_week,
           date(iv.create_time)                                           as create_time,
           iv.country_category,
           iv.seller_sku_adj,
           iv.seller_name_new,
           sum(iv.total)                                                  as total,
           sum(iv.total_price)                                            as total_price,
           sum(iv.available_total)                                        as available_total,
           sum(iv.available_total_price)                                  as available_total_price,
           sum(iv.afn_fulfillable_quantity)                               as afn_fulfillable_quantity,
           sum(iv.afn_fulfillable_quantity_price)                         as afn_fulfillable_quantity_price,
           sum(iv.reserved_fc_transfers)                                  as reserved_fc_transfers,
           sum(iv.reserved_fc_transfers_price)                            as reserved_fc_transfers_price,
           sum(iv.reserved_fc_processing)                                 as reserved_fc_processing,
           sum(iv.reserved_fc_processing_price)                           as reserved_fc_processing_price,
           sum(iv.reserved_customerorders)                                as reserved_customerorders,
           sum(iv.reserved_customerorders_price)                          as reserved_customerorders_price,
           sum(iv.afn_unsellable_quantity)                                as afn_unsellable_quantity,
           sum(iv.afn_unsellable_quantity_price)                          as afn_unsellable_quantity_price,
           sum(iv.afn_inbound_receiving_quantity)                         as afn_inbound_receiving_quantity,
           sum(iv.afn_inbound_receiving_quantity_price)                   as afn_inbound_receiving_quantity_price,
           sum(iv.stock_up_num)                                           as stock_up_num,
           sum(iv.stock_up_num_price)                                     as stock_up_num_price,
           sum(iv.afn_researching_quantity)                               as afn_researching_quantity,
           sum(iv.afn_researching_quantity_price)                         as afn_researching_quantity_price,
           max(iv.cg_price)                                               as cg_price,
           max(iv.cg_transport_costs)                                     as cg_transport_costs,

           -- 库龄分段
           sum(iv.inv_age_0_to_30_days + iv.inv_age_31_to_60_days +
               iv.inv_age_61_to_90_days)                                  as inv_age_0_3_days,
           sum(iv.inv_age_0_to_30_price + iv.inv_age_31_to_60_price +
               iv.inv_age_61_to_90_price)                                 as inv_age_0_3_price,
           sum(iv.inv_age_91_to_180_days)                                 as inv_age_3_6_days,
           sum(iv.inv_age_91_to_180_price)                                as inv_age_3_6_price,
           sum(iv.inv_age_181_to_270_days)                                as inv_age_6_9_days,
           sum(iv.inv_age_181_to_270_price)                               as inv_age_6_9_price,
           sum(iv.inv_age_271_to_330_days + iv.inv_age_331_to_365_days)   as inv_age_9_12_days,
           sum(iv.inv_age_271_to_330_price + iv.inv_age_331_to_365_price) as inv_age_9_12_price,
           sum(iv.inv_age_365_plus_days)                                  as inv_age_over_12_days,
           sum(iv.inv_age_365_plus_price)                                 as inv_age_over_12_price,

           -- 低库龄数据（<=180天库龄）
           sum(iv.inv_age_0_to_30_days + iv.inv_age_31_to_60_days +
               iv.inv_age_61_to_90_days + iv.inv_age_91_to_180_days)      as lowerlibrary_ages_days,
           sum(iv.inv_age_0_to_30_price + iv.inv_age_31_to_60_price +
               iv.inv_age_61_to_90_price +
               iv.inv_age_91_to_180_price)                                as lowerlibrary_ages_price,

           -- 超库龄数据（>180天库龄）
           sum(iv.inv_age_181_to_270_days + iv.inv_age_271_to_330_days +
               iv.inv_age_331_to_365_days +
               iv.inv_age_365_plus_days)                                  as superlibrary_ages_days,
           sum(iv.inv_age_181_to_270_price + iv.inv_age_271_to_330_price +
               iv.inv_age_331_to_365_price +
               iv.inv_age_365_plus_price)                                 as superlibrary_ages_price,

           -- 超库龄数据（>90天库龄）
           sum(iv.inv_age_91_to_180_days + iv.inv_age_181_to_270_days +
               iv.inv_age_271_to_330_days +
               iv.inv_age_331_to_365_days +
               iv.inv_age_365_plus_days)                                  as over_inv90_days,
           sum(iv.inv_age_91_to_180_price + iv.inv_age_181_to_270_price +
               iv.inv_age_271_to_330_price +
               iv.inv_age_331_to_365_price +
               iv.inv_age_365_plus_price)                                 as over_inv90_price
    from inventory_value iv
    group by iv.create_time, iv.country_category, iv.seller_sku_adj, iv.seller_name_new
)
select *,
       superlibrary_ages_price /
       nullif((lowerlibrary_ages_price + superlibrary_ages_price), 0) as superlibrary_proportion
from month_end_data
order by create_time desc;


-- 补货建议数据，同fba库存明细
drop table if exists etl_datasync.ops_weekly_rpt_replenish_sug_basic_data;
create table etl_datasync.ops_weekly_rpt_replenish_sug_basic_data as
with replenishment_value as (
    select distinct *
    from etl_datasync.etl_dispose_lx_replenishment_suggest_restocking
    where (
        create_time >= date_sub(date_sub(curdate(), interval weekday(curdate()) day), interval 1 day)
        and create_time < date_sub(curdate(), interval weekday(curdate()) day)
        and
        create_time >= date_add(date_add(str_to_date(concat(dt_week, '1'), '%X%V%w'),
                                         interval -1 week), interval 6 day)
        and create_time < date_add(
            date_add(date_add(str_to_date(concat(dt_week, '1'), '%X%V%w'),
                              interval -1 week), interval 6 day),
            interval 1 day)
    )
    or (
        create_time >= curdate()
        and create_time < date_add(curdate(), interval 1 day)
    )
),
month_end_data as (
    select dt_year,
           yearweek(create_time, 1)           as dt_week,
           create_time,
           country_category,
           seller_sku_adj,
           seller_name_new,

           -- 月末补货数据快照
           max(sc_quantity_local_valid)       as sc_quantity_local_valid,
           max(sc_quantity_purchase_shipping) as sc_quantity_purchase_shipping,
           max(sc_quantity_purchase_plan)     as sc_quantity_purchase_plan,
           max(sc_quantity_local_qc)          as sc_quantity_local_qc,

           -- 库存周转相关
           (max(sc_quantity_local_valid) +
            max(sc_quantity_purchase_shipping) +
            max(sc_quantity_purchase_plan) +
            max(sc_quantity_local_qc))        as local_quantity

    from replenishment_value
    group by dt_year, dt_week, create_time, country_category, seller_sku_adj, seller_name_new
    order by dt_week desc
)
select *
from month_end_data;

drop table if exists etl_datasync.ops_rpt_fba_shipment_basic_data;
create table etl_datasync.ops_rpt_fba_shipment_basic_data as
select *,
       datediff(current_date, min_receiving_time) as days_since_launch,
       datediff(current_date, max_receiving_time) as days_latest_delivery,
       case
           when datediff(current_date, min_receiving_time) between 0 and 30 then '<=30天'
           when datediff(current_date, min_receiving_time) between 31 and 90 then '<=90天'
           when datediff(current_date, min_receiving_time) between 91 and 180 then '<=180'
           when datediff(current_date, min_receiving_time) > 180 then '>180天'
           end                                    as since_launch_range,
       case
           when datediff(current_date, max_receiving_time) between 0 and 7 then '0-7天'
           when datediff(current_date, max_receiving_time) between 8 and 14 then '8-14天'
           when datediff(current_date, max_receiving_time) between 15 and 30 then '15-30天'
           when datediff(current_date, max_receiving_time) >= 30 then '>=30天'
           end                                    as delivery_time_range
from (
    select msku,
           seller_name_new,
           country_category,
           min(str_to_date(receiving_time, '%Y-%m-%d %H:%i:%s')) as min_receiving_time,
           max(str_to_date(receiving_time, '%Y-%m-%d %H:%i:%s')) as max_receiving_time,
           max(receiving_cnt)                                    as receiving_cnt
    from (
        select f.country_category,
               f.store_name,
               f.seller_name_new,
               f.msku,
               f.country,
               case
                   when f.receiving_time = '' then null
                   else f.receiving_time
                   end as receiving_time,
               f.asin,
               f.parent_asin,
               f.fnsku,
               f.sku,
               f.shipment_id,
               f.quantity_shipped,
               f.quantity_received,
               r.receiving_cnt
        from etl_datasync.etl_dispose_lx_fba_shipment as f
        left join (
            select msku,
                   store_name,
                   count(*) as receiving_cnt
            from etl_datasync.etl_dispose_lx_fba_shipment
            where receiving_time is not null
              and quantity_shipped <> 0
            group by msku, store_name
        ) as r
          on f.msku = r.msku and f.store_name = r.store_name
        where f.receiving_time is not null
          and f.quantity_received <> 0
    ) as a
    group by msku, seller_name_new, country_category
) as b;



-- 发货货件处理
drop table if exists etl_datasync.ops_rpt_logi_est_days_data;
create table etl_datasync.ops_rpt_logi_est_days_data as
with 货件处理 as (select shipment_id,                              -- 货件单号
                         substring_index(seller, ' ', 1) as sname, -- 店铺
                         country,                                  -- 国家
                         msku,                                     -- MSKU
                         shipment_status                           -- 货件状态
                  from dwd_datasync.lx_fba_shipment
                  where shipment_status in ('WORKING', 'READY_TO_SHIP', 'SHIPPED', 'IN_TRANSIT')),
     发货单处理 as (select splb.shipment_id,           -- 货件单号
                           splb.sname,                 -- 店铺
                           splb.shipment_sn,           -- 发货单号
                           splb.msku,                  -- MSKU
                           spd.shipment_time,          -- 发货时间
                           spd.logistics_channel_name, -- 物流渠道
                           splb.remark,                -- 备注
                           splb.shipment_status        -- 货件状态
                    from dwd_datasync.lx_inbound_shipment_detail_ShangPinLieBiao as splb
                             left join dwd_datasync.lx_inbound_shipment_detail as spd
                                       on splb.shipment_sn = spd.shipment_sn
                    where splb.shipment_status in ('WORKING', 'READY_TO_SHIP', 'SHIPPED', 'IN_TRANSIT')),
     联结 as (select a.shipment_id,            -- 货件单号
                     a.sname,                  -- 店铺
                     a.country,                -- 国家
                     b.shipment_sn,            -- 发货单号
                     a.msku,
                     b.shipment_time,          -- 发货时间
                     b.logistics_channel_name, -- 物流渠道
                     b.remark,                 -- 货件备注
                     a.shipment_status,        -- 货件状态,
                     substring_index(a.sname, '-', 1)                         as seller_name_new,
                     case
                         when a.country = '英国' then '英国站'
                         when a.country in ('美国', '加拿大', '巴西', '墨西哥') then '北美站'
                         else '欧洲站'
                         end                                                  as country_category,
                     min(b.shipment_time) over (partition by a.sname, a.MSKU) as earliest_ship_time,
                     case
                         when logistics_channel_name regexp '空' then '空运'
                         when logistics_channel_name regexp '铁' then '铁路'
                         when logistics_channel_name regexp ('海|航|卡派') then '海运'
                         end                                                     channel_abbrev,
                     case
                         when logistics_channel_name regexp '空' then 15
                         when logistics_channel_name regexp '铁' then 45
                         when logistics_channel_name regexp ('海|航|卡派') then 60
                         end                                                     logistics_est_days
              from 货件处理 as a
                       left join 发货单处理 as b
                                 on a.shipment_id = b.shipment_id and a.msku = b.msku and a.sname = b.sname)
select distinct seller_name_new,    -- 店铺
                country_category,   -- 国家类别
                msku,
                shipment_time,      -- 货件发货时间
                earliest_ship_time, -- 最早发货时间
                channel_abbrev,     -- 渠道简写
                logistics_est_days  -- 物流预计天数
from 联结
where sname not regexp 'baihuiyi|Yuanoboo|Bailboo|Qianytyy|hongyuanEU'
  and earliest_ship_time = shipment_time
  and earliest_ship_time is not null
  and channel_abbrev is not null;



-- 订单处理 获取计算利润
drop table if exists etl_datasync.ops_weekly_rpt_settlement_profit_interim;
create table if not exists etl_datasync.ops_weekly_rpt_settlement_profit_interim
with 结算利润指标 as (
    select data_date,
           country_category,
           seller_name_new,
           seller_sku_adj,
           total_sales_amount,
           gross_profit,
           gross_profit_with_tax
    from etl_datasync.etl_dispose_lx_statistics_profit_statistics_msku
    where data_date >= date_sub(current_date, interval 90 day)
      and store_name not regexp 'baihuiyi|Yuanoboo|Bailboo|Qianytyy'
),
分段指标 as (
    select country_category,
           seller_name_new,
           seller_sku_adj,
           date(curdate())                                                               as cur_date,
           sum(case when data_date >= curdate() - interval 30 day then total_sales_amount end) as amount_30,
           sum(case when data_date >= curdate() - interval 14 day then total_sales_amount end) as amount_14,
           sum(case when data_date >= curdate() - interval 7 day  then total_sales_amount end) as amount_7,
           sum(case when data_date >= curdate() - interval 3 day  then total_sales_amount end) as amount_3,
           sum(case when data_date >= curdate() - interval 30 day then gross_profit       end) as gprofit_30,
           sum(case when data_date >= curdate() - interval 14 day then gross_profit       end) as gprofit_14,
           sum(case when data_date >= curdate() - interval 7 day  then gross_profit       end) as gprofit_7,
           sum(case when data_date >= curdate() - interval 3 day  then gross_profit       end) as gprofit_3
    from 结算利润指标
    group by country_category, seller_name_new, seller_sku_adj
)
select a.*,
       b.cur_date,
       b.amount_30,
       b.amount_14,
       b.amount_7,
       b.amount_3,
       b.gprofit_30,
       b.gprofit_14,
       b.gprofit_7,
       b.gprofit_3,
       b.gprofit_30 / nullif(b.amount_30, 0) as gprofit_ratio_30,
       b.gprofit_14 / nullif(b.amount_14, 0) as gprofit_ratio_14,
       b.gprofit_7  / nullif(b.amount_7, 0)  as gprofit_ratio_7,
       b.gprofit_3  / nullif(b.amount_3, 0)  as gprofit_ratio_3
from 结算利润指标 as a
left join 分段指标 as b
  on a.country_category = b.country_category
 and a.seller_name_new = b.seller_name_new
 and a.seller_sku_adj = b.seller_sku_adj;



-- 获取结算利润 店铺维度
drop table if exists etl_datasync.ops_weekly_rpt_settlement_profit_basic_data;
create table etl_datasync.ops_weekly_rpt_settlement_profit_basic_data as
with 周度数据表现 as (
    select date_sub(data_date, interval weekday(data_date) day)            as week_start,
           date_add(date_sub(data_date, interval weekday(data_date) day), interval 6 day) as week_end,
           max(yearweek(data_date, 1))                                     as year_week,
           country_category,
           seller_name_new,
           seller_sku_adj,
           sum(total_sales_amount)                                         as total_sales_amount,
           sum(gross_profit)                                               as gross_profit,
           sum(gross_profit_with_tax)                                      as gross_profit_with_tax,
           sum(gross_profit) / nullif(sum(total_sales_amount), 0)          as profit_margin,
           sum(gross_profit_with_tax) / nullif(sum(total_sales_amount), 0) as profit_with_tax_margin
    from etl_datasync.etl_dispose_lx_statistics_profit_statistics_msku
    where data_date >= date_sub(current_date, interval 90 day)
      and store_name not regexp 'baihuiyi|Yuanoboo|Bailboo|Qianytyy'
    group by week_start, week_end, country_category, seller_name_new, seller_sku_adj
    order by year_week desc, seller_sku_adj desc
),
完整周数 as (
    select *,
           lag(w.year_week, 1)
               over (partition by w.seller_sku_adj, w.seller_name_new, w.country_category order by w.year_week) as prev_week_date
    from 周度数据表现 as w
),
上周利润 as (
    select *,
           case
               when prev_week_date is null or year_week - prev_week_date != 1 then null
               else lag(gross_profit, 1) over w
               end as last_week_gross_profit,
           case
               when prev_week_date is null or year_week - prev_week_date != 1 then null
               else lag(profit_margin, 1) over w
               end as last_week_profit_margin
    from 完整周数
    window w as (partition by seller_sku_adj, seller_name_new, country_category order by year_week)
),
分级 as (
    select *,
           gross_profit - last_week_gross_profit as wk_profit_diff
    from 上周利润
)
select *,
       case
           when profit_margin >= 0.15 then 'A'
           when profit_margin >= 0.10 and profit_margin < 0.15 then 'B'
           when profit_margin >= 0.05 and profit_margin < 0.10 then 'C'
           when profit_margin >= 0.00 and profit_margin < 0.05 then 'D'
           else 'E'
           end as abcd_category,
       case
           when profit_margin >= 0.15 then '>=15%'
           when profit_margin >= 0.10 and profit_margin < 0.15 then '10%-15%'
           when profit_margin >= 0.05 and profit_margin < 0.10 then '5%-10%'
           when profit_margin >= 0.00 and profit_margin < 0.05 then '0%-5%'
           else '<0%'
           end as gp_margin_range
from 分级;



-- 结算利润 站点维度
drop table if exists etl_datasync.ops_weekly_rpt_site_settlement_profit_basic_data;
create table etl_datasync.ops_weekly_rpt_site_settlement_profit_basic_data as
with 周度数据表现 as (
    select date_sub(data_date, interval weekday(data_date) day)            as week_start,
           date_add(date_sub(data_date, interval weekday(data_date) day), interval 6 day) as week_end,
           max(yearweek(data_date, 1))                                     as year_week,
           country_category,
           seller_name_new,
           store_name,
           country,
           seller_sku_adj,
           sum(total_sales_amount)                                         as total_sales_amount,
           sum(gross_profit)                                               as gross_profit,
           sum(gross_profit_with_tax)                                      as gross_profit_with_tax,
           sum(gross_profit) / nullif(sum(total_sales_amount), 0)          as profit_margin,
           sum(gross_profit_with_tax) / nullif(sum(total_sales_amount), 0) as profit_with_tax_margin
    from etl_datasync.etl_dispose_lx_statistics_profit_statistics_msku
    where data_date >= date_sub(current_date, interval 90 day)
      and store_name not regexp 'baihuiyi|Yuanoboo|Bailboo|Qianytyy'
    group by week_start, week_end, country_category, seller_name_new, store_name, country, seller_sku_adj
    order by year_week desc, seller_sku_adj desc
),
完整周数 as (
    select *,
           lag(w.year_week, 1)
               over (partition by w.seller_sku_adj, w.seller_name_new, w.store_name, w.country, w.country_category order by w.year_week) as prev_week_date
    from 周度数据表现 as w
),
上周利润 as (
    select *,
           case
               when prev_week_date is null or year_week - prev_week_date != 1 then null
               else lag(gross_profit, 1) over w
               end as last_week_gross_profit,
           case
               when prev_week_date is null or year_week - prev_week_date != 1 then null
               else lag(profit_margin, 1) over w
               end as last_week_profit_margin
    from 完整周数
    window w as (partition by seller_sku_adj, seller_name_new, store_name, country, country_category order by year_week)
),
分级 as (
    select *,
           gross_profit - last_week_gross_profit as wk_profit_diff
    from 上周利润
)
select *,
       case
           when profit_margin >= 0.15 then 'A'
           when profit_margin >= 0.10 and profit_margin < 0.15 then 'B'
           when profit_margin >= 0.05 and profit_margin < 0.10 then 'C'
           when profit_margin >= 0.00 and profit_margin < 0.05 then 'D'
           else 'E'
           end as abcd_category,
       case
           when profit_margin >= 0.15 then '>=15%'
           when profit_margin >= 0.10 and profit_margin < 0.15 then '10%-15%'
           when profit_margin >= 0.05 and profit_margin < 0.10 then '5%-10%'
           when profit_margin >= 0.00 and profit_margin < 0.05 then '0%-5%'
           else '<0%'
           end as gp_margin_range
from 分级;


-- 产品表现基本数据
drop table if exists etl_datasync.ops_weekly_rpt_prod_perf_interim;
create table if not exists etl_datasync.ops_weekly_rpt_prod_perf_interim
with 产品表现指标 as (
    select start_date,
           year(start_date)        as year_date,
           month(start_date)       as month_date,
           yearweek(start_date, 1) as week_date,
           local_name,
           local_sku,
           asin,
           seller_name,
           seller_sku,
           country,
           brands,
           principal_names,
           developer_names,
           currency_icon,
           volume,
           order_items,
           amount,
           gross_profit,
           predict_gross_profit,
           spend,
           ad_order_quantity,
           ad_sales_amount,
           return_goods_count,
           return_count,
           return_amount,
           clicks,
           impressions,
           net_amount,
           sessions_total,
           afn_fulfillable_quantity,
           price,
           source_rate,
           `rank`,
           reviews_count,
           avg_star,
           seller_sku_adj,
           seller_name_new,
           country_category,
           org_currency_icon
    from etl_datasync.etl_dispose_lx_statistics_product_performance_2026
    where start_date >= date_sub(current_date, interval 90 day)
      and seller_name not regexp 'baihuiyi|Yuanoboo|Bailboo|Qianytyy'
),
分段销量 as (
    select country_category,
           seller_name_new,
           seller_sku_adj,
           date(curdate())                                                          as cur_date,
           sum(case when start_date >= curdate() - interval 90 day then volume end) as sales_90,
           sum(case when start_date >= curdate() - interval 60 day then volume end) as sales_60,
           sum(case when start_date >= curdate() - interval 30 day then volume end) as sales_30,
           sum(case when start_date >= curdate() - interval 14 day then volume end) as sales_14,
           sum(case when start_date >= curdate() - interval 7 day  then volume end) as sales_7,
           sum(case when start_date >= curdate() - interval 3 day  then volume end) as sales_3,
           sum(case when start_date >= curdate() - interval 90 day then amount end) as amount_90,
           sum(case when start_date >= curdate() - interval 60 day then amount end) as amount_60,
           sum(case when start_date >= curdate() - interval 30 day then amount end) as amount_30,
           sum(case when start_date >= curdate() - interval 14 day then amount end) as amount_14,
           sum(case when start_date >= curdate() - interval 7 day  then amount end) as amount_7,
           sum(case when start_date >= curdate() - interval 3 day  then amount end) as amount_3,
           sum(case when start_date >= curdate() - interval 90 day then predict_gross_profit end) as pprofit_90,
           sum(case when start_date >= curdate() - interval 60 day then predict_gross_profit end) as pprofit_60,
           sum(case when start_date >= curdate() - interval 30 day then predict_gross_profit end) as pprofit_30,
           sum(case when start_date >= curdate() - interval 14 day then predict_gross_profit end) as pprofit_14,
           sum(case when start_date >= curdate() - interval 7 day  then predict_gross_profit end) as pprofit_7,
           sum(case when start_date >= curdate() - interval 3 day  then predict_gross_profit end) as pprofit_3
    from 产品表现指标
    group by country_category, seller_name_new, seller_sku_adj
)
select a.*,
       b.cur_date,
       b.sales_90,
       b.sales_60,
       b.sales_30,
       b.sales_14,
       b.sales_7,
       b.sales_3,
       b.amount_90,
       b.amount_60,
       b.amount_30,
       b.amount_14,
       b.amount_7,
       b.amount_3,
       b.pprofit_90,
       b.pprofit_60,
       b.pprofit_30,
       b.pprofit_14,
       b.pprofit_7,
       b.pprofit_3,
       b.pprofit_30 / nullif(b.amount_30, 0) as pprofit_ratio_30,
       b.pprofit_14 / nullif(b.amount_14, 0) as pprofit_ratio_14,
       b.pprofit_7  / nullif(b.amount_7, 0)  as pprofit_ratio_7,
       b.pprofit_3  / nullif(b.amount_3, 0)  as pprofit_ratio_3
from 产品表现指标 as a
left join 分段销量 as b
  on a.country_category = b.country_category
 and a.seller_name_new = b.seller_name_new
 and a.seller_sku_adj = b.seller_sku_adj;


-- 产品表现 AFN 周天数：店铺/站点 basic 共用，避免重复扫描 interim 表计算同一份结果
drop temporary table if exists etl_datasync.tmp_weekly_prod_perf_afn_days;
create temporary table etl_datasync.tmp_weekly_prod_perf_afn_days as
select date_sub(start_date, interval weekday(start_date) day)        as week_start,
       date_add(date_sub(start_date, interval weekday(start_date) day), interval 6 day) as week_end,
       max(yearweek(start_date, 1))                                  as year_week,
       seller_name_new,
       seller_sku_adj,
       country_category,
       count(start_date)                                             as week_days,
       sum(case when afn_fulfillable_quantity > 0 then 1 else 0 end) as afn_fulfillable_quantity_not_zero_days
from (
    select start_date,
           week_date,
           seller_name_new,
           seller_sku_adj,
           country_category,
           max(afn_fulfillable_quantity) as afn_fulfillable_quantity
    from etl_datasync.ops_weekly_rpt_prod_perf_interim
    group by start_date, week_date, seller_name_new, seller_sku_adj, country_category
) as a
group by week_start, week_end, seller_name_new, seller_sku_adj, country_category;


-- 产品表现店铺维度
drop table if exists etl_datasync.ops_weekly_rpt_prod_perf_basic_data;
create table if not exists etl_datasync.ops_weekly_rpt_prod_perf_basic_data
with 周度数据表现 as (
    select date_sub(start_date, interval weekday(start_date) day)       as week_start,
           date_add(date_sub(start_date, interval weekday(start_date) day), interval 6 day) as week_end,
           max(yearweek(start_date, 1))                                 as year_week,
           max(local_name)                                              as local_name,
           max(local_sku)                                               as local_sku,
           max(asin)                                                    as asin,
           seller_sku_adj,
           seller_name_new,
           country_category,
           max(brands)                                                  as brands,
           max(principal_names)                                         as principal_names,
           max(developer_names)                                         as developer_names,
           max(currency_icon)                                           as currency_icon,

           sum(volume)                                                  as volume,
           sum(order_items)                                             as order_items,
           sum(amount)                                                  as amount,
           sum(
               case
                   when country = '德国'   then amount / 1.19
                   when country = '法国'   then amount / 1.2
                   when country = '瑞典'   then amount / 1.25
                   when country = '西班牙' then amount / 1.21
                   when country = '意大利' then amount / 1.22
                   when country = '英国'   then amount / 1.2
                   when country = '比利时' then amount / 1.21
                   when country = '荷兰'   then amount / 1.21
                   when country = '爱尔兰' then amount / 1.23
                   when country = '波兰'   then amount / 1.23
                   when country = '墨西哥' then amount / 1.16
                   when country = '土耳其' then amount / 1.20
                   else amount
               end
           ) as amount_tax,
           sum(gross_profit)                                            as gross_profit,
           sum(predict_gross_profit)                                    as predict_gross_profit,
           sum(case when volume = 0 then 0 else predict_gross_profit end) as predict_gross_profit_adj,
           sum(spend)                                                   as spend,
           sum(ad_order_quantity)                                       as ad_order_quantity,
           sum(ad_sales_amount)                                         as ad_sales_amount,
           sum(return_goods_count)                                      as return_goods_count,
           sum(return_count)                                            as return_count,
           sum(return_amount)                                           as return_amount,
           sum(clicks)                                                  as clicks,
           sum(impressions)                                             as impressions,
           sum(net_amount)                                              as net_amount,
           sum(sessions_total)                                          as sessions_total,
           round(sum(abs(spend)) / nullif(sum(ad_sales_amount), 0), 4)  as acos,
           round(sum(abs(clicks)) / nullif(sum(impressions), 0), 4)    as ctr,
           round(sum(ad_order_quantity) / nullif(sum(clicks), 0), 4)    as ad_cvr,
           round((sum(order_items) - sum(ad_order_quantity))
                     / nullif(sum(sessions_total) - sum(clicks), 0), 4) as nature_cvr,
           round(sum(ad_order_quantity) / nullif(sum(order_items), 0), 4) as ad_order_proportion,
           round(sum(abs(spend)) / nullif(sum(net_amount), 0), 4)       as acoas,
           round(sum(predict_gross_profit) / nullif(sum(amount), 0), 4) as predict_profit_margin,
           round(sum(return_goods_count) / nullif(sum(volume), 0), 4)   as return_proportion,
           round(sum(return_amount) / nullif(sum(amount), 0), 4)        as refund_proportion,
           max(afn_fulfillable_quantity)                                as afn_fulfillable_quantity,
           group_concat(case
                            when weekday(start_date) = 6
                                then concat(country, '-', price) end
                        separator
                        ',')                                            as concat_price,
           group_concat(case
                            when weekday(start_date) = 6
                                then concat(country, '-', `rank`) end
                        separator
                        ',')                                            as concat_rank,
           group_concat(case
                            when weekday(start_date) = 6
                                then concat(country, '-', reviews_count) end
                        separator
                        ',')                                            as concat_reviews_count,
           group_concat(case
                            when weekday(start_date) = 6
                                then concat(country, '-', avg_star) end
                        separator
                        ',')                                            as concat_avg_star,
           max(sales_30)                                                as sales_30,
           max(sales_60)                                                as sales_60
    from etl_datasync.ops_weekly_rpt_prod_perf_interim
    group by week_start, week_end, seller_sku_adj, seller_name_new, country_category
),
完整周数 as (
    select w.*,
           a.week_days,
           a.afn_fulfillable_quantity_not_zero_days,
           lag(w.year_week, 1)
               over (partition by w.seller_sku_adj, w.seller_name_new, w.country_category order by w.year_week) as prev_week_date
    from 周度数据表现 as w
    left join etl_datasync.tmp_weekly_prod_perf_afn_days as a
      on w.year_week = a.year_week
     and w.seller_sku_adj = a.seller_sku_adj
     and w.seller_name_new = a.seller_name_new
     and w.country_category = a.country_category
    where w.seller_sku_adj is not null
),
上周销量 as (
    select wd.*,
           case
               when prev_week_date is null or year_week - prev_week_date != 1 then null
               else lag(volume, 1) over w
               end as last_week_volume,
           case
               when prev_week_date is null or year_week - prev_week_date != 1 then null
               else lag(amount, 1) over w
               end as last_week_amount,
           case
               when prev_week_date is null or year_week - prev_week_date != 1 then null
               else lag(week_days, 1) over w
               end as last_week_sales_days
    from 完整周数 as wd
    window w as (partition by seller_sku_adj, seller_name_new, country_category order by year_week)
),
日均销量计算 as (
    select *,
           volume - last_week_volume as volume_diff,
           amount - last_week_amount as amount_diff,
           predict_gross_profit_adj / nullif(amount_tax, 0) as predict_profit_margin_adj,
           case
               when week_days > 0 then round(volume / week_days, 2)
               end as avg_daily_volume,
           case
               when last_week_sales_days > 0 then round(last_week_volume / last_week_sales_days, 2)
               end as last_week_avg_daily_volume
    from 上周销量
)
select *,
       case
           when avg_daily_volume >= 5 then '日销>=5'
           when avg_daily_volume >= 1 and avg_daily_volume < 5 then '日销1-5'
           when avg_daily_volume > 0  and avg_daily_volume < 1 then '日销0-1'
           when avg_daily_volume = 0 then '日销0'
           else ''
           end as avg_daily_volume_category,
       case
           when last_week_avg_daily_volume >= 5 then '日销>=5'
           when last_week_avg_daily_volume >= 1 and last_week_avg_daily_volume < 5 then '日销1-5'
           when last_week_avg_daily_volume > 0  and last_week_avg_daily_volume < 1 then '日销0-1'
           when last_week_avg_daily_volume = 0 then '日销0'
           else ''
           end as last_week_avg_daily_volume_category,
       case
           when predict_profit_margin < 0 or predict_profit_margin is null then 'E'
           when avg_daily_volume < 1 then 'D'
           when avg_daily_volume >= 1 then
               case
                   when predict_profit_margin >= 0.20 then 'A'
                   when predict_profit_margin >= 0.15 and predict_profit_margin < 0.20 then 'B'
                   when predict_profit_margin >= 0.10 and predict_profit_margin < 0.15 then 'C'
                   else 'D'
                   end
           end as predict_abcd_category,
       case
           when predict_profit_margin_adj >= 0.35 then '毛利率>0.35'
           when predict_profit_margin_adj >= 0.25 and predict_profit_margin_adj < 0.35 then '毛利率0.25-0.35'
           when predict_profit_margin_adj >= 0.15 and predict_profit_margin_adj < 0.25 then '毛利率0.15-0.25'
           when predict_profit_margin_adj >= 0.10 and predict_profit_margin_adj < 0.15 then '毛利率0.1-0.15'
           when predict_profit_margin_adj >= 0    and predict_profit_margin_adj < 0.10 then '毛利率0.05-0.1'
           else '毛利率小于0'
           end as profit_margin_category
from 日均销量计算;



-- 站点商品表现基础数据
drop table if exists etl_datasync.ops_weekly_rpt_site_prod_perf_basic_data;
create table if not exists etl_datasync.ops_weekly_rpt_site_prod_perf_basic_data
with 周度数据表现 as (
    select date_sub(start_date, interval weekday(start_date) day)       as week_start,
           date_add(date_sub(start_date, interval weekday(start_date) day), interval 6 day) as week_end,
           max(yearweek(start_date, 1))                                 as year_week,
           max(local_name)                                              as local_name,
           max(local_sku)                                               as local_sku,
           max(asin)                                                    as asin,
           seller_sku_adj,
           seller_name,
           seller_name_new,
           country,
           country_category,
           max(brands)                                                  as brands,
           max(principal_names)                                         as principal_names,
           max(developer_names)                                         as developer_names,
           max(currency_icon)                                           as currency_icon,

           sum(volume)                                                  as volume,
           sum(order_items)                                             as order_items,
           sum(amount)                                                  as amount,
           sum(
               case
                   when country = '德国'   then amount / 1.19
                   when country = '法国'   then amount / 1.2
                   when country = '瑞典'   then amount / 1.25
                   when country = '西班牙' then amount / 1.21
                   when country = '意大利' then amount / 1.22
                   when country = '英国'   then amount / 1.2
                   when country = '比利时' then amount / 1.21
                   when country = '荷兰'   then amount / 1.21
                   when country = '爱尔兰' then amount / 1.23
                   when country = '波兰'   then amount / 1.23
                   when country = '墨西哥' then amount / 1.16
                   when country = '土耳其' then amount / 1.20
                   else amount
               end
           ) as amount_tax,
           sum(gross_profit)                                            as gross_profit,
           sum(predict_gross_profit)                                    as predict_gross_profit,
           sum(case when volume = 0 then 0 else predict_gross_profit end) as predict_gross_profit_adj,
           sum(spend)                                                   as spend,
           sum(ad_order_quantity)                                       as ad_order_quantity,
           sum(ad_sales_amount)                                         as ad_sales_amount,
           sum(return_goods_count)                                      as return_goods_count,
           sum(return_count)                                            as return_count,
           sum(return_amount)                                           as return_amount,
           sum(clicks)                                                  as clicks,
           sum(impressions)                                             as impressions,
           sum(net_amount)                                              as net_amount,
           sum(sessions_total)                                          as sessions_total,
           round(sum(abs(spend)) / nullif(sum(ad_sales_amount), 0), 4)  as acos,
           round(sum(abs(clicks)) / nullif(sum(impressions), 0), 4)     as ctr,
           round(sum(ad_order_quantity) / nullif(sum(clicks), 0), 4)    as ad_cvr,
           round((sum(order_items) - sum(ad_order_quantity))
                     / nullif(sum(sessions_total) - sum(clicks), 0), 4) as nature_cvr,
           round(sum(ad_order_quantity) / nullif(sum(order_items), 0), 4) as ad_order_proportion,
           round(sum(abs(spend)) / nullif(sum(net_amount), 0), 4)       as acoas,
           round(sum(predict_gross_profit) / nullif(sum(amount), 0), 4) as predict_profit_margin,
           round(sum(return_goods_count) / nullif(sum(volume), 0), 4)   as return_proportion,
           round(sum(return_amount) / nullif(sum(amount), 0), 4)        as refund_proportion,
           max(afn_fulfillable_quantity)                                as afn_fulfillable_quantity,
           group_concat(case
                            when weekday(start_date) = 6
                                then price end
                        separator
                        ',')                                            as concat_price,
           group_concat(case
                            when weekday(start_date) = 6
                                then `rank` end
                        separator
                        ',')                                            as concat_rank,
           group_concat(case
                            when weekday(start_date) = 6
                                then reviews_count end
                        separator
                        ',')                                            as concat_reviews_count,
           group_concat(case
                            when weekday(start_date) = 6
                                then avg_star end
                        separator
                        ',')                                            as concat_avg_star,
           max(sales_30)                                                as sales_30,
           max(sales_60)                                                as sales_60
    from etl_datasync.ops_weekly_rpt_prod_perf_interim
    group by week_start, week_end, seller_sku_adj, seller_name_new, seller_name, country, country_category
),
完整周数 as (
    select w.*,
           a.week_days,
           a.afn_fulfillable_quantity_not_zero_days,
           lag(w.year_week, 1)
               over (partition by w.seller_sku_adj, w.seller_name_new, w.seller_name, w.country, w.country_category order by w.year_week) as prev_week_date
    from 周度数据表现 as w
    left join etl_datasync.tmp_weekly_prod_perf_afn_days as a
      on w.year_week = a.year_week
     and w.seller_sku_adj = a.seller_sku_adj
     and w.seller_name_new = a.seller_name_new
     and w.country_category = a.country_category
    where w.seller_sku_adj is not null
),
上周销量 as (
    select wd.*,
           case
               when prev_week_date is null or year_week - prev_week_date != 1 then null
               else lag(volume, 1) over w
               end as last_week_volume,
           case
               when prev_week_date is null or year_week - prev_week_date != 1 then null
               else lag(amount, 1) over w
               end as last_week_amount,
           case
               when prev_week_date is null or year_week - prev_week_date != 1 then null
               else lag(week_days, 1) over w
               end as last_week_sales_days
    from 完整周数 as wd
    window w as (partition by seller_sku_adj, seller_name_new, seller_name, country, country_category order by year_week)
),
日均销量计算 as (
    select *,
           volume - last_week_volume as volume_diff,
           amount - last_week_amount as amount_diff,
           predict_gross_profit_adj / nullif(amount_tax, 0) as predict_profit_margin_adj,
           case
               when week_days > 0 then round(volume / week_days, 2)
               end as avg_daily_volume,
           case
               when last_week_sales_days > 0 then round(last_week_volume / last_week_sales_days, 2)
               end as last_week_avg_daily_volume
    from 上周销量
)
select *,
       case
           when avg_daily_volume >= 5 then '日销>=5'
           when avg_daily_volume >= 1 and avg_daily_volume < 5 then '日销1-5'
           when avg_daily_volume > 0  and avg_daily_volume < 1 then '日销0-1'
           when avg_daily_volume = 0 then '日销0'
           else ''
           end as avg_daily_volume_category,
       case
           when last_week_avg_daily_volume >= 5 then '日销>=5'
           when last_week_avg_daily_volume >= 1 and last_week_avg_daily_volume < 5 then '日销1-5'
           when last_week_avg_daily_volume > 0  and last_week_avg_daily_volume < 1 then '日销0-1'
           when last_week_avg_daily_volume = 0 then '日销0'
           else ''
           end as last_week_avg_daily_volume_category,
       case
           when predict_profit_margin < 0 or predict_profit_margin is null then 'E'
           when avg_daily_volume < 1 then 'D'
           when avg_daily_volume >= 1 then
               case
                   when predict_profit_margin >= 0.20 then 'A'
                   when predict_profit_margin >= 0.15 and predict_profit_margin < 0.20 then 'B'
                   when predict_profit_margin >= 0.10 and predict_profit_margin < 0.15 then 'C'
                   else 'D'
                   end
           end as predict_abcd_category,
       case
           when predict_profit_margin_adj >= 0.35 then '毛利率>0.35'
           when predict_profit_margin_adj >= 0.25 and predict_profit_margin_adj < 0.35 then '毛利率0.25-0.35'
           when predict_profit_margin_adj >= 0.15 and predict_profit_margin_adj < 0.25 then '毛利率0.15-0.25'
           when predict_profit_margin_adj >= 0.10 and predict_profit_margin_adj < 0.15 then '毛利率0.1-0.15'
           when predict_profit_margin_adj >= 0    and predict_profit_margin_adj < 0.10 then '毛利率0.05-0.1'
           else '毛利率小于0'
           end as profit_margin_category
from 日均销量计算;


select yearweek(date_sub(date_sub(curdate(), interval weekday(curdate()) day), interval 7 day), 1);
select yearweek(date_sub(curdate(), interval 1 week), 1);
set @s_week = yearweek(date_sub(curdate(), interval 1 week), 1);
-- Step 1：产品表现 + listing + 货件 + 结算利润 + 季度分类 + 上月分类 + 上周筛选
drop temporary table if exists etl_datasync.tmp_weekly_store_step1;
create temporary table etl_datasync.tmp_weekly_store_step1 as
with 产品表现_店铺_周维度 as (
    select *
    from etl_datasync.ops_weekly_rpt_prod_perf_basic_data
    where length(seller_sku_adj) between 5 and 10),
listing_产品管理_店铺 as (
    select distinct create_time,
                    seller_sku,
                    country_category,
                    seller_name_ue,
                    seller_name_new,
                    principal,
                    sales_team_1,
                    onsale_sites,
                    unsale_sites,
                    sales_status,
                    avg_price_cny,
                    group_concat(distinct global_tags separator ',') as global_tags,
                    group_concat(distinct
                                 case
                                     when global_tags regexp '清货-正常' then '清货-正常'
                                     when global_tags regexp '清货-紧急' then '清货-紧急'
                                 end
                                 separator ',')                      as clearance_tags,
                    group_concat(distinct
                                 case
                                     when global_tags regexp '不合规-'
                                         then regexp_substr(global_tags, '不合规-[^,|，]+')
                                 end
                                 separator
                                 ',')                                as non_compliant_tags,
                    max_sku,
                    max_local_name,
                    max_spu,
                    max_tag_name,
                    max_product_dev_time,
                    max_brand_name,
                    max_category_name,
                    max_product_developer,
                    max_cg_box_pcs,
                    max_cg_price,
                    max_cg_transport_costs,
                    new_old_product
    from etl_datasync.ops_rpt_listing_prod_basic_data
    where length(seller_sku) between 5 and 10
    group by create_time,
             seller_sku,
             country_category,
             seller_name_ue,
             seller_name_new,
             principal,
             sales_team_1,
             onsale_sites,
             unsale_sites,
             sales_status,
             avg_price_cny,
             max_sku,
             max_local_name,
             max_spu,
             max_tag_name,
             max_product_dev_time,
             max_brand_name,
             max_category_name,
             max_product_developer,
             max_cg_box_pcs,
             max_cg_price,
             max_cg_transport_costs,
             new_old_product
)
select ppbd.year_week,
       ppbd.week_start,
       ppbd.week_end,
       ppbd.country_category,
       ppbd.seller_name_new,
       ppbd.seller_sku_adj,
       ppbd.local_sku,
       lpbd.sales_team_1,
       lpbd.principal,
       lpbd.global_tags,
       lpbd.clearance_tags,
       lpbd.non_compliant_tags,
       lpbd.max_spu,
       lpbd.max_sku,
       lpbd.max_local_name,
       lpbd.max_category_name,
       lpbd.max_brand_name,
       lpbd.new_old_product,
       lpbd.max_product_dev_time,
       lpbd.avg_price_cny,
       lpbd.onsale_sites,
       lpbd.unsale_sites,
       lpbd.sales_status,
       ppbd.avg_daily_volume_category,
       ppbd.last_week_avg_daily_volume_category,
       coalesce(spbd.abcd_category, 'E')           as abcd_category,
       spbd.gp_margin_range,
       qbd.pre_2q_predict_abcd_category,
       qbd.pre_1q_predict_abcd_category,
       qbd.category_changes,
       coalesce(ppbd.predict_abcd_category, 'E')   as predict_abcd_category,
       coalesce(ubd.pre_1m_predict_abcd_category, 'E') as pre_1m_predict_abcd_category,
       case
           when ppbd.avg_daily_volume >= 1 and ppbd.predict_profit_margin >= 0.10 then 0
           else 1
           end                                     as is_predict_abc,
       lpbd.max_tag_name,
       lpbd.max_cg_box_pcs,
       lpbd.max_cg_price,
       lpbd.max_cg_transport_costs,
       fsbd.receiving_cnt,
       fsbd.min_receiving_time,
       fsbd.days_since_launch,
       fsbd.since_launch_range,
       fsbd.max_receiving_time,
       fsbd.days_latest_delivery,
       fsbd.delivery_time_range,
       case
           when lpbd.new_old_product = '新品' and fsbd.days_latest_delivery >= 90
               and fsbd.receiving_cnt <= 1 then '新品未补货'
           else '已补货'
           end                                     as new_is_replenishment,
       ppbd.concat_price,
       ppbd.concat_rank,
       ppbd.concat_reviews_count,
       ppbd.concat_avg_star,
       ppbd.week_days,
       ppbd.afn_fulfillable_quantity_not_zero_days,
       ppbd.avg_daily_volume,
       ppbd.volume,
       ppbd.last_week_volume,
       ppbd.volume_diff,
       ppbd.amount,
       ppbd.amount_tax,
       ppbd.last_week_amount,
       ppbd.amount_diff,
       ppbd.net_amount,
       ppbd.order_items,
       spbd.total_sales_amount,
       spbd.gross_profit,
       spbd.last_week_gross_profit,
       spbd.wk_profit_diff,
       spbd.profit_margin,
       ppbd.predict_gross_profit,
       ppbd.predict_gross_profit_adj,
       ppbd.predict_profit_margin,
       ppbd.predict_profit_margin_adj,
       ppbd.profit_margin_category,
       ppbd.return_goods_count,
       ppbd.return_amount,
       ppbd.return_proportion,
       ppbd.refund_proportion,
       ppbd.spend,
       ppbd.acos,
       ppbd.acoas,
       ppbd.ctr,
       ppbd.ad_sales_amount,
       ppbd.ad_order_quantity,
       ppbd.ad_order_proportion,
       ppbd.ad_cvr,
       ppbd.impressions,
       ppbd.clicks,
       ppbd.sessions_total,
       ppbd.nature_cvr,
       ppbd.sales_30,
       ppbd.sales_60,
       lfd.last_week_filtrate
from 产品表现_店铺_周维度 as ppbd
left join listing_产品管理_店铺 as lpbd
  on ppbd.seller_sku_adj = lpbd.seller_sku
 and ppbd.seller_name_new = lpbd.seller_name_new
 and ppbd.country_category = lpbd.country_category
 and ppbd.local_sku = lpbd.max_sku
left join etl_datasync.ops_rpt_fba_shipment_basic_data as fsbd
  on ppbd.seller_sku_adj = fsbd.msku
 and ppbd.seller_name_new = fsbd.seller_name_new
 and ppbd.country_category = fsbd.country_category
left join etl_datasync.ops_weekly_rpt_settlement_profit_basic_data as spbd
  on ppbd.seller_sku_adj = spbd.seller_sku_adj
 and ppbd.seller_name_new = spbd.seller_name_new
 and ppbd.country_category = spbd.country_category
 and spbd.year_week = ppbd.year_week
left join etl_datasync.ops_quarter_rpt_prod_perf_basic_data as qbd
  on ppbd.seller_sku_adj = qbd.seller_sku_adj
 and ppbd.seller_name_new = qbd.seller_name_new
 and ppbd.country_category = qbd.country_category
left join (
    select y_month,
           country_category,
           seller_name_new,
           seller_sku_adj,
           asin,
           local_sku,
           predict_profit_margin as pre_1m_predict_profit_margin,
           predict_abcd_category as pre_1m_predict_abcd_category
    from etl_datasync.ops_monthly_rpt_prod_perf_basic_data
    where y_month = date_format(date_sub(curdate(), interval 1 month), '%Y-%m')
) as ubd
  on ppbd.seller_sku_adj = ubd.seller_sku_adj
 and ppbd.seller_name_new = ubd.seller_name_new
 and ppbd.country_category = ubd.country_category
left join (
    select year_week,
           country_category,
           seller_name_new,
           seller_sku_adj,
           max_sku,
           filtrate as last_week_filtrate
    from dws_datasync.ops_weekly_rpt_prod_perf_data_2026
    where year_week = yearweek(date_sub(curdate(), interval 2 week), 1)
) as lfd
  on ppbd.seller_sku_adj = lfd.seller_sku_adj
 and ppbd.seller_name_new = lfd.seller_name_new
 and ppbd.country_category = lfd.country_category;
-- Step 2：Step 1 + FBA 库存 + 补货建议
drop temporary table if exists etl_datasync.tmp_weekly_store_step2;
create temporary table etl_datasync.tmp_weekly_store_step2 as
select s1.*,
       fbd.total,
       fbd.total_price,
       fbd.available_total,
       fbd.available_total_price,
       fbd.afn_fulfillable_quantity,
       fbd.reserved_fc_transfers,
       fbd.reserved_fc_processing,
       fbd.reserved_customerorders,
       fbd.afn_unsellable_quantity,
       fbd.afn_inbound_receiving_quantity,
       fbd.stock_up_num,
       fbd.afn_researching_quantity,
       fbd.inv_age_0_3_days,
       fbd.inv_age_0_3_price,
       fbd.inv_age_3_6_days,
       fbd.inv_age_3_6_price,
       fbd.inv_age_6_9_days,
       fbd.inv_age_6_9_price,
       fbd.inv_age_9_12_days,
       fbd.inv_age_9_12_price,
       fbd.inv_age_over_12_days,
       fbd.inv_age_over_12_price,
       fbd.lowerlibrary_ages_days,
       fbd.lowerlibrary_ages_price,
       fbd.superlibrary_ages_days,
       fbd.superlibrary_ages_price,
       fbd.over_inv90_days,
       fbd.over_inv90_price,
       fbd.superlibrary_proportion,
       rbd.sc_quantity_local_valid,
       rbd.sc_quantity_purchase_shipping,
       rbd.sc_quantity_purchase_plan,
       rbd.sc_quantity_local_qc,
       rbd.local_quantity
from etl_datasync.tmp_weekly_store_step1 as s1
left join etl_datasync.ops_weekly_rpt_fba_inv_detail_basic_data as fbd
  on s1.seller_sku_adj = fbd.seller_sku_adj
 and s1.seller_name_new = fbd.seller_name_new
 and s1.country_category = fbd.country_category
 and s1.year_week = fbd.dt_week
left join etl_datasync.ops_weekly_rpt_replenish_sug_basic_data as rbd
  on s1.seller_sku_adj = rbd.seller_sku_adj
 and s1.seller_name_new = rbd.seller_name_new
 and s1.country_category = rbd.country_category
 and s1.year_week + 1 = rbd.dt_week;
-- Step 3：Step 2 + 物流天数（精确匹配 + 欧洲站兜底）
drop temporary table if exists etl_datasync.tmp_weekly_store_step3;
create temporary table etl_datasync.tmp_weekly_store_step3 as
select s2.*,
       coalesce(ist_country.earliest_ship_time, ist_eu.earliest_ship_time) as earliest_ship_time,
       coalesce(ist_country.channel_abbrev, ist_eu.channel_abbrev)         as channel_abbrev,
       coalesce(ist_country.logistics_est_days, ist_eu.logistics_est_days) as logistics_est_days,
       case
           when coalesce(ist_country.earliest_ship_time, ist_eu.earliest_ship_time) is null
               then null
           else date_add(coalesce(ist_country.earliest_ship_time, ist_eu.earliest_ship_time),
                         interval coalesce(ist_country.logistics_est_days, ist_eu.logistics_est_days) day)
           end                                                             as expected_delivery_time
from etl_datasync.tmp_weekly_store_step2 as s2
left join etl_datasync.ops_rpt_logi_est_days_data as ist_country
  on s2.seller_name_new = ist_country.seller_name_new
 and s2.seller_sku_adj = ist_country.msku
 and s2.country_category = ist_country.country_category
left join etl_datasync.ops_rpt_logi_est_days_data as ist_eu
  on s2.seller_name_new = ist_eu.seller_name_new
 and s2.seller_sku_adj = ist_eu.msku
 and ist_eu.country_category = '欧洲站'
 and s2.country_category in ('英国站', '欧洲站')
 and ist_country.seller_name_new is null;
-- Step 4：最终计算 + 产品生命周期，写回原目标表
# insert into dws_datasync.ops_weekly_rpt_prod_perf_data_2026
with 计算字段 as (
    select *,
           case
               when volume > 0 or (coalesce(local_quantity, 0) + coalesce(total, 0)) > 0 then '1'
               else '0'
               end as filtrate,
           coalesce(local_quantity + total, 0)                            as fba_local_quantity,
           (max_cg_price + max_cg_transport_costs) * local_quantity       as local_cost,
           coalesce(sales_30, 0)                                          as sales_30_coalesce,
           coalesce(sales_60, 0)                                          as sales_60_coalesce,
           row_number() over (partition by year_week, sales_team_1
                              order by volume_diff)                       as rk_volume_diff,
           case
               when available_total > 0 and (volume = 0 or afn_fulfillable_quantity_not_zero_days = 0) then '99999'
               when available_total > 0 and (volume > 0 and afn_fulfillable_quantity_not_zero_days > 0)
                   then available_total / (volume / afn_fulfillable_quantity_not_zero_days)
               when available_total = 0 then 0
               end                                                        as available_salable_days,
           case
               when (coalesce(local_quantity, 0) + coalesce(total, 0)) > 0
                    and (volume = 0 or afn_fulfillable_quantity_not_zero_days = 0) then '99999'
               when (coalesce(local_quantity, 0) + coalesce(total, 0)) > 0
                    and (volume > 0 and afn_fulfillable_quantity_not_zero_days > 0)
                   then (local_quantity + total) / (volume / afn_fulfillable_quantity_not_zero_days)
               when (coalesce(local_quantity, 0) + coalesce(total, 0)) = 0 then 0
               end                                                        as fba_local_salable_days,
           superlibrary_ages_days / nullif(avg_daily_volume, 0)            as overdue_prod_sal_days,
           inv_age_6_9_days / nullif(avg_daily_volume, 0)                  as `6_9m_prod_sal_days`,
           inv_age_9_12_days / nullif(avg_daily_volume, 0)                 as `9_12m_prod_sal_days`,
           inv_age_over_12_days / nullif(avg_daily_volume, 0)              as `12m_plus_prod_sal_days`,
           case
               when lowerlibrary_ages_days > 0 and superlibrary_ages_days = 0 then '0-6个月(不含超库龄)'
               when lowerlibrary_ages_days > 0 and superlibrary_ages_days > 0 then '0-6个月(含超库龄)'
               when lowerlibrary_ages_days = 0 and superlibrary_ages_days > 0 then '6个月以上'
               else '无库龄段数据'
               end                                                        as aging_range
    from etl_datasync.tmp_weekly_store_step3
),
汇总字段 as (
    select year_week,
           week_start,
           week_end,
           filtrate,
           coalesce(last_week_filtrate, 0) as last_week_filtrate,
           country_category,
           seller_name_new,
           seller_sku_adj,
           sales_team_1,
           principal,
           global_tags,
           clearance_tags,
           non_compliant_tags,
           max_spu,
           max_sku,
           max_local_name,
           max_category_name,
           max_brand_name,
           new_old_product,
           max_product_dev_time,
           avg_price_cny,
           onsale_sites,
           unsale_sites,
           sales_status,
           avg_daily_volume_category,
           last_week_avg_daily_volume_category,
           abcd_category,
           gp_margin_range,
           pre_2q_predict_abcd_category,
           pre_1q_predict_abcd_category,
           category_changes,
           predict_abcd_category,
           predict_profit_margin_adj,
           profit_margin_category,
           pre_1m_predict_abcd_category,
           is_predict_abc,
           max_tag_name,
           max_cg_box_pcs,
           max_cg_price,
           max_cg_transport_costs,
           receiving_cnt,
           min_receiving_time,
           days_since_launch,
           since_launch_range,
           max_receiving_time,
           days_latest_delivery,
           delivery_time_range,
           new_is_replenishment,
           concat_price,
           concat_rank,
           concat_reviews_count,
           concat_avg_star,
           week_days,
           afn_fulfillable_quantity_not_zero_days,
           avg_daily_volume,
           volume,
           last_week_volume,
           volume_diff,
           rk_volume_diff,
           amount,
           amount_tax,
           last_week_amount,
           amount_diff,
           net_amount,
           order_items,
           total_sales_amount,
           gross_profit,
           last_week_gross_profit,
           wk_profit_diff,
           profit_margin,
           predict_gross_profit,
           predict_gross_profit_adj,
           predict_profit_margin,
           return_goods_count,
           return_amount,
           return_proportion,
           refund_proportion,
           spend,
           acos,
           acoas,
           ctr,
           ad_sales_amount,
           ad_order_quantity,
           ad_order_proportion,
           ad_cvr,
           impressions,
           clicks,
           sessions_total,
           nature_cvr,
           total,
           total_price,
           available_total,
           afn_fulfillable_quantity,
           reserved_fc_transfers,
           reserved_fc_processing,
           reserved_customerorders,
           afn_unsellable_quantity,
           afn_inbound_receiving_quantity,
           stock_up_num,
           afn_researching_quantity,
           sc_quantity_local_valid,
           sc_quantity_purchase_shipping,
           sc_quantity_purchase_plan,
           sc_quantity_local_qc,
           local_quantity,
           local_cost,
           available_total_price,
           fba_local_quantity,
           (max_cg_price + max_cg_transport_costs) * local_quantity + total_price as fba_local_cost,
           sales_30,
           sales_60,
           available_total / nullif(sales_30_coalesce, 0)                         as amz_inv_sales_ratio,
           (local_quantity + total) / nullif(sales_30_coalesce, 0)                as fba_local_inv_sales_ratio,
           fba_local_salable_days,
           case
               when fba_local_salable_days = 0 and fba_local_salable_days is not null then '可售天数0天'
               when fba_local_salable_days > 0  and fba_local_salable_days < 30   then '可售天数30天内'
               when fba_local_salable_days >= 30 and fba_local_salable_days < 60   then '可售天数60天内'
               when fba_local_salable_days >= 60 and fba_local_salable_days < 90   then '可售天数90天内'
               when fba_local_salable_days >= 90 and fba_local_salable_days < 180  then '可售天数180天内'
               when fba_local_salable_days >= 180 and fba_local_salable_days < 270 then '可售天数270天内'
               when fba_local_salable_days >= 270 and fba_local_salable_days < 360 then '可售天数360天内'
               when fba_local_salable_days >= 360 then '可售天数360天以上'
               else ''
               end as fba_local_salable_days_range,
           available_salable_days,
           case
               when available_salable_days = 0 and available_salable_days is not null then '可售天数0天'
               when available_salable_days > 0  and available_salable_days < 30   then '可售天数30天内'
               when available_salable_days >= 30 and available_salable_days < 60   then '可售天数60天内'
               when available_salable_days >= 60 and available_salable_days < 90   then '可售天数90天内'
               when available_salable_days >= 90 and available_salable_days < 180  then '可售天数180天内'
               when available_salable_days >= 180 and available_salable_days < 270 then '可售天数270天内'
               when available_salable_days >= 270 and available_salable_days < 360 then '可售天数360天内'
               when available_salable_days >= 360 then '可售天数360天以上'
               else ''
               end as available_salable_days_range,
           coalesce(inv_age_0_3_days, 0)         as inv_age_0_3_days,
           coalesce(inv_age_0_3_price, 0)        as inv_age_0_3_price,
           coalesce(inv_age_3_6_days, 0)         as inv_age_3_6_days,
           coalesce(inv_age_3_6_price, 0)        as inv_age_3_6_price,
           coalesce(inv_age_6_9_days, 0)         as inv_age_6_9_days,
           coalesce(inv_age_6_9_price, 0)        as inv_age_6_9_price,
           coalesce(inv_age_9_12_days, 0)        as inv_age_9_12_days,
           coalesce(inv_age_9_12_price, 0)       as inv_age_9_12_price,
           coalesce(inv_age_over_12_days, 0)     as inv_age_over_12_days,
           coalesce(inv_age_over_12_price, 0)    as inv_age_over_12_price,
           coalesce(lowerlibrary_ages_days, 0)   as lowerlibrary_ages_days,
           coalesce(lowerlibrary_ages_price, 0)  as lowerlibrary_ages_price,
           coalesce(superlibrary_ages_days, 0)   as superlibrary_ages_days,
           coalesce(superlibrary_ages_price, 0)  as superlibrary_ages_price,
           coalesce(over_inv90_days, 0)          as over_inv90_days,
           coalesce(over_inv90_price, 0)         as over_inv90_price,
           superlibrary_proportion,
           overdue_prod_sal_days,
           `6_9m_prod_sal_days`,
           `9_12m_prod_sal_days`,
           `12m_plus_prod_sal_days`,
           aging_range,
           earliest_ship_time,
           channel_abbrev,
           logistics_est_days,
           expected_delivery_time
    from 计算字段
),
产品生命周期 as (
    select country_category, seller_name_new, seller_sku, product_lifecycle_stage
    from dws_datasync.dws_product_lifecycle_market_v2
    where create_time = (select max(create_time) from dws_datasync.dws_product_lifecycle_market_v2)
)
select wd.*,
       case
           when available_salable_days > 60
                or datediff(expected_delivery_time, week_end) < available_salable_days
               then '不会缺货'
           else case
                    when stock_up_num = 0 and local_quantity = 0 then '缺货未补货'
                    when stock_up_num > 0 or local_quantity > 0 then '缺货已补货'
               end
           end as stockout_status,
       pl.product_lifecycle_stage,
       case
            when over_inv90_days > 0 and sales_60 = 0 then '是：库龄90天+且近60天不出单'
           else '否'
           end as clearance_status,
       now() as create_time
from 汇总字段 as wd
left join 产品生命周期 as pl
  on wd.country_category = pl.country_category
 and wd.seller_name_new = pl.seller_name_new
 and wd.seller_sku_adj = pl.seller_sku
where year_week = @s_week
order by wd.sales_team_1 desc, cast(wd.rk_volume_diff as signed);



select yearweek(date_sub(date_sub(curdate(), interval weekday(curdate()) day), interval 7 day), 1);
select yearweek(date_sub(curdate(), interval 1 week), 1);
set @s_week = yearweek(date_sub(curdate(), interval 1 week), 1);
-- Step 1：产品表现 + listing + 货件 + 结算利润 + 季度分类 + 上月分类 + 上周筛选
drop temporary table if exists etl_datasync.tmp_weekly_site_step1;
create temporary table etl_datasync.tmp_weekly_site_step1 as
with 产品表现_站点_周维度 as (
    select *
    from etl_datasync.ops_weekly_rpt_site_prod_perf_basic_data
    where length(seller_sku_adj) between 5 and 10
),
listing_产品管理_站点 as (
    select distinct create_time,
                    seller_sku,
                    country_category,
                    seller_name_ue,
                    seller_name_new,
                    seller_name,
                    marketplace,
                    principal,
                    sales_team_1,
                    onsale_sites,
                    unsale_sites,
                    sales_status,
                    avg_price_cny,
                    global_tags,
                    case
                        when global_tags regexp '清货-正常' then '清货-正常'
                        when global_tags regexp '清货-紧急' then '清货-紧急'
                    end                                  as clearance_tags,
                    case
                        when global_tags regexp '不合规-'
                            then regexp_substr(global_tags, '不合规-[^,|，]+')
                    end                                  as non_compliant_tags,
                    max_sku,
                    max_local_name,
                    max_spu,
                    max_tag_name,
                    max_product_dev_time,
                    max_brand_name,
                    max_category_name,
                    max_product_developer,
                    max_cg_box_pcs,
                    max_cg_price,
                    max_cg_transport_costs,
                    new_old_product
    from etl_datasync.ops_rpt_listing_prod_basic_data
    where length(seller_sku) between 5 and 10
)
select ppbd.year_week,
       ppbd.week_start,
       ppbd.week_end,
       ppbd.country_category,
       ppbd.seller_name_new,
       ppbd.seller_name,
       ppbd.country,
       ppbd.seller_sku_adj,
       ppbd.local_sku,
       lpbd.sales_team_1,
       lpbd.principal,
       lpbd.global_tags,
       lpbd.clearance_tags,
       lpbd.non_compliant_tags,
       lpbd.max_spu,
       lpbd.max_sku,
       lpbd.max_local_name,
       lpbd.max_category_name,
       lpbd.max_brand_name,
       lpbd.new_old_product,
       lpbd.max_product_dev_time,
       lpbd.avg_price_cny,
       lpbd.onsale_sites,
       lpbd.unsale_sites,
       lpbd.sales_status,
       ppbd.avg_daily_volume_category,
       ppbd.last_week_avg_daily_volume_category,
       coalesce(spbd.abcd_category, 'E')           as abcd_category,
       spbd.gp_margin_range,
       qbd.pre_2q_predict_abcd_category,
       qbd.pre_1q_predict_abcd_category,
       qbd.category_changes,
       coalesce(ppbd.predict_abcd_category, 'E')   as predict_abcd_category,
       coalesce(ubd.pre_1m_predict_abcd_category, 'E') as pre_1m_predict_abcd_category,
       case
           when ppbd.avg_daily_volume >= 1 and ppbd.predict_profit_margin >= 0.10 then 0
           else 1
           end                                     as is_predict_abc,
       lpbd.max_tag_name,
       lpbd.max_cg_box_pcs,
       lpbd.max_cg_price,
       lpbd.max_cg_transport_costs,
       fsbd.receiving_cnt,
       fsbd.min_receiving_time,
       fsbd.days_since_launch,
       fsbd.since_launch_range,
       fsbd.max_receiving_time,
       fsbd.days_latest_delivery,
       fsbd.delivery_time_range,
       case
           when lpbd.new_old_product = '新品' and fsbd.days_latest_delivery >= 90
               and fsbd.receiving_cnt <= 1 then '新品未补货'
           else '已补货'
           end                                     as new_is_replenishment,
       ppbd.concat_price,
       ppbd.concat_rank,
       ppbd.concat_reviews_count,
       ppbd.concat_avg_star,
       ppbd.week_days,
       ppbd.afn_fulfillable_quantity_not_zero_days,
       ppbd.avg_daily_volume,
       ppbd.volume,
       ppbd.last_week_volume,
       ppbd.volume_diff,
       ppbd.amount,
       ppbd.amount_tax,
       ppbd.last_week_amount,
       ppbd.amount_diff,
       ppbd.net_amount,
       ppbd.order_items,
       spbd.total_sales_amount,
       spbd.gross_profit,
       spbd.last_week_gross_profit,
       spbd.wk_profit_diff,
       spbd.profit_margin,
       ppbd.predict_gross_profit,
       ppbd.predict_gross_profit_adj,
       ppbd.predict_profit_margin,
       ppbd.predict_profit_margin_adj,
       ppbd.profit_margin_category,
       ppbd.return_goods_count,
       ppbd.return_amount,
       ppbd.return_proportion,
       ppbd.refund_proportion,
       ppbd.spend,
       ppbd.acos,
       ppbd.acoas,
       ppbd.ctr,
       ppbd.ad_sales_amount,
       ppbd.ad_order_quantity,
       ppbd.ad_order_proportion,
       ppbd.ad_cvr,
       ppbd.impressions,
       ppbd.clicks,
       ppbd.sessions_total,
       ppbd.nature_cvr,
       ppbd.sales_30,
       ppbd.sales_60,
       lfd.last_week_filtrate
from 产品表现_站点_周维度 as ppbd
left join listing_产品管理_站点 as lpbd
  on ppbd.seller_sku_adj = lpbd.seller_sku
 and ppbd.seller_name_new = lpbd.seller_name_new
 and ppbd.country_category = lpbd.country_category
 and ppbd.country = lpbd.marketplace
 and ppbd.local_sku = lpbd.max_sku
left join etl_datasync.ops_rpt_fba_shipment_basic_data as fsbd
  on ppbd.seller_sku_adj = fsbd.msku
 and ppbd.seller_name_new = fsbd.seller_name_new
 and ppbd.country_category = fsbd.country_category
left join etl_datasync.ops_weekly_rpt_site_settlement_profit_basic_data as spbd
  on ppbd.seller_sku_adj = spbd.seller_sku_adj
 and ppbd.seller_name_new = spbd.seller_name_new
 and ppbd.country_category = spbd.country_category
 and ppbd.country = spbd.country
 and spbd.year_week = ppbd.year_week
left join etl_datasync.ops_quarter_rpt_prod_perf_basic_data_site as qbd
  on ppbd.seller_sku_adj = qbd.seller_sku_adj
 and ppbd.seller_name_new = qbd.seller_name_new
 and ppbd.country_category = qbd.country_category
 and ppbd.country = qbd.country
left join (
    select y_month,
           country_category,
           seller_name_new,
           seller_name,
           country,
           seller_sku_adj,
           asin,
           local_sku,
           predict_profit_margin as pre_1m_predict_profit_margin,
           predict_abcd_category as pre_1m_predict_abcd_category
    from etl_datasync.ops_monthly_rpt_site_prod_perf_basic_data
    where y_month = date_format(date_sub(curdate(), interval 1 month), '%Y-%m')
) as ubd
  on ppbd.seller_sku_adj = ubd.seller_sku_adj
 and ppbd.seller_name_new = ubd.seller_name_new
 and ppbd.country_category = ubd.country_category
 and ppbd.country = ubd.country
left join (
    select year_week,
           country_category,
           seller_name_new,
           seller_name,
           country,
           seller_sku_adj,
           max_sku,
           filtrate as last_week_filtrate
    from dws_datasync.ops_weekly_rpt_prod_perf_sites_data
    where year_week = yearweek(date_sub(curdate(), interval 2 week), 1)
) as lfd
  on ppbd.seller_sku_adj = lfd.seller_sku_adj
 and ppbd.seller_name_new = lfd.seller_name_new
 and ppbd.country_category = lfd.country_category
 and ppbd.country = lfd.country;
-- Step 2：Step 1 + FBA 库存 + 补货建议
drop temporary table if exists etl_datasync.tmp_weekly_site_step2;
create temporary table etl_datasync.tmp_weekly_site_step2 as
select s1.*,
       fbd.total,
       fbd.total_price,
       fbd.available_total,
       fbd.available_total_price,
       fbd.afn_fulfillable_quantity,
       fbd.reserved_fc_transfers,
       fbd.reserved_fc_processing,
       fbd.reserved_customerorders,
       fbd.afn_unsellable_quantity,
       fbd.afn_inbound_receiving_quantity,
       fbd.stock_up_num,
       fbd.afn_researching_quantity,
       fbd.inv_age_0_3_days,
       fbd.inv_age_0_3_price,
       fbd.inv_age_3_6_days,
       fbd.inv_age_3_6_price,
       fbd.inv_age_6_9_days,
       fbd.inv_age_6_9_price,
       fbd.inv_age_9_12_days,
       fbd.inv_age_9_12_price,
       fbd.inv_age_over_12_days,
       fbd.inv_age_over_12_price,
       fbd.lowerlibrary_ages_days,
       fbd.lowerlibrary_ages_price,
       fbd.superlibrary_ages_days,
       fbd.superlibrary_ages_price,
       fbd.over_inv90_days,
       fbd.over_inv90_price,
       fbd.superlibrary_proportion,
       rbd.sc_quantity_local_valid,
       rbd.sc_quantity_purchase_shipping,
       rbd.sc_quantity_purchase_plan,
       rbd.sc_quantity_local_qc,
       rbd.local_quantity
from etl_datasync.tmp_weekly_site_step1 as s1
left join etl_datasync.ops_weekly_rpt_fba_inv_detail_basic_data as fbd
  on s1.seller_sku_adj = fbd.seller_sku_adj
 and s1.seller_name_new = fbd.seller_name_new
 and s1.country_category = fbd.country_category
 and s1.year_week = fbd.dt_week
left join etl_datasync.ops_weekly_rpt_replenish_sug_basic_data as rbd
  on s1.seller_sku_adj = rbd.seller_sku_adj
 and s1.seller_name_new = rbd.seller_name_new
 and s1.country_category = rbd.country_category
 and s1.year_week = rbd.dt_week;
-- Step 3：Step 2 + 物流天数
drop temporary table if exists etl_datasync.tmp_weekly_site_step3;
create temporary table etl_datasync.tmp_weekly_site_step3 as
select s2.*,
       coalesce(ist_country.earliest_ship_time, ist_eu.earliest_ship_time) as earliest_ship_time,
       coalesce(ist_country.channel_abbrev, ist_eu.channel_abbrev)         as channel_abbrev,
       coalesce(ist_country.logistics_est_days, ist_eu.logistics_est_days) as logistics_est_days,
       case
           when coalesce(ist_country.earliest_ship_time, ist_eu.earliest_ship_time) is null
               then null
           else date_add(coalesce(ist_country.earliest_ship_time, ist_eu.earliest_ship_time),
                         interval coalesce(ist_country.logistics_est_days, ist_eu.logistics_est_days) day)
           end                                                             as expected_delivery_time
from etl_datasync.tmp_weekly_site_step2 as s2
left join etl_datasync.ops_rpt_logi_est_days_data as ist_country
  on s2.seller_name_new = ist_country.seller_name_new
 and s2.seller_sku_adj = ist_country.msku
 and s2.country_category = ist_country.country_category
left join etl_datasync.ops_rpt_logi_est_days_data as ist_eu
  on s2.seller_name_new = ist_eu.seller_name_new
 and s2.seller_sku_adj = ist_eu.msku
 and ist_eu.country_category = '欧洲站'
 and s2.country_category in ('英国站', '欧洲站')
 and ist_country.seller_name_new is null;
-- Step 4：最终计算 + 产品生命周期，写回原目标表
# insert into dws_datasync.ops_weekly_rpt_prod_perf_sites_data
with 计算字段 as (
    select *,
           case
               when volume > 0 or (coalesce(local_quantity, 0) + coalesce(total, 0)) > 0 then '1'
               else '0'
               end as filtrate,
           coalesce(local_quantity + total, 0)                            as fba_local_quantity,
           (max_cg_price + max_cg_transport_costs) * local_quantity       as local_cost,
           coalesce(sales_30, 0)                                          as sales_30_coalesce,
           coalesce(sales_60, 0)                                          as sales_60_coalesce,
           row_number() over (partition by year_week, sales_team_1
                              order by volume_diff)                       as rk_volume_diff,
           case
               when available_total > 0 and (volume = 0 or afn_fulfillable_quantity_not_zero_days = 0) then '99999'
               when available_total > 0 and (volume > 0 and afn_fulfillable_quantity_not_zero_days > 0)
                   then available_total / (volume / afn_fulfillable_quantity_not_zero_days)
               when available_total = 0 then 0
               end                                                        as available_salable_days,
           case
               when (coalesce(local_quantity, 0) + coalesce(total, 0)) > 0
                    and (volume = 0 or afn_fulfillable_quantity_not_zero_days = 0) then '99999'
               when (coalesce(local_quantity, 0) + coalesce(total, 0)) > 0
                    and (volume > 0 and afn_fulfillable_quantity_not_zero_days > 0)
                   then (local_quantity + total) / (volume / afn_fulfillable_quantity_not_zero_days)
               when (coalesce(local_quantity, 0) + coalesce(total, 0)) = 0 then 0
               end                                                        as fba_local_salable_days,
           superlibrary_ages_days / nullif(avg_daily_volume, 0)            as overdue_prod_sal_days,
           inv_age_6_9_days / nullif(avg_daily_volume, 0)                  as `6_9m_prod_sal_days`,
           inv_age_9_12_days / nullif(avg_daily_volume, 0)                 as `9_12m_prod_sal_days`,
           inv_age_over_12_days / nullif(avg_daily_volume, 0)              as `12m_plus_prod_sal_days`,
           case
               when lowerlibrary_ages_days > 0 and superlibrary_ages_days = 0 then '0-6个月(不含超库龄)'
               when lowerlibrary_ages_days > 0 and superlibrary_ages_days > 0 then '0-6个月(含超库龄)'
               when lowerlibrary_ages_days = 0 and superlibrary_ages_days > 0 then '6个月以上'
               else '无库龄段数据'
               end                                                        as aging_range
    from etl_datasync.tmp_weekly_site_step3
),
汇总字段 as (
    select year_week,
           week_start,
           week_end,
           filtrate,
           coalesce(last_week_filtrate, 0) as last_week_filtrate,
           country_category,
           seller_name_new,
           seller_name,
           country,
           seller_sku_adj,
           sales_team_1,
           principal,
           global_tags,
           clearance_tags,
           non_compliant_tags,
           max_spu,
           max_sku,
           max_local_name,
           max_category_name,
           new_old_product,
           max_product_dev_time,
           avg_price_cny,
           onsale_sites,
           unsale_sites,
           sales_status,
           avg_daily_volume_category,
           last_week_avg_daily_volume_category,
           abcd_category,
           gp_margin_range,
           pre_2q_predict_abcd_category,
           pre_1q_predict_abcd_category,
           category_changes,
           predict_abcd_category,
           predict_profit_margin_adj,
           profit_margin_category,
           pre_1m_predict_abcd_category,
           is_predict_abc,
           max_tag_name,
           max_brand_name,
           max_cg_box_pcs,
           max_cg_price,
           max_cg_transport_costs,
           receiving_cnt,
           min_receiving_time,
           days_since_launch,
           since_launch_range,
           max_receiving_time,
           days_latest_delivery,
           delivery_time_range,
           new_is_replenishment,
           concat_price,
           concat_rank,
           concat_reviews_count,
           concat_avg_star,
           week_days,
           afn_fulfillable_quantity_not_zero_days,
           avg_daily_volume,
           volume,
           last_week_volume,
           volume_diff,
           rk_volume_diff,
           amount,
           amount_tax,
           last_week_amount,
           amount_diff,
           net_amount,
           order_items,
           total_sales_amount,
           gross_profit,
           last_week_gross_profit,
           wk_profit_diff,
           profit_margin,
           predict_gross_profit,
           predict_gross_profit_adj,
           predict_profit_margin,
           return_goods_count,
           return_amount,
           return_proportion,
           refund_proportion,
           spend,
           acos,
           acoas,
           ctr,
           ad_sales_amount,
           ad_order_quantity,
           ad_order_proportion,
           ad_cvr,
           impressions,
           clicks,
           sessions_total,
           nature_cvr,
           total,
           total_price,
           available_total,
           afn_fulfillable_quantity,
           reserved_fc_transfers,
           reserved_fc_processing,
           reserved_customerorders,
           afn_unsellable_quantity,
           afn_inbound_receiving_quantity,
           stock_up_num,
           afn_researching_quantity,
           sc_quantity_local_valid,
           sc_quantity_purchase_shipping,
           sc_quantity_purchase_plan,
           sc_quantity_local_qc,
           local_quantity,
           local_cost,
           available_total_price,
           fba_local_quantity,
           (max_cg_price + max_cg_transport_costs) * local_quantity + total_price as fba_local_cost,
           sales_30,
           sales_60,
           available_total / nullif(sales_30_coalesce, 0)                         as amz_inv_sales_ratio,
           (local_quantity + total) / nullif(sales_30_coalesce, 0)                as fba_local_inv_sales_ratio,
           fba_local_salable_days,
           case
               when fba_local_salable_days = 0 and fba_local_salable_days is not null then '可售天数0天'
               when fba_local_salable_days > 0  and fba_local_salable_days < 30   then '可售天数30天内'
               when fba_local_salable_days >= 30 and fba_local_salable_days < 60   then '可售天数60天内'
               when fba_local_salable_days >= 60 and fba_local_salable_days < 90   then '可售天数90天内'
               when fba_local_salable_days >= 90 and fba_local_salable_days < 180  then '可售天数180天内'
               when fba_local_salable_days >= 180 and fba_local_salable_days < 270 then '可售天数270天内'
               when fba_local_salable_days >= 270 and fba_local_salable_days < 360 then '可售天数360天内'
               when fba_local_salable_days >= 360 then '可售天数360天以上'
               else ''
               end as fba_local_salable_days_range,
           available_salable_days,
           case
               when available_salable_days = 0 and available_salable_days is not null then '可售天数0天'
               when available_salable_days > 0  and available_salable_days < 30   then '可售天数30天内'
               when available_salable_days >= 30 and available_salable_days < 60   then '可售天数60天内'
               when available_salable_days >= 60 and available_salable_days < 90   then '可售天数90天内'
               when available_salable_days >= 90 and available_salable_days < 180  then '可售天数180天内'
               when available_salable_days >= 180 and available_salable_days < 270 then '可售天数270天内'
               when available_salable_days >= 270 and available_salable_days < 360 then '可售天数360天内'
               when available_salable_days >= 360 then '可售天数360天以上'
               else ''
               end as available_salable_days_range,
           coalesce(inv_age_0_3_days, 0)         as inv_age_0_3_days,
           coalesce(inv_age_0_3_price, 0)        as inv_age_0_3_price,
           coalesce(inv_age_3_6_days, 0)         as inv_age_3_6_days,
           coalesce(inv_age_3_6_price, 0)        as inv_age_3_6_price,
           coalesce(inv_age_6_9_days, 0)         as inv_age_6_9_days,
           coalesce(inv_age_6_9_price, 0)        as inv_age_6_9_price,
           coalesce(inv_age_9_12_days, 0)        as inv_age_9_12_days,
           coalesce(inv_age_9_12_price, 0)       as inv_age_9_12_price,
           coalesce(inv_age_over_12_days, 0)     as inv_age_over_12_days,
           coalesce(inv_age_over_12_price, 0)    as inv_age_over_12_price,
           coalesce(lowerlibrary_ages_days, 0)   as lowerlibrary_ages_days,
           coalesce(lowerlibrary_ages_price, 0)  as lowerlibrary_ages_price,
           coalesce(superlibrary_ages_days, 0)   as superlibrary_ages_days,
           coalesce(superlibrary_ages_price, 0)  as superlibrary_ages_price,
           coalesce(over_inv90_days, 0)          as over_inv90_days,
           coalesce(over_inv90_price, 0)         as over_inv90_price,
           superlibrary_proportion,
           overdue_prod_sal_days,
           `6_9m_prod_sal_days`,
           `9_12m_prod_sal_days`,
           `12m_plus_prod_sal_days`,
           aging_range,
           earliest_ship_time,
           channel_abbrev,
           logistics_est_days,
           expected_delivery_time
    from 计算字段
),
产品生命周期 as (
    select country_category, seller_name_new, seller_sku, product_lifecycle_stage
    from dws_datasync.dws_product_lifecycle_market_v2
    where create_time = (select max(create_time) from dws_datasync.dws_product_lifecycle_market_v2)
)
select wd.*,
       case
           when available_salable_days > 60
                or datediff(expected_delivery_time, week_end) < available_salable_days
               then '不会缺货'
           else case
                    when stock_up_num = 0 and local_quantity = 0 then '缺货未补货'
                    when stock_up_num > 0 or local_quantity > 0 then '缺货已补货'
               end
           end as stockout_status,
       pl.product_lifecycle_stage,
       case
            when over_inv90_days > 0 and sales_60 = 0 then '是：库龄90天+且近60天不出单'
           else '否'
           end as clearance_status,
       now() as create_time
from 汇总字段 as wd
left join 产品生命周期 as pl
  on wd.country_category = pl.country_category
 and wd.seller_name_new = pl.seller_name_new
 and wd.seller_sku_adj = pl.seller_sku
where year_week = @s_week
order by wd.sales_team_1 desc, cast(wd.rk_volume_diff as signed);


