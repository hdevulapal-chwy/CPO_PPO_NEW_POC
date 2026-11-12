-- Read-only reverse test: search OMS source tables on any creation date.
-- Do not rely on the loaded OMS table having July data.
WITH bi AS (
    SELECT order_order_id AS order_id, shipment_tracking_number,
           SUM(order_line_quantity) AS bi_quantity
    FROM edldb.chewybi.order_line_measures
    WHERE DATE(order_placed_date) BETWEEN '{{ START_DATE }}'::DATE AND '{{ END_DATE }}'::DATE
      AND shipment_tracking_number IS NOT NULL
    GROUP BY 1, 2
),
missing AS (
    SELECT b.* FROM bi b
    WHERE NOT EXISTS (
        SELECT 1 FROM {{ OMS_ORDERS_SHIPPED_TABLE }} o
        WHERE o.order_id = b.order_id
          AND o.shipment_tracking_number = b.shipment_tracking_number
          AND DATE(CONVERT_TIMEZONE('UTC', 'America/New_York', o.TIMECREATED::TIMESTAMP_NTZ))
              BETWEEN '{{ START_DATE }}'::DATE AND '{{ END_DATE }}'::DATE
    )
),
target_items AS (
    SELECT DISTINCT oi.TIMECREATED, oi.id, oi.orders_id, oi.partnumber
    FROM EDLDB.ORDER_MANAGEMENT_SERVICE.ORDERITEM oi
    WHERE EXISTS (SELECT 1 FROM missing m WHERE m.order_id = oi.orders_id)
),
shipment_items AS (
    SELECT c.orderitem_id, c.manifest_id, SUM(c.quantity) AS quantity
    FROM EDLDB.ORDER_MANAGEMENT_SERVICE.ORDITEMCONF c
    INNER JOIN target_items t ON t.id = c.orderitem_id
    GROUP BY 1, 2
),
original_rows AS (
    SELECT DISTINCT oi.TIMECREATED, oi.orders_id AS order_id, oi.id AS order_item_id,
           m.trackingid AS shipment_tracking_number, oi.partnumber, si.quantity
    FROM target_items oi
    JOIN shipment_items si ON si.orderitem_id = oi.id
    JOIN EDLDB.ORDER_MANAGEMENT_SERVICE.MANIFEST m ON m.id = si.manifest_id
    WHERE m.status <> 'V' AND m.trackingid IS NOT NULL
),
oms_any_date AS (
    SELECT o.order_id, o.shipment_tracking_number, COUNT(*) AS found_rows,
           MIN(DATE(CONVERT_TIMEZONE('UTC', 'America/New_York', o.TIMECREATED::TIMESTAMP_NTZ))) AS first_created_date,
           MAX(DATE(CONVERT_TIMEZONE('UTC', 'America/New_York', o.TIMECREATED::TIMESTAMP_NTZ))) AS last_created_date,
           COUNT(CASE WHEN DATE(CONVERT_TIMEZONE('UTC', 'America/New_York', o.TIMECREATED::TIMESTAMP_NTZ))
                           = DATEADD(day, -1, '{{ START_DATE }}'::DATE) THEN 1 END) AS previous_day_rows,
           COUNT(CASE WHEN DATE(CONVERT_TIMEZONE('UTC', 'America/New_York', o.TIMECREATED::TIMESTAMP_NTZ))
                           BETWEEN '{{ START_DATE }}'::DATE AND '{{ END_DATE }}'::DATE THEN 1 END) AS inside_range_rows,
           SUM(o.quantity) AS oms_quantity
    FROM original_rows o
    WHERE EXISTS (SELECT 1 FROM missing m
                  WHERE m.order_id = o.order_id AND m.shipment_tracking_number = o.shipment_tracking_number)
    GROUP BY 1, 2
),
classified AS (
    SELECT m.*, o.* EXCLUDE (order_id, shipment_tracking_number),
           CASE WHEN o.found_rows IS NULL THEN 'NOT_FOUND_ON_ANY_DATE'
                WHEN o.first_created_date IS NULL THEN 'FOUND_WITH_NULL_CREATION_DATE'
                WHEN o.first_created_date = DATEADD(day, -1, '{{ START_DATE }}'::DATE)
                 AND o.last_created_date = DATEADD(day, -1, '{{ START_DATE }}'::DATE)
                    THEN 'FOUND_ONLY_ON_PREVIOUS_DAY'
                WHEN o.inside_range_rows > 0 THEN 'FOUND_INSIDE_RANGE_CHECK_LOADED_TABLE'
                WHEN o.previous_day_rows > 0 THEN 'FOUND_ON_PREVIOUS_DAY_AND_OTHER_DATES'
                WHEN o.last_created_date < '{{ START_DATE }}'::DATE THEN 'FOUND_ON_OTHER_EARLIER_DATES'
                WHEN o.first_created_date > '{{ END_DATE }}'::DATE THEN 'FOUND_ON_LATER_DATES'
                ELSE 'FOUND_ON_MULTIPLE_OUTSIDE_DATES' END AS category
    FROM missing m LEFT JOIN oms_any_date o
      ON m.order_id = o.order_id AND m.shipment_tracking_number = o.shipment_tracking_number
)
SELECT COALESCE(category, 'ALL_CHEWYBI_ONLY') AS category,
       COUNT(*) AS pairs,
       COUNT(CASE WHEN found_rows IS NOT NULL THEN 1 END) AS found_in_oms_any_date,
       COUNT(CASE WHEN found_rows IS NOT NULL AND oms_quantity IS NOT DISTINCT FROM bi_quantity
                  THEN 1 END) AS equal_quantity_pairs,
       COUNT(CASE WHEN found_rows IS NOT NULL AND oms_quantity IS DISTINCT FROM bi_quantity
                  THEN 1 END) AS different_quantity_pairs,
       MIN(first_created_date) AS earliest_oms_eastern_date,
       MAX(last_created_date) AS latest_oms_eastern_date,
       MIN(order_id) AS example_order_id
FROM classified
GROUP BY GROUPING SETS ((), (category))
ORDER BY category;
