-- ============================================================================
-- V34 change based on v33
-- 1) 保持 v33 的既有标签口径、指标计算规则及标签详情配置。
-- 2) 运营状态改为仅按供应链库存判定：
--    断货中 = FBA 可售库存(afn_fulfillable_quantity)=0，且 FBA 在途(stock_up_num)或本地仓数量>0；
--    停售   = FBA 可售库存=0，且 FBA 在途与本地仓数量均=0。
-- 3) 运营状态专用库存源：
--    etl_dispose_lx_storage_fba_warehouse_detail.afn_fulfillable_quantity / stock_up_num；
--    etl_dispose_lx_replenishment_suggest_restocking 的四项本地仓数量之和。
-- 4) 生命周期、站点生命周期：新品期结束后，未满足成熟期条件的商品继续归入成长期。
-- 5) 首次回补 2026-07-18、2026-07-19；日常运行及回补均仅保留业务日期最近两天。
-- ============================================================================

DROP EVENT IF EXISTS `dws_datasync`.`ev_dws_label_table_daily`;
DROP EVENT IF EXISTS `dws_datasync`.`ev_dws_标签表_daily`;
DROP PROCEDURE IF EXISTS `dws_datasync`.`sp_dws_label_table_daily`;
DROP PROCEDURE IF EXISTS `dws_datasync`.`sp_dws_标签表_含国家销售角色_daily`;
DROP PROCEDURE IF EXISTS `dws_datasync`.`sp_dws_国家销售角色_daily`;
DROP PROCEDURE IF EXISTS `dws_datasync`.`sp_dws_标签表_含站点标签_daily`;
DROP PROCEDURE IF EXISTS `dws_datasync`.`sp_dws_站点销售角色_站点生命周期_daily`;
DROP PROCEDURE IF EXISTS `dws_datasync`.`sp_dws_标签表_daily`;
DROP PROCEDURE IF EXISTS `dws_datasync`.`sp_dws_标签表_按日期_daily`;
DROP PROCEDURE IF EXISTS `dws_datasync`.`sp_dws_站点销售角色_站点生命周期_按日期_daily`;
DROP PROCEDURE IF EXISTS `dws_datasync`.`sp_dws_标签表_含站点标签_按日期_daily`;

