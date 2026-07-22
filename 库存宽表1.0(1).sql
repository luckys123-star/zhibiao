-- ============================================================
-- 库存宽表1.0
-- 目标：重写 dws_库存宽表 日更新逻辑，避免千万级产品表现表全表扫描
-- 粒度：数据日期 / 店铺 / 站点 / 仓库 / SKU / MSKU
-- 调度：每日早上7点执行
--
-- 性能原则：
--   1. 先生成 tmp_dim / tmp_dim_asin 小维度集合，再用小维度过滤大表。
--   2. 产品表现仅取近90天，且仅取当前库存维度 + 跟卖相关原始品牌ASIN。
--   3. 订单利润仅取补货候选SKU近90天订单。
--   4. 去年同期环比仅取补货候选SKU、去年同期前后90天窗口。
--   5. FBA/本地仓数量取近2天内每个维度最新快照，避免直接取2天导致重复放大。
--
-- 建议索引（如线上仍慢，优先检查这些索引是否存在）：
--   etl_dispose_lx_statistics_product_performance_2026:
--     (country_category, seller_name_new, seller_sku_adj, start_date)
--     (asin, seller_name_new, start_date)
--   etl_dispose_lx_statistics_product_performance_2024/2025:
--     (country_category, seller_name_new, seller_sku_adj, start_date)
--   etl_dispose_lx_storage_fba_warehouse_detail:
--     (create_time, country_category, seller_name_new, seller_sku_adj)
--   etl_dispose_lx_replenishment_suggest_restocking:
--     (country_category, seller_name_new, seller_sku_adj, create_time)
--   dwd_datasync.lx_sales_mws_orders_detail:
--     (country_category, seller_name_new, seller_sku_adj, create_time)
--
-- 说明：
--   文件名按需求改为 库存宽表1.0.sql。
--   目标表仍使用现有 `dws_库存宽表`。如需新表，请统一替换目标表名。
-- ============================================================

DROP PROCEDURE IF EXISTS dws_datasync.sp_库存宽表;
DELIMITER //

