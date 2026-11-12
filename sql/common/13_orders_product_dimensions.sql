-- Run after 12_orders_enriched.sql has loaded the requested dates.
-- Read the saved shipment table: its temporary batch is not available in a
-- separate Python connection. Keep the source shipment table unchanged.
-- Latest lifecycle snapshot per part number prevents the join multiplying rows.
-- LEFT JOIN retains shipments even when product dimensions are unavailable.
CREATE OR REPLACE TEMPORARY TABLE OMS_ORDERS_SHIPPED_DIMENSIONS_BATCH AS
WITH pharmacy_skus AS (
    SELECT DISTINCT product_part_number AS partnumber
    FROM {{ CATEGORY_TABLE }}
    WHERE UPPER(TRIM(product_category_level1)) = 'PHARMACY'
      AND product_part_number IS NOT NULL
),
batch_orders AS (
    SELECT s.*
    FROM {{ OMS_ORDERS_SHIPPED_TABLE }} s
    WHERE DATE(CONVERT_TIMEZONE('UTC', 'America/New_York', TIMECREATED::TIMESTAMP_NTZ))
          BETWEEN TO_DATE('{{ START_DATE }}', 'YYYY-MM-DD')
              AND TO_DATE('{{ END_DATE }}', 'YYYY-MM-DD')
      AND NOT EXISTS (SELECT 1 FROM pharmacy_skus p WHERE p.partnumber = s.partnumber)
),
ranked_snapshots AS (
    SELECT
        p.product_part_number AS partnumber,
        p.product_packaged_length AS item_l,
        p.product_packaged_width AS item_w,
        p.product_packaged_height AS item_h,
        p.product_packaged_weight AS item_wt,
        ROW_NUMBER() OVER (
            PARTITION BY p.product_part_number ORDER BY p.snapshot_date DESC NULLS LAST
        ) AS latest_row
    FROM {{ PRODUCTS_TABLE }} p
    WHERE EXISTS (
        SELECT 1 FROM batch_orders b
        WHERE b.partnumber = p.product_part_number
    )
),
product_dimensions AS (
    SELECT partnumber, item_l, item_w, item_h, item_wt
    FROM ranked_snapshots WHERE latest_row = 1
)
SELECT b.*, p.item_l, p.item_w, p.item_h, p.item_wt
FROM batch_orders b
LEFT JOIN product_dimensions p ON b.partnumber = p.partnumber;

CREATE TABLE IF NOT EXISTS {{ OMS_ORDERS_SHIPPED_DIMENSIONS_TABLE }}
LIKE OMS_ORDERS_SHIPPED_DIMENSIONS_BATCH;

-- Retain other months and replace this batch in the dimensions table as well.
DELETE FROM {{ OMS_ORDERS_SHIPPED_DIMENSIONS_TABLE }}
WHERE DATE(CONVERT_TIMEZONE('UTC', 'America/New_York', TIMECREATED::TIMESTAMP_NTZ))
      BETWEEN TO_DATE('{{ START_DATE }}', 'YYYY-MM-DD')
          AND TO_DATE('{{ END_DATE }}', 'YYYY-MM-DD');

INSERT INTO {{ OMS_ORDERS_SHIPPED_DIMENSIONS_TABLE }}
    (TIMECREATED, ORDER_ID, ORDER_ITEM_ID, SHIPMENT_TRACKING_NUMBER, PARTNUMBER,
     QUANTITY, ITEM_L, ITEM_W, ITEM_H, ITEM_WT)
SELECT TIMECREATED, ORDER_ID, ORDER_ITEM_ID, SHIPMENT_TRACKING_NUMBER, PARTNUMBER,
       QUANTITY, ITEM_L, ITEM_W, ITEM_H, ITEM_WT
FROM OMS_ORDERS_SHIPPED_DIMENSIONS_BATCH;