-- 注意：本部署文件保留现有 dws_datasync.dws_标签表，不执行 DROP/CREATE TABLE。
DELIMITER //
CREATE PROCEDURE `dws_datasync`.`sp_dws_标签表_按日期_daily`(IN p_data_date DATE)
BEGIN
    DECLARE v_data_date date DEFAULT NULL;
    DECLARE v_max_source_date date DEFAULT NULL;
    DECLARE v_next_date date DEFAULT NULL;
    DECLARE v_7d date DEFAULT NULL;
    DECLARE v_14d date DEFAULT NULL;
    DECLARE v_30d date DEFAULT NULL;
    DECLARE v_90d date DEFAULT NULL;
    DECLARE v_180d date DEFAULT NULL;
    DECLARE v_proc_name varchar(255) DEFAULT 'sp_dws_标签表_按日期_daily';
    DECLARE v_log_id int DEFAULT NULL;
    DECLARE v_record_count int DEFAULT 0;
    DECLARE v_error_msg text;
    DECLARE v_stage varchar(255) DEFAULT '初始化';

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS CONDITION 1 v_error_msg = MESSAGE_TEXT;
        SET v_error_msg = CONCAT('[执行阶段：', v_stage, '] ', v_error_msg);
        ROLLBACK;

        IF v_log_id IS NOT NULL THEN
            UPDATE `etl_datasync`.`etl_execution_log`
            SET `status` = 'error',
                `end_time` = NOW()
            WHERE `id` = v_log_id;

            INSERT INTO `etl_datasync`.`etl_error_log`
                (`proc_name`, `error_time`, `error_message`, `execution_log_id`)
            VALUES
                (v_proc_name, NOW(), v_error_msg, v_log_id);
        END IF;

        -- 不吞掉异常，避免客户端看到“执行成功”但标签未写入。
        RESIGNAL;
    END;

    INSERT INTO `etl_datasync`.`etl_execution_log`
        (`proc_name`, `start_time`, `status`)
    VALUES
        (v_proc_name, NOW(), 'started');

    SET v_log_id = LAST_INSERT_ID();

    SELECT MAX(DATE(`start_date`))
    INTO v_max_source_date
    FROM `dwd_datasync`.`lx_statistics_product_performance`;

    IF p_data_date IS NOT NULL AND (v_max_source_date IS NULL OR p_data_date > v_max_source_date) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = '指定业务日期晚于产品表现表的最新业务日期，不能回补。';
    END IF;

    SET v_data_date = COALESCE(p_data_date, v_max_source_date);

    IF v_data_date IS NOT NULL THEN
        SET v_next_date = DATE_ADD(v_data_date, INTERVAL 1 DAY);
        SET v_7d = DATE_SUB(v_data_date, INTERVAL 6 DAY);
        SET v_14d = DATE_SUB(v_data_date, INTERVAL 13 DAY);
        SET v_30d = DATE_SUB(v_data_date, INTERVAL 29 DAY);
        SET v_90d = DATE_SUB(v_data_date, INTERVAL 89 DAY);
        SET v_180d = DATE_SUB(v_data_date, INTERVAL 180 DAY);

        SET v_stage = 'tmp_active_labels';

        DROP TEMPORARY TABLE IF EXISTS tmp_active_labels;
        CREATE TEMPORARY TABLE tmp_active_labels AS
        SELECT DISTINCT CAST(`label_name` AS CHAR(100))     label_name,
                        CAST(`sub_label_name` AS CHAR(100)) sub_label_name,
                        `sub_label_id`                      sub_label_id
        FROM `dws_datasync`.`dws_标签详情表`
        WHERE CAST(`status` AS CHAR) = '启用'
          AND `label_name` IS NOT NULL
          AND `sub_label_name` IS NOT NULL;


        SET v_stage = 'tmp_listing_latest';
        -- 全量 Listing 最新同步记录：每个 marketplace+seller+seller_sku 仅保留 create_time 最大的一条。
        -- 同时排除退款占位 SKU（amzn.gr 开头）和 Amazon 占位 SKU（Amazon 开头，大小写不敏感）。
        DROP TEMPORARY TABLE IF EXISTS tmp_listing_latest;
        CREATE TEMPORARY TABLE tmp_listing_latest AS
        SELECT CAST(li.`marketplace` AS CHAR(50))  AS marketplace,
               CAST(li.`seller_name` AS CHAR(50))  AS seller_name,
               CAST(li.`seller_sku` AS CHAR(255)) AS seller_sku,
               li.`create_time`,
               CAST(li.`status` AS CHAR(50))      AS listing_status
        FROM (
            SELECT li.*,
                   ROW_NUMBER() OVER (
                       PARTITION BY CAST(li.`marketplace` AS CHAR), CAST(li.`seller_name` AS CHAR), CAST(li.`seller_sku` AS CHAR)
                       ORDER BY li.`create_time` DESC, li.`id` DESC
                   ) AS rn
            FROM `dwd_datasync`.`lx_sales_mws_listing` li
            WHERE li.`seller_sku` IS NOT NULL
              AND CAST(li.`seller_sku` AS CHAR) <> ''
              AND LOWER(TRIM(CAST(li.`seller_sku` AS CHAR))) NOT LIKE 'amzn.gr%'
              AND UPPER(TRIM(CAST(li.`seller_sku` AS CHAR))) NOT LIKE 'AMAZON%'
        ) li
        WHERE li.rn = 1;
        ALTER TABLE tmp_listing_latest
            ADD INDEX idx_tmp_listing_latest (marketplace, seller_name, seller_sku);

        SET v_stage = 'tmp_listing_keys';
        -- 以 tmp_listing_latest 为全量维度主表，生成国家类别+店铺+MSKU 主键。
        -- tmp_listing_latest 已只保留每个 marketplace+seller+seller_sku 最新 create_time 记录，并排除 amzn.gr 和 Amazon 开头 SKU。
        DROP TEMPORARY TABLE IF EXISTS tmp_listing_keys;
        CREATE TEMPORARY TABLE tmp_listing_keys AS
        SELECT DISTINCT
               CASE
                   WHEN CAST(li.`marketplace` AS CHAR) = '英国' THEN '英国站'
                   WHEN CAST(li.`marketplace` AS CHAR) IN ('美国', '加拿大', '巴西', '墨西哥') THEN '北美站'
                   ELSE '欧洲站' END AS country_category,
               CASE
                   WHEN LOCATE('-', SUBSTRING_INDEX(CAST(li.`seller_name` AS CHAR), ' ', 1)) > 0 THEN LEFT(
                           SUBSTRING_INDEX(CAST(li.`seller_name` AS CHAR), ' ', 1),
                           LOCATE('-', SUBSTRING_INDEX(CAST(li.`seller_name` AS CHAR), ' ', 1)) - 1)
                   ELSE SUBSTRING_INDEX(CAST(li.`seller_name` AS CHAR), ' ', 1) END AS store,
               CAST(li.`seller_sku` AS CHAR(255)) AS msku
        FROM tmp_listing_latest li;
        ALTER TABLE tmp_listing_keys
            ADD INDEX idx_tmp_listing_keys (country_category, store, MSKU);
        -- 性能优化：产品表现表约 360 万行且仅有主键索引。以下临时表只保留本次标签涉及的
        -- 国家类别+店铺+MSKU，并一次完成国家/店铺/MSKU/日期标准化；后续断货、创建日期、
        -- 客户体验、站点状态、流量结构均复用本表，标签规则和时间口径不变。
        SET v_stage = 'tmp_perf';
        DROP TEMPORARY TABLE IF EXISTS tmp_perf;
        CREATE TEMPORARY TABLE tmp_perf AS
        SELECT k.country_category,
               NULL                  AS                                                         country,
               k.store,
               k.MSKU,
               MIN(CASE
                       WHEN p.`product_create_time` REGEXP '^[0-9]{4}-[0-9]{2}-[0-9]{2}'
                           THEN STR_TO_DATE(LEFT(p.`product_create_time`, 10), '%Y-%m-%d') END) product_create_date,
               SUM(CASE
                       WHEN DATE(p.`start_date`) BETWEEN v_7d AND v_data_date THEN COALESCE(p.`volume`, 0)
                       ELSE 0 END) / 7.0                                                        vol_7d,
               SUM(CASE
                       WHEN DATE(p.`start_date`) BETWEEN v_14d AND v_data_date THEN COALESCE(p.`volume`, 0)
                       ELSE 0 END) / 14.0                                                       vol_14d,
               SUM(CASE
                       WHEN DATE(p.`start_date`) BETWEEN v_30d AND v_data_date THEN COALESCE(p.`volume`, 0)
                       ELSE 0 END) / 30.0                                                       vol_30d,
               SUM(CASE
                       WHEN DATE(p.`start_date`) BETWEEN v_90d AND v_data_date THEN COALESCE(p.`volume`, 0)
                       ELSE 0 END) / 90.0                                                       vol_90d,
               CASE
                   WHEN SUM(CASE
                                WHEN DATE(p.`start_date`) BETWEEN v_7d AND v_data_date THEN COALESCE(p.`amount`, 0)
                                ELSE 0 END) > 0 THEN SUM(CASE
                                                             WHEN DATE(p.`start_date`) BETWEEN v_7d AND v_data_date
                                                                 THEN CASE WHEN COALESCE(p.`volume`, 0) = 0 THEN 0
                                                                           ELSE COALESCE(p.`predict_gross_profit`, 0) END
                                                             ELSE 0 END) / SUM(CASE
                                                                                   WHEN DATE(p.`start_date`) BETWEEN v_7d AND v_data_date
                                                                                       THEN COALESCE(p.`amount`, 0)
                                                                                   ELSE 0 END) * 100
                   ELSE 0 END                                                                   margin_7d,
               CASE
                   WHEN SUM(CASE
                                WHEN DATE(p.`start_date`) BETWEEN v_14d AND v_data_date THEN COALESCE(p.`amount`, 0)
                                ELSE 0 END) > 0 THEN SUM(CASE
                                                             WHEN DATE(p.`start_date`) BETWEEN v_14d AND v_data_date
                                                                 THEN CASE WHEN COALESCE(p.`volume`, 0) = 0 THEN 0
                                                                           ELSE COALESCE(p.`predict_gross_profit`, 0) END
                                                             ELSE 0 END) / SUM(CASE
                                                                                   WHEN DATE(p.`start_date`) BETWEEN v_14d AND v_data_date
                                                                                       THEN COALESCE(p.`amount`, 0)
                                                                                   ELSE 0 END) * 100
                   ELSE 0 END                                                                   margin_14d,
               CASE
                   WHEN SUM(CASE
                                WHEN DATE(p.`start_date`) BETWEEN v_30d AND v_data_date THEN COALESCE(p.`amount`, 0)
                                ELSE 0 END) > 0 THEN SUM(CASE
                                                             WHEN DATE(p.`start_date`) BETWEEN v_30d AND v_data_date
                                                                 THEN CASE WHEN COALESCE(p.`volume`, 0) = 0 THEN 0
                                                                           ELSE COALESCE(p.`predict_gross_profit`, 0) END
                                                             ELSE 0 END) / SUM(CASE
                                                                                   WHEN DATE(p.`start_date`) BETWEEN v_30d AND v_data_date
                                                                                       THEN COALESCE(p.`amount`, 0)
                                                                                   ELSE 0 END) * 100
                   ELSE 0 END                                                                   margin_30d,
               CASE
                   WHEN SUM(CASE
                                WHEN DATE(p.`start_date`) BETWEEN v_90d AND v_data_date THEN COALESCE(p.`amount`, 0)
                                ELSE 0 END) > 0 THEN SUM(CASE
                                                             WHEN DATE(p.`start_date`) BETWEEN v_90d AND v_data_date
                                                                 THEN CASE WHEN COALESCE(p.`volume`, 0) = 0 THEN 0
                                                                           ELSE COALESCE(p.`predict_gross_profit`, 0) END
                                                             ELSE 0 END) / SUM(CASE
                                                                                   WHEN DATE(p.`start_date`) BETWEEN v_90d AND v_data_date
                                                                                       THEN COALESCE(p.`amount`, 0)
                                                                                   ELSE 0 END) * 100
                   ELSE 0 END                                                                   margin_90d,
               SUM(CASE
                       WHEN DATE(p.`start_date`) = v_data_date THEN COALESCE(p.`afn_fulfillable_quantity`, 0)
                       ELSE 0 END)                                                              fba_current,
               SUM(COALESCE(p.`volume`, 0))                                                     vol_stat_period,
               0                                                                                has_fba_oos_stat_period,
               MAX(CASE WHEN p.`country` IS NOT NULL THEN 1 ELSE 0 END)                              AS has_product_data
        FROM tmp_listing_keys k
                 LEFT JOIN `dwd_datasync`.`lx_statistics_product_performance` p
                            ON k.country_category = CASE
                                                        WHEN CAST(p.`country` AS CHAR) = '英国' THEN '英国站'
                                                        WHEN CAST(p.`country` AS CHAR) IN ('美国', '加拿大', '巴西', '墨西哥') THEN '北美站'
                                                        ELSE '欧洲站' END
                               AND k.store = CASE
                                                 WHEN LOCATE('-', SUBSTRING_INDEX(CAST(p.`seller_name` AS CHAR), ' ', 1)) > 0 THEN LEFT(
                                                         SUBSTRING_INDEX(CAST(p.`seller_name` AS CHAR), ' ', 1),
                                                         LOCATE('-', SUBSTRING_INDEX(CAST(p.`seller_name` AS CHAR), ' ', 1)) - 1)
                                                 ELSE SUBSTRING_INDEX(CAST(p.`seller_name` AS CHAR), ' ', 1) END
                               AND k.MSKU = CAST(p.`seller_sku` AS CHAR)
                               AND DATE(p.`start_date`) BETWEEN v_90d AND v_data_date
        GROUP BY k.country_category, k.store, k.MSKU;


        SET v_stage = 'tmp_perf_scoped';
        DROP TEMPORARY TABLE IF EXISTS tmp_perf_scoped;
        CREATE TEMPORARY TABLE tmp_perf_scoped AS
        SELECT k.country_category,
               CAST(p.`country` AS CHAR(100)) AS source_country,
               k.store AS perf_store,
               k.MSKU AS perf_msku,
               DATE(p.`start_date`) AS stat_date,
               p.`product_create_time`,
               p.`afn_fulfillable_quantity`,
               p.`volume`,
               p.`spend`,
               p.`amount`,
               p.`avg_star`
        FROM tmp_listing_keys k
                 LEFT JOIN `dwd_datasync`.`lx_statistics_product_performance` p
                            ON k.country_category = CASE
                                                        WHEN CAST(p.`country` AS CHAR) = '英国' THEN '英国站'
                                                        WHEN CAST(p.`country` AS CHAR) IN ('美国', '加拿大', '巴西', '墨西哥') THEN '北美站'
                                                        ELSE '欧洲站' END
                               AND k.store = CASE
                                                 WHEN LOCATE('-', SUBSTRING_INDEX(CAST(p.`seller_name` AS CHAR), ' ', 1)) > 0
                                                     THEN LEFT(SUBSTRING_INDEX(CAST(p.`seller_name` AS CHAR), ' ', 1),
                                                               LOCATE('-', SUBSTRING_INDEX(CAST(p.`seller_name` AS CHAR), ' ', 1)) - 1)
                                                 ELSE SUBSTRING_INDEX(CAST(p.`seller_name` AS CHAR), ' ', 1) END
                               AND k.MSKU = CAST(p.`seller_sku` AS CHAR)
                               AND DATE(p.`start_date`) <= v_data_date;
        ALTER TABLE tmp_perf_scoped
            ADD INDEX idx_tmp_perf_scoped_date_key (stat_date, country_category, perf_store, perf_msku),
            ADD INDEX idx_tmp_perf_scoped_key_date (country_category, perf_store, perf_msku, stat_date);
        -- 返厂品识别所需的站点级库存日表：按国家类别+店铺+MSKU+日期聚合。
        -- 同一站点不同国家库存共享时，站点级有效 FBA 可售库存取 MAX(FBA 可售库存)，供最近180天断货历史及库存恢复日判断使用。
        -- 当前“断货中”不使用本表，而是单独按业务日期当天产品表现 FBA 可售库存=0 且 Listing 当前停售判断。
        SET v_stage = 'tmp_oos_perf_daily';
        DROP TEMPORARY TABLE IF EXISTS tmp_oos_perf_daily;
        CREATE TEMPORARY TABLE tmp_oos_perf_daily AS
        SELECT country_category,
               perf_store AS store,
               perf_msku AS MSKU,
               stat_date,
               MAX(COALESCE(afn_fulfillable_quantity, 0)) AS site_fba_available,
               SUM(COALESCE(volume, 0)) AS site_sales_volume
        FROM tmp_perf_scoped
        WHERE stat_date BETWEEN v_180d AND v_data_date
        GROUP BY country_category, perf_store, perf_msku, stat_date;
        ALTER TABLE tmp_oos_perf_daily
            ADD INDEX idx_tmp_oos_perf_daily (country_category, store, MSKU, stat_date);
 
        -- 但“断货中”依赖当前 Listing 是否停售，后续仍需构建 Listing 状态临时表。
        -- 首次到货日：按国家类别+店铺+MSKU取 lx_fba_shipment.receiving_time 的最小日期；仅取不晚于打标日的有效日期。
        SET v_stage = 'tmp_first_receiving';
        DROP TEMPORARY TABLE IF EXISTS tmp_first_receiving;
        CREATE TEMPORARY TABLE tmp_first_receiving AS
        SELECT k.country_category,
               k.store,
               k.MSKU,
               MIN(STR_TO_DATE(LEFT(CAST(s.`receiving_time` AS CHAR), 10), '%Y-%m-%d')) AS first_receiving_date
        FROM tmp_listing_keys k
                 JOIN `dwd_datasync`.`lx_fba_shipment` s
                      ON k.country_category = CASE
                                                  WHEN CAST(s.`country` AS CHAR) = '英国' THEN '英国站'
                                                  WHEN CAST(s.`country` AS CHAR) IN ('美国', '加拿大', '巴西', '墨西哥') THEN '北美站'
                                                  ELSE '欧洲站' END
                     AND k.store = CASE
                                       WHEN LOCATE('-', SUBSTRING_INDEX(CAST(s.`seller` AS CHAR), ' ', 1)) > 0 THEN LEFT(
                                               SUBSTRING_INDEX(CAST(s.`seller` AS CHAR), ' ', 1),
                                               LOCATE('-', SUBSTRING_INDEX(CAST(s.`seller` AS CHAR), ' ', 1)) - 1)
                                       ELSE SUBSTRING_INDEX(CAST(s.`seller` AS CHAR), ' ', 1) END
                     AND k.MSKU = CAST(s.`msku` AS CHAR)
        WHERE CAST(s.`receiving_time` AS CHAR) REGEXP '^[0-9]{4}-[0-9]{2}-[0-9]{2}'
          AND STR_TO_DATE(LEFT(CAST(s.`receiving_time` AS CHAR), 10), '%Y-%m-%d') <= v_data_date
        GROUP BY k.country_category, k.store, k.MSKU;
        ALTER TABLE tmp_first_receiving
            ADD INDEX idx_tmp_first_receiving (country_category, store, MSKU, first_receiving_date);

        -- 新版运营状态不再以 Listing 的“在售/停售”状态作为断货或停售判定条件；
        -- Listing 仍仅作为商品池主表使用。

        SET v_stage = 'tmp_fba';

        DROP TEMPORARY TABLE IF EXISTS tmp_fba;
        CREATE TEMPORARY TABLE tmp_fba AS
        SELECT CAST(f.`country_category` AS CHAR)                                      country_category,
               CASE
                   WHEN LOCATE('-', SUBSTRING_INDEX(CAST(f.`seller_name_new` AS CHAR), ' ', 1)) > 0 THEN LEFT(
                           SUBSTRING_INDEX(CAST(f.`seller_name_new` AS CHAR), ' ', 1),
                           LOCATE('-', SUBSTRING_INDEX(CAST(f.`seller_name_new` AS CHAR), ' ', 1)) - 1)
                   ELSE SUBSTRING_INDEX(CAST(f.`seller_name_new` AS CHAR), ' ', 1) END store,
               CAST(f.`seller_sku_adj` AS CHAR)                                        MSKU,
               SUM(COALESCE(f.`total`, 0))                                             total_stock,
               SUM(COALESCE(f.`available_total`, 0))                                   available_stock,
               SUM(COALESCE(f.`stock_up_num`, 0))                                      stock_up_num
        FROM `etl_datasync`.`etl_dispose_lx_storage_fba_warehouse_detail` f
        WHERE f.`create_time` >= DATE_SUB(v_data_date, INTERVAL 1 DAY)
          AND f.`create_time` < DATE_ADD(v_data_date, INTERVAL 1 DAY)
          AND f.`seller_sku_adj` IS NOT NULL
          AND CAST(f.`seller_sku_adj` AS CHAR) <> ''
        GROUP BY country_category, store, MSKU;

        SET v_stage = 'tmp_stock';

        DROP TEMPORARY TABLE IF EXISTS tmp_stock;
        CREATE TEMPORARY TABLE tmp_stock AS
        SELECT p.country_category,
               NULL AS                                                 country,
               p.store,
               p.MSKU,
               COALESCE(MAX(f.total_stock), MAX(p.fba_current), 0)     total_stock,
               COALESCE(MAX(f.available_stock), MAX(p.fba_current), 0) available_stock,
               COALESCE(MAX(f.stock_up_num), 0)                        stock_up_num,
               MAX(p.vol_90d)                                          vol_90d
        FROM tmp_perf p
                 LEFT JOIN tmp_fba f
                           ON p.country_category = f.country_category AND p.store = f.store AND p.MSKU = f.MSKU
        GROUP BY p.country_category, p.store, p.MSKU;

        -- 运营状态专用 FBA 库存：只用于“断货中/停售/测款扶持/正常在售”判定。
        -- 每个国家类别+店铺+MSKU 先取不晚于业务日的最新同步时点，再汇总该时点的库存明细，
        -- FBA 可售库存使用 afn_fulfillable_quantity；FBA 在途使用 stock_up_num。
        SET v_stage = 'tmp_op_fba_latest_key';
        DROP TEMPORARY TABLE IF EXISTS tmp_op_fba_latest_key;
        CREATE TEMPORARY TABLE tmp_op_fba_latest_key AS
        SELECT k.country_category,
               k.store,
               k.MSKU,
               MAX(f.`create_time`) AS max_create_time
        FROM tmp_listing_keys k
                 JOIN `etl_datasync`.`etl_dispose_lx_storage_fba_warehouse_detail` f
                      ON k.country_category = CAST(f.`country_category` AS CHAR)
                         AND k.store = CASE
                                           WHEN LOCATE('-', SUBSTRING_INDEX(CAST(f.`seller_name_new` AS CHAR), ' ', 1)) > 0
                                               THEN LEFT(SUBSTRING_INDEX(CAST(f.`seller_name_new` AS CHAR), ' ', 1),
                                                         LOCATE('-', SUBSTRING_INDEX(CAST(f.`seller_name_new` AS CHAR), ' ', 1)) - 1)
                                           ELSE SUBSTRING_INDEX(CAST(f.`seller_name_new` AS CHAR), ' ', 1)
                                       END
                         AND k.MSKU = CAST(f.`seller_sku_adj` AS CHAR)
        WHERE f.`create_time` < v_next_date
        GROUP BY k.country_category, k.store, k.MSKU;
        ALTER TABLE tmp_op_fba_latest_key
            ADD INDEX idx_tmp_op_fba_latest_key (country_category, store, MSKU, max_create_time);

        SET v_stage = 'tmp_op_fba';
        DROP TEMPORARY TABLE IF EXISTS tmp_op_fba;
        CREATE TEMPORARY TABLE tmp_op_fba AS
        SELECT x.country_category,
               x.store,
               x.MSKU,
               SUM(COALESCE(f.`afn_fulfillable_quantity`, 0)) AS fba_available,
               SUM(COALESCE(f.`stock_up_num`, 0)) AS fba_in_transit
        FROM tmp_op_fba_latest_key x
                 JOIN `etl_datasync`.`etl_dispose_lx_storage_fba_warehouse_detail` f
                      ON x.country_category = CAST(f.`country_category` AS CHAR)
                         AND x.store = CASE
                                           WHEN LOCATE('-', SUBSTRING_INDEX(CAST(f.`seller_name_new` AS CHAR), ' ', 1)) > 0
                                               THEN LEFT(SUBSTRING_INDEX(CAST(f.`seller_name_new` AS CHAR), ' ', 1),
                                                         LOCATE('-', SUBSTRING_INDEX(CAST(f.`seller_name_new` AS CHAR), ' ', 1)) - 1)
                                           ELSE SUBSTRING_INDEX(CAST(f.`seller_name_new` AS CHAR), ' ', 1)
                                       END
                         AND x.MSKU = CAST(f.`seller_sku_adj` AS CHAR)
                         AND f.`create_time` = x.max_create_time
        GROUP BY x.country_category, x.store, x.MSKU;
        ALTER TABLE tmp_op_fba
            ADD INDEX idx_tmp_op_fba (country_category, store, MSKU);

        -- 运营状态专用本地仓数量：四个原始字段分别取最新同步时点的 MAX，
        -- 再相加，避免同一 MSKU 在源表多行明细时重复累加。
        SET v_stage = 'tmp_op_local_latest_key';
        DROP TEMPORARY TABLE IF EXISTS tmp_op_local_latest_key;
        CREATE TEMPORARY TABLE tmp_op_local_latest_key AS
        SELECT k.country_category,
               k.store,
               k.MSKU,
               MAX(r.`create_time`) AS max_create_time
        FROM tmp_listing_keys k
                 JOIN `etl_datasync`.`etl_dispose_lx_replenishment_suggest_restocking` r
                      ON k.country_category = CAST(r.`country_category` AS CHAR)
                         AND k.store = CASE
                                           WHEN LOCATE('-', SUBSTRING_INDEX(CAST(r.`seller_name_new` AS CHAR), ' ', 1)) > 0
                                               THEN LEFT(SUBSTRING_INDEX(CAST(r.`seller_name_new` AS CHAR), ' ', 1),
                                                         LOCATE('-', SUBSTRING_INDEX(CAST(r.`seller_name_new` AS CHAR), ' ', 1)) - 1)
                                           ELSE SUBSTRING_INDEX(CAST(r.`seller_name_new` AS CHAR), ' ', 1)
                                       END
                         AND k.MSKU = CAST(r.`seller_sku_adj` AS CHAR)
        WHERE r.`create_time` < v_next_date
        GROUP BY k.country_category, k.store, k.MSKU;
        ALTER TABLE tmp_op_local_latest_key
            ADD INDEX idx_tmp_op_local_latest_key (country_category, store, MSKU, max_create_time);

        SET v_stage = 'tmp_op_local';
        DROP TEMPORARY TABLE IF EXISTS tmp_op_local;
        CREATE TEMPORARY TABLE tmp_op_local AS
        SELECT x.country_category,
               x.store,
               x.MSKU,
               MAX(COALESCE(r.`sc_quantity_local_valid`, 0))
               + MAX(COALESCE(r.`sc_quantity_purchase_shipping`, 0))
               + MAX(COALESCE(r.`sc_quantity_purchase_plan`, 0))
               + MAX(COALESCE(r.`sc_quantity_local_qc`, 0)) AS local_quantity
        FROM tmp_op_local_latest_key x
                 JOIN `etl_datasync`.`etl_dispose_lx_replenishment_suggest_restocking` r
                      ON x.country_category = CAST(r.`country_category` AS CHAR)
                         AND x.store = CASE
                                           WHEN LOCATE('-', SUBSTRING_INDEX(CAST(r.`seller_name_new` AS CHAR), ' ', 1)) > 0
                                               THEN LEFT(SUBSTRING_INDEX(CAST(r.`seller_name_new` AS CHAR), ' ', 1),
                                                         LOCATE('-', SUBSTRING_INDEX(CAST(r.`seller_name_new` AS CHAR), ' ', 1)) - 1)
                                           ELSE SUBSTRING_INDEX(CAST(r.`seller_name_new` AS CHAR), ' ', 1)
                                       END
                         AND x.MSKU = CAST(r.`seller_sku_adj` AS CHAR)
                         AND r.`create_time` = x.max_create_time
        GROUP BY x.country_category, x.store, x.MSKU;
        ALTER TABLE tmp_op_local
            ADD INDEX idx_tmp_op_local (country_category, store, MSKU);

        SET v_stage = 'tmp_price';

        DROP TEMPORARY TABLE IF EXISTS tmp_price;
        CREATE TEMPORARY TABLE tmp_price AS
        SELECT country_category,
               country,
               store,
               MSKU,
               SUBSTRING_INDEX(GROUP_CONCAT(price_label ORDER BY price_priority SEPARATOR ','), ',', 1) price_label
        FROM (SELECT CASE
                         WHEN CAST(t.`国家` AS CHAR) = '英国' THEN '英国站'
                         WHEN CAST(t.`国家` AS CHAR) IN ('美国', '加拿大', '巴西', '墨西哥') THEN '北美站'
                         ELSE COALESCE(CAST(t.`国家类别` AS CHAR), '欧洲站') END        country_category,
                     CAST(t.`国家` AS CHAR)                                             country,
                     CASE
                         WHEN LOCATE('-', SUBSTRING_INDEX(CAST(t.`新店铺` AS CHAR), ' ', 1)) > 0 THEN LEFT(
                                 SUBSTRING_INDEX(CAST(t.`新店铺` AS CHAR), ' ', 1),
                                 LOCATE('-', SUBSTRING_INDEX(CAST(t.`新店铺` AS CHAR), ' ', 1)) - 1)
                         ELSE SUBSTRING_INDEX(CAST(t.`新店铺` AS CHAR), ' ', 1) END     store,
                     CAST(t.`msku` AS CHAR)                                             MSKU,
                     CASE
                         WHEN t.`listing价格` IS NULL THEN NULL
                         WHEN (t.`0毛利润价格` IS NOT NULL AND t.`listing价格` < t.`0毛利润价格`) OR
                              (t.`清货底价` IS NOT NULL AND t.`listing价格` < t.`清货底价`) THEN '清仓区'
                         WHEN t.`listing价格` >= t.`0毛利润价格` AND t.`listing价格` < t.`10毛利润价格` THEN '微利区'
                         WHEN t.`listing价格` >= t.`10毛利润价格` AND t.`listing价格` < t.`20毛利润价格` THEN '基础利润区'
                         WHEN t.`listing价格` >= t.`20毛利润价格` AND t.`listing价格` < t.`30毛利润价格` THEN '健康利润区'
                         WHEN t.`listing价格` >= t.`30毛利润价格` THEN '超额利润区' END price_label,
                     CASE
                         WHEN (t.`0毛利润价格` IS NOT NULL AND t.`listing价格` < t.`0毛利润价格`) OR
                              (t.`清货底价` IS NOT NULL AND t.`listing价格` < t.`清货底价`) THEN 1
                         WHEN t.`listing价格` < t.`10毛利润价格` THEN 2
                         WHEN t.`listing价格` < t.`20毛利润价格` THEN 3
                         WHEN t.`listing价格` < t.`30毛利润价格` THEN 4
                         WHEN t.`listing价格` >= t.`30毛利润价格` THEN 5
                         ELSE 999 END                                                   price_priority
              FROM `temporary_dwd`.`在库节点_输出定价表` t
              WHERE t.`msku` IS NOT NULL
                AND CAST(t.`msku` AS CHAR) <> ''
                AND LOWER(TRIM(CAST(t.`msku` AS CHAR))) NOT LIKE 'amzn.gr%'
                AND UPPER(TRIM(CAST(t.`msku` AS CHAR))) NOT LIKE 'AMAZON%') a
        WHERE price_label IS NOT NULL
        GROUP BY country_category, country, store, MSKU;

        -- 返厂品/返场事件：复用上方站点级日库存临时表；同一站点不同国家库存共享，库存取 MAX(FBA 可售库存)。
        -- 逻辑：最近180天内（不含打标日）站点级有效FBA可售库存=0；最后断货日后首次库存恢复到>5，以该首次到货日为起点，仅21天内打返厂品标签。
        SET v_stage = 'tmp_return_perf_daily';
        DROP TEMPORARY TABLE IF EXISTS tmp_return_perf_daily;
        CREATE TEMPORARY TABLE tmp_return_perf_daily AS
        SELECT country_category, store, MSKU, stat_date, site_fba_available, site_sales_volume
        FROM tmp_oos_perf_daily
        WHERE stat_date BETWEEN v_180d AND v_data_date;

        ALTER TABLE tmp_return_perf_daily
            ADD INDEX idx_tmp_return_perf_daily (country_category, store, MSKU, stat_date);

        SET v_stage = 'tmp_last_oos';

        DROP TEMPORARY TABLE IF EXISTS tmp_last_oos;

        CREATE TEMPORARY TABLE tmp_last_oos AS

        SELECT country_category, store, MSKU, MAX(stat_date) last_oos_date

        FROM tmp_return_perf_daily

        WHERE stat_date BETWEEN v_180d AND DATE_SUB(v_data_date, INTERVAL 1 DAY)

          AND site_fba_available = 0

        GROUP BY country_category, store, MSKU;


        -- 先单独落地“最后断货后首次库存恢复到>5”的结果，避免同一条查询重复打开 tmp_return_perf_daily 临时表。
        SET v_stage = 'tmp_first_restock';
        DROP TEMPORARY TABLE IF EXISTS tmp_first_restock;
        CREATE TEMPORARY TABLE tmp_first_restock AS
        SELECT o.country_category,
               o.store,
               o.MSKU,
               o.last_oos_date,
               MIN(d.stat_date) AS first_restock_date
        FROM tmp_last_oos o
                 JOIN tmp_return_perf_daily d
                      ON o.country_category = d.country_category
                     AND o.store = d.store
                     AND o.MSKU = d.MSKU
        WHERE d.stat_date > o.last_oos_date
          AND d.stat_date <= v_data_date
          AND d.site_fba_available > 5
        GROUP BY o.country_category, o.store, o.MSKU, o.last_oos_date;
        ALTER TABLE tmp_first_restock
            ADD INDEX idx_tmp_first_restock (country_category, store, MSKU, first_restock_date);

        -- 返场品21天窗口以最后断货后首次库存恢复到>5的日期为起点；保留 first_resume_sale_date 字段名，避免影响后续标签写入语句。
        SET v_stage = 'tmp_return';
        DROP TEMPORARY TABLE IF EXISTS tmp_return;
        CREATE TEMPORARY TABLE tmp_return AS
        SELECT r.country_category,
               r.store,
               r.MSKU,
               r.last_oos_date,
               r.first_restock_date,
               r.first_restock_date AS first_resume_sale_date
        FROM tmp_first_restock r;


        -- 客户体验：复用产品表现标准化临时表；仍仅取德国站、最新业务日期的 avg_star。
        SET v_stage = 'tmp_de_rating';
        DROP TEMPORARY TABLE IF EXISTS tmp_de_rating;
        CREATE TEMPORARY TABLE tmp_de_rating AS
        SELECT '欧洲站' AS country_category,
               CAST(perf_store AS CHAR(100)) AS rating_store,
               CAST(perf_msku AS CHAR(255)) AS MSKU,
               MAX(avg_star) AS avg_star
        FROM tmp_perf_scoped
        WHERE stat_date = v_data_date
          AND (source_country IN ('德国', '德国站')
               OR UPPER(source_country) IN ('DE', 'GERMANY', 'AMAZON.DE'))
        GROUP BY rating_store, MSKU;
        ALTER TABLE tmp_de_rating
            ADD INDEX idx_tmp_de_rating (country_category, rating_store, MSKU);

        -- 德国站点 listing 维度：客户体验仅针对德国站点商品，无 product 数据时 avg_star 为 NULL。
        SET v_stage = 'tmp_de_listing_keys';
        DROP TEMPORARY TABLE IF EXISTS tmp_de_listing_keys;
        CREATE TEMPORARY TABLE tmp_de_listing_keys AS
        SELECT DISTINCT
               '欧洲站' AS country_category,
               CASE
                   WHEN LOCATE('-', SUBSTRING_INDEX(CAST(li.`seller_name` AS CHAR), ' ', 1)) > 0
                       THEN LEFT(SUBSTRING_INDEX(CAST(li.`seller_name` AS CHAR), ' ', 1),
                                 LOCATE('-', SUBSTRING_INDEX(CAST(li.`seller_name` AS CHAR), ' ', 1)) - 1)
                   ELSE SUBSTRING_INDEX(CAST(li.`seller_name` AS CHAR), ' ', 1) END AS store,
               CAST(li.`seller_sku` AS CHAR(255)) AS MSKU
        FROM tmp_listing_latest li
        WHERE CAST(li.`marketplace` AS CHAR) IN ('德国', '德国站')
           OR UPPER(CAST(li.`marketplace` AS CHAR)) IN ('DE', 'GERMANY', 'AMAZON.DE');
        ALTER TABLE tmp_de_listing_keys
            ADD INDEX idx_tmp_de_listing_keys (country_category, store, MSKU);

        SET v_stage = 'tmp_customer_experience';
        DROP TEMPORARY TABLE IF EXISTS tmp_customer_experience;
        CREATE TEMPORARY TABLE tmp_customer_experience AS
        SELECT k.country_category,
               '德国' AS country,
               k.store,
               k.MSKU,
               r.avg_star
        FROM tmp_de_listing_keys k
                 LEFT JOIN tmp_de_rating r
                      ON k.country_category = r.country_category
                     AND k.store = r.rating_store
                     AND k.MSKU = r.MSKU;
        -- 退货情况：先将订单明细裁剪到当前标签维度，先按 amazon_order_id + order_item_id 去重订单行，再按 amazon_order_id 确定最近100个订单。
        -- 退货订单行以 is_return 非空且非“未退款”为准；退货率按最近100单内实际退货订单行下单量/全部订单行下单量计算。
        SET v_stage = 'tmp_order_raw';
        DROP TEMPORARY TABLE IF EXISTS tmp_order_raw;
        CREATE TEMPORARY TABLE tmp_order_raw AS
        SELECT k.country_category,
               k.store,
               k.MSKU,
               CAST(o.`amazon_order_id` AS CHAR) AS amazon_order_id,
               COALESCE(NULLIF(CAST(o.`order_item_id` AS CHAR), ''),
                        CONCAT('__NO_ORDER_ITEM__:', CAST(o.`amazon_order_id` AS CHAR))) AS order_item_id,
               COALESCE(
                   STR_TO_DATE(LEFT(CAST(o.`purchase_date_local_utc` AS CHAR), 19), '%Y-%m-%d %H:%i:%s'),
                   STR_TO_DATE(LEFT(CAST(o.`purchase_date_local` AS CHAR), 19), '%Y-%m-%d %H:%i:%s'),
                    o.`create_time`
                ) AS order_time,
                COALESCE(o.`quantity_ordered`, 0) AS sales_volume,
                CASE
                   WHEN o.`is_return` IS NOT NULL
                        AND TRIM(CAST(o.`is_return` AS CHAR)) <> ''
                        AND TRIM(CAST(o.`is_return` AS CHAR)) NOT IN ('未退款', '否', '0', 'false', 'FALSE')
                       THEN 1
                   ELSE 0 END AS is_returned
        FROM tmp_listing_keys k
                 JOIN `dwd_datasync`.`lx_sales_mws_orders_detail` o
                      ON k.country_category = CASE
                                                  WHEN CAST(o.`country` AS CHAR) = '英国' THEN '英国站'
                                                  WHEN CAST(o.`country` AS CHAR) IN ('美国', '加拿大', '巴西', '墨西哥')
                                                      THEN '北美站'
                                                  ELSE '欧洲站' END
                     AND k.store = CASE
                                       WHEN LOCATE('-', SUBSTRING_INDEX(CAST(o.`seller_name` AS CHAR), ' ', 1)) > 0 THEN LEFT(
                                               SUBSTRING_INDEX(CAST(o.`seller_name` AS CHAR), ' ', 1),
                                               LOCATE('-', SUBSTRING_INDEX(CAST(o.`seller_name` AS CHAR), ' ', 1)) - 1)
                                       ELSE SUBSTRING_INDEX(CAST(o.`seller_name` AS CHAR), ' ', 1) END
                     AND k.MSKU = CAST(o.`seller_sku` AS CHAR)
        WHERE o.`amazon_order_id` IS NOT NULL
          AND CAST(o.`amazon_order_id` AS CHAR) <> '';
        ALTER TABLE tmp_order_raw
            ADD INDEX idx_tmp_order_raw (country_category, store, MSKU, amazon_order_id);

        -- 先以 amazon_order_id + order_item_id 对订单行去重：同一订单下不同 order_item_id 为不同订单行，保留各行下单量；原始表索引仅保留四列，避免长文本联合索引超过 MySQL 键长上限。
        SET v_stage = 'tmp_order_line_dedup';
        DROP TEMPORARY TABLE IF EXISTS tmp_order_line_dedup;
        CREATE TEMPORARY TABLE tmp_order_line_dedup AS
        SELECT country_category,
               store,
               MSKU,
               amazon_order_id,
               order_item_id,
               MAX(order_time) AS order_time,
               MAX(sales_volume) AS sales_volume,
               MAX(is_returned) AS is_returned
        FROM tmp_order_raw
        GROUP BY country_category, store, MSKU, amazon_order_id, order_item_id;
        ALTER TABLE tmp_order_line_dedup
            ADD INDEX idx_tmp_order_line_dedup (country_category, store, MSKU, amazon_order_id);

        -- 再按 amazon_order_id 汇总订单总下单量；最近100单仍按去重订单数计算。
        SET v_stage = 'tmp_order_dedup';
        DROP TEMPORARY TABLE IF EXISTS tmp_order_dedup;
        CREATE TEMPORARY TABLE tmp_order_dedup AS
        SELECT country_category,
               store,
               MSKU,
               amazon_order_id,
               MAX(order_time) AS order_time,
               SUM(sales_volume) AS sales_volume
        FROM tmp_order_line_dedup
        GROUP BY country_category, store, MSKU, amazon_order_id;
        ALTER TABLE tmp_order_dedup
            ADD INDEX idx_tmp_order_dedup (country_category, store, MSKU, order_time);

        SET v_stage = 'tmp_return_last_100';

        DROP TEMPORARY TABLE IF EXISTS tmp_return_last_100;
        CREATE TEMPORARY TABLE tmp_return_last_100 AS
        SELECT l.country_category,
               l.store,
               l.MSKU,
               l.amazon_order_id,
               SUM(l.sales_volume) AS sales_volume,
               SUM(CASE WHEN l.is_returned = 1 THEN l.sales_volume ELSE 0 END) AS return_sales_volume
        FROM (
                 SELECT d.country_category,
                        d.store,
                        d.MSKU,
                        d.amazon_order_id,
                        ROW_NUMBER() OVER (
                            PARTITION BY d.country_category, d.store, d.MSKU
                            ORDER BY d.order_time DESC, d.amazon_order_id DESC
                            ) AS rn
                 FROM tmp_order_dedup d
             ) ranked
                 JOIN tmp_order_line_dedup l
                      ON ranked.country_category = l.country_category
                     AND ranked.store = l.store
                     AND ranked.MSKU = l.MSKU
                     AND ranked.amazon_order_id = l.amazon_order_id
        WHERE ranked.rn <= 100
        GROUP BY l.country_category, l.store, l.MSKU, l.amazon_order_id;

        SET v_stage = 'tmp_return_rate';

        DROP TEMPORARY TABLE IF EXISTS tmp_return_rate;
        CREATE TEMPORARY TABLE tmp_return_rate AS
        SELECT country_category,
               store,
               MSKU,
               COUNT(*) AS order_count,
               SUM(CASE WHEN return_sales_volume > 0 THEN 1 ELSE 0 END) AS return_order_count,
               SUM(sales_volume) AS sales_volume,
               SUM(return_sales_volume) AS return_sales_volume,
               SUM(return_sales_volume) / NULLIF(SUM(sales_volume), 0) AS return_rate
        FROM tmp_return_last_100
        GROUP BY country_category, store, MSKU;

        SET v_stage = 'tmp_hits';

        DROP TEMPORARY TABLE IF EXISTS tmp_hits;
        CREATE TEMPORARY TABLE tmp_hits
        (
            `国家类别`       varchar(20),
            `国家`           varchar(100),
            `店铺`           varchar(100),
            `MSKU`           varchar(500),
            label_name       varchar(100),
            child_label_name varchar(100),
            label_period     varchar(20)
        ) ENGINE = InnoDB
          DEFAULT CHARSET = utf8mb4
          COLLATE = utf8mb4_0900_ai_ci;

        -- 销售角色：按 国家类别+店铺+MSKU。先生成7/14/30/90天销售角色，供生命周期“成熟期”判断复用。
        SET v_stage = 'tmp_sales_role';
        DROP TEMPORARY TABLE IF EXISTS tmp_sales_role;
        CREATE TEMPORARY TABLE tmp_sales_role AS
        SELECT country_category,
               NULL AS                                                                      country,
               store,
               MSKU,
               CASE
                   WHEN (vol_7d > 5 AND margin_7d > 15) OR (vol_7d BETWEEN 1 AND 5 AND margin_7d > 25) THEN '明星产品'
                   WHEN (vol_7d > 5 AND margin_7d BETWEEN 5 AND 15) OR
                        (vol_7d BETWEEN 1 AND 5 AND margin_7d BETWEEN 10 AND 25) THEN '潜力产品'
                   WHEN (vol_7d BETWEEN 1 AND 5 AND margin_7d >= 5 AND margin_7d < 10) OR (vol_7d < 1 AND margin_7d > 5)
                       THEN '瘦狗产品'
                   WHEN vol_7d = 0 OR (vol_7d > 0 AND margin_7d < 5) THEN '问题产品' END    role_7d,
               CASE
                   WHEN (vol_14d > 5 AND margin_14d > 15) OR (vol_14d BETWEEN 1 AND 5 AND margin_14d > 25) THEN '明星产品'
                   WHEN (vol_14d > 5 AND margin_14d BETWEEN 5 AND 15) OR
                        (vol_14d BETWEEN 1 AND 5 AND margin_14d BETWEEN 10 AND 25) THEN '潜力产品'
                   WHEN (vol_14d BETWEEN 1 AND 5 AND margin_14d >= 5 AND margin_14d < 10) OR
                        (vol_14d < 1 AND margin_14d > 5) THEN '瘦狗产品'
                   WHEN vol_14d = 0 OR (vol_14d > 0 AND margin_14d < 5) THEN '问题产品' END role_14d,
               CASE
                   WHEN (vol_30d > 5 AND margin_30d > 15) OR (vol_30d BETWEEN 1 AND 5 AND margin_30d > 25) THEN '明星产品'
                   WHEN (vol_30d > 5 AND margin_30d BETWEEN 5 AND 15) OR
                        (vol_30d BETWEEN 1 AND 5 AND margin_30d BETWEEN 10 AND 25) THEN '潜力产品'
                   WHEN (vol_30d BETWEEN 1 AND 5 AND margin_30d >= 5 AND margin_30d < 10) OR
                        (vol_30d < 1 AND margin_30d > 5) THEN '瘦狗产品'
                   WHEN vol_30d = 0 OR (vol_30d > 0 AND margin_30d < 5) THEN '问题产品' END role_30d,
               CASE
                   WHEN (vol_90d > 5 AND margin_90d > 15) OR (vol_90d BETWEEN 1 AND 5 AND margin_90d > 25) THEN '明星产品'
                   WHEN (vol_90d > 5 AND margin_90d BETWEEN 5 AND 15) OR
                        (vol_90d BETWEEN 1 AND 5 AND margin_90d BETWEEN 10 AND 25) THEN '潜力产品'
                   WHEN (vol_90d BETWEEN 1 AND 5 AND margin_90d >= 5 AND margin_90d < 10) OR
                        (vol_90d < 1 AND margin_90d > 5) THEN '瘦狗产品'
                   WHEN vol_90d = 0 OR (vol_90d > 0 AND margin_90d < 5) THEN '问题产品' END role_90d
        FROM tmp_perf;

        -- MySQL 临时表不能在同一条 UNION SQL 中被重复打开；这里拆成4条 INSERT，避免 Can't reopen table: tmp_sales_role。
        INSERT INTO tmp_hits
        SELECT country_category, NULL, store, MSKU, '销售角色', role_7d, '7d'
        FROM tmp_sales_role
        WHERE role_7d IS NOT NULL;

        INSERT INTO tmp_hits
        SELECT country_category, NULL, store, MSKU, '销售角色', role_14d, '14d'
        FROM tmp_sales_role
        WHERE role_14d IS NOT NULL;

        INSERT INTO tmp_hits
        SELECT country_category, NULL, store, MSKU, '销售角色', role_30d, '30d'
        FROM tmp_sales_role
        WHERE role_30d IS NOT NULL;

        INSERT INTO tmp_hits
        SELECT country_category, NULL, store, MSKU, '销售角色', role_90d, '90d'
        FROM tmp_sales_role
        WHERE role_90d IS NOT NULL;

        -- 生命周期：按国家类别+店铺+MSKU，依据 lx_fba_shipment.receiving_time 的首次到货日判断。
        -- 0~30天测款期；31~120天新品期；新品期结束后，未满足成熟期条件的商品均为成长期；>300天且四个销售周期均非瘦狗/问题产品时为成熟期。
        INSERT INTO tmp_hits
        SELECT p.country_category,
               NULL,
               p.store,
               p.MSKU,
               '生命周期',
               CASE
                   WHEN DATEDIFF(v_data_date, fr.first_receiving_date) BETWEEN 0 AND 30 THEN '测款期'
                   WHEN DATEDIFF(v_data_date, fr.first_receiving_date) BETWEEN 31 AND 120 THEN '新品期'
                   WHEN DATEDIFF(v_data_date, fr.first_receiving_date) BETWEEN 121 AND 300 THEN '成长期'
                   WHEN DATEDIFF(v_data_date, fr.first_receiving_date) > 300
                        AND COALESCE(sr.role_7d, '') NOT IN ('瘦狗产品', '问题产品')
                        AND COALESCE(sr.role_14d, '') NOT IN ('瘦狗产品', '问题产品')
                        AND COALESCE(sr.role_30d, '') NOT IN ('瘦狗产品', '问题产品')
                        AND COALESCE(sr.role_90d, '') NOT IN ('瘦狗产品', '问题产品') THEN '成熟期'
                   WHEN DATEDIFF(v_data_date, fr.first_receiving_date) > 300 THEN '成长期'
               END AS child_label_name,
               CASE
                   WHEN DATEDIFF(v_data_date, fr.first_receiving_date) BETWEEN 0 AND 30 THEN '30d'
                   WHEN DATEDIFF(v_data_date, fr.first_receiving_date) BETWEEN 31 AND 120 THEN '90d'
                   WHEN DATEDIFF(v_data_date, fr.first_receiving_date) BETWEEN 121 AND 300 THEN '6m'
                   WHEN DATEDIFF(v_data_date, fr.first_receiving_date) > 300
                        AND COALESCE(sr.role_7d, '') NOT IN ('瘦狗产品', '问题产品')
                        AND COALESCE(sr.role_14d, '') NOT IN ('瘦狗产品', '问题产品')
                        AND COALESCE(sr.role_30d, '') NOT IN ('瘦狗产品', '问题产品')
                        AND COALESCE(sr.role_90d, '') NOT IN ('瘦狗产品', '问题产品') THEN 'long_term'
                   WHEN DATEDIFF(v_data_date, fr.first_receiving_date) > 300 THEN '6m'
               END AS label_period
        FROM tmp_perf p
                 JOIN tmp_first_receiving fr
                      ON p.country_category = fr.country_category AND p.store = fr.store AND p.MSKU = fr.MSKU
                 LEFT JOIN tmp_sales_role sr
                           ON p.country_category = sr.country_category AND p.store = sr.store AND p.MSKU = sr.MSKU
        HAVING child_label_name IS NOT NULL;

        -- 定价：非库存类，国家+店铺+MSKU。
        INSERT INTO tmp_hits
        SELECT country_category, country, store, MSKU, '定价', price_label, 'current'
        FROM tmp_price
        WHERE price_label IS NOT NULL;


        -- 站点状态：基于 Listing 历史覆盖站点判断；五国覆盖判断规则不变。
        SET v_stage = 'tmp_site_status_base';
        DROP TEMPORARY TABLE IF EXISTS tmp_site_status_base;
        CREATE TEMPORARY TABLE tmp_site_status_base AS
        SELECT CAST(li.`marketplace` AS CHAR)                                                    AS site_country,
               CASE
                   WHEN LOCATE('-', SUBSTRING_INDEX(CAST(li.`seller_name` AS CHAR), ' ', 1)) > 0 THEN LEFT(
                           SUBSTRING_INDEX(CAST(li.`seller_name` AS CHAR), ' ', 1),
                           LOCATE('-', SUBSTRING_INDEX(CAST(li.`seller_name` AS CHAR), ' ', 1)) - 1)
                   ELSE SUBSTRING_INDEX(CAST(li.`seller_name` AS CHAR), ' ', 1) END AS site_store,
               CAST(li.`seller_sku` AS CHAR)                                        AS site_msku,
               CASE
                   WHEN CAST(li.`marketplace` AS CHAR) IN ('德国', '德国站') OR
                        UPPER(CAST(li.`marketplace` AS CHAR)) IN ('DE', 'GERMANY', 'AMAZON.DE') THEN '德国'
                   WHEN CAST(li.`marketplace` AS CHAR) IN ('意大利', '意大利站') OR
                        UPPER(CAST(li.`marketplace` AS CHAR)) IN ('IT', 'ITALY', 'AMAZON.IT') THEN '意大利'
                   WHEN CAST(li.`marketplace` AS CHAR) IN ('法国', '法国站') OR
                        UPPER(CAST(li.`marketplace` AS CHAR)) IN ('FR', 'FRANCE', 'AMAZON.FR') THEN '法国'
                   WHEN CAST(li.`marketplace` AS CHAR) IN ('西班牙', '西班牙站') OR
                        UPPER(CAST(li.`marketplace` AS CHAR)) IN ('ES', 'SPAIN', 'AMAZON.ES') THEN '西班牙'
                   WHEN CAST(li.`marketplace` AS CHAR) IN ('荷兰', '荷兰站') OR
                        UPPER(CAST(li.`marketplace` AS CHAR)) IN ('NL', 'NETHERLANDS', 'AMAZON.NL') THEN '荷兰'
                   END                                                             AS site_code
        FROM tmp_listing_latest li
        GROUP BY site_country, site_store, site_msku, site_code;

        SET v_stage = 'tmp_site_status_msku';
        DROP TEMPORARY TABLE IF EXISTS tmp_site_status_msku;
        CREATE TEMPORARY TABLE tmp_site_status_msku AS
        SELECT site_msku AS MSKU,
               CASE WHEN COUNT(DISTINCT site_code) = 5 THEN '五国全覆盖' ELSE '部分覆盖' END AS site_status_label
        FROM tmp_site_status_base
        WHERE site_code IS NOT NULL
        GROUP BY site_msku;

        SET v_stage = 'tmp_site_status';
        DROP TEMPORARY TABLE IF EXISTS tmp_site_status;
        CREATE TEMPORARY TABLE tmp_site_status AS
        SELECT '欧洲站' AS country_category,
               b.site_country AS country,
               b.site_store AS store,
               b.site_msku AS MSKU,
               s.site_status_label
        FROM tmp_site_status_base b
                 JOIN tmp_site_status_msku s ON b.site_msku = s.MSKU
        WHERE b.site_code IS NOT NULL
          AND s.site_status_label IS NOT NULL;

        INSERT INTO tmp_hits
        SELECT country_category, country, store, MSKU, '站点状态', site_status_label, 'current'
        FROM tmp_site_status
        WHERE site_status_label IS NOT NULL;
        -- 库存水平：按 dws_datasync.dws_库存宽表 的库存支撑天数判断；按 国家类别(站点)+店铺+MSKU，country字段置NULL。
        -- 如实际库存表字段名与这里不同，请将 `数据日期`、`站点`、`店铺名`、`MSKU`、`库存支撑天数` 替换为实际字段名。
        SET v_stage = 'tmp_inventory_level';
        DROP TEMPORARY TABLE IF EXISTS tmp_inventory_level;
        SET v_stage = 'tmp_inventory_date';
        DROP TEMPORARY TABLE IF EXISTS tmp_inventory_date;
        CREATE TEMPORARY TABLE tmp_inventory_date AS
        SELECT MAX(k2.`数据日期`) AS inventory_date
        FROM `dws_datasync`.`dws_库存宽表` k2
        WHERE k2.`数据日期` <= v_data_date;

        CREATE TEMPORARY TABLE tmp_inventory_level AS
        SELECT CAST(k.`站点` AS CHAR)                                         AS country_category,
               NULL                                                           AS country,
               CASE
                   WHEN LOCATE('-', SUBSTRING_INDEX(CAST(k.`店铺名` AS CHAR), ' ', 1)) > 0 THEN LEFT(
                           SUBSTRING_INDEX(CAST(k.`店铺名` AS CHAR), ' ', 1),
                           LOCATE('-', SUBSTRING_INDEX(CAST(k.`店铺名` AS CHAR), ' ', 1)) - 1)
                   ELSE SUBSTRING_INDEX(CAST(k.`店铺名` AS CHAR), ' ', 1) END AS store,
               CAST(k.`MSKU` AS CHAR)                                         AS MSKU,
               CASE
                   WHEN MAX(k.`库存支撑天数`) < 35 THEN '低库存'
                   WHEN MAX(k.`库存支撑天数`) >= 35 AND MAX(k.`库存支撑天数`) < 90 THEN '中库存'
                   WHEN MAX(k.`库存支撑天数`) >= 90 THEN '高库存'
                   END                                                        AS inventory_level_label
        FROM `dws_datasync`.`dws_库存宽表` k FORCE INDEX (`idx_date_store_site_wh_msku`)
                 JOIN tmp_inventory_date d
                      ON k.`数据日期` = d.inventory_date
        WHERE d.inventory_date IS NOT NULL
          AND LOWER(TRIM(CAST(k.`MSKU` AS CHAR))) NOT LIKE 'amzn.gr%'
          AND UPPER(TRIM(CAST(k.`MSKU` AS CHAR))) NOT LIKE 'AMAZON%'
          AND CAST(k.`MSKU` AS CHAR) <> ''
          AND k.`库存支撑天数` IS NOT NULL
        GROUP BY country_category, store, MSKU
        HAVING inventory_level_label IS NOT NULL;

        INSERT INTO tmp_hits
        SELECT country_category, NULL, store, MSKU, '库存水平', inventory_level_label, 'current'
        FROM tmp_inventory_level
        WHERE inventory_level_label IS NOT NULL;

        -- 流量结构：基于 Listing 维度，关联产品表现近30天数据；无 product 数据时不打标签。
        SET v_stage = 'tmp_traffic_structure';
        DROP TEMPORARY TABLE IF EXISTS tmp_traffic_structure;
        CREATE TEMPORARY TABLE tmp_traffic_structure AS
        SELECT country_category,
               NULL AS country,
               traffic_store AS store,
               traffic_msku AS MSKU,
               CASE
                   WHEN sales_amount_30d <= 0 AND ad_spend_30d > 0 THEN '高度依赖广告'
                   WHEN sales_amount_30d <= 0 AND ad_spend_30d = 0 THEN '自然流量'
                   WHEN ad_spend_30d / sales_amount_30d >= 0.70 THEN '高度依赖广告'
                   WHEN ad_spend_30d / sales_amount_30d >= 0.40 AND ad_spend_30d / sales_amount_30d < 0.70 THEN '中度依赖广告'
                   WHEN ad_spend_30d / sales_amount_30d >= 0.10 AND ad_spend_30d / sales_amount_30d < 0.40 THEN '健康状态'
                   WHEN ad_spend_30d / sales_amount_30d < 0.10 THEN '自然流量'
                   END AS traffic_structure_label
        FROM (
            SELECT country_category,
                   perf_store AS traffic_store,
                   perf_msku AS traffic_msku,
                   SUM(ABS(COALESCE(spend, 0))) AS ad_spend_30d,
                   SUM(COALESCE(amount, 0)) AS sales_amount_30d,
                   COUNT(stat_date) AS product_record_count_30d
            FROM tmp_perf_scoped
            WHERE stat_date BETWEEN v_30d AND v_data_date
            GROUP BY country_category, perf_store, perf_msku
        ) a
        WHERE product_record_count_30d > 0;

        INSERT INTO tmp_hits
        SELECT country_category, NULL, store, MSKU, '流量结构', traffic_structure_label, '30d'
        FROM tmp_traffic_structure
        WHERE traffic_structure_label IS NOT NULL;

        -- 所有依赖产品表现标准化表的标签已计算完成，提前释放临时空间。
        SET v_stage = 'tmp_perf_scoped_cleanup';
        DROP TEMPORARY TABLE IF EXISTS tmp_perf_scoped;
        -- 客户体验：严格按 dws_标签详情表的已启用规则分段；按德国+店铺+MSKU输出，国家类别为欧洲站。
        INSERT INTO tmp_hits
        SELECT country_category,
               country,
               store,
               MSKU,
               '客户体验',
               CASE
                   WHEN avg_star IS NULL OR avg_star = 0 THEN '无评价'
                   WHEN avg_star >= 4.00 AND avg_star <= 4.50 THEN '口碑优秀'
                   WHEN avg_star >= 3.50 AND avg_star < 4.00 THEN '口碑正常'
                   WHEN avg_star < 3.50 THEN '口碑风险'
                   END AS child_label_name,
               'current'
        FROM tmp_customer_experience
        WHERE avg_star IS NULL
           OR avg_star = 0
           OR (avg_star >= 4.00 AND avg_star <= 4.50)
           OR (avg_star >= 3.50 AND avg_star < 4.00)
           OR avg_star < 3.50;

        -- 退货情况：按国家类别+店铺+MSKU 的最近100个去重 amazon_order_id，以实际退货订单行下单量/全部订单行下单量计算退货率。
        INSERT INTO tmp_hits
        SELECT country_category,
               NULL,
               store,
               MSKU,
               '退货情况',
               CASE
                   WHEN return_rate < 0.02 THEN '低退货率'
                   WHEN return_rate >= 0.02 AND return_rate < 0.05 THEN '正常退货率'
                   WHEN return_rate >= 0.05 AND return_rate <= 0.20 THEN '高退货率'
                   WHEN return_rate > 0.20 THEN '严重退货'
                   END AS child_label_name,
               'current'
        FROM tmp_return_rate
        WHERE return_rate IS NOT NULL;

        -- 运营状态（互斥）：断货中 > 停售 > 返厂品 > 测款扶持 > 正常在售。
        -- 断货中：FBA 可售库存=0，且 FBA 在途或本地仓数量>0。
        -- 停售：FBA 可售库存=0，且 FBA 在途、本地仓数量均=0。
        -- 不再以 Listing 状态、产品表现表是否有数据作为断货/停售判断条件。
        -- 测款扶持：首次货件到货日起0~30天，且当前 FBA 可售库存>0。
        SET v_stage = 'tmp_op';
        DROP TEMPORARY TABLE IF EXISTS tmp_op;
        CREATE TEMPORARY TABLE tmp_op AS
        SELECT k.country_category,
               NULL AS country,
               k.store,
               k.MSKU,
               COALESCE(f.fba_available, 0) AS fba_available,
               COALESCE(f.fba_in_transit, 0) AS fba_in_transit,
               COALESCE(l.local_quantity, 0) AS local_quantity,
               CASE
                   WHEN fr.first_receiving_date IS NOT NULL
                        AND DATEDIFF(v_data_date, fr.first_receiving_date) BETWEEN 0 AND 30
                        AND COALESCE(f.fba_available, 0) > 0 THEN 1
                   ELSE 0 END AS is_test_support,
               CASE
                   WHEN COALESCE(f.fba_available, 0) = 0
                        AND (COALESCE(f.fba_in_transit, 0) > 0 OR COALESCE(l.local_quantity, 0) > 0) THEN 1
                   ELSE 0 END AS is_out_of_stock,
               CASE
                   WHEN COALESCE(f.fba_available, 0) = 0
                        AND COALESCE(f.fba_in_transit, 0) = 0
                        AND COALESCE(l.local_quantity, 0) = 0 THEN 1
                   ELSE 0 END AS is_stopped,
               CASE
                   WHEN r.first_resume_sale_date IS NOT NULL
                        AND DATEDIFF(v_data_date, r.first_resume_sale_date) BETWEEN 0 AND 21 THEN 1
                   ELSE 0 END AS is_return_event
        FROM tmp_listing_keys k
                 LEFT JOIN tmp_op_fba f
                             ON k.country_category = f.country_category AND k.store = f.store AND k.MSKU = f.MSKU
                 LEFT JOIN tmp_op_local l
                             ON k.country_category = l.country_category AND k.store = l.store AND k.MSKU = l.MSKU
                 LEFT JOIN tmp_first_receiving fr
                             ON k.country_category = fr.country_category AND k.store = fr.store AND k.MSKU = fr.MSKU
                 LEFT JOIN tmp_return r
                             ON k.country_category = r.country_category AND k.store = r.store AND k.MSKU = r.MSKU;

        -- 运营状态必须互斥：每个国家类别+店铺+MSKU仅保留一个状态。
        -- 优先级：断货中 > 停售 > 返厂品 > 测款扶持 > 正常在售。
        INSERT INTO tmp_hits
        SELECT country_category,
               NULL AS country,
               store,
               MSKU,
               '运营状态' AS label_name,
               CASE
                   WHEN is_out_of_stock = 1 THEN '断货中'
                   WHEN is_stopped = 1 THEN '停售'
                   WHEN is_return_event = 1 THEN '返厂品'
                   WHEN is_test_support = 1 THEN '测款扶持'
                   WHEN fba_available > 0 THEN '正常在售'
               END AS child_label_name,
               CASE
                   WHEN is_out_of_stock = 1 THEN 'current'
                   WHEN is_stopped = 1 THEN 'current'
                   WHEN is_return_event = 1 THEN 'current'
                   WHEN is_test_support = 1 THEN '30d'
                   WHEN fba_available > 0 THEN 'current'
               END AS label_period
        FROM tmp_op
        WHERE is_out_of_stock = 1
           OR is_stopped = 1
           OR is_return_event = 1
           OR is_test_support = 1
           OR fba_available > 0;

        -- 返厂品阶段下钻：按国家类别+店铺+MSKU统计；以首次库存恢复到>5的日期为起点，首次到货后21天内输出，国家字段置NULL。
        -- 返厂品阶段下钻：最近180天最后一次站点级FBA=0后，首次恢复至>5的日期为首次到货/库存恢复日。
        -- 0~7天为观察期，8~21天为干预期，超过21天为退出阶段。
        INSERT INTO tmp_hits
        SELECT r.country_category,
               NULL,
               r.store,
               r.MSKU,
               '返厂品阶段下钻',
               CASE
                   WHEN DATEDIFF(v_data_date, r.first_resume_sale_date) BETWEEN 0 AND 7 THEN '观察期'
                   WHEN DATEDIFF(v_data_date, r.first_resume_sale_date) BETWEEN 8 AND 21 THEN '干预期'
                   WHEN DATEDIFF(v_data_date, r.first_resume_sale_date) > 21 THEN '退出阶段'
               END AS child_label_name,
               'current' AS label_period
        FROM tmp_return r
        WHERE r.first_resume_sale_date IS NOT NULL
          AND DATEDIFF(v_data_date, r.first_resume_sale_date) >= 0;

        -- 断货在途流程标签：
        -- 1) 先以运营状态判定“断货中”；2) 仅查询这些维度的货件；
        -- 3) 按货件状态最近更新时间取每个 MSKU 的最新状态记录；4) 直接使用该记录的 shipment_status。
        SET v_stage = 'tmp_oos_category';
        DROP TEMPORARY TABLE IF EXISTS tmp_oos_category;
        CREATE TEMPORARY TABLE tmp_oos_category AS
        SELECT CAST(country_category AS CHAR(20)) AS country_category,
               CAST(store AS CHAR(100)) AS store,
               CAST(MSKU AS CHAR(255)) AS MSKU
        FROM tmp_op
        WHERE is_out_of_stock = 1
        GROUP BY country_category, store, MSKU;
        ALTER TABLE tmp_oos_category
            ADD INDEX idx_tmp_oos_category (country_category, store, MSKU);

        SET v_stage = 'tmp_ship';

        DROP TEMPORARY TABLE IF EXISTS tmp_ship;
        CREATE TEMPORARY TABLE tmp_ship AS
        SELECT country_category,
               store,
               MSKU,
               shipment_status
        FROM (
                 SELECT o.country_category,
                        o.store,
                        o.MSKU,
                        CAST(s.`shipment_status` AS CHAR) AS shipment_status,
                        ROW_NUMBER() OVER (
                            PARTITION BY o.country_category, o.store, o.MSKU
                            -- 货件状态按最近更新时间取值：优先 gmt_modified；仅 WORKING 状态可回退 working_time，其余再回退 gmt_create、create_time。
                            ORDER BY COALESCE(
                                         STR_TO_DATE(LEFT(CAST(s.`gmt_modified` AS CHAR), 19), '%Y-%m-%d %H:%i:%s'),
                                         CASE
                                             -- working_time 仅表示进入 WORKING 状态的时间，不能作为其他状态的通用更新时间。
                                             WHEN UPPER(CAST(s.`shipment_status` AS CHAR)) = 'WORKING'
                                                 THEN STR_TO_DATE(LEFT(CAST(s.`working_time` AS CHAR), 19), '%Y-%m-%d %H:%i:%s')
                                         END,
                                         STR_TO_DATE(LEFT(CAST(s.`gmt_create` AS CHAR), 19), '%Y-%m-%d %H:%i:%s'),
                                         STR_TO_DATE(LEFT(CAST(s.`create_time` AS CHAR), 19), '%Y-%m-%d %H:%i:%s')
                                     ) DESC,
                                     s.`id` DESC
                            ) AS rn
                 FROM tmp_oos_category o
                          JOIN `dwd_datasync`.`lx_fba_shipment` s
                               ON o.country_category = CASE
                                                           WHEN CAST(s.`country` AS CHAR) = '英国' THEN '英国站'
                                                           WHEN CAST(s.`country` AS CHAR) IN ('美国', '加拿大', '巴西', '墨西哥')
                                                               THEN '北美站'
                                                           ELSE '欧洲站' END
                              AND o.store = CASE
                                                WHEN LOCATE('-', SUBSTRING_INDEX(CAST(s.`seller` AS CHAR), ' ', 1)) > 0 THEN LEFT(
                                                        SUBSTRING_INDEX(CAST(s.`seller` AS CHAR), ' ', 1),
                                                        LOCATE('-', SUBSTRING_INDEX(CAST(s.`seller` AS CHAR), ' ', 1)) - 1)
                                                ELSE SUBSTRING_INDEX(CAST(s.`seller` AS CHAR), ' ', 1) END
                              AND o.MSKU = CAST(s.`msku` AS CHAR)
                 WHERE s.`shipment_status` IS NOT NULL
                   AND CAST(s.`shipment_status` AS CHAR) <> ''
             ) latest_shipment
        WHERE latest_shipment.rn = 1;

        INSERT INTO tmp_hits
        SELECT country_category, NULL, store, MSKU, '断货在途流程标签', shipment_status, 'current'
        FROM tmp_ship
        WHERE shipment_status IS NOT NULL;

        SET v_stage = '最终标签写入';
        START TRANSACTION;
        -- Keep only v_data_date and v_data_date - 1. Delete current date first so reruns cannot duplicate rows.
        DELETE FROM `dws_datasync`.`dws_标签表`
        WHERE `data_date` = v_data_date;

        DELETE FROM `dws_datasync`.`dws_标签表`
        WHERE `data_date` < DATE_SUB(v_data_date, INTERVAL 1 DAY);

        INSERT INTO `dws_datasync`.`dws_标签表` (`data_date`, `country_category`, `country`, `store`, `msku`,
                                                 `label_id`, `label_period`, `created_time`)
        SELECT DISTINCT v_data_date,
                        h.`国家类别`,
                        h.`国家`,
                        h.`店铺`,
                        h.`MSKU`,
                        d.sub_label_id,
                        h.label_period,
                        NOW()
        FROM tmp_hits h
                 JOIN tmp_active_labels d ON d.label_name = h.label_name AND d.sub_label_name = h.child_label_name
        WHERE h.child_label_name IS NOT NULL
          AND h.`MSKU` IS NOT NULL
          AND h.`MSKU` <> '';
        SET v_record_count = ROW_COUNT();
        COMMIT;

        UPDATE `etl_datasync`.`etl_execution_log`
        SET `status` = 'success',
            `end_time` = NOW(),
            `data_time` = v_data_date,
            `record_count` = v_record_count
        WHERE `id` = v_log_id;
    ELSE
        UPDATE `etl_datasync`.`etl_execution_log`
        SET `status` = 'success',
            `end_time` = NOW(),
            `record_count` = 0
        WHERE `id` = v_log_id;
    END IF;
