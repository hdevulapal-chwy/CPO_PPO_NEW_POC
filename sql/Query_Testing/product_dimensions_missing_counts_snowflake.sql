-- Run all SET statements and the SELECT in one Snowflake worksheet.
SET START_DATE = '2026-07-01';
SET END_DATE = '2026-09-30';
SET OMS_ORDERS_SHIPPED_TABLE = 'EDLDB_DEV.SC_ORDER_ROUTING_TEAM_SANDBOX.OMS_ORDERS_SHIPPED_TEST';
SET PRODUCTS_TABLE = 'EDLDB.CHEWYBI.PRODUCT_LIFECYCLE_SNAPSHOT';
SET CATEGORY_TABLE = 'EDLDB.CHEWYBI.PRODUCTS';

-- Distinct SKU/order counts, not shipment-row counts.
WITH pharmacy_skus AS (
    SELECT DISTINCT product_part_number AS partnumber
    FROM IDENTIFIER($CATEGORY_TABLE)
    WHERE UPPER(TRIM(product_category_level1)) = 'PHARMACY'
      AND product_part_number IS NOT NULL
),
shipments AS (
    SELECT s.order_id, s.partnumber
    FROM IDENTIFIER($OMS_ORDERS_SHIPPED_TABLE) s
    WHERE DATE(CONVERT_TIMEZONE('UTC', 'America/New_York', TIMECREATED::TIMESTAMP_NTZ))
          BETWEEN $START_DATE::DATE AND $END_DATE::DATE
      AND NOT EXISTS (SELECT 1 FROM pharmacy_skus p WHERE p.partnumber = s.partnumber)
),
ranked_snapshots AS (
    SELECT p.product_part_number AS partnumber,
           p.product_packaged_length AS item_l,
           p.product_packaged_width AS item_w,
           p.product_packaged_height AS item_h,
           p.product_packaged_weight AS item_wt,
           ROW_NUMBER() OVER (PARTITION BY p.product_part_number
                              ORDER BY p.snapshot_date DESC NULLS LAST) AS latest_row
    FROM IDENTIFIER($PRODUCTS_TABLE) p
    WHERE EXISTS (SELECT 1 FROM shipments s WHERE s.partnumber = p.product_part_number)
),
dimensions AS (
    SELECT partnumber, item_l, item_w, item_h, item_wt
    FROM ranked_snapshots WHERE latest_row = 1
),
audit AS (
    SELECT s.*, d.item_l, d.item_w, d.item_h, d.item_wt
    FROM shipments s LEFT JOIN dimensions d ON s.partnumber = d.partnumber
)
SELECT
    COUNT(DISTINCT partnumber) AS TOTAL_SKUS,
    COUNT(DISTINCT order_id) AS TOTAL_ORDERS,
    COUNT(DISTINCT CASE WHEN item_wt IS NULL THEN partnumber END) AS MISSING_WEIGHT_SKUS,
    COUNT(DISTINCT CASE WHEN item_wt IS NULL THEN order_id END) AS MISSING_WEIGHT_ORDERS,
    COUNT(DISTINCT CASE WHEN item_l IS NULL OR item_w IS NULL OR item_h IS NULL
                        THEN partnumber END) AS MISSING_DIMENSIONS_SKUS,
    COUNT(DISTINCT CASE WHEN item_l IS NULL OR item_w IS NULL OR item_h IS NULL
                        THEN order_id END) AS MISSING_DIMENSIONS_ORDERS,
    COUNT(DISTINCT CASE WHEN item_wt IS NULL OR item_l IS NULL OR item_w IS NULL OR item_h IS NULL
                        THEN partnumber END) AS MISSING_EITHER_SKUS,
    COUNT(DISTINCT CASE WHEN item_wt IS NULL OR item_l IS NULL OR item_w IS NULL OR item_h IS NULL
                        THEN order_id END) AS MISSING_EITHER_ORDERS,
    COUNT(DISTINCT CASE WHEN TRY_TO_DOUBLE(item_wt::VARCHAR) = 0 THEN partnumber END) AS ZERO_WEIGHT_SKUS,
    COUNT(DISTINCT CASE WHEN TRY_TO_DOUBLE(item_wt::VARCHAR) = 0 THEN order_id END) AS ZERO_WEIGHT_ORDERS
FROM audit;