CREATE PROCEDURE dws_datasync.sp_库存宽表()
BEGIN
    DECLARE v_data_date DATE DEFAULT CURDATE();
    DECLARE v_proc_name VARCHAR(255) DEFAULT 'sp_库存宽表';
    DECLARE v_log_id INT DEFAULT NULL;
    DECLARE v_record_count INT DEFAULT 0;
    DECLARE v_error_msg TEXT;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS CONDITION 1 v_error_msg = MESSAGE_TEXT;

        IF v_log_id IS NOT NULL THEN
            UPDATE etl_datasync.etl_execution_log
            SET status = 'error',
                end_time = NOW()
            WHERE id = v_log_id;

            INSERT INTO etl_datasync.etl_error_log
                (proc_name, error_time, error_message, execution_log_id)
            VALUES
                (v_proc_name, NOW(), v_error_msg, v_log_id);
        END IF;
    END;

    INSERT INTO etl_datasync.etl_execution_log
        (proc_name, start_time, status)
    VALUES
        (v_proc_name, NOW(), 'started');

    SET v_log_id = LAST_INSERT_ID();

    -- ============================================================
    -- 0. 清理目标数据
    -- ============================================================
    DELETE FROM `dws_库存宽表`
    WHERE `数据日期` = v_data_date;

    DELETE FROM `dws_库存宽表`
    WHERE `数据日期` < v_data_date - INTERVAL 365 DAY;

    -- ============================================================
    -- 1. FBA仓库粒度基础数据：近2天内按维度取最新快照
    -- ============================================================
    DROP TEMPORARY TABLE IF EXISTS tmp_fba_latest_key;
    CREATE TEMPORARY TABLE tmp_fba_latest_key AS
    SELECT
        f.`name`,
        f.country_category,
        f.seller_name_new,
        f.seller_sku_adj,
        f.asin,
        MAX(f.create_time) AS max_create_time
    FROM etl_datasync.etl_dispose_lx_storage_fba_warehouse_detail AS f
    WHERE f.create_time >= v_data_date - INTERVAL 1 DAY
      AND f.create_time <  v_data_date + INTERVAL 1 DAY
      AND f.seller_name_new NOT IN ('gushili', 'Joochees', 'ouhao', 'pingter')
      AND f.seller_sku_adj IS NOT NULL
    GROUP BY
        f.`name`, f.country_category, f.seller_name_new, f.seller_sku_adj, f.asin;

    ALTER TABLE tmp_fba_latest_key
        ADD INDEX idx_key (`name`(64), country_category(3), seller_name_new(64), seller_sku_adj(64), asin(30), max_create_time);

    DROP TEMPORARY TABLE IF EXISTS tmp_fba_wh;
    CREATE TEMPORARY TABLE tmp_fba_wh AS
    SELECT
        f.`name`,
        f.country_category,
        f.seller_name_new,
        MAX(f.seller_sku) AS seller_sku,
        f.seller_sku_adj,
        f.asin,
        COALESCE(MAX(NULLIF(f.sku, '')), '') AS sku,
        SUM(COALESCE(f.total, 0)) AS total,
        SUM(COALESCE(f.available_total, 0)) AS available_total,
        SUM(COALESCE(f.afn_fulfillable_quantity, 0)) AS afn_fulfillable_quantity,
        SUM(COALESCE(f.stock_up_num, 0)) AS stock_up_num,
        SUM(COALESCE(f.afn_unsellable_quantity, 0)) AS afn_unsellable_quantity,
        MAX(COALESCE(f.cg_price, 0)) AS cg_price,
        MAX(COALESCE(f.cg_transport_costs, 0)) AS cg_transport_costs
    FROM etl_datasync.etl_dispose_lx_storage_fba_warehouse_detail AS f
    JOIN tmp_fba_latest_key AS k
      ON f.`name` = k.`name`
     AND f.country_category = k.country_category
     AND f.seller_name_new = k.seller_name_new
     AND f.seller_sku_adj = k.seller_sku_adj
     AND COALESCE(f.asin, '') = COALESCE(k.asin, '')
     AND f.create_time = k.max_create_time
    GROUP BY f.`name`, f.country_category, f.seller_name_new, f.seller_sku_adj, f.asin;

    ALTER TABLE tmp_fba_wh
        ADD INDEX idx_wh_dim (country_category(3), seller_name_new(64), seller_sku_adj(64)),
        ADD INDEX idx_wh_asin (asin(30)),
        ADD INDEX idx_wh_seller_sku (seller_sku(64));

    DROP TEMPORARY TABLE IF EXISTS tmp_dim;
    CREATE TEMPORARY TABLE tmp_dim AS
    SELECT DISTINCT
        country_category,
        seller_name_new,
        seller_sku_adj
    FROM tmp_fba_wh;

    ALTER TABLE tmp_dim
        ADD INDEX idx_dim (country_category(3), seller_name_new(64), seller_sku_adj(64));

    DROP TEMPORARY TABLE IF EXISTS tmp_dim_asin;
    CREATE TEMPORARY TABLE tmp_dim_asin AS
    SELECT DISTINCT asin
    FROM tmp_fba_wh
    WHERE asin IS NOT NULL AND asin <> '';

    ALTER TABLE tmp_dim_asin ADD INDEX idx_dim_asin (asin(30));

    -- ============================================================
    -- 2. 当天listing和产品资料：仅取当前维度
    -- ============================================================
    DROP TEMPORARY TABLE IF EXISTS tmp_listing_current;
    CREATE TEMPORARY TABLE tmp_listing_current AS
    SELECT
        d.country_category,
        d.seller_name_new,
        d.seller_sku_adj,
        l.seller_name,
        l.marketplace,
        l.status,
        l.seller_name_ue,
        l.local_sku,
        l.local_name,
        l.fnsku,
        l.asin,
        l.global_tags,
        l.principal,
        l.sales_team_1,
        l.seller_brand
    FROM tmp_dim AS d
    JOIN etl_datasync.etl_dispose_lx_sales_mws_listing AS l
      ON d.country_category = l.country_category
     AND d.seller_name_new = l.seller_name_new
     AND d.seller_sku_adj = l.seller_sku
    WHERE l.create_time >= v_data_date
      AND l.create_time <  v_data_date + INTERVAL 1 DAY;

    ALTER TABLE tmp_listing_current
        ADD INDEX idx_lc_dim (country_category(3), seller_name_new(64), seller_sku_adj(64)),
        ADD INDEX idx_lc_sku (seller_sku_adj(64), seller_name_new(64), local_sku(64), marketplace(20));

    DROP TEMPORARY TABLE IF EXISTS tmp_product_info;
    CREATE TEMPORARY TABLE tmp_product_info AS
    SELECT
        d.country_category,
        d.seller_name_new,
        d.seller_sku_adj,
        MAX(pi.brand_name) AS max_brand_name,
        MAX(pi.tag_name) AS max_tag_name,
        MAX(pi.cg_price) AS max_cg_price,
        MAX(pi.cg_transport_costs) AS max_cg_transport_costs,
        MAX(pi.cg_box_pcs) AS max_cg_box_pcs
    FROM tmp_dim AS d
    LEFT JOIN tmp_listing_current AS l
      ON d.country_category = l.country_category
     AND d.seller_name_new = l.seller_name_new
     AND d.seller_sku_adj = l.seller_sku_adj
    LEFT JOIN etl_datasync.etl_dispose_lx_product_local_product_info AS pi
      ON d.seller_sku_adj = pi.seller_sku
     AND d.seller_name_new = pi.seller_name_new
     AND l.local_sku = pi.local_sku
     AND l.marketplace = pi.country
     AND pi.create_time >= v_data_date
     AND pi.create_time <  v_data_date + INTERVAL 1 DAY
    GROUP BY d.country_category, d.seller_name_new, d.seller_sku_adj;

    ALTER TABLE tmp_product_info
        ADD INDEX idx_pi_dim (country_category(3), seller_name_new(64), seller_sku_adj(64));

    DROP TEMPORARY TABLE IF EXISTS tmp_listing_info;
    CREATE TEMPORARY TABLE tmp_listing_info AS
    SELECT
        d.country_category,
        d.seller_name_new,
        d.seller_sku_adj,
        MAX(l.seller_name_ue) AS seller_name_ue,
        GROUP_CONCAT(DISTINCT CONCAT(l.marketplace, ':', l.status) SEPARATOR ',') AS marketplace_status,
        GROUP_CONCAT(DISTINCT l.seller_name SEPARATOR ',') AS seller_name_concat,
        GROUP_CONCAT(DISTINCT CASE WHEN l.status = '在售' THEN l.marketplace END SEPARATOR ',') AS onsale_sites,
        GROUP_CONCAT(DISTINCT CASE WHEN l.status <> '在售' AND l.status IS NOT NULL THEN l.marketplace END SEPARATOR ',') AS unsale_sites,
        CASE
            WHEN MAX(CASE WHEN l.status = '在售' THEN 1 ELSE 0 END) = 1
             AND MAX(CASE WHEN l.status <> '在售' AND l.status IS NOT NULL THEN 1 ELSE 0 END) = 0 THEN '在售'
            WHEN MAX(CASE WHEN l.status = '在售' THEN 1 ELSE 0 END) = 0 THEN '未售'
            ELSE '部分在售'
        END AS sales_status,
        '汇总' AS marketplace_concat,
        CASE
            WHEN d.country_category = '北美站' THEN CONCAT(MAX(l.seller_name_ue), '-US')
            WHEN d.country_category = '英国站' THEN CONCAT(MAX(l.seller_name_ue), '-UK')
            ELSE CONCAT(MAX(l.seller_name_ue), '-DE')
        END AS seller_name_copy,
        MAX(l.local_sku) AS max_sku,
        MAX(l.local_name) AS max_local_name,
        GROUP_CONCAT(DISTINCT l.global_tags SEPARATOR ',') AS global_tags,
        MAX(l.principal) AS principal,
        MAX(l.sales_team_1) AS sales_team_1,
        MAX(l.fnsku) AS max_fnsku,
        MAX(l.asin) AS max_asin
    FROM tmp_dim AS d
    LEFT JOIN tmp_listing_current AS l
      ON d.country_category = l.country_category
     AND d.seller_name_new = l.seller_name_new
     AND d.seller_sku_adj = l.seller_sku_adj
    GROUP BY d.country_category, d.seller_name_new, d.seller_sku_adj;

    ALTER TABLE tmp_listing_info
        ADD INDEX idx_li_dim (country_category(3), seller_name_new(64), seller_sku_adj(64));

    -- ============================================================
    -- 3. 跟卖ASIN映射：仅取当前库存涉及的ASIN
    -- ============================================================
    DROP TEMPORARY TABLE IF EXISTS tmp_self_brand_asin;
    CREATE TEMPORARY TABLE tmp_self_brand_asin AS
    SELECT DISTINCT
        store.`店铺名` AS shop_name,
        store.`品牌名` AS brand_name,
        l.asin
    FROM tmp_dim_asin AS a
    JOIN etl_datasync.etl_dispose_lx_sales_mws_listing AS l
      ON a.asin = l.asin
    JOIN opt_db.store_brand_relation AS store
      ON store.`店铺名` = SUBSTRING_INDEX(l.seller_name, '-', 1)
     AND store.`品牌名` = l.seller_brand
    WHERE l.asin IS NOT NULL AND l.asin <> ''
      AND l.create_time >= v_data_date
      AND l.create_time <  v_data_date + INTERVAL 1 DAY;

    ALTER TABLE tmp_self_brand_asin
        ADD INDEX idx_sba_asin (asin(30)),
        ADD INDEX idx_sba_shop_asin (shop_name(64), asin(30));

    DROP TEMPORARY TABLE IF EXISTS tmp_asin_to_self_store;
    CREATE TEMPORARY TABLE tmp_asin_to_self_store AS
    SELECT asin, MAX(shop_name) AS self_store_name
    FROM tmp_self_brand_asin
    GROUP BY asin;

    ALTER TABLE tmp_asin_to_self_store
        ADD INDEX idx_atss_asin (asin(30)),
        ADD INDEX idx_atss_store (self_store_name(64));

    -- ============================================================
    -- 4. 产品表现：仅近90天 + 当前维度/跟卖原始ASIN
    -- ============================================================
    DROP TEMPORARY TABLE IF EXISTS tmp_pp_target_90d;
    CREATE TEMPORARY TABLE tmp_pp_target_90d AS
    SELECT
        p.start_date,
        p.country_category,
        p.seller_name_new,
        p.seller_sku_adj,
        p.asin,
        COALESCE(p.volume, 0) AS volume,
        COALESCE(p.amount, 0) AS amount,
        COALESCE(p.predict_gross_profit, 0) AS predict_gross_profit,
        COALESCE(p.afn_fulfillable_quantity, 0) AS afn_fulfillable_quantity
    FROM tmp_dim AS d
    JOIN etl_datasync.etl_dispose_lx_statistics_product_performance_2026 AS p
      ON d.country_category = p.country_category
     AND d.seller_name_new = p.seller_name_new
     AND d.seller_sku_adj = p.seller_sku_adj
    WHERE p.start_date >= v_data_date - INTERVAL 90 DAY
      AND p.start_date <  v_data_date + INTERVAL 1 DAY;

    -- 不给百万级明细临时表建索引：后续仅做一次性聚合，索引构建成本通常高于收益。

    DROP TEMPORARY TABLE IF EXISTS tmp_pp_origin_90d;
    CREATE TEMPORARY TABLE tmp_pp_origin_90d AS
    SELECT
        p.start_date,
        p.country_category,
        p.seller_name_new,
        p.seller_sku_adj,
        p.asin,
        COALESCE(p.volume, 0) AS volume,
        COALESCE(p.amount, 0) AS amount,
        COALESCE(p.predict_gross_profit, 0) AS predict_gross_profit,
        COALESCE(p.afn_fulfillable_quantity, 0) AS afn_fulfillable_quantity
    FROM tmp_asin_to_self_store AS s
    JOIN etl_datasync.etl_dispose_lx_statistics_product_performance_2026 AS p
      ON s.asin = p.asin
     AND s.self_store_name = p.seller_name_new
    WHERE p.start_date >= v_data_date - INTERVAL 90 DAY
      AND p.start_date <  v_data_date + INTERVAL 1 DAY;

    -- 不给百万级跟卖原始明细临时表建索引：后续仅做一次性聚合，避免额外索引构建耗时。

    DROP TEMPORARY TABLE IF EXISTS tmp_prod_perf_sku_asin_metrics;
    CREATE TEMPORARY TABLE tmp_prod_perf_sku_asin_metrics AS
    SELECT
        t.country_category,
        t.seller_name_new,
        t.seller_sku_adj,
        t.asin,
        SUM(CASE WHEN t.start_date >= v_data_date - INTERVAL 90 DAY THEN t.volume ELSE 0 END) AS sales_90d,
        SUM(CASE WHEN t.start_date >= v_data_date - INTERVAL 30 DAY THEN t.volume ELSE 0 END) AS sales_30d,
        SUM(CASE WHEN t.start_date >= v_data_date - INTERVAL 14 DAY THEN t.volume ELSE 0 END) AS sales_14d,
        SUM(CASE WHEN t.start_date >= v_data_date - INTERVAL 7 DAY  THEN t.volume ELSE 0 END) AS sales_7d,
        SUM(CASE WHEN t.start_date >= v_data_date - INTERVAL 3 DAY  THEN t.volume ELSE 0 END) AS sales_3d,
        SUM(CASE WHEN t.start_date >= v_data_date - INTERVAL 30 DAY THEN t.amount ELSE 0 END) AS amount_30d,
        SUM(CASE WHEN t.start_date >= v_data_date - INTERVAL 14 DAY THEN t.amount ELSE 0 END) AS amount_14d,
        SUM(CASE WHEN t.start_date >= v_data_date - INTERVAL 7 DAY  THEN t.amount ELSE 0 END) AS amount_7d,
        SUM(CASE WHEN t.start_date >= v_data_date - INTERVAL 3 DAY  THEN t.amount ELSE 0 END) AS amount_3d,
        SUM(CASE WHEN t.start_date >= v_data_date - INTERVAL 30 DAY THEN t.predict_gross_profit ELSE 0 END) AS pprofit_30d,
        SUM(CASE WHEN t.start_date >= v_data_date - INTERVAL 14 DAY THEN t.predict_gross_profit ELSE 0 END) AS pprofit_14d,
        SUM(CASE WHEN t.start_date >= v_data_date - INTERVAL 7 DAY  THEN t.predict_gross_profit ELSE 0 END) AS pprofit_7d,
        SUM(CASE WHEN t.start_date >= v_data_date - INTERVAL 3 DAY  THEN t.predict_gross_profit ELSE 0 END) AS pprofit_3d
    FROM tmp_pp_target_90d AS t
    GROUP BY t.country_category, t.seller_name_new, t.seller_sku_adj, t.asin;

    ALTER TABLE tmp_prod_perf_sku_asin_metrics
        ADD INDEX idx_ppsam_dim (country_category(3), seller_name_new(64), seller_sku_adj(64)),
        ADD INDEX idx_ppsam_asin (asin(30), seller_name_new(64));

    DROP TEMPORARY TABLE IF EXISTS tmp_prod_perf_sku_metrics;
    CREATE TEMPORARY TABLE tmp_prod_perf_sku_metrics AS
    SELECT
        m.country_category,
        m.seller_name_new,
        m.seller_sku_adj,
        MAX(m.sales_90d) AS sales_90d,
        MAX(m.sales_30d) AS sales_30d,
        MAX(m.sales_14d) AS sales_14d,
        MAX(m.sales_7d) AS sales_7d,
        MAX(m.sales_3d) AS sales_3d,
        MAX(m.amount_30d) AS amount_30d,
        MAX(m.amount_14d) AS amount_14d,
        MAX(m.amount_7d) AS amount_7d,
        MAX(m.amount_3d) AS amount_3d,
        MAX(m.pprofit_30d) AS pprofit_30d,
        MAX(m.pprofit_14d) AS pprofit_14d,
        MAX(m.pprofit_7d) AS pprofit_7d,
        MAX(m.pprofit_3d) AS pprofit_3d,
        MAX(m.pprofit_30d) / NULLIF(MAX(m.amount_30d), 0) AS pprofit_ratio_30d,
        MAX(m.pprofit_14d) / NULLIF(MAX(m.amount_14d), 0) AS pprofit_ratio_14d,
        MAX(m.pprofit_7d)  / NULLIF(MAX(m.amount_7d), 0)  AS pprofit_ratio_7d,
        MAX(m.pprofit_3d)  / NULLIF(MAX(m.amount_3d), 0)  AS pprofit_ratio_3d
    FROM tmp_prod_perf_sku_asin_metrics AS m
    GROUP BY m.country_category, m.seller_name_new, m.seller_sku_adj;

    ALTER TABLE tmp_prod_perf_sku_metrics
        ADD INDEX idx_ppsm_dim (country_category(3), seller_name_new(64), seller_sku_adj(64));

    DROP TEMPORARY TABLE IF EXISTS tmp_origin_perf_sku_asin_metrics;
    CREATE TEMPORARY TABLE tmp_origin_perf_sku_asin_metrics AS
    SELECT
        t.country_category,
        t.seller_name_new,
        t.seller_sku_adj,
        t.asin,
        SUM(CASE WHEN t.start_date >= v_data_date - INTERVAL 30 DAY THEN t.volume ELSE 0 END) AS sales_30d,
        SUM(CASE WHEN t.start_date >= v_data_date - INTERVAL 14 DAY THEN t.volume ELSE 0 END) AS sales_14d,
        SUM(CASE WHEN t.start_date >= v_data_date - INTERVAL 7 DAY  THEN t.volume ELSE 0 END) AS sales_7d,
        SUM(CASE WHEN t.start_date >= v_data_date - INTERVAL 3 DAY  THEN t.volume ELSE 0 END) AS sales_3d
    FROM tmp_pp_origin_90d AS t
    GROUP BY t.country_category, t.seller_name_new, t.seller_sku_adj, t.asin;

    ALTER TABLE tmp_origin_perf_sku_asin_metrics
        ADD INDEX idx_opsam_dim (country_category(3), seller_name_new(64), seller_sku_adj(64)),
        ADD INDEX idx_opsam_asin_store (asin(30), seller_name_new(64));

    DROP TEMPORARY TABLE IF EXISTS tmp_origin_perf_sku_metrics;
    CREATE TEMPORARY TABLE tmp_origin_perf_sku_metrics AS
    SELECT
        m.country_category,
        m.seller_name_new,
        m.seller_sku_adj,
        MAX(m.sales_30d) AS sales_30d,
        MAX(m.sales_14d) AS sales_14d,
        MAX(m.sales_7d) AS sales_7d,
        MAX(m.sales_3d) AS sales_3d
    FROM tmp_origin_perf_sku_asin_metrics AS m
    GROUP BY m.country_category, m.seller_name_new, m.seller_sku_adj;

    ALTER TABLE tmp_origin_perf_sku_metrics
        ADD INDEX idx_opsm_dim (country_category(3), seller_name_new(64), seller_sku_adj(64));

    DROP TEMPORARY TABLE IF EXISTS tmp_origin_sales_all;
    CREATE TEMPORARY TABLE tmp_origin_sales_all AS
    SELECT
        s.asin,
        s.self_store_name,
        MAX(metrics.sales_3d) AS sales_3d,
        MAX(metrics.sales_7d) AS sales_7d,
        MAX(metrics.sales_14d) AS sales_14d,
        MAX(metrics.sales_30d) AS sales_30d
    FROM tmp_asin_to_self_store AS s
    LEFT JOIN tmp_origin_perf_sku_asin_metrics AS origin
      ON origin.asin = s.asin
     AND origin.seller_name_new = s.self_store_name
    LEFT JOIN tmp_origin_perf_sku_metrics AS metrics
      ON origin.country_category = metrics.country_category
     AND origin.seller_name_new = metrics.seller_name_new
     AND origin.seller_sku_adj = metrics.seller_sku_adj
    GROUP BY s.asin, s.self_store_name;

    ALTER TABLE tmp_origin_sales_all
        ADD INDEX idx_osa_asin_store (asin, self_store_name);

    DROP TEMPORARY TABLE IF EXISTS tmp_prod_perf_follow_origin;
    CREATE TEMPORARY TABLE tmp_prod_perf_follow_origin AS
    SELECT
        b.country_category,
        b.seller_name_new,
        b.seller_sku_adj,
        MAX(CASE WHEN self_asin.asin IS NOT NULL THEN 1 ELSE 0 END) AS fllow_flag,
        MAX(CASE WHEN self_asin.asin IS NULL THEN origin.sales_3d ELSE NULL END) AS origin_sales_3d,
        MAX(CASE WHEN self_asin.asin IS NULL THEN origin.sales_7d ELSE NULL END) AS origin_sales_7d,
        MAX(CASE WHEN self_asin.asin IS NULL THEN origin.sales_14d ELSE NULL END) AS origin_sales_14d,
        MAX(CASE WHEN self_asin.asin IS NULL THEN origin.sales_30d ELSE NULL END) AS origin_sales_30d
    FROM tmp_prod_perf_sku_asin_metrics AS b
    LEFT JOIN tmp_self_brand_asin AS self_asin
      ON b.seller_name_new = self_asin.shop_name
     AND b.asin = self_asin.asin
    LEFT JOIN tmp_origin_sales_all AS origin
      ON b.asin = origin.asin
     AND self_asin.asin IS NULL
    GROUP BY b.country_category, b.seller_name_new, b.seller_sku_adj;

    ALTER TABLE tmp_prod_perf_follow_origin
        ADD INDEX idx_pfo_dim (country_category(3), seller_name_new(64), seller_sku_adj(64));

    DROP TEMPORARY TABLE IF EXISTS tmp_salable_days;
    CREATE TEMPORARY TABLE tmp_salable_days AS
    SELECT
        t.country_category,
        t.seller_name_new,
        t.seller_sku_adj,
        COUNT(DISTINCT CASE WHEN t.start_date >= v_data_date - INTERVAL 90 DAY AND t.afn_fulfillable_quantity > 0 THEN t.start_date END) AS r_90d_salable_days,
        COUNT(DISTINCT CASE WHEN t.start_date >= v_data_date - INTERVAL 30 DAY AND t.afn_fulfillable_quantity > 0 THEN t.start_date END) AS r_30d_salable_days,
        COUNT(DISTINCT CASE WHEN t.start_date >= v_data_date - INTERVAL 14 DAY AND t.afn_fulfillable_quantity > 0 THEN t.start_date END) AS r_14d_salable_days,
        COUNT(DISTINCT CASE WHEN t.start_date >= v_data_date - INTERVAL 7 DAY  AND t.afn_fulfillable_quantity > 0 THEN t.start_date END) AS r_7d_salable_days,
        COUNT(DISTINCT CASE WHEN t.start_date >= v_data_date - INTERVAL 3 DAY  AND t.afn_fulfillable_quantity > 0 THEN t.start_date END) AS r_3d_salable_days
    FROM tmp_pp_target_90d AS t
    GROUP BY t.country_category, t.seller_name_new, t.seller_sku_adj;

    ALTER TABLE tmp_salable_days
        ADD INDEX idx_sd_dim (country_category(3), seller_name_new(64), seller_sku_adj(64));

    -- ============================================================
    -- 5. 库存MSKU汇总 / 本地仓库存
    -- ============================================================
    DROP TEMPORARY TABLE IF EXISTS tmp_fba_msku;
    CREATE TEMPORARY TABLE tmp_fba_msku AS
    SELECT
        country_category,
        seller_name_new,
        seller_sku_adj,
        SUM(total) AS total,
        SUM(available_total) AS available_total,
        SUM(stock_up_num) AS stock_up_num
    FROM tmp_fba_wh
    GROUP BY country_category, seller_name_new, seller_sku_adj;

    ALTER TABLE tmp_fba_msku
        ADD INDEX idx_fm_dim (country_category(3), seller_name_new(64), seller_sku_adj(64));

    DROP TEMPORARY TABLE IF EXISTS tmp_local_latest_key;
    CREATE TEMPORARY TABLE tmp_local_latest_key AS
    SELECT
        r.country_category,
        r.seller_name_new,
        r.seller_sku_adj,
        MAX(r.create_time) AS max_create_time
    FROM tmp_dim AS d
    JOIN etl_datasync.etl_dispose_lx_replenishment_suggest_restocking AS r
      ON d.country_category = r.country_category
     AND d.seller_name_new = r.seller_name_new
     AND d.seller_sku_adj = r.seller_sku_adj
    WHERE r.create_time >= v_data_date - INTERVAL 1 DAY
      AND r.create_time <  v_data_date + INTERVAL 1 DAY
    GROUP BY r.country_category, r.seller_name_new, r.seller_sku_adj;

    ALTER TABLE tmp_local_latest_key
        ADD INDEX idx_llk_dim (country_category(3), seller_name_new(64), seller_sku_adj(64), max_create_time);

    DROP TEMPORARY TABLE IF EXISTS tmp_local_warehouse;
    CREATE TEMPORARY TABLE tmp_local_warehouse AS
    SELECT
        r.country_category,
        r.seller_name_new,
        r.seller_sku_adj,
        MAX(COALESCE(r.sc_quantity_local_valid, 0)) AS sc_quantity_local_valid,
        MAX(COALESCE(r.sc_quantity_purchase_shipping, 0)) AS sc_quantity_purchase_shipping,
        MAX(COALESCE(r.sc_quantity_purchase_plan, 0)) AS sc_quantity_purchase_plan,
        MAX(COALESCE(r.sc_quantity_local_qc, 0)) AS sc_quantity_local_qc,
        MAX(COALESCE(r.local_quantity, 0)) AS local_quantity
    FROM etl_datasync.etl_dispose_lx_replenishment_suggest_restocking AS r
    JOIN tmp_local_latest_key AS k
      ON r.country_category = k.country_category
     AND r.seller_name_new = k.seller_name_new
     AND r.seller_sku_adj = k.seller_sku_adj
     AND r.create_time = k.max_create_time
    GROUP BY r.country_category, r.seller_name_new, r.seller_sku_adj;

    ALTER TABLE tmp_local_warehouse
        ADD INDEX idx_lw_dim (country_category(3), seller_name_new(64), seller_sku_adj(64));

    -- ============================================================
    -- 6. 基础标签 / 收货 / 分类
    -- ============================================================
    DROP TEMPORARY TABLE IF EXISTS tmp_receiving_label;
    CREATE TEMPORARY TABLE tmp_receiving_label AS
    SELECT
        d.country_category,
        d.seller_name_new,
        d.seller_sku_adj,
        MAX(STR_TO_DATE(NULLIF(f.receiving_time, ''), '%Y-%m-%d %H:%i:%s')) AS max_receiving_time,
        COUNT(DISTINCT CASE
            WHEN f.receiving_time IS NOT NULL
             AND f.receiving_time <> ''
             AND COALESCE(f.quantity_shipped, 0) <> 0
            THEN CONCAT(f.shipment_id, '|', f.msku, '|', f.store_name)
        END) AS receiving_cnt
    FROM tmp_dim AS d
    LEFT JOIN etl_datasync.etl_dispose_lx_fba_shipment AS f
      ON d.country_category = f.country_category
     AND d.seller_name_new = f.seller_name_new
     AND d.seller_sku_adj = f.msku
     AND f.receiving_time IS NOT NULL
     AND f.receiving_time <> ''
     AND COALESCE(f.quantity_received, 0) <> 0
    GROUP BY d.country_category, d.seller_name_new, d.seller_sku_adj;

    ALTER TABLE tmp_receiving_label
        ADD INDEX idx_rl_dim (country_category(3), seller_name_new(64), seller_sku_adj(64));

    DROP TEMPORARY TABLE IF EXISTS tmp_profit_label;
    CREATE TEMPORARY TABLE tmp_profit_label AS
    SELECT
        d.country_category,
        d.seller_name_new,
        d.seller_sku_adj,
        SUM(COALESCE(p.gross_profit, 0)) / NULLIF(SUM(COALESCE(p.total_sales_amount, 0)), 0) AS profit_margin,
        CASE
            WHEN SUM(COALESCE(p.gross_profit, 0)) / NULLIF(SUM(COALESCE(p.total_sales_amount, 0)), 0) >= 0.15 THEN 'A'
            WHEN SUM(COALESCE(p.gross_profit, 0)) / NULLIF(SUM(COALESCE(p.total_sales_amount, 0)), 0) >= 0.10 THEN 'B'
            WHEN SUM(COALESCE(p.gross_profit, 0)) / NULLIF(SUM(COALESCE(p.total_sales_amount, 0)), 0) >= 0.05 THEN 'C'
            WHEN SUM(COALESCE(p.gross_profit, 0)) / NULLIF(SUM(COALESCE(p.total_sales_amount, 0)), 0) >= 0.00 THEN 'D'
            ELSE 'E'
        END AS abcd_category,
        CASE
            WHEN SUM(COALESCE(p.gross_profit, 0)) / NULLIF(SUM(COALESCE(p.total_sales_amount, 0)), 0) >= 0.15 THEN '>=15%'
            WHEN SUM(COALESCE(p.gross_profit, 0)) / NULLIF(SUM(COALESCE(p.total_sales_amount, 0)), 0) >= 0.10 THEN '10%-15%'
            WHEN SUM(COALESCE(p.gross_profit, 0)) / NULLIF(SUM(COALESCE(p.total_sales_amount, 0)), 0) >= 0.05 THEN '5%-10%'
            WHEN SUM(COALESCE(p.gross_profit, 0)) / NULLIF(SUM(COALESCE(p.total_sales_amount, 0)), 0) >= 0.00 THEN '0%-5%'
            ELSE '<0%'
        END AS gp_margin_range
    FROM tmp_dim AS d
    LEFT JOIN etl_datasync.etl_dispose_lx_statistics_profit_statistics_msku AS p
      ON d.country_category = p.country_category
     AND d.seller_name_new = p.seller_name_new
     AND d.seller_sku_adj = p.seller_sku_adj
     AND p.data_date >= v_data_date - INTERVAL 7 DAY
     AND p.data_date <  v_data_date + INTERVAL 1 DAY
     AND p.store_name NOT REGEXP 'baihuiyi|Yuanoboo|Bailboo|Qianytyy'
    GROUP BY d.country_category, d.seller_name_new, d.seller_sku_adj;

    ALTER TABLE tmp_profit_label
        ADD INDEX idx_pl_dim (country_category(3), seller_name_new(64), seller_sku_adj(64));

    DROP TEMPORARY TABLE IF EXISTS tmp_abcd_labels;
    CREATE TEMPORARY TABLE tmp_abcd_labels AS
    SELECT
        d.country_category,
        d.seller_name_new,
        d.seller_sku_adj,
        CASE
            WHEN pi.max_tag_name REGEXP '2027|2026|2025|2024 十月|2024 十一月|2024 十二月' THEN '新品'
            ELSE '老品'
        END AS new_old_product,
        li.principal,
        li.sales_team_1,
        li.max_sku,
        li.max_local_name,
        li.global_tags,
        pi.max_brand_name,
        COALESCE(pl.abcd_category, 'E') AS abcd_category,
        COALESCE(pl.gp_margin_range, '<0%') AS gp_margin_range,
        CASE
            WHEN psm.pprofit_ratio_7d < 0 OR psm.pprofit_ratio_7d IS NULL THEN 'E'
            WHEN COALESCE(psm.sales_7d, 0) / 7 < 1 THEN 'D'
            WHEN psm.pprofit_ratio_7d >= 0.20 THEN 'A'
            WHEN psm.pprofit_ratio_7d >= 0.15 THEN 'B'
            WHEN psm.pprofit_ratio_7d >= 0.10 THEN 'C'
            ELSE 'D'
        END AS predict_abcd_category,
        CASE
            WHEN psm.pprofit_ratio_30d < 0 OR psm.pprofit_ratio_30d IS NULL THEN 'E'
            WHEN COALESCE(psm.sales_30d, 0) / 30 < 1 THEN 'D'
            WHEN psm.pprofit_ratio_30d >= 0.20 THEN 'A'
            WHEN psm.pprofit_ratio_30d >= 0.15 THEN 'B'
            WHEN psm.pprofit_ratio_30d >= 0.10 THEN 'C'
            ELSE 'D'
        END AS pre_1m_predict_abcd_category,
        CASE
            WHEN psm.pprofit_ratio_30d < 0 OR psm.pprofit_ratio_30d IS NULL THEN 'E'
            WHEN COALESCE(psm.sales_90d, 0) / 90 < 1 THEN 'D'
            WHEN psm.pprofit_ratio_30d >= 0.20 THEN 'A'
            WHEN psm.pprofit_ratio_30d >= 0.15 THEN 'B'
            WHEN psm.pprofit_ratio_30d >= 0.10 THEN 'C'
            ELSE 'D'
        END AS pre_1q_predict_abcd_category,
        pi.max_cg_transport_costs,
        pi.max_cg_price,
        pi.max_cg_box_pcs,
        rl.max_receiving_time,
        rl.receiving_cnt,
        CASE
            WHEN COALESCE(fm.available_total, 0) > 0 THEN '不会缺货'
            WHEN COALESCE(fm.stock_up_num, 0) = 0 AND COALESCE(lw.local_quantity, 0) = 0 THEN '缺货未补货'
            WHEN COALESCE(fm.stock_up_num, 0) > 0 OR COALESCE(lw.local_quantity, 0) > 0 THEN '缺货已补货'
            ELSE NULL
        END AS stockout_status
    FROM tmp_dim AS d
    LEFT JOIN tmp_listing_info AS li
      ON d.country_category = li.country_category
     AND d.seller_name_new = li.seller_name_new
     AND d.seller_sku_adj = li.seller_sku_adj
    LEFT JOIN tmp_product_info AS pi
      ON d.country_category = pi.country_category
     AND d.seller_name_new = pi.seller_name_new
     AND d.seller_sku_adj = pi.seller_sku_adj
    LEFT JOIN tmp_receiving_label AS rl
      ON d.country_category = rl.country_category
     AND d.seller_name_new = rl.seller_name_new
     AND d.seller_sku_adj = rl.seller_sku_adj
    LEFT JOIN tmp_profit_label AS pl
      ON d.country_category = pl.country_category
     AND d.seller_name_new = pl.seller_name_new
     AND d.seller_sku_adj = pl.seller_sku_adj
    LEFT JOIN tmp_prod_perf_sku_metrics AS psm
      ON d.country_category = psm.country_category
     AND d.seller_name_new = psm.seller_name_new
     AND d.seller_sku_adj = psm.seller_sku_adj
    LEFT JOIN tmp_fba_msku AS fm
      ON d.country_category = fm.country_category
     AND d.seller_name_new = fm.seller_name_new
     AND d.seller_sku_adj = fm.seller_sku_adj
    LEFT JOIN tmp_local_warehouse AS lw
      ON d.country_category = lw.country_category
     AND d.seller_name_new = lw.seller_name_new
     AND d.seller_sku_adj = lw.seller_sku_adj;

    ALTER TABLE tmp_abcd_labels
        ADD INDEX idx_abcd_dim (country_category(3), seller_name_new(64), seller_sku_adj(64));

    -- ============================================================
    -- 7. 日销修正 / 补货候选
    -- ============================================================
    DROP TEMPORARY TABLE IF EXISTS tmp_pre_daily_sales;
    CREATE TEMPORARY TABLE tmp_pre_daily_sales AS
    SELECT
        spb.country_category,
        spb.seller_name_new,
        spb.seller_sku_adj,
        spb.sales_90d,
        CASE
            WHEN ks.r_30d_salable_days >= 7
                THEN CASE WHEN ks.r_3d_salable_days > 0 THEN COALESCE(spb.sales_3d, 0) / ks.r_3d_salable_days ELSE 0 END
            ELSE COALESCE(spb.sales_3d, 0) / GREATEST(COALESCE(ks.r_3d_salable_days, 0), 2)
        END AS adjusted_daily_sales_3d,
        CASE
            WHEN ks.r_30d_salable_days >= 7
                THEN CASE
                    WHEN ks.r_7d_salable_days >= 7 THEN COALESCE(spb.sales_7d, 0) / ks.r_7d_salable_days
                    ELSE LEAST(
                        CASE WHEN ks.r_7d_salable_days > 0 THEN COALESCE(spb.sales_7d, 0) / ks.r_7d_salable_days ELSE 0 END,
                        (CASE WHEN ks.r_7d_salable_days > 0 THEN COALESCE(spb.sales_7d, 0) / ks.r_7d_salable_days ELSE 0 END)
                        * (ks.r_7d_salable_days / (ks.r_7d_salable_days + 3))
                        + (COALESCE(spb.sales_30d, 0) / ks.r_30d_salable_days)
                        * (1 - ks.r_7d_salable_days / (ks.r_7d_salable_days + 3))
                    )
                END
            ELSE COALESCE(spb.sales_7d, 0) / GREATEST(COALESCE(ks.r_7d_salable_days, 0), 3)
        END AS adjusted_daily_sales_7d,
        CASE
            WHEN ks.r_30d_salable_days >= 7
                THEN CASE
                    WHEN ks.r_14d_salable_days >= 14 THEN COALESCE(spb.sales_14d, 0) / ks.r_14d_salable_days
                    ELSE LEAST(
                        CASE WHEN ks.r_14d_salable_days > 0 THEN COALESCE(spb.sales_14d, 0) / ks.r_14d_salable_days ELSE 0 END,
                        (CASE WHEN ks.r_14d_salable_days > 0 THEN COALESCE(spb.sales_14d, 0) / ks.r_14d_salable_days ELSE 0 END)
                        * (ks.r_14d_salable_days / (ks.r_14d_salable_days + 7))
                        + (COALESCE(spb.sales_30d, 0) / ks.r_30d_salable_days)
                        * (1 - ks.r_14d_salable_days / (ks.r_14d_salable_days + 7))
                    )
                END
            ELSE COALESCE(spb.sales_14d, 0) / GREATEST(COALESCE(ks.r_14d_salable_days, 0), 7)
        END AS adjusted_daily_sales_14d,
        CASE
            WHEN ks.r_30d_salable_days >= 7 THEN COALESCE(spb.sales_30d, 0) / ks.r_30d_salable_days
            ELSE COALESCE(spb.sales_30d, 0) / GREATEST(COALESCE(ks.r_30d_salable_days, 0), 15)
        END AS adjusted_daily_sales_30d
    FROM tmp_prod_perf_sku_metrics AS spb
    LEFT JOIN tmp_salable_days AS ks
      ON spb.country_category = ks.country_category
     AND spb.seller_name_new = ks.seller_name_new
     AND spb.seller_sku_adj = ks.seller_sku_adj;

    ALTER TABLE tmp_pre_daily_sales
        ADD INDEX idx_pds_dim (country_category(3), seller_name_new(64), seller_sku_adj(64));

    DROP TEMPORARY TABLE IF EXISTS tmp_support_layer_all;
    CREATE TEMPORARY TABLE tmp_support_layer_all AS
    SELECT
        pre.*,
        CASE
            WHEN COALESCE(pre.pre_daily_avg_sales, 0) <= 0 THEN NULL
            ELSE pre.support_inventory_qty / pre.pre_daily_avg_sales
        END AS inventory_support_days,
        CASE
            WHEN COALESCE(pre.pre_daily_avg_sales, 0) <= 0 THEN 5
            WHEN pre.support_inventory_qty / pre.pre_daily_avg_sales <= 35 THEN 1
            WHEN pre.support_inventory_qty / pre.pre_daily_avg_sales > 35
             AND pre.support_inventory_qty / pre.pre_daily_avg_sales <= 65 THEN 2
            WHEN pre.support_inventory_qty / pre.pre_daily_avg_sales > 65
             AND pre.support_inventory_qty / pre.pre_daily_avg_sales <= 90 THEN 3
            WHEN pre.support_inventory_qty / pre.pre_daily_avg_sales > 90 THEN 4
            ELSE 2
        END AS support_replenish_level_sort,
        CASE
            WHEN COALESCE(pre.pre_daily_avg_sales, 0) <= 0 THEN '日销为0'
            WHEN pre.support_inventory_qty / pre.pre_daily_avg_sales <= 35 THEN '紧急补货'
            WHEN pre.support_inventory_qty / pre.pre_daily_avg_sales > 35
             AND pre.support_inventory_qty / pre.pre_daily_avg_sales <= 65 THEN '建议补货'
            WHEN pre.support_inventory_qty / pre.pre_daily_avg_sales > 65
             AND pre.support_inventory_qty / pre.pre_daily_avg_sales <= 90 THEN '计划补货'
            WHEN pre.support_inventory_qty / pre.pre_daily_avg_sales > 90 THEN '库存充足'
            ELSE '建议补货'
        END AS support_replenish_level
    FROM (
        SELECT
            pre_calc.*,
            pre_calc.pre_available_total + pre_calc.pre_stock_up_num + pre_calc.pre_local_quantity AS support_inventory_qty,
            CASE
                WHEN pre_calc.pre_normal_replenish_need_qty < pre_calc.pre_replenish_trigger_qty
                 AND pre_calc.pre_r_30d_salable_days < 15
                 AND pre_calc.hist_90d_instock_days >= 15
                 AND pre_calc.hist_90d_instock_daily_sales > 1.5
                 AND pre_calc.history_recovery_need_qty >= pre_calc.pre_replenish_trigger_qty
                THEN 1 ELSE 0
            END AS history_recovery_flag
        FROM (
            SELECT
                pre_base.*,
                pre_base.pre_replenish_comp_months * 30 * COALESCE(pre_base.pre_daily_avg_sales, 0)
                - pre_base.pre_available_total
                - pre_base.pre_stock_up_num
                - pre_base.pre_local_quantity
                - pre_base.pre_sc_quantity_purchase_plan AS pre_normal_replenish_need_qty,
                pre_base.hist_90d_instock_daily_sales * 120
                - pre_base.pre_available_total
                - pre_base.pre_stock_up_num
                - pre_base.pre_local_quantity
                - pre_base.pre_sc_quantity_purchase_plan AS history_recovery_need_qty
            FROM (
                SELECT
                    wd.*,
                    4 AS pre_replenish_comp_months,
                    CASE
                        WHEN (wd.max_brand_name LIKE '%2025%' AND (wd.receiving_cnt <= 1 OR wd.receiving_cnt IS NULL))
                          OR (wd.max_brand_name LIKE '%2026%' AND (wd.receiving_cnt <= 1 OR wd.receiving_cnt IS NULL))
                        THEN COALESCE(pds.adjusted_daily_sales_3d, 0) * 0.5 + COALESCE(pds.adjusted_daily_sales_7d, 0) * 0.5
                        ELSE COALESCE(pds.adjusted_daily_sales_7d, 0) * 0.6 + COALESCE(pds.adjusted_daily_sales_14d, 0) * 0.2 + COALESCE(pds.adjusted_daily_sales_30d, 0) * 0.2
                    END AS pre_daily_avg_sales,
                    COALESCE(fm.available_total, 0) AS pre_available_total,
                    COALESCE(fm.stock_up_num, 0) AS pre_stock_up_num,
                    COALESCE(lw.local_quantity, 0) AS pre_local_quantity,
                    COALESCE(lw.sc_quantity_purchase_plan, 0) AS pre_sc_quantity_purchase_plan,
                    COALESCE(ks.r_30d_salable_days, 0) AS pre_r_30d_salable_days,
                    COALESCE(ks.r_90d_salable_days, 0) AS hist_90d_instock_days,
                    COALESCE(pds.sales_90d, 0) AS hist_90d_instock_sales,
                    CASE WHEN COALESCE(ks.r_90d_salable_days, 0) > 0 THEN COALESCE(pds.sales_90d, 0) / ks.r_90d_salable_days ELSE 0 END AS hist_90d_instock_daily_sales,
                    CASE WHEN COALESCE(wd.max_cg_box_pcs, 0) > 0 THEN wd.max_cg_box_pcs ELSE 50 END AS pre_replenish_trigger_qty
                FROM tmp_abcd_labels AS wd
                LEFT JOIN tmp_fba_msku AS fm
                  ON wd.country_category = fm.country_category
                 AND wd.seller_name_new = fm.seller_name_new
                 AND wd.seller_sku_adj = fm.seller_sku_adj
                LEFT JOIN tmp_local_warehouse AS lw
                  ON wd.country_category = lw.country_category
                 AND wd.seller_name_new = lw.seller_name_new
                 AND wd.seller_sku_adj = lw.seller_sku_adj
                LEFT JOIN tmp_salable_days AS ks
                  ON wd.country_category = ks.country_category
                 AND wd.seller_name_new = ks.seller_name_new
                 AND wd.seller_sku_adj = ks.seller_sku_adj
                LEFT JOIN tmp_pre_daily_sales AS pds
                  ON wd.country_category = pds.country_category
                 AND wd.seller_name_new = pds.seller_name_new
                 AND wd.seller_sku_adj = pds.seller_sku_adj
            ) AS pre_base
        ) AS pre_calc
    ) AS pre;

    ALTER TABLE tmp_support_layer_all
        ADD INDEX idx_sla_dim (country_category(3), seller_name_new(64), seller_sku_adj(64), support_replenish_level_sort);

    DROP TEMPORARY TABLE IF EXISTS tmp_replenish_candidates;
    CREATE TEMPORARY TABLE tmp_replenish_candidates AS
    SELECT *
    FROM tmp_support_layer_all
    WHERE support_replenish_level_sort IN (1, 2, 3);

    ALTER TABLE tmp_replenish_candidates
        ADD INDEX idx_rc_dim (country_category(3), seller_name_new(64), seller_sku_adj(64));

    DROP TEMPORARY TABLE IF EXISTS tmp_rc_dim;
    CREATE TEMPORARY TABLE tmp_rc_dim AS
    SELECT DISTINCT country_category, seller_name_new, seller_sku_adj
    FROM tmp_replenish_candidates;

    ALTER TABLE tmp_rc_dim
        ADD INDEX idx_rcd_dim (country_category(3), seller_name_new(64), seller_sku_adj(64));

    -- ============================================================
    -- 8. 去年同期环比：仅候选SKU
    -- ============================================================
    DROP TEMPORARY TABLE IF EXISTS tmp_hist_daily;
    CREATE TEMPORARY TABLE tmp_hist_daily (
        start_date DATE,
        country_category VARCHAR(20),
        seller_name_new VARCHAR(100),
        seller_sku_adj VARCHAR(500),
        day_volume INT,
        afn_fulfillable_quantity INT,
        INDEX idx_hd_dim (country_category(3), seller_name_new(64), seller_sku_adj(64), start_date)
    ) ENGINE=InnoDB;

    INSERT INTO tmp_hist_daily
    SELECT
        p.start_date,
        p.country_category,
        p.seller_name_new,
        p.seller_sku_adj,
        SUM(COALESCE(p.volume, 0)) AS day_volume,
        MAX(COALESCE(p.afn_fulfillable_quantity, 0)) AS afn_fulfillable_quantity
    FROM tmp_rc_dim AS d
    JOIN etl_datasync.etl_dispose_lx_statistics_product_performance_2024 AS p
      ON d.country_category = p.country_category
     AND d.seller_name_new = p.seller_name_new
     AND d.seller_sku_adj = p.seller_sku_adj
    WHERE DATE_SUB(DATE_SUB(v_data_date, INTERVAL 1 YEAR), INTERVAL 90 DAY) <= '2024-12-31'
      AND DATE_ADD(DATE_SUB(v_data_date, INTERVAL 1 YEAR), INTERVAL 90 DAY) >= '2024-01-01'
      AND p.start_date >= DATE_SUB(DATE_SUB(v_data_date, INTERVAL 1 YEAR), INTERVAL 90 DAY)
      AND p.start_date <= DATE_ADD(DATE_SUB(v_data_date, INTERVAL 1 YEAR), INTERVAL 90 DAY)
    GROUP BY p.start_date, p.country_category, p.seller_name_new, p.seller_sku_adj;

    INSERT INTO tmp_hist_daily
    SELECT
        p.start_date,
        p.country_category,
        p.seller_name_new,
        p.seller_sku_adj,
        SUM(COALESCE(p.volume, 0)) AS day_volume,
        MAX(COALESCE(p.afn_fulfillable_quantity, 0)) AS afn_fulfillable_quantity
    FROM tmp_rc_dim AS d
    JOIN etl_datasync.etl_dispose_lx_statistics_product_performance_2025 AS p
      ON d.country_category = p.country_category
     AND d.seller_name_new = p.seller_name_new
     AND d.seller_sku_adj = p.seller_sku_adj
    WHERE DATE_SUB(DATE_SUB(v_data_date, INTERVAL 1 YEAR), INTERVAL 90 DAY) <= '2025-12-31'
      AND DATE_ADD(DATE_SUB(v_data_date, INTERVAL 1 YEAR), INTERVAL 90 DAY) >= '2025-01-01'
      AND p.start_date >= DATE_SUB(DATE_SUB(v_data_date, INTERVAL 1 YEAR), INTERVAL 90 DAY)
      AND p.start_date <= DATE_ADD(DATE_SUB(v_data_date, INTERVAL 1 YEAR), INTERVAL 90 DAY)
    GROUP BY p.start_date, p.country_category, p.seller_name_new, p.seller_sku_adj;

    DROP TEMPORARY TABLE IF EXISTS tmp_future_stat;
    CREATE TEMPORARY TABLE tmp_future_stat AS
    SELECT
        h.country_category,
        h.seller_name_new,
        h.seller_sku_adj,
        SUM(CASE WHEN h.afn_fulfillable_quantity <> 0 THEN 1 ELSE 0 END) AS future_instock_days,
        SUM(CASE WHEN h.afn_fulfillable_quantity <> 0 THEN h.day_volume ELSE 0 END) AS future_instock_sales
    FROM tmp_hist_daily AS h
    WHERE h.start_date >= DATE_SUB(v_data_date, INTERVAL 1 YEAR)
      AND h.start_date <= DATE_ADD(DATE_SUB(v_data_date, INTERVAL 1 YEAR), INTERVAL 90 DAY)
    GROUP BY h.country_category, h.seller_name_new, h.seller_sku_adj;

    DROP TEMPORARY TABLE IF EXISTS tmp_prev_stat;
    CREATE TEMPORARY TABLE tmp_prev_stat AS
    SELECT
        h.country_category,
        h.seller_name_new,
        h.seller_sku_adj,
        SUM(CASE WHEN h.afn_fulfillable_quantity <> 0 THEN 1 ELSE 0 END) AS prev_instock_days,
        SUM(CASE WHEN h.afn_fulfillable_quantity <> 0 THEN h.day_volume ELSE 0 END) AS prev_matched_sales
    FROM tmp_hist_daily AS h
    WHERE h.start_date >= DATE_SUB(DATE_SUB(v_data_date, INTERVAL 1 YEAR), INTERVAL 90 DAY)
      AND h.start_date <= DATE_SUB(v_data_date, INTERVAL 1 YEAR)
    GROUP BY h.country_category, h.seller_name_new, h.seller_sku_adj;

    DROP TEMPORARY TABLE IF EXISTS tmp_sales_change_rate;
    CREATE TEMPORARY TABLE tmp_sales_change_rate AS
    SELECT
        f.country_category,
        f.seller_name_new,
        f.seller_sku_adj,
        f.future_instock_days,
        f.future_instock_sales,
        p.prev_instock_days,
        p.prev_matched_sales,
        CASE WHEN f.future_instock_days = 0 THEN NULL
             WHEN f.future_instock_days < 90 THEN f.future_instock_sales / f.future_instock_days * 90
             ELSE f.future_instock_sales END AS future_instock_sales_adj,
        CASE WHEN p.prev_instock_days = 0 THEN NULL
             WHEN p.prev_instock_days < 90 THEN p.prev_matched_sales / p.prev_instock_days * 90
             ELSE p.prev_matched_sales END AS prev_matched_sales_adj,
        LEAST(GREATEST(
            CASE
                WHEN f.future_instock_days < 45 THEN NULL
                WHEN p.prev_instock_days < 45 THEN NULL
                WHEN p.prev_matched_sales IS NULL OR p.prev_matched_sales = 0 THEN NULL
                ELSE
                    (
                        (
                            CASE WHEN f.future_instock_days < 90 THEN f.future_instock_sales / f.future_instock_days * 90 ELSE f.future_instock_sales END
                        ) -
                        (
                            CASE WHEN p.prev_instock_days < 90 THEN p.prev_matched_sales / p.prev_instock_days * 90 ELSE p.prev_matched_sales END
                        )
                    ) / GREATEST(
                        CASE WHEN p.prev_instock_days < 90 THEN p.prev_matched_sales / p.prev_instock_days * 90 ELSE p.prev_matched_sales END,
                        30
                    ) * LEAST(
                        (CASE WHEN p.prev_instock_days < 90 THEN p.prev_matched_sales / p.prev_instock_days * 90 ELSE p.prev_matched_sales END) / 50.0,
                        1.0
                    )
            END,
            -0.5
        ), 1.5) AS sales_change_rate_adj
    FROM tmp_future_stat AS f
    LEFT JOIN tmp_prev_stat AS p
      ON f.country_category = p.country_category
     AND f.seller_name_new = p.seller_name_new
     AND f.seller_sku_adj = p.seller_sku_adj;

    ALTER TABLE tmp_sales_change_rate
        ADD INDEX idx_scr_dim (country_category(3), seller_name_new(64), seller_sku_adj(64));

    -- ============================================================
    -- 9. 订单毛利率：仅候选SKU近90天订单
    -- ============================================================
    DROP TEMPORARY TABLE IF EXISTS tmp_orders_profit_base;
    CREATE TEMPORARY TABLE tmp_orders_profit_base AS
    SELECT
        o.create_time,
        o.country,
        o.amazon_order_id,
        o.seller_name_new,
        o.seller_sku_adj,
        o.country_category,
        o.sales_price_amount,
        o.profit
    FROM tmp_rc_dim AS d
    JOIN (
        SELECT
            create_time,
            country,
            amazon_order_id,
            CAST(
                CASE
                    WHEN LOCATE('-', seller_name) > 0
                        THEN LEFT(seller_name, LOCATE('-', seller_name) - 1)
                    ELSE seller_name
                END AS CHAR(100)
            ) AS seller_name_new,
            CAST(
                IF(
                    LENGTH(SUBSTRING_INDEX(seller_sku, ',', 1)) > 16,
                    REPLACE(
                        SUBSTRING_INDEX(SUBSTRING_INDEX(seller_sku, ',', 1), '-', 1),
                        'amzn.gr.',
                        ''
                    ),
                    SUBSTRING_INDEX(seller_sku, ',', 1)
                ) AS CHAR(100)
            ) AS seller_sku_adj,
            CAST(
                CASE
                    WHEN country = '英国' THEN '英国站'
                    WHEN country IN ('美国', '加拿大', '巴西', '墨西哥') THEN '北美站'
                    ELSE '欧洲站'
                END AS CHAR(20)
            ) AS country_category,
            sales_price_amount,
            profit
        FROM dwd_datasync.lx_sales_mws_orders_detail
        WHERE create_time >= v_data_date - INTERVAL 90 DAY
          AND create_time <  v_data_date + INTERVAL 1 DAY
          AND sales_price_amount IS NOT NULL
    ) AS o
      ON d.country_category = o.country_category
     AND d.seller_name_new = o.seller_name_new
     AND d.seller_sku_adj = o.seller_sku_adj;

    ALTER TABLE tmp_orders_profit_base
        ADD INDEX idx_opb_dim (seller_name_new(64), seller_sku_adj(64), country_category(3), country(20), create_time);

    DROP TEMPORARY TABLE IF EXISTS tmp_orders_selected_country;
    CREATE TEMPORARY TABLE tmp_orders_selected_country AS
    SELECT seller_name_new, seller_sku_adj, country_category, country AS best_country
    FROM (
        SELECT x.*,
               ROW_NUMBER() OVER (
                   PARTITION BY seller_name_new, seller_sku_adj, country_category
                   ORDER BY profit_rate_5 DESC, sales_price_amount_5 DESC, profit_5 DESC, country
               ) AS country_rank
        FROM (
            SELECT
                seller_name_new,
                seller_sku_adj,
                country_category,
                country,
                COUNT(*) AS order_cnt_5,
                SUM(sales_price_amount) AS sales_price_amount_5,
                SUM(profit) AS profit_5,
                SUM(profit) / SUM(sales_price_amount) AS profit_rate_5
            FROM (
                SELECT b.*,
                       ROW_NUMBER() OVER (
                           PARTITION BY seller_name_new, seller_sku_adj, country_category, country
                           ORDER BY create_time DESC, amazon_order_id DESC
                       ) AS rn_5
                FROM tmp_orders_profit_base AS b
            ) AS r
            WHERE rn_5 <= 5
            GROUP BY seller_name_new, seller_sku_adj, country_category, country
            HAVING COUNT(*) = 5 AND SUM(sales_price_amount) <> 0
        ) AS x
    ) AS y
    WHERE country_rank = 1;

    ALTER TABLE tmp_orders_selected_country
        ADD INDEX idx_osc_dim (seller_name_new(64), seller_sku_adj(64), country_category(3), best_country(20));

    DROP TEMPORARY TABLE IF EXISTS tmp_orders_profit_result;
    CREATE TEMPORARY TABLE tmp_orders_profit_result AS
    SELECT
        seller_name_new,
        seller_sku_adj,
        country_category,
        best_country,
        COUNT(*) AS order_cnt_20,
        ROUND(SUM(profit) / SUM(sales_price_amount), 2) AS final_profit_rate
    FROM (
        SELECT
            b.*,
            sc.best_country,
            ROW_NUMBER() OVER (
                PARTITION BY b.seller_name_new, b.seller_sku_adj, b.country_category
                ORDER BY b.create_time DESC, b.amazon_order_id DESC
            ) AS rn_20
        FROM tmp_orders_profit_base AS b
        JOIN tmp_orders_selected_country AS sc
          ON b.seller_name_new = sc.seller_name_new
         AND b.seller_sku_adj = sc.seller_sku_adj
         AND b.country_category = sc.country_category
         AND b.country = sc.best_country
    ) AS t
    WHERE rn_20 <= 20
    GROUP BY seller_name_new, seller_sku_adj, country_category, best_country
    HAVING SUM(sales_price_amount) <> 0;

    ALTER TABLE tmp_orders_profit_result
        ADD INDEX idx_opr_dim (seller_name_new(64), seller_sku_adj(64), country_category(3));

    -- ============================================================
    -- 10. 结算利润：仅当前维度近30天
    -- ============================================================
    DROP TEMPORARY TABLE IF EXISTS tmp_settlement_profit;
    CREATE TEMPORARY TABLE tmp_settlement_profit AS
    SELECT
        d.country_category,
        d.seller_name_new,
        d.seller_sku_adj,
        SUM(CASE WHEN p.data_date >= v_data_date - INTERVAL 30 DAY THEN COALESCE(p.total_sales_amount, 0) ELSE 0 END) AS gamount_30d,
        SUM(CASE WHEN p.data_date >= v_data_date - INTERVAL 14 DAY THEN COALESCE(p.total_sales_amount, 0) ELSE 0 END) AS gamount_14d,
        SUM(CASE WHEN p.data_date >= v_data_date - INTERVAL 7 DAY  THEN COALESCE(p.total_sales_amount, 0) ELSE 0 END) AS gamount_7d,
        SUM(CASE WHEN p.data_date >= v_data_date - INTERVAL 3 DAY  THEN COALESCE(p.total_sales_amount, 0) ELSE 0 END) AS gamount_3d,
        SUM(CASE WHEN p.data_date >= v_data_date - INTERVAL 30 DAY THEN COALESCE(p.gross_profit, 0) ELSE 0 END) AS gprofit_30d,
        SUM(CASE WHEN p.data_date >= v_data_date - INTERVAL 14 DAY THEN COALESCE(p.gross_profit, 0) ELSE 0 END) AS gprofit_14d,
        SUM(CASE WHEN p.data_date >= v_data_date - INTERVAL 7 DAY  THEN COALESCE(p.gross_profit, 0) ELSE 0 END) AS gprofit_7d,
        SUM(CASE WHEN p.data_date >= v_data_date - INTERVAL 3 DAY  THEN COALESCE(p.gross_profit, 0) ELSE 0 END) AS gprofit_3d,
        SUM(CASE WHEN p.data_date >= v_data_date - INTERVAL 30 DAY THEN COALESCE(p.gross_profit, 0) ELSE 0 END) / NULLIF(SUM(CASE WHEN p.data_date >= v_data_date - INTERVAL 30 DAY THEN COALESCE(p.total_sales_amount, 0) ELSE 0 END), 0) AS gprofit_ratio_30d,
        SUM(CASE WHEN p.data_date >= v_data_date - INTERVAL 14 DAY THEN COALESCE(p.gross_profit, 0) ELSE 0 END) / NULLIF(SUM(CASE WHEN p.data_date >= v_data_date - INTERVAL 14 DAY THEN COALESCE(p.total_sales_amount, 0) ELSE 0 END), 0) AS gprofit_ratio_14d,
        SUM(CASE WHEN p.data_date >= v_data_date - INTERVAL 7 DAY  THEN COALESCE(p.gross_profit, 0) ELSE 0 END) / NULLIF(SUM(CASE WHEN p.data_date >= v_data_date - INTERVAL 7 DAY  THEN COALESCE(p.total_sales_amount, 0) ELSE 0 END), 0) AS gprofit_ratio_7d,
        SUM(CASE WHEN p.data_date >= v_data_date - INTERVAL 3 DAY  THEN COALESCE(p.gross_profit, 0) ELSE 0 END) / NULLIF(SUM(CASE WHEN p.data_date >= v_data_date - INTERVAL 3 DAY  THEN COALESCE(p.total_sales_amount, 0) ELSE 0 END), 0) AS gprofit_ratio_3d
    FROM tmp_dim AS d
    LEFT JOIN etl_datasync.etl_dispose_lx_statistics_profit_statistics_msku AS p
      ON d.country_category = p.country_category
     AND d.seller_name_new = p.seller_name_new
     AND d.seller_sku_adj = p.seller_sku_adj
     AND p.data_date >= v_data_date - INTERVAL 30 DAY
     AND p.data_date <  v_data_date + INTERVAL 1 DAY
    GROUP BY d.country_category, d.seller_name_new, d.seller_sku_adj;

    ALTER TABLE tmp_settlement_profit
        ADD INDEX idx_sp_dim (country_category(3), seller_name_new(64), seller_sku_adj(64));

    -- ============================================================
    -- 11. 跟卖合并后的日销修正
    -- ============================================================
    DROP TEMPORARY TABLE IF EXISTS tmp_final_daily_sales_adj;
    CREATE TEMPORARY TABLE tmp_final_daily_sales_adj AS
    SELECT
        spb.country_category,
        spb.seller_name_new,
        spb.seller_sku_adj,
        CASE WHEN COALESCE(fo.fllow_flag, 1) = 1 THEN spb.sales_30d ELSE COALESCE(spb.sales_30d, 0) + COALESCE(fo.origin_sales_30d, 0) END AS final_sales_30d,
        CASE WHEN COALESCE(fo.fllow_flag, 1) = 1 THEN spb.sales_14d ELSE COALESCE(spb.sales_14d, 0) + COALESCE(fo.origin_sales_14d, 0) END AS final_sales_14d,
        CASE WHEN COALESCE(fo.fllow_flag, 1) = 1 THEN spb.sales_7d  ELSE COALESCE(spb.sales_7d, 0)  + COALESCE(fo.origin_sales_7d, 0)  END AS final_sales_7d,
        CASE WHEN COALESCE(fo.fllow_flag, 1) = 1 THEN spb.sales_3d  ELSE COALESCE(spb.sales_3d, 0)  + COALESCE(fo.origin_sales_3d, 0)  END AS final_sales_3d,
        CASE
            WHEN ks.r_30d_salable_days >= 7 THEN
                (CASE WHEN COALESCE(fo.fllow_flag, 1) = 1 THEN COALESCE(spb.sales_30d, 0) ELSE COALESCE(spb.sales_30d, 0) + COALESCE(fo.origin_sales_30d, 0) END) / ks.r_30d_salable_days
            ELSE
                (CASE WHEN COALESCE(fo.fllow_flag, 1) = 1 THEN COALESCE(spb.sales_30d, 0) ELSE COALESCE(spb.sales_30d, 0) + COALESCE(fo.origin_sales_30d, 0) END) / GREATEST(COALESCE(ks.r_30d_salable_days, 0), 15)
        END AS adjusted_daily_sales_30d,
        CASE
            WHEN ks.r_30d_salable_days >= 7 THEN
                CASE
                    WHEN ks.r_14d_salable_days >= 14 THEN
                        (CASE WHEN COALESCE(fo.fllow_flag, 1) = 1 THEN COALESCE(spb.sales_14d, 0) ELSE COALESCE(spb.sales_14d, 0) + COALESCE(fo.origin_sales_14d, 0) END) / ks.r_14d_salable_days
                    ELSE LEAST(
                        CASE WHEN ks.r_14d_salable_days > 0 THEN (CASE WHEN COALESCE(fo.fllow_flag, 1) = 1 THEN COALESCE(spb.sales_14d, 0) ELSE COALESCE(spb.sales_14d, 0) + COALESCE(fo.origin_sales_14d, 0) END) / ks.r_14d_salable_days ELSE 0 END,
                        (CASE WHEN ks.r_14d_salable_days > 0 THEN (CASE WHEN COALESCE(fo.fllow_flag, 1) = 1 THEN COALESCE(spb.sales_14d, 0) ELSE COALESCE(spb.sales_14d, 0) + COALESCE(fo.origin_sales_14d, 0) END) / ks.r_14d_salable_days ELSE 0 END)
                        * (ks.r_14d_salable_days / (ks.r_14d_salable_days + 7))
                        + ((CASE WHEN COALESCE(fo.fllow_flag, 1) = 1 THEN COALESCE(spb.sales_30d, 0) ELSE COALESCE(spb.sales_30d, 0) + COALESCE(fo.origin_sales_30d, 0) END) / ks.r_30d_salable_days)
                        * (1 - ks.r_14d_salable_days / (ks.r_14d_salable_days + 7))
                    )
                END
            ELSE
                (CASE WHEN COALESCE(fo.fllow_flag, 1) = 1 THEN COALESCE(spb.sales_14d, 0) ELSE COALESCE(spb.sales_14d, 0) + COALESCE(fo.origin_sales_14d, 0) END) / GREATEST(COALESCE(ks.r_14d_salable_days, 0), 7)
        END AS adjusted_daily_sales_14d,
        CASE
            WHEN ks.r_30d_salable_days >= 7 THEN
                CASE
                    WHEN ks.r_7d_salable_days >= 7 THEN
                        (CASE WHEN COALESCE(fo.fllow_flag, 1) = 1 THEN COALESCE(spb.sales_7d, 0) ELSE COALESCE(spb.sales_7d, 0) + COALESCE(fo.origin_sales_7d, 0) END) / ks.r_7d_salable_days
                    ELSE LEAST(
                        CASE WHEN ks.r_7d_salable_days > 0 THEN (CASE WHEN COALESCE(fo.fllow_flag, 1) = 1 THEN COALESCE(spb.sales_7d, 0) ELSE COALESCE(spb.sales_7d, 0) + COALESCE(fo.origin_sales_7d, 0) END) / ks.r_7d_salable_days ELSE 0 END,
                        (CASE WHEN ks.r_7d_salable_days > 0 THEN (CASE WHEN COALESCE(fo.fllow_flag, 1) = 1 THEN COALESCE(spb.sales_7d, 0) ELSE COALESCE(spb.sales_7d, 0) + COALESCE(fo.origin_sales_7d, 0) END) / ks.r_7d_salable_days ELSE 0 END)
                        * (ks.r_7d_salable_days / (ks.r_7d_salable_days + 3))
                        + ((CASE WHEN COALESCE(fo.fllow_flag, 1) = 1 THEN COALESCE(spb.sales_30d, 0) ELSE COALESCE(spb.sales_30d, 0) + COALESCE(fo.origin_sales_30d, 0) END) / ks.r_30d_salable_days)
                        * (1 - ks.r_7d_salable_days / (ks.r_7d_salable_days + 3))
                    )
                END
            ELSE
                (CASE WHEN COALESCE(fo.fllow_flag, 1) = 1 THEN COALESCE(spb.sales_7d, 0) ELSE COALESCE(spb.sales_7d, 0) + COALESCE(fo.origin_sales_7d, 0) END) / GREATEST(COALESCE(ks.r_7d_salable_days, 0), 3)
        END AS adjusted_daily_sales_7d,
        CASE
            WHEN ks.r_30d_salable_days >= 7 THEN
                CASE WHEN ks.r_3d_salable_days > 0 THEN
                    (CASE WHEN COALESCE(fo.fllow_flag, 1) = 1 THEN COALESCE(spb.sales_3d, 0) ELSE COALESCE(spb.sales_3d, 0) + COALESCE(fo.origin_sales_3d, 0) END) / ks.r_3d_salable_days
                ELSE 0 END
            ELSE
                (CASE WHEN COALESCE(fo.fllow_flag, 1) = 1 THEN COALESCE(spb.sales_3d, 0) ELSE COALESCE(spb.sales_3d, 0) + COALESCE(fo.origin_sales_3d, 0) END) / GREATEST(COALESCE(ks.r_3d_salable_days, 0), 2)
        END AS adjusted_daily_sales_3d
    FROM tmp_prod_perf_sku_metrics AS spb
    LEFT JOIN tmp_prod_perf_follow_origin AS fo
      ON spb.country_category = fo.country_category
     AND spb.seller_name_new = fo.seller_name_new
     AND spb.seller_sku_adj = fo.seller_sku_adj
    LEFT JOIN tmp_salable_days AS ks
      ON spb.country_category = ks.country_category
     AND spb.seller_name_new = ks.seller_name_new
     AND spb.seller_sku_adj = ks.seller_sku_adj;

    ALTER TABLE tmp_final_daily_sales_adj
        ADD INDEX idx_fdsa_dim (country_category(3), seller_name_new(64), seller_sku_adj(64));

    -- ============================================================
    -- 12. 最终补货计算
    -- ============================================================
    DROP TEMPORARY TABLE IF EXISTS tmp_replenish_result;
    CREATE TEMPORARY TABLE tmp_replenish_result AS
    SELECT
        wd.country_category,
        wd.seller_name_new,
        wd.seller_sku_adj,
        CASE
            WHEN wd.max_brand_name LIKE '%2025%' AND (wd.receiving_cnt <= 1 OR wd.receiving_cnt IS NULL) THEN '2025新品'
            WHEN wd.max_brand_name LIKE '%2026%' AND (wd.receiving_cnt <= 1 OR wd.receiving_cnt IS NULL) THEN '2026新品'
            ELSE '老品'
        END AS new_old_prod_jg,
        CASE
            WHEN (wd.max_brand_name LIKE '%2025%' AND (wd.receiving_cnt <= 1 OR wd.receiving_cnt IS NULL))
              OR (wd.max_brand_name LIKE '%2026%' AND (wd.receiving_cnt <= 1 OR wd.receiving_cnt IS NULL))
            THEN COALESCE(fdsa.adjusted_daily_sales_3d, 0) * 0.5 + COALESCE(fdsa.adjusted_daily_sales_7d, 0) * 0.5
            ELSE COALESCE(fdsa.adjusted_daily_sales_7d, 0) * 0.6 + COALESCE(fdsa.adjusted_daily_sales_14d, 0) * 0.2 + COALESCE(fdsa.adjusted_daily_sales_30d, 0) * 0.2
        END AS daily_avg_sales,
        4 AS replenish_comp_months,
        CASE
            WHEN COALESCE(
                CASE
                    WHEN (wd.max_brand_name LIKE '%2025%' AND (wd.receiving_cnt <= 1 OR wd.receiving_cnt IS NULL))
                      OR (wd.max_brand_name LIKE '%2026%' AND (wd.receiving_cnt <= 1 OR wd.receiving_cnt IS NULL))
                    THEN COALESCE(fdsa.adjusted_daily_sales_3d, 0) * 0.5 + COALESCE(fdsa.adjusted_daily_sales_7d, 0) * 0.5
                    ELSE COALESCE(fdsa.adjusted_daily_sales_7d, 0) * 0.6 + COALESCE(fdsa.adjusted_daily_sales_14d, 0) * 0.2 + COALESCE(fdsa.adjusted_daily_sales_30d, 0) * 0.2
                END, 0) = 0 THEN NULL
            ELSE (COALESCE(fm.total, 0) + COALESCE(lw.local_quantity, 0)) /
                CASE
                    WHEN (wd.max_brand_name LIKE '%2025%' AND (wd.receiving_cnt <= 1 OR wd.receiving_cnt IS NULL))
                      OR (wd.max_brand_name LIKE '%2026%' AND (wd.receiving_cnt <= 1 OR wd.receiving_cnt IS NULL))
                    THEN COALESCE(fdsa.adjusted_daily_sales_3d, 0) * 0.5 + COALESCE(fdsa.adjusted_daily_sales_7d, 0) * 0.5
                    ELSE COALESCE(fdsa.adjusted_daily_sales_7d, 0) * 0.6 + COALESCE(fdsa.adjusted_daily_sales_14d, 0) * 0.2 + COALESCE(fdsa.adjusted_daily_sales_30d, 0) * 0.2
                END
        END AS salable_days,
        60 * (CASE
            WHEN (wd.max_brand_name LIKE '%2025%' AND (wd.receiving_cnt <= 1 OR wd.receiving_cnt IS NULL))
              OR (wd.max_brand_name LIKE '%2026%' AND (wd.receiving_cnt <= 1 OR wd.receiving_cnt IS NULL))
            THEN COALESCE(fdsa.adjusted_daily_sales_3d, 0) * 0.5 + COALESCE(fdsa.adjusted_daily_sales_7d, 0) * 0.5
            ELSE COALESCE(fdsa.adjusted_daily_sales_7d, 0) * 0.6 + COALESCE(fdsa.adjusted_daily_sales_14d, 0) * 0.2 + COALESCE(fdsa.adjusted_daily_sales_30d, 0) * 0.2
        END) - (COALESCE(fm.total, 0) + COALESCE(lw.local_quantity, 0)) AS `60d_stocko_qty`,
        90 * (CASE
            WHEN (wd.max_brand_name LIKE '%2025%' AND (wd.receiving_cnt <= 1 OR wd.receiving_cnt IS NULL))
              OR (wd.max_brand_name LIKE '%2026%' AND (wd.receiving_cnt <= 1 OR wd.receiving_cnt IS NULL))
            THEN COALESCE(fdsa.adjusted_daily_sales_3d, 0) * 0.5 + COALESCE(fdsa.adjusted_daily_sales_7d, 0) * 0.5
            ELSE COALESCE(fdsa.adjusted_daily_sales_7d, 0) * 0.6 + COALESCE(fdsa.adjusted_daily_sales_14d, 0) * 0.2 + COALESCE(fdsa.adjusted_daily_sales_30d, 0) * 0.2
        END) - (COALESCE(fm.total, 0) + COALESCE(lw.local_quantity, 0)) AS `90d_stocko_qty`,
        180 * (CASE
            WHEN (wd.max_brand_name LIKE '%2025%' AND (wd.receiving_cnt <= 1 OR wd.receiving_cnt IS NULL))
              OR (wd.max_brand_name LIKE '%2026%' AND (wd.receiving_cnt <= 1 OR wd.receiving_cnt IS NULL))
            THEN COALESCE(fdsa.adjusted_daily_sales_3d, 0) * 0.5 + COALESCE(fdsa.adjusted_daily_sales_7d, 0) * 0.5
            ELSE COALESCE(fdsa.adjusted_daily_sales_7d, 0) * 0.6 + COALESCE(fdsa.adjusted_daily_sales_14d, 0) * 0.2 + COALESCE(fdsa.adjusted_daily_sales_30d, 0) * 0.2
        END) - (COALESCE(fm.total, 0) + COALESCE(lw.local_quantity, 0)) AS `180d_stocko_qty`,
        4 * 30 * (CASE
            WHEN (wd.max_brand_name LIKE '%2025%' AND (wd.receiving_cnt <= 1 OR wd.receiving_cnt IS NULL))
              OR (wd.max_brand_name LIKE '%2026%' AND (wd.receiving_cnt <= 1 OR wd.receiving_cnt IS NULL))
            THEN COALESCE(fdsa.adjusted_daily_sales_3d, 0) * 0.5 + COALESCE(fdsa.adjusted_daily_sales_7d, 0) * 0.5
            ELSE COALESCE(fdsa.adjusted_daily_sales_7d, 0) * 0.6 + COALESCE(fdsa.adjusted_daily_sales_14d, 0) * 0.2 + COALESCE(fdsa.adjusted_daily_sales_30d, 0) * 0.2
        END) - COALESCE(fm.available_total, 0) - COALESCE(lw.local_quantity, 0) - COALESCE(fm.stock_up_num, 0) - COALESCE(lw.sc_quantity_purchase_plan, 0) AS replenish_need_qty,
        CASE WHEN COALESCE(wd.max_cg_box_pcs, 0) > 0 THEN wd.max_cg_box_pcs ELSE 50 END AS replenish_trigger_qty,
        scr.sales_change_rate_adj,
        CASE
            WHEN scr.sales_change_rate_adj IS NULL THEN 1
            WHEN 1 + scr.sales_change_rate_adj < 0 THEN 1
            ELSE 1 + scr.sales_change_rate_adj
        END AS sales_adj_factor,
        opr.final_profit_rate,
        rc.history_recovery_flag,
        rc.pre_daily_avg_sales,
        rc.pre_normal_replenish_need_qty,
        rc.pre_replenish_trigger_qty,
        rc.hist_90d_instock_days,
        rc.hist_90d_instock_sales,
        rc.hist_90d_instock_daily_sales,
        rc.history_recovery_need_qty,
        rc.support_inventory_qty,
        rc.inventory_support_days,
        rc.support_replenish_level,
        rc.support_replenish_level_sort,
        CASE
            WHEN COALESCE(rc.history_recovery_flag, 0) = 1 THEN CASE WHEN COALESCE(wd.max_cg_box_pcs, 0) > 0 THEN wd.max_cg_box_pcs ELSE 50 END
            WHEN (
                4 * 30 * (CASE
                    WHEN (wd.max_brand_name LIKE '%2025%' AND (wd.receiving_cnt <= 1 OR wd.receiving_cnt IS NULL))
                      OR (wd.max_brand_name LIKE '%2026%' AND (wd.receiving_cnt <= 1 OR wd.receiving_cnt IS NULL))
                    THEN COALESCE(fdsa.adjusted_daily_sales_3d, 0) * 0.5 + COALESCE(fdsa.adjusted_daily_sales_7d, 0) * 0.5
                    ELSE COALESCE(fdsa.adjusted_daily_sales_7d, 0) * 0.6 + COALESCE(fdsa.adjusted_daily_sales_14d, 0) * 0.2 + COALESCE(fdsa.adjusted_daily_sales_30d, 0) * 0.2
                END) - COALESCE(fm.available_total, 0) - COALESCE(lw.local_quantity, 0) - COALESCE(fm.stock_up_num, 0) - COALESCE(lw.sc_quantity_purchase_plan, 0)
            ) > 0 AND COALESCE(wd.max_cg_box_pcs, 0) > 0
            THEN GREATEST(ROUND((
                4 * 30 * (CASE
                    WHEN (wd.max_brand_name LIKE '%2025%' AND (wd.receiving_cnt <= 1 OR wd.receiving_cnt IS NULL))
                      OR (wd.max_brand_name LIKE '%2026%' AND (wd.receiving_cnt <= 1 OR wd.receiving_cnt IS NULL))
                    THEN COALESCE(fdsa.adjusted_daily_sales_3d, 0) * 0.5 + COALESCE(fdsa.adjusted_daily_sales_7d, 0) * 0.5
                    ELSE COALESCE(fdsa.adjusted_daily_sales_7d, 0) * 0.6 + COALESCE(fdsa.adjusted_daily_sales_14d, 0) * 0.2 + COALESCE(fdsa.adjusted_daily_sales_30d, 0) * 0.2
                END) - COALESCE(fm.available_total, 0) - COALESCE(lw.local_quantity, 0) - COALESCE(fm.stock_up_num, 0) - COALESCE(lw.sc_quantity_purchase_plan, 0)
            ) * (CASE WHEN scr.sales_change_rate_adj IS NULL THEN 1 WHEN 1 + scr.sales_change_rate_adj < 0 THEN 1 ELSE 1 + scr.sales_change_rate_adj END) / wd.max_cg_box_pcs, 0), 1) * wd.max_cg_box_pcs
            WHEN (
                4 * 30 * (CASE
                    WHEN (wd.max_brand_name LIKE '%2025%' AND (wd.receiving_cnt <= 1 OR wd.receiving_cnt IS NULL))
                      OR (wd.max_brand_name LIKE '%2026%' AND (wd.receiving_cnt <= 1 OR wd.receiving_cnt IS NULL))
                    THEN COALESCE(fdsa.adjusted_daily_sales_3d, 0) * 0.5 + COALESCE(fdsa.adjusted_daily_sales_7d, 0) * 0.5
                    ELSE COALESCE(fdsa.adjusted_daily_sales_7d, 0) * 0.6 + COALESCE(fdsa.adjusted_daily_sales_14d, 0) * 0.2 + COALESCE(fdsa.adjusted_daily_sales_30d, 0) * 0.2
                END) - COALESCE(fm.available_total, 0) - COALESCE(lw.local_quantity, 0) - COALESCE(fm.stock_up_num, 0) - COALESCE(lw.sc_quantity_purchase_plan, 0)
            ) > 0
            THEN GREATEST(ROUND((
                4 * 30 * (CASE
                    WHEN (wd.max_brand_name LIKE '%2025%' AND (wd.receiving_cnt <= 1 OR wd.receiving_cnt IS NULL))
                      OR (wd.max_brand_name LIKE '%2026%' AND (wd.receiving_cnt <= 1 OR wd.receiving_cnt IS NULL))
                    THEN COALESCE(fdsa.adjusted_daily_sales_3d, 0) * 0.5 + COALESCE(fdsa.adjusted_daily_sales_7d, 0) * 0.5
                    ELSE COALESCE(fdsa.adjusted_daily_sales_7d, 0) * 0.6 + COALESCE(fdsa.adjusted_daily_sales_14d, 0) * 0.2 + COALESCE(fdsa.adjusted_daily_sales_30d, 0) * 0.2
                END) - COALESCE(fm.available_total, 0) - COALESCE(lw.local_quantity, 0) - COALESCE(fm.stock_up_num, 0) - COALESCE(lw.sc_quantity_purchase_plan, 0)
            ) * (CASE WHEN scr.sales_change_rate_adj IS NULL THEN 1 WHEN 1 + scr.sales_change_rate_adj < 0 THEN 1 ELSE 1 + scr.sales_change_rate_adj END), 0), 50)
            ELSE ROUND((
                4 * 30 * (CASE
                    WHEN (wd.max_brand_name LIKE '%2025%' AND (wd.receiving_cnt <= 1 OR wd.receiving_cnt IS NULL))
                      OR (wd.max_brand_name LIKE '%2026%' AND (wd.receiving_cnt <= 1 OR wd.receiving_cnt IS NULL))
                    THEN COALESCE(fdsa.adjusted_daily_sales_3d, 0) * 0.5 + COALESCE(fdsa.adjusted_daily_sales_7d, 0) * 0.5
                    ELSE COALESCE(fdsa.adjusted_daily_sales_7d, 0) * 0.6 + COALESCE(fdsa.adjusted_daily_sales_14d, 0) * 0.2 + COALESCE(fdsa.adjusted_daily_sales_30d, 0) * 0.2
                END) - COALESCE(fm.available_total, 0) - COALESCE(lw.local_quantity, 0) - COALESCE(fm.stock_up_num, 0) - COALESCE(lw.sc_quantity_purchase_plan, 0)
            ) * (CASE WHEN scr.sales_change_rate_adj IS NULL THEN 1 WHEN 1 + scr.sales_change_rate_adj < 0 THEN 1 ELSE 1 + scr.sales_change_rate_adj END), 0)
        END AS replenish_qty,
        CASE
            WHEN COALESCE(rc.history_recovery_flag, 0) = 1 THEN CASE WHEN COALESCE(wd.max_cg_box_pcs, 0) > 0 THEN 1 ELSE 0 END
            WHEN (
                4 * 30 * (CASE
                    WHEN (wd.max_brand_name LIKE '%2025%' AND (wd.receiving_cnt <= 1 OR wd.receiving_cnt IS NULL))
                      OR (wd.max_brand_name LIKE '%2026%' AND (wd.receiving_cnt <= 1 OR wd.receiving_cnt IS NULL))
                    THEN COALESCE(fdsa.adjusted_daily_sales_3d, 0) * 0.5 + COALESCE(fdsa.adjusted_daily_sales_7d, 0) * 0.5
                    ELSE COALESCE(fdsa.adjusted_daily_sales_7d, 0) * 0.6 + COALESCE(fdsa.adjusted_daily_sales_14d, 0) * 0.2 + COALESCE(fdsa.adjusted_daily_sales_30d, 0) * 0.2
                END) - COALESCE(fm.available_total, 0) - COALESCE(lw.local_quantity, 0) - COALESCE(fm.stock_up_num, 0) - COALESCE(lw.sc_quantity_purchase_plan, 0)
            ) > 0 AND COALESCE(wd.max_cg_box_pcs, 0) > 0
            THEN GREATEST(ROUND((
                4 * 30 * (CASE
                    WHEN (wd.max_brand_name LIKE '%2025%' AND (wd.receiving_cnt <= 1 OR wd.receiving_cnt IS NULL))
                      OR (wd.max_brand_name LIKE '%2026%' AND (wd.receiving_cnt <= 1 OR wd.receiving_cnt IS NULL))
                    THEN COALESCE(fdsa.adjusted_daily_sales_3d, 0) * 0.5 + COALESCE(fdsa.adjusted_daily_sales_7d, 0) * 0.5
                    ELSE COALESCE(fdsa.adjusted_daily_sales_7d, 0) * 0.6 + COALESCE(fdsa.adjusted_daily_sales_14d, 0) * 0.2 + COALESCE(fdsa.adjusted_daily_sales_30d, 0) * 0.2
                END) - COALESCE(fm.available_total, 0) - COALESCE(lw.local_quantity, 0) - COALESCE(fm.stock_up_num, 0) - COALESCE(lw.sc_quantity_purchase_plan, 0)
            ) * (CASE WHEN scr.sales_change_rate_adj IS NULL THEN 1 WHEN 1 + scr.sales_change_rate_adj < 0 THEN 1 ELSE 1 + scr.sales_change_rate_adj END) / wd.max_cg_box_pcs, 0), 1)
            WHEN (
                4 * 30 * (CASE
                    WHEN (wd.max_brand_name LIKE '%2025%' AND (wd.receiving_cnt <= 1 OR wd.receiving_cnt IS NULL))
                      OR (wd.max_brand_name LIKE '%2026%' AND (wd.receiving_cnt <= 1 OR wd.receiving_cnt IS NULL))
                    THEN COALESCE(fdsa.adjusted_daily_sales_3d, 0) * 0.5 + COALESCE(fdsa.adjusted_daily_sales_7d, 0) * 0.5
                    ELSE COALESCE(fdsa.adjusted_daily_sales_7d, 0) * 0.6 + COALESCE(fdsa.adjusted_daily_sales_14d, 0) * 0.2 + COALESCE(fdsa.adjusted_daily_sales_30d, 0) * 0.2
                END) - COALESCE(fm.available_total, 0) - COALESCE(lw.local_quantity, 0) - COALESCE(fm.stock_up_num, 0) - COALESCE(lw.sc_quantity_purchase_plan, 0)
            ) > 0 THEN 0
            ELSE NULL
        END AS replenish_box_qty,
        CASE WHEN COALESCE(psm.sales_30d, 0) = 0 THEN NULL ELSE fm.available_total / psm.sales_30d END AS amz_instock_sales_ratio,
        CASE WHEN COALESCE(psm.sales_30d, 0) = 0 THEN NULL ELSE (COALESCE(fm.total, 0) + COALESCE(lw.local_quantity, 0)) / psm.sales_30d END AS instock_intrans_pur_sales_ratio
    FROM tmp_abcd_labels AS wd
    LEFT JOIN tmp_fba_msku AS fm
      ON wd.country_category = fm.country_category
     AND wd.seller_name_new = fm.seller_name_new
     AND wd.seller_sku_adj = fm.seller_sku_adj
    LEFT JOIN tmp_local_warehouse AS lw
      ON wd.country_category = lw.country_category
     AND wd.seller_name_new = lw.seller_name_new
     AND wd.seller_sku_adj = lw.seller_sku_adj
    LEFT JOIN tmp_final_daily_sales_adj AS fdsa
      ON wd.country_category = fdsa.country_category
     AND wd.seller_name_new = fdsa.seller_name_new
     AND wd.seller_sku_adj = fdsa.seller_sku_adj
    LEFT JOIN tmp_sales_change_rate AS scr
      ON wd.country_category = scr.country_category
     AND wd.seller_name_new = scr.seller_name_new
     AND wd.seller_sku_adj = scr.seller_sku_adj
    LEFT JOIN tmp_orders_profit_result AS opr
      ON wd.country_category = opr.country_category
     AND wd.seller_name_new = opr.seller_name_new
     AND wd.seller_sku_adj = opr.seller_sku_adj
    LEFT JOIN tmp_prod_perf_sku_metrics AS psm
      ON wd.country_category = psm.country_category
     AND wd.seller_name_new = psm.seller_name_new
     AND wd.seller_sku_adj = psm.seller_sku_adj
    LEFT JOIN tmp_support_layer_all AS rc
      ON wd.country_category = rc.country_category
     AND wd.seller_name_new = rc.seller_name_new
     AND wd.seller_sku_adj = rc.seller_sku_adj;

    ALTER TABLE tmp_replenish_result
        ADD INDEX idx_rr_dim (country_category(3), seller_name_new(64), seller_sku_adj(64));

    -- ============================================================
    -- 13. 写入目标宽表
    -- ============================================================
    INSERT INTO `dws_库存宽表` (
        `数据日期`, `店铺名`, `站点`, `仓库名`, `SKU`, `MSKU`, `ASIN`, `FNSKU`,
        `新品/老品标识`, `市场状态`, `店铺名称拼接`, `在售站点`, `未售站点`,
        `销售状态`, `市场拼接`, `店铺名副本`, `店铺名UE`, `本地名称`,
        `品牌名称`, `负责人`, `销售团队`, `最大收货时间`, `收货次数`,
        `单箱数量`, `采购价格`, `头程成本`, `缺货状态`,
        `结算ABCD分类`, `结算毛利率范围`, `订单ABCD分类`, `近1月订单ABCD分类`, `近一季度订单ABCD分类`,
        `FBA+本地库存数量`, `总库存`, `可用库存`, `可售库存`, `实际在途`, `不可售库存`,
        `本地可用`, `采购在途`, `采购计划`, `待检待上架量`, `本地仓数量`,
        `近90天FBA可售天数`, `近30天FBA可售天数`, `近14天FBA可售天数`, `近7天FBA可售天数`, `近3天FBA可售天数`,
        `近90天销量`, `近30天销量`, `近14天销量`, `近7天销量`, `近3天销量`,
        `近30天销售额`, `近14天销售额`, `近7天销售额`, `近3天销售额`,
        `近30天订单毛利润`, `近14天订单毛利润`, `近7天订单毛利润`, `近3天订单毛利润`,
        `近30天订单毛利率`, `近14天订单毛利率`, `近7天订单毛利率`, `近3天订单毛利率`,
        `近30天结算销售额`, `近14天结算销售额`, `近7天结算销售额`, `近3天结算销售额`,
        `近30天结算毛利润`, `近14天结算毛利润`, `近7天结算毛利润`, `近3天结算毛利润`,
        `近30天结算毛利率`, `近14天结算毛利率`, `近7天结算毛利率`, `近3天结算毛利率`,
        `前日均销量`, `前正常补货需求量`, `前补货触发量`,
        `近90天有货天数`, `近90天有货销量`, `近90天有货日均销量`,
        `历史恢复需求量`, `历史恢复标记`,
        `库存支撑数量`, `库存支撑天数`, `库存支撑补货等级`, `库存支撑补货等级排序`,
        `补货_新品老品`, `日均销量`, `补足月数`, `可售天数`,
        `60天缺货数量`, `90天缺货数量`, `180天缺货数量`, `补货周期计算缺货数量`,
        `补货需求量`, `补货触发量`, `销售变化调整率`, `销售调整系数`, `原始订单毛利率`,
        `补货数量`, `补货箱数`, `补货金额`, `亚马逊库存销售比`, `库存+在途+采购销售比`,
        `是否需要补货`, `跟卖标记`, `历史90天兜底标记`, `create_time`
    )
    SELECT
        v_data_date AS `数据日期`,
        f.seller_name_new AS `店铺名`,
        f.country_category AS `站点`,
        f.`name` AS `仓库名`,
        f.sku AS `SKU`,
        f.seller_sku_adj AS `MSKU`,
        f.asin AS `ASIN`,
        li.max_fnsku AS `FNSKU`,
        abcd.new_old_product AS `新品/老品标识`,
        li.marketplace_status AS `市场状态`,
        li.seller_name_concat AS `店铺名称拼接`,
        li.onsale_sites AS `在售站点`,
        li.unsale_sites AS `未售站点`,
        li.sales_status AS `销售状态`,
        li.marketplace_concat AS `市场拼接`,
        li.seller_name_copy AS `店铺名副本`,
        li.seller_name_ue AS `店铺名UE`,
        li.max_local_name AS `本地名称`,
        abcd.max_brand_name AS `品牌名称`,
        li.principal AS `负责人`,
        li.sales_team_1 AS `销售团队`,
        abcd.max_receiving_time AS `最大收货时间`,
        abcd.receiving_cnt AS `收货次数`,
        COALESCE(abcd.max_cg_box_pcs, 0) AS `单箱数量`,
        COALESCE(abcd.max_cg_price, f.cg_price) AS `采购价格`,
        COALESCE(abcd.max_cg_transport_costs, f.cg_transport_costs) AS `头程成本`,
        abcd.stockout_status AS `缺货状态`,
        abcd.abcd_category AS `结算ABCD分类`,
        abcd.gp_margin_range AS `结算毛利率范围`,
        abcd.predict_abcd_category AS `订单ABCD分类`,
        abcd.pre_1m_predict_abcd_category AS `近1月订单ABCD分类`,
        abcd.pre_1q_predict_abcd_category AS `近一季度订单ABCD分类`,
        COALESCE(fm.total, 0) + COALESCE(lw.local_quantity, 0) AS `FBA+本地库存数量`,
        f.total AS `总库存`,
        f.available_total AS `可用库存`,
        f.afn_fulfillable_quantity AS `可售库存`,
        f.stock_up_num AS `实际在途`,
        f.afn_unsellable_quantity AS `不可售库存`,
        lw.sc_quantity_local_valid AS `本地可用`,
        lw.sc_quantity_purchase_shipping AS `采购在途`,
        lw.sc_quantity_purchase_plan AS `采购计划`,
        lw.sc_quantity_local_qc AS `待检待上架量`,
        lw.local_quantity AS `本地仓数量`,
        ks.r_90d_salable_days AS `近90天FBA可售天数`,
        ks.r_30d_salable_days AS `近30天FBA可售天数`,
        ks.r_14d_salable_days AS `近14天FBA可售天数`,
        ks.r_7d_salable_days AS `近7天FBA可售天数`,
        ks.r_3d_salable_days AS `近3天FBA可售天数`,
        psm.sales_90d AS `近90天销量`,
        fdsa.final_sales_30d AS `近30天销量`,
        fdsa.final_sales_14d AS `近14天销量`,
        fdsa.final_sales_7d AS `近7天销量`,
        fdsa.final_sales_3d AS `近3天销量`,
        psm.amount_30d AS `近30天销售额`,
        psm.amount_14d AS `近14天销售额`,
        psm.amount_7d AS `近7天销售额`,
        psm.amount_3d AS `近3天销售额`,
        psm.pprofit_30d AS `近30天订单毛利润`,
        psm.pprofit_14d AS `近14天订单毛利润`,
        psm.pprofit_7d AS `近7天订单毛利润`,
        psm.pprofit_3d AS `近3天订单毛利润`,
        psm.pprofit_ratio_30d AS `近30天订单毛利率`,
        psm.pprofit_ratio_14d AS `近14天订单毛利率`,
        psm.pprofit_ratio_7d AS `近7天订单毛利率`,
        psm.pprofit_ratio_3d AS `近3天订单毛利率`,
        sp.gamount_30d AS `近30天结算销售额`,
        sp.gamount_14d AS `近14天结算销售额`,
        sp.gamount_7d AS `近7天结算销售额`,
        sp.gamount_3d AS `近3天结算销售额`,
        sp.gprofit_30d AS `近30天结算毛利润`,
        sp.gprofit_14d AS `近14天结算毛利润`,
        sp.gprofit_7d AS `近7天结算毛利润`,
        sp.gprofit_3d AS `近3天结算毛利润`,
        sp.gprofit_ratio_30d AS `近30天结算毛利率`,
        sp.gprofit_ratio_14d AS `近14天结算毛利率`,
        sp.gprofit_ratio_7d AS `近7天结算毛利率`,
        sp.gprofit_ratio_3d AS `近3天结算毛利率`,
        rr.pre_daily_avg_sales AS `前日均销量`,
        rr.pre_normal_replenish_need_qty AS `前正常补货需求量`,
        rr.pre_replenish_trigger_qty AS `前补货触发量`,
        rr.hist_90d_instock_days AS `近90天有货天数`,
        rr.hist_90d_instock_sales AS `近90天有货销量`,
        rr.hist_90d_instock_daily_sales AS `近90天有货日均销量`,
        rr.history_recovery_need_qty AS `历史恢复需求量`,
        rr.history_recovery_flag AS `历史恢复标记`,
        rr.support_inventory_qty AS `库存支撑数量`,
        rr.inventory_support_days AS `库存支撑天数`,
        rr.support_replenish_level AS `库存支撑补货等级`,
        rr.support_replenish_level_sort AS `库存支撑补货等级排序`,
        rr.new_old_prod_jg AS `补货_新品老品`,
        rr.daily_avg_sales AS `日均销量`,
        rr.replenish_comp_months AS `补足月数`,
        rr.salable_days AS `可售天数`,
        rr.`60d_stocko_qty` AS `60天缺货数量`,
        rr.`90d_stocko_qty` AS `90天缺货数量`,
        rr.`180d_stocko_qty` AS `180天缺货数量`,
        rr.replenish_need_qty AS `补货周期计算缺货数量`,
        rr.replenish_need_qty AS `补货需求量`,
        rr.replenish_trigger_qty AS `补货触发量`,
        rr.sales_change_rate_adj AS `销售变化调整率`,
        rr.sales_adj_factor AS `销售调整系数`,
        rr.final_profit_rate AS `原始订单毛利率`,
        rr.replenish_qty AS `补货数量`,
        rr.replenish_box_qty AS `补货箱数`,
        (COALESCE(abcd.max_cg_price, f.cg_price, 0) + COALESCE(abcd.max_cg_transport_costs, f.cg_transport_costs, 0)) * rr.replenish_qty AS `补货金额`,
        rr.amz_instock_sales_ratio AS `亚马逊库存销售比`,
        rr.instock_intrans_pur_sales_ratio AS `库存+在途+采购销售比`,
        CASE
            WHEN rr.replenish_need_qty > 0
              OR COALESCE(rr.history_recovery_flag, 0) = 1
            THEN '是'
            ELSE '否'
        END AS `是否需要补货`,
        COALESCE(fo.fllow_flag, 0) AS `跟卖标记`,
        rr.history_recovery_flag AS `历史90天兜底标记`,
        NOW() AS `create_time`
    FROM tmp_fba_wh AS f
    LEFT JOIN tmp_listing_info AS li
      ON f.country_category = li.country_category
     AND f.seller_name_new = li.seller_name_new
     AND f.seller_sku_adj = li.seller_sku_adj
    LEFT JOIN tmp_abcd_labels AS abcd
      ON f.country_category = abcd.country_category
     AND f.seller_name_new = abcd.seller_name_new
     AND f.seller_sku_adj = abcd.seller_sku_adj
    LEFT JOIN tmp_fba_msku AS fm
      ON f.country_category = fm.country_category
     AND f.seller_name_new = fm.seller_name_new
     AND f.seller_sku_adj = fm.seller_sku_adj
    LEFT JOIN tmp_local_warehouse AS lw
      ON f.country_category = lw.country_category
     AND f.seller_name_new = lw.seller_name_new
     AND f.seller_sku_adj = lw.seller_sku_adj
    LEFT JOIN tmp_salable_days AS ks
      ON f.country_category = ks.country_category
     AND f.seller_name_new = ks.seller_name_new
     AND f.seller_sku_adj = ks.seller_sku_adj
    LEFT JOIN tmp_prod_perf_sku_metrics AS psm
      ON f.country_category = psm.country_category
     AND f.seller_name_new = psm.seller_name_new
     AND f.seller_sku_adj = psm.seller_sku_adj
    LEFT JOIN tmp_final_daily_sales_adj AS fdsa
      ON f.country_category = fdsa.country_category
     AND f.seller_name_new = fdsa.seller_name_new
     AND f.seller_sku_adj = fdsa.seller_sku_adj
    LEFT JOIN tmp_settlement_profit AS sp
      ON f.country_category = sp.country_category
     AND f.seller_name_new = sp.seller_name_new
     AND f.seller_sku_adj = sp.seller_sku_adj
    LEFT JOIN tmp_replenish_result AS rr
      ON f.country_category = rr.country_category
     AND f.seller_name_new = rr.seller_name_new
     AND f.seller_sku_adj = rr.seller_sku_adj
    LEFT JOIN tmp_prod_perf_follow_origin AS fo
      ON f.country_category = fo.country_category
     AND f.seller_name_new = fo.seller_name_new
     AND f.seller_sku_adj = fo.seller_sku_adj;

    SET v_record_count = ROW_COUNT();

    UPDATE etl_datasync.etl_execution_log
    SET status = 'success',
        end_time = NOW(),
        data_time = v_data_date,
        record_count = v_record_count
    WHERE id = v_log_id;

END //

DELIMITER ;

DROP EVENT IF EXISTS dws_datasync.evt_库存宽表;
DELIMITER //

CREATE EVENT dws_datasync.evt_库存宽表
    ON SCHEDULE EVERY 1 DAY
    STARTS TIMESTAMP(CURRENT_DATE(), '07:00:00')
    ON COMPLETION PRESERVE
    ENABLE
DO
BEGIN
    CALL dws_datasync.sp_库存宽表();
END //

DELIMITER ;

-- DROP EVENT IF EXISTS dws_datasync.evt_G库存宽表_1_0;
-- DROP PROCEDURE IF EXISTS dws_datasync.sp_G库存宽表_1_0;