END //
DELIMITER ;

-- 保持原无参过程名，供每日事件及历史调用使用；自动取产品表现表最新业务日期。
DELIMITER //
CREATE PROCEDURE `dws_datasync`.`sp_dws_标签表_daily`()
BEGIN
    CALL `dws_datasync`.`sp_dws_标签表_按日期_daily`(NULL);
END //
DELIMITER ;

DELIMITER //
CREATE PROCEDURE `dws_datasync`.`sp_dws_站点销售角色_站点生命周期_按日期_daily`(IN p_data_date DATE)
BEGIN
    DECLARE v_data_date DATE DEFAULT NULL;
    DECLARE v_max_source_date DATE DEFAULT NULL;
    DECLARE v_7d DATE DEFAULT NULL;
    DECLARE v_14d DATE DEFAULT NULL;
    DECLARE v_30d DATE DEFAULT NULL;
    DECLARE v_90d DATE DEFAULT NULL;
    DECLARE v_proc_name VARCHAR(255) DEFAULT 'sp_dws_站点销售角色_站点生命周期_按日期_daily';
    DECLARE v_log_id INT DEFAULT NULL;
    DECLARE v_record_count INT DEFAULT 0;
    DECLARE v_error_msg TEXT;
    DECLARE v_stage VARCHAR(255) DEFAULT 'initialization';

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS CONDITION 1 v_error_msg = MESSAGE_TEXT;
        ROLLBACK;
        IF v_log_id IS NOT NULL THEN
            UPDATE `etl_datasync`.`etl_execution_log`
            SET `status` = 'error', `end_time` = NOW()
            WHERE `id` = v_log_id;
            INSERT INTO `etl_datasync`.`etl_error_log`
                (`proc_name`, `error_time`, `error_message`, `execution_log_id`)
            VALUES
                (v_proc_name, NOW(), CONCAT('[stage: ', v_stage, '] ', v_error_msg), v_log_id);
        END IF;
        RESIGNAL;
    END;

    INSERT INTO `etl_datasync`.`etl_execution_log` (`proc_name`, `start_time`, `status`)
    VALUES (v_proc_name, NOW(), 'started');
    SET v_log_id = LAST_INSERT_ID();

    -- 与基础标签过程保持同一业务日期；回补时使用传入业务日期。
    SELECT MAX(DATE(`start_date`)) INTO v_max_source_date
    FROM `dwd_datasync`.`lx_statistics_product_performance`;

    IF p_data_date IS NOT NULL AND (v_max_source_date IS NULL OR p_data_date > v_max_source_date) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = '指定业务日期晚于产品表现表的最新业务日期，不能回补。';
    END IF;

    SET v_data_date = COALESCE(p_data_date, v_max_source_date);

    IF v_data_date IS NOT NULL THEN
        SET v_7d = DATE_SUB(v_data_date, INTERVAL 6 DAY);
        SET v_14d = DATE_SUB(v_data_date, INTERVAL 13 DAY);
        SET v_30d = DATE_SUB(v_data_date, INTERVAL 29 DAY);
        SET v_90d = DATE_SUB(v_data_date, INTERVAL 89 DAY);

        -- 标签详情表必须先部署 ID=13（站点销售角色）和 ID=14（站点生命周期）的新定义。
        SET v_stage = 'active station labels';
        DROP TEMPORARY TABLE IF EXISTS tmp_station_active_labels;
        CREATE TEMPORARY TABLE tmp_station_active_labels AS
        SELECT DISTINCT CAST(`label_name` AS CHAR(100)) AS label_name,
                        CAST(`sub_label_name` AS CHAR(100)) AS sub_label_name,
                        `sub_label_id`
        FROM `dws_datasync`.`dws_标签详情表`
        WHERE CAST(`label_name` AS CHAR) IN ('站点销售角色', '站点生命周期')
          AND CAST(`status` AS CHAR) = '启用'
          AND `sub_label_name` IS NOT NULL;

        -- 商品池：Listing 最新同步记录（marketplace + seller_name + seller_sku），
        -- 以国家 + 清洗店铺 + MSKU 作为站点标签粒度；排除退款及 Amazon 占位 SKU。
        SET v_stage = 'station listing keys';
        DROP TEMPORARY TABLE IF EXISTS tmp_station_listing_keys;
        CREATE TEMPORARY TABLE tmp_station_listing_keys AS
        SELECT DISTINCT
               CASE WHEN CAST(li.`marketplace` AS CHAR) = '英国' THEN '英国站'
                    WHEN CAST(li.`marketplace` AS CHAR) IN ('美国', '加拿大', '巴西', '墨西哥') THEN '北美站'
                    ELSE '欧洲站' END AS country_category,
               CAST(li.`marketplace` AS CHAR(100)) AS country,
               CASE
                   WHEN LOCATE('-', SUBSTRING_INDEX(CAST(li.`seller_name` AS CHAR), ' ', 1)) > 0
                       THEN LEFT(SUBSTRING_INDEX(CAST(li.`seller_name` AS CHAR), ' ', 1),
                                 LOCATE('-', SUBSTRING_INDEX(CAST(li.`seller_name` AS CHAR), ' ', 1)) - 1)
                   ELSE SUBSTRING_INDEX(CAST(li.`seller_name` AS CHAR), ' ', 1)
               END AS store,
               CAST(li.`seller_sku` AS CHAR(255)) AS msku
        FROM (
            SELECT li.*,
                   ROW_NUMBER() OVER (
                       PARTITION BY CAST(li.`marketplace` AS CHAR),
                                    CAST(li.`seller_name` AS CHAR),
                                    CAST(li.`seller_sku` AS CHAR)
                       ORDER BY li.`create_time` DESC, li.`id` DESC
                   ) AS rn
            FROM `dwd_datasync`.`lx_sales_mws_listing` li
            WHERE li.`seller_sku` IS NOT NULL
              AND CAST(li.`seller_sku` AS CHAR) <> ''
              AND LOWER(TRIM(CAST(li.`seller_sku` AS CHAR))) NOT LIKE 'amzn.gr%'
              AND UPPER(TRIM(CAST(li.`seller_sku` AS CHAR))) NOT LIKE 'AMAZON%'
        ) li
        WHERE li.rn = 1;
        ALTER TABLE tmp_station_listing_keys
            ADD INDEX idx_station_listing_keys (country, store, msku);

        -- 指标统计粒度：国家 + 店铺 + MSKU。先同时计算 7/14/30/90 天，
        -- 其中 30d 写入站点销售角色；7/14/30/90d 仅供站点生命周期“成熟期”判断。
        SET v_stage = 'station sales metrics';
        DROP TEMPORARY TABLE IF EXISTS tmp_station_sales_metrics;
        CREATE TEMPORARY TABLE tmp_station_sales_metrics AS
        SELECT k.country_category,
               k.country,
               k.store,
               k.msku,
               SUM(CASE WHEN DATE(p.`start_date`) BETWEEN v_7d AND v_data_date THEN COALESCE(p.`volume`, 0) ELSE 0 END) AS volume_7d,
               SUM(CASE WHEN DATE(p.`start_date`) BETWEEN v_14d AND v_data_date THEN COALESCE(p.`volume`, 0) ELSE 0 END) AS volume_14d,
               SUM(CASE WHEN DATE(p.`start_date`) BETWEEN v_30d AND v_data_date THEN COALESCE(p.`volume`, 0) ELSE 0 END) AS volume_30d,
               SUM(CASE WHEN DATE(p.`start_date`) BETWEEN v_90d AND v_data_date THEN COALESCE(p.`volume`, 0) ELSE 0 END) AS volume_90d,
               CASE WHEN SUM(CASE WHEN DATE(p.`start_date`) BETWEEN v_7d AND v_data_date THEN COALESCE(p.`amount`, 0) ELSE 0 END) > 0
                    THEN SUM(CASE WHEN DATE(p.`start_date`) BETWEEN v_7d AND v_data_date THEN CASE WHEN COALESCE(p.`volume`, 0) = 0 THEN 0 ELSE COALESCE(p.`predict_gross_profit`, 0) END ELSE 0 END)
                         / NULLIF(SUM(CASE WHEN DATE(p.`start_date`) BETWEEN v_7d AND v_data_date THEN COALESCE(p.`amount`, 0) ELSE 0 END), 0)
                    ELSE NULL END AS margin_rate_7d,
               CASE WHEN SUM(CASE WHEN DATE(p.`start_date`) BETWEEN v_14d AND v_data_date THEN COALESCE(p.`amount`, 0) ELSE 0 END) > 0
                    THEN SUM(CASE WHEN DATE(p.`start_date`) BETWEEN v_14d AND v_data_date THEN CASE WHEN COALESCE(p.`volume`, 0) = 0 THEN 0 ELSE COALESCE(p.`predict_gross_profit`, 0) END ELSE 0 END)
                         / NULLIF(SUM(CASE WHEN DATE(p.`start_date`) BETWEEN v_14d AND v_data_date THEN COALESCE(p.`amount`, 0) ELSE 0 END), 0)
                    ELSE NULL END AS margin_rate_14d,
               CASE WHEN SUM(CASE WHEN DATE(p.`start_date`) BETWEEN v_30d AND v_data_date THEN COALESCE(p.`amount`, 0) ELSE 0 END) > 0
                    THEN SUM(CASE WHEN DATE(p.`start_date`) BETWEEN v_30d AND v_data_date THEN CASE WHEN COALESCE(p.`volume`, 0) = 0 THEN 0 ELSE COALESCE(p.`predict_gross_profit`, 0) END ELSE 0 END)
                         / NULLIF(SUM(CASE WHEN DATE(p.`start_date`) BETWEEN v_30d AND v_data_date THEN COALESCE(p.`amount`, 0) ELSE 0 END), 0)
                    ELSE NULL END AS margin_rate_30d,
               CASE WHEN SUM(CASE WHEN DATE(p.`start_date`) BETWEEN v_90d AND v_data_date THEN COALESCE(p.`amount`, 0) ELSE 0 END) > 0
                    THEN SUM(CASE WHEN DATE(p.`start_date`) BETWEEN v_90d AND v_data_date THEN CASE WHEN COALESCE(p.`volume`, 0) = 0 THEN 0 ELSE COALESCE(p.`predict_gross_profit`, 0) END ELSE 0 END)
                         / NULLIF(SUM(CASE WHEN DATE(p.`start_date`) BETWEEN v_90d AND v_data_date THEN COALESCE(p.`amount`, 0) ELSE 0 END), 0)
                    ELSE NULL END AS margin_rate_90d,
               AVG(CASE WHEN DATE(p.`start_date`) BETWEEN v_7d AND v_data_date AND p.`rank` > 0 THEN p.`rank` END) AS small_rank_7d,
               AVG(CASE WHEN DATE(p.`start_date`) BETWEEN v_14d AND v_data_date AND p.`rank` > 0 THEN p.`rank` END) AS small_rank_14d,
               AVG(CASE WHEN DATE(p.`start_date`) BETWEEN v_30d AND v_data_date AND p.`rank` > 0 THEN p.`rank` END) AS small_rank_30d,
               AVG(CASE WHEN DATE(p.`start_date`) BETWEEN v_90d AND v_data_date AND p.`rank` > 0 THEN p.`rank` END) AS small_rank_90d
        FROM tmp_station_listing_keys k
        LEFT JOIN `dwd_datasync`.`lx_statistics_product_performance` p
          ON k.country = CAST(p.`country` AS CHAR)
         AND k.store = CASE WHEN LOCATE('-', SUBSTRING_INDEX(CAST(p.`seller_name` AS CHAR), ' ', 1)) > 0
                            THEN LEFT(SUBSTRING_INDEX(CAST(p.`seller_name` AS CHAR), ' ', 1), LOCATE('-', SUBSTRING_INDEX(CAST(p.`seller_name` AS CHAR), ' ', 1)) - 1)
                            ELSE SUBSTRING_INDEX(CAST(p.`seller_name` AS CHAR), ' ', 1) END
         AND k.msku = CAST(p.`seller_sku` AS CHAR)
         AND DATE(p.`start_date`) BETWEEN v_90d AND v_data_date
        GROUP BY k.country_category, k.country, k.store, k.msku;
        ALTER TABLE tmp_station_sales_metrics
            ADD INDEX idx_station_sales_metrics (country, store, msku);

        -- 规则：问题产品优先；基于日销和结算毛利率得到基础角色；小类排名 rank 执行封顶/降级。
        -- rank=99999 为无效排名，直接归问题产品。
        SET v_stage = 'station role classification';
        DROP TEMPORARY TABLE IF EXISTS tmp_station_sales_roles;
        CREATE TEMPORARY TABLE tmp_station_sales_roles AS
        SELECT country_category, country, store, msku,
               CASE
                   WHEN COALESCE(volume_7d / 7.0, 0) <= 0 THEN '问题产品(站点)'
                   WHEN COALESCE(margin_rate_7d, 0) < 0.05 THEN '问题产品(站点)'
                   WHEN small_rank_7d IS NULL OR small_rank_7d <= 0 OR small_rank_7d >= 99999 THEN '问题产品(站点)'
                   WHEN small_rank_7d > 100 THEN '瘦狗产品(站点)'
                   WHEN small_rank_7d BETWEEN 51 AND 100 AND ((volume_7d / 7.0 > 3 AND margin_rate_7d >= 0.15) OR (volume_7d / 7.0 BETWEEN 1 AND 3 AND margin_rate_7d >= 0.25)) THEN '潜力产品(站点)'
                   WHEN small_rank_7d <= 50 AND ((volume_7d / 7.0 > 3 AND margin_rate_7d >= 0.15) OR (volume_7d / 7.0 BETWEEN 1 AND 3 AND margin_rate_7d >= 0.25)) THEN '明星产品(站点)'
                   WHEN (volume_7d / 7.0 > 3 AND margin_rate_7d >= 0.05 AND margin_rate_7d < 0.15) OR (volume_7d / 7.0 BETWEEN 1 AND 3 AND margin_rate_7d >= 0.10 AND margin_rate_7d < 0.25) THEN '潜力产品(站点)'
                   ELSE '瘦狗产品(站点)'
               END AS role_7d,
               CASE
                   WHEN COALESCE(volume_14d / 14.0, 0) <= 0 THEN '问题产品(站点)'
                   WHEN COALESCE(margin_rate_14d, 0) < 0.05 THEN '问题产品(站点)'
                   WHEN small_rank_14d IS NULL OR small_rank_14d <= 0 OR small_rank_14d >= 99999 THEN '问题产品(站点)'
                   WHEN small_rank_14d > 100 THEN '瘦狗产品(站点)'
                   WHEN small_rank_14d BETWEEN 51 AND 100 AND ((volume_14d / 14.0 > 3 AND margin_rate_14d >= 0.15) OR (volume_14d / 14.0 BETWEEN 1 AND 3 AND margin_rate_14d >= 0.25)) THEN '潜力产品(站点)'
                   WHEN small_rank_14d <= 50 AND ((volume_14d / 14.0 > 3 AND margin_rate_14d >= 0.15) OR (volume_14d / 14.0 BETWEEN 1 AND 3 AND margin_rate_14d >= 0.25)) THEN '明星产品(站点)'
                   WHEN (volume_14d / 14.0 > 3 AND margin_rate_14d >= 0.05 AND margin_rate_14d < 0.15) OR (volume_14d / 14.0 BETWEEN 1 AND 3 AND margin_rate_14d >= 0.10 AND margin_rate_14d < 0.25) THEN '潜力产品(站点)'
                   ELSE '瘦狗产品(站点)'
               END AS role_14d,
               CASE
                   WHEN COALESCE(volume_30d / 30.0, 0) <= 0 THEN '问题产品(站点)'
                   WHEN COALESCE(margin_rate_30d, 0) < 0.05 THEN '问题产品(站点)'
                   WHEN small_rank_30d IS NULL OR small_rank_30d <= 0 OR small_rank_30d >= 99999 THEN '问题产品(站点)'
                   WHEN small_rank_30d > 100 THEN '瘦狗产品(站点)'
                   WHEN small_rank_30d BETWEEN 51 AND 100 AND ((volume_30d / 30.0 > 3 AND margin_rate_30d >= 0.15) OR (volume_30d / 30.0 BETWEEN 1 AND 3 AND margin_rate_30d >= 0.25)) THEN '潜力产品(站点)'
                   WHEN small_rank_30d <= 50 AND ((volume_30d / 30.0 > 3 AND margin_rate_30d >= 0.15) OR (volume_30d / 30.0 BETWEEN 1 AND 3 AND margin_rate_30d >= 0.25)) THEN '明星产品(站点)'
                   WHEN (volume_30d / 30.0 > 3 AND margin_rate_30d >= 0.05 AND margin_rate_30d < 0.15) OR (volume_30d / 30.0 BETWEEN 1 AND 3 AND margin_rate_30d >= 0.10 AND margin_rate_30d < 0.25) THEN '潜力产品(站点)'
                   ELSE '瘦狗产品(站点)'
               END AS role_30d,
               CASE
                   WHEN COALESCE(volume_90d / 90.0, 0) <= 0 THEN '问题产品(站点)'
                   WHEN COALESCE(margin_rate_90d, 0) < 0.05 THEN '问题产品(站点)'
                   WHEN small_rank_90d IS NULL OR small_rank_90d <= 0 OR small_rank_90d >= 99999 THEN '问题产品(站点)'
                   WHEN small_rank_90d > 100 THEN '瘦狗产品(站点)'
                   WHEN small_rank_90d BETWEEN 51 AND 100 AND ((volume_90d / 90.0 > 3 AND margin_rate_90d >= 0.15) OR (volume_90d / 90.0 BETWEEN 1 AND 3 AND margin_rate_90d >= 0.25)) THEN '潜力产品(站点)'
                   WHEN small_rank_90d <= 50 AND ((volume_90d / 90.0 > 3 AND margin_rate_90d >= 0.15) OR (volume_90d / 90.0 BETWEEN 1 AND 3 AND margin_rate_90d >= 0.25)) THEN '明星产品(站点)'
                   WHEN (volume_90d / 90.0 > 3 AND margin_rate_90d >= 0.05 AND margin_rate_90d < 0.15) OR (volume_90d / 90.0 BETWEEN 1 AND 3 AND margin_rate_90d >= 0.10 AND margin_rate_90d < 0.25) THEN '潜力产品(站点)'
                   ELSE '瘦狗产品(站点)'
               END AS role_90d
        FROM tmp_station_sales_metrics;
        ALTER TABLE tmp_station_sales_roles
            ADD INDEX idx_station_sales_roles (country, store, msku);

        -- 首次到货：同样按国家 + 店铺 + MSKU 取 lx_fba_shipment.receiving_time 最小日期。
        SET v_stage = 'station first receiving';
        DROP TEMPORARY TABLE IF EXISTS tmp_station_first_receiving;
        CREATE TEMPORARY TABLE tmp_station_first_receiving AS
        SELECT k.country_category, k.country, k.store, k.msku,
               MIN(STR_TO_DATE(LEFT(CAST(s.`receiving_time` AS CHAR), 10), '%Y-%m-%d')) AS first_receiving_date
        FROM tmp_station_listing_keys k
        JOIN `dwd_datasync`.`lx_fba_shipment` s
          ON k.country = CAST(s.`country` AS CHAR)
         AND k.store = CASE WHEN LOCATE('-', SUBSTRING_INDEX(CAST(s.`seller` AS CHAR), ' ', 1)) > 0
                            THEN LEFT(SUBSTRING_INDEX(CAST(s.`seller` AS CHAR), ' ', 1), LOCATE('-', SUBSTRING_INDEX(CAST(s.`seller` AS CHAR), ' ', 1)) - 1)
                            ELSE SUBSTRING_INDEX(CAST(s.`seller` AS CHAR), ' ', 1) END
         AND k.msku = CAST(s.`msku` AS CHAR)
        -- receiving_time 为 VARCHAR，源表存在空字符串；不能直接 DATE('')，否则严格模式报  Incorrect datetime value。
        WHERE NULLIF(TRIM(CAST(s.`receiving_time` AS CHAR)), '') IS NOT NULL
          AND CAST(s.`receiving_time` AS CHAR) REGEXP '^[0-9]{4}-[0-9]{2}-[0-9]{2}'
          AND STR_TO_DATE(LEFT(CAST(s.`receiving_time` AS CHAR), 10), '%Y-%m-%d') <= v_data_date
        GROUP BY k.country_category, k.country, k.store, k.msku;
        ALTER TABLE tmp_station_first_receiving
            ADD INDEX idx_station_first_receiving (country, store, msku);

        SET v_stage = 'station label write';
        START TRANSACTION;

        -- 新增站点标签只清理自身：当天先删以支持重跑；同时仅保留最近两天业务日期。
        DELETE t
        FROM `dws_datasync`.`dws_标签表` t
        JOIN tmp_station_active_labels l ON l.sub_label_id = t.label_id
        WHERE t.`data_date` = v_data_date;

        DELETE t
        FROM `dws_datasync`.`dws_标签表` t
        JOIN tmp_station_active_labels l ON l.sub_label_id = t.label_id
        WHERE t.`data_date` < DATE_SUB(v_data_date, INTERVAL 1 DAY);

        -- 站点销售角色按 7/14/30/90d 分别落表；四个周期均使用相同的日销、结算毛利率和小类排名规则。
        INSERT INTO `dws_datasync`.`dws_标签表`
            (`data_date`, `country_category`, `country`, `store`, `msku`, `label_id`, `label_period`, `created_time`)
        SELECT v_data_date, r.country_category, r.country, r.store, r.msku,
               l.sub_label_id, '7d', NOW()
        FROM tmp_station_sales_roles r
        JOIN tmp_station_active_labels l
          ON l.label_name = '站点销售角色'
         AND l.sub_label_name = r.role_7d;
        SET v_record_count = ROW_COUNT();

        INSERT INTO `dws_datasync`.`dws_标签表`
            (`data_date`, `country_category`, `country`, `store`, `msku`, `label_id`, `label_period`, `created_time`)
        SELECT v_data_date, r.country_category, r.country, r.store, r.msku,
               l.sub_label_id, '14d', NOW()
        FROM tmp_station_sales_roles r
        JOIN tmp_station_active_labels l
          ON l.label_name = '站点销售角色'
         AND l.sub_label_name = r.role_14d;
        SET v_record_count = v_record_count + ROW_COUNT();

        INSERT INTO `dws_datasync`.`dws_标签表`
            (`data_date`, `country_category`, `country`, `store`, `msku`, `label_id`, `label_period`, `created_time`)
        SELECT v_data_date, r.country_category, r.country, r.store, r.msku,
               l.sub_label_id, '30d', NOW()
        FROM tmp_station_sales_roles r
        JOIN tmp_station_active_labels l
          ON l.label_name = '站点销售角色'
         AND l.sub_label_name = r.role_30d;
        SET v_record_count = v_record_count + ROW_COUNT();

        INSERT INTO `dws_datasync`.`dws_标签表`
            (`data_date`, `country_category`, `country`, `store`, `msku`, `label_id`, `label_period`, `created_time`)
        SELECT v_data_date, r.country_category, r.country, r.store, r.msku,
               l.sub_label_id, '90d', NOW()
        FROM tmp_station_sales_roles r
        JOIN tmp_station_active_labels l
          ON l.label_name = '站点销售角色'
         AND l.sub_label_name = r.role_90d;
        SET v_record_count = v_record_count + ROW_COUNT();

        -- 衰退期为人工维护定义，自动 SQL 仅写入测款期/新品期/成长期/成熟期。
        INSERT INTO `dws_datasync`.`dws_标签表`
            (`data_date`, `country_category`, `country`, `store`, `msku`, `label_id`, `label_period`, `created_time`)
        SELECT v_data_date, fr.country_category, fr.country, fr.store, fr.msku,
               l.sub_label_id,
               CASE
                   WHEN DATEDIFF(v_data_date, fr.first_receiving_date) BETWEEN 0 AND 30 THEN '30d'
                   WHEN DATEDIFF(v_data_date, fr.first_receiving_date) BETWEEN 31 AND 120 THEN '90d'
                   WHEN DATEDIFF(v_data_date, fr.first_receiving_date) BETWEEN 121 AND 300 THEN '6m'
                   WHEN DATEDIFF(v_data_date, fr.first_receiving_date) > 300
                        AND COALESCE(r.role_7d, '') NOT IN ('瘦狗产品(站点)', '问题产品(站点)')
                        AND COALESCE(r.role_14d, '') NOT IN ('瘦狗产品(站点)', '问题产品(站点)')
                        AND COALESCE(r.role_30d, '') NOT IN ('瘦狗产品(站点)', '问题产品(站点)')
                        AND COALESCE(r.role_90d, '') NOT IN ('瘦狗产品(站点)', '问题产品(站点)') THEN 'long_term'
                   WHEN DATEDIFF(v_data_date, fr.first_receiving_date) > 300 THEN '6m'
               END AS label_period,
               NOW()
        FROM tmp_station_first_receiving fr
        LEFT JOIN tmp_station_sales_roles r
          ON fr.country = r.country AND fr.store = r.store AND fr.msku = r.msku
        JOIN tmp_station_active_labels l
          ON l.label_name = '站点生命周期'
         AND l.sub_label_name = CASE
                   WHEN DATEDIFF(v_data_date, fr.first_receiving_date) BETWEEN 0 AND 30 THEN '测款期(站点)'
                   WHEN DATEDIFF(v_data_date, fr.first_receiving_date) BETWEEN 31 AND 120 THEN '新品期(站点)'
                   WHEN DATEDIFF(v_data_date, fr.first_receiving_date) BETWEEN 121 AND 300 THEN '成长期(站点)'
                   WHEN DATEDIFF(v_data_date, fr.first_receiving_date) > 300
                        AND COALESCE(r.role_7d, '') NOT IN ('瘦狗产品(站点)', '问题产品(站点)')
                        AND COALESCE(r.role_14d, '') NOT IN ('瘦狗产品(站点)', '问题产品(站点)')
                        AND COALESCE(r.role_30d, '') NOT IN ('瘦狗产品(站点)', '问题产品(站点)')
                        AND COALESCE(r.role_90d, '') NOT IN ('瘦狗产品(站点)', '问题产品(站点)') THEN '成熟期(站点)'
                   WHEN DATEDIFF(v_data_date, fr.first_receiving_date) > 300 THEN '成长期(站点)'
               END
        WHERE DATEDIFF(v_data_date, fr.first_receiving_date) >= 0;
        SET v_record_count = v_record_count + ROW_COUNT();
        COMMIT;

        UPDATE `etl_datasync`.`etl_execution_log`
        SET `status` = 'success', `end_time` = NOW(), `data_time` = v_data_date, `record_count` = v_record_count
        WHERE `id` = v_log_id;
    ELSE
        UPDATE `etl_datasync`.`etl_execution_log`
        SET `status` = 'success', `end_time` = NOW(), `record_count` = 0
        WHERE `id` = v_log_id;
    END IF;
