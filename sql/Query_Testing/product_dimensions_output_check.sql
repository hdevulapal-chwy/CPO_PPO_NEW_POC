-- Read-only checks of the stored step-13 output, rather than an enrichment preview.
WITH pharmacy AS (
    SELECT DISTINCT product_part_number AS partnumber
    FROM {{ CATEGORY_TABLE }}
    WHERE UPPER(TRIM(product_category_level1)) = 'PHARMACY'
      AND product_part_number IS NOT NULL
),
base_rows AS (
    SELECT s.* FROM {{ OMS_ORDERS_SHIPPED_TABLE }} s
    WHERE DATE(CONVERT_TIMEZONE('UTC', 'America/New_York', s.TIMECREATED::TIMESTAMP_NTZ))
          BETWEEN '{{ START_DATE }}'::DATE AND '{{ END_DATE }}'::DATE
),
eligible AS (
    SELECT b.* FROM base_rows b
    WHERE NOT EXISTS (SELECT 1 FROM pharmacy p WHERE p.partnumber = b.partnumber)
),
output_rows AS (
    SELECT o.* FROM {{ OMS_ORDERS_SHIPPED_DIMENSIONS_TABLE }} o
    WHERE DATE(CONVERT_TIMEZONE('UTC', 'America/New_York', o.TIMECREATED::TIMESTAMP_NTZ))
          BETWEEN '{{ START_DATE }}'::DATE AND '{{ END_DATE }}'::DATE
),
ranked_snapshots AS (
    SELECT p.product_part_number AS partnumber,
           p.product_packaged_length AS item_l, p.product_packaged_width AS item_w,
           p.product_packaged_height AS item_h, p.product_packaged_weight AS item_wt,
           ROW_NUMBER() OVER (PARTITION BY p.product_part_number
                              ORDER BY p.snapshot_date DESC NULLS LAST) AS latest_row
    FROM {{ PRODUCTS_TABLE }} p
    WHERE EXISTS (SELECT 1 FROM output_rows o WHERE o.partnumber = p.product_part_number)
),
missing_rows AS (
    SELECT TIMECREATED, ORDER_ID, ORDER_ITEM_ID, SHIPMENT_TRACKING_NUMBER, PARTNUMBER, QUANTITY FROM eligible
    EXCEPT
    SELECT TIMECREATED, ORDER_ID, ORDER_ITEM_ID, SHIPMENT_TRACKING_NUMBER, PARTNUMBER, QUANTITY FROM output_rows
),
extra_rows AS (
    SELECT TIMECREATED, ORDER_ID, ORDER_ITEM_ID, SHIPMENT_TRACKING_NUMBER, PARTNUMBER, QUANTITY FROM output_rows
    EXCEPT
    SELECT TIMECREATED, ORDER_ID, ORDER_ITEM_ID, SHIPMENT_TRACKING_NUMBER, PARTNUMBER, QUANTITY FROM eligible
),
output_stats AS (
    SELECT COUNT(*) AS output_rows,
           COUNT(DISTINCT o.partnumber) AS output_skus,
           COUNT(DISTINCT o.order_id) AS output_orders,
           COALESCE(SUM(o.quantity), 0) AS output_quantity,
           COUNT(CASE WHEN ph.partnumber IS NOT NULL THEN 1 END) AS pharmacy_rows_remaining,
           COUNT(CASE WHEN o.item_l IS DISTINCT FROM p.item_l OR o.item_w IS DISTINCT FROM p.item_w
                        OR o.item_h IS DISTINCT FROM p.item_h OR o.item_wt IS DISTINCT FROM p.item_wt
                      THEN 1 END) AS rows_differing_from_latest_snapshot,
           COUNT(DISTINCT CASE WHEN o.item_wt IS NULL THEN o.partnumber END) AS missing_weight_skus,
           COUNT(DISTINCT CASE WHEN o.item_wt IS NULL THEN o.order_id END) AS missing_weight_orders,
           COUNT(DISTINCT CASE WHEN o.item_l IS NULL OR o.item_w IS NULL OR o.item_h IS NULL
                               THEN o.partnumber END) AS missing_dimensions_skus,
           COUNT(DISTINCT CASE WHEN o.item_l IS NULL OR o.item_w IS NULL OR o.item_h IS NULL
                               THEN o.order_id END) AS missing_dimensions_orders,
           COUNT(DISTINCT CASE WHEN TRY_TO_DOUBLE(o.item_wt::VARCHAR) = 0 THEN o.partnumber END) AS zero_weight_skus,
           COUNT(DISTINCT CASE WHEN TRY_TO_DOUBLE(o.item_wt::VARCHAR) = 0 THEN o.order_id END) AS zero_weight_orders
    FROM output_rows o LEFT JOIN ranked_snapshots p ON p.partnumber = o.partnumber AND p.latest_row = 1
    LEFT JOIN pharmacy ph ON ph.partnumber = o.partnumber
)
SELECT (SELECT COUNT(*) FROM base_rows) AS BASE_ROWS,
       (SELECT COUNT(*) FROM base_rows) - (SELECT COUNT(*) FROM eligible) AS EXCLUDED_PHARMACY_ROWS,
       (SELECT COUNT(*) FROM eligible) AS EXPECTED_OUTPUT_ROWS,
       o.*,
       o.output_rows - (SELECT COUNT(*) FROM eligible) AS ROW_DIFFERENCE,
       o.output_quantity - (SELECT COALESCE(SUM(quantity), 0) FROM eligible) AS QUANTITY_DIFFERENCE,
       (SELECT COUNT(*) FROM missing_rows) AS MISSING_SHIPMENT_KEYS,
       (SELECT COUNT(*) FROM extra_rows) AS EXTRA_SHIPMENT_KEYS
FROM output_stats o;