END //

-- 保持原无参站点过程名，默认按产品表现表最新业务日期计算。
CREATE PROCEDURE `dws_datasync`.`sp_dws_站点销售角色_站点生命周期_daily`()
BEGIN
    CALL `dws_datasync`.`sp_dws_站点销售角色_站点生命周期_按日期_daily`(NULL);
END //

-- 将调度包装为串行调用；按日期版本用于首次回补，避免 15 日、16 日写入时使用同一个业务日期。
CREATE PROCEDURE `dws_datasync`.`sp_dws_标签表_含站点标签_按日期_daily`(IN p_data_date DATE)
BEGIN
    DECLARE v_base_status VARCHAR(20) DEFAULT NULL;

    CALL `dws_datasync`.`sp_dws_标签表_按日期_daily`(p_data_date);

    -- 复核基础标签过程结果，避免基础标签失败后仍写入新增站点标签。
    SELECT `status` INTO v_base_status
    FROM `etl_datasync`.`etl_execution_log`
    WHERE `proc_name` = 'sp_dws_标签表_按日期_daily'
    ORDER BY `id` DESC
    LIMIT 1;

    IF COALESCE(v_base_status, '') <> 'success' THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'sp_dws_标签表_按日期_daily 执行失败，已停止站点销售角色及站点生命周期标签写入。';
    END IF;

    CALL `dws_datasync`.`sp_dws_站点销售角色_站点生命周期_按日期_daily`(p_data_date);
END //

-- 每日事件仍调用无参包装；它会自动取产品表现表最新业务日期。
CREATE PROCEDURE `dws_datasync`.`sp_dws_标签表_含站点标签_daily`()
BEGIN
    CALL `dws_datasync`.`sp_dws_标签表_含站点标签_按日期_daily`(NULL);
END //
DELIMITER ;

-- 不删除 evt_标签表：若事件不存在则创建；若已存在则仅更新为每日 07:20 串行调度。
-- 这样可避免首次部署时因 ALTER EVENT 找不到事件而导致脚本末尾报错。
DELIMITER //
CREATE EVENT IF NOT EXISTS `dws_datasync`.`evt_标签表`
    ON SCHEDULE EVERY 1 DAY
        STARTS TIMESTAMP(CURRENT_DATE(), '07:20:00')
    ON COMPLETION PRESERVE
    ENABLE
DO
BEGIN
    CALL `dws_datasync`.`sp_dws_标签表_含站点标签_daily`();
END //

ALTER EVENT `dws_datasync`.`evt_标签表`
    ON SCHEDULE EVERY 1 DAY
        STARTS TIMESTAMP(CURRENT_DATE(), '07:20:00')
    ON COMPLETION PRESERVE
    ENABLE
DO
BEGIN
    CALL `dws_datasync`.`sp_dws_标签表_含站点标签_daily`();
END //
DELIMITER ;

-- ============================================================================
-- 执行说明
-- 1) 首次部署后，请按顺序回补两天（2026-07-18、2026-07-19）：
-- CALL `dws_datasync`.`sp_dws_标签表_含站点标签_按日期_daily`('2026-07-18');
-- CALL `dws_datasync`.`sp_dws_标签表_含站点标签_按日期_daily`('2026-07-19');
--    第二次执行后，全表仅保留 2026-07-18 和 2026-07-19 两个业务日期的数据。
-- 2) 日常无需传参：每日 07:20 的 evt_标签表 自动调用无参包装过程，
--    并始终仅保留产品表现表最新业务日期及其前一日的数据。
-- 3) 如需手工重跑最新业务日期：
-- CALL `dws_datasync`.`sp_dws_标签表_含站点标签_daily`();
-- ============================================================================


