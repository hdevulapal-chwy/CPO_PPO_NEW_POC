-- Read-only: start with OMS-only pairs in the requested window, then search
-- ChewyBI for the same pairs WITHOUT an order_placed_date restriction.
WITH oms AS (
    SELECT order_id, shipment_tracking_number, SUM(quantity) AS oms_quantity
    FROM {{ OMS_ORDERS_SHIPPED_TABLE }}
    WHERE DATE(CONVERT_TIMEZONE('UTC', 'America/New_York', TIMECREATED::TIMESTAMP_NTZ))
          BETWEEN '{{ START_DATE }}'::DATE AND '{{ END_DATE }}'::DATE
      AND shipment_tracking_number IS NOT NULL
    GROUP BY 1, 2
),
missing AS (
    SELECT o.* FROM oms o
    WHERE NOT EXISTS (
        SELECT 1 FROM edldb.chewybi.order_line_measures b
        WHERE b.order_order_id = o.order_id
          AND b.shipment_tracking_number = o.shipment_tracking_number
          AND DATE(b.order_placed_date) BETWEEN '{{ START_DATE }}'::DATE AND '{{ END_DATE }}'::DATE
    )
),
bi_any_date AS (
    SELECT b.order_order_id AS order_id, b.shipment_tracking_number,
           COUNT(*) AS found_rows,
           MIN(DATE(b.order_placed_date)) AS first_placed_date,
           MAX(DATE(b.order_placed_date)) AS last_placed_date,
           COUNT(CASE WHEN DATE(b.order_placed_date) = DATEADD(day, -1, '{{ START_DATE }}'::DATE)
                      THEN 1 END) AS previous_day_rows,
           SUM(b.order_line_quantity) AS bi_quantity
    FROM edldb.chewybi.order_line_measures b
    WHERE EXISTS (SELECT 1 FROM missing m
                  WHERE m.order_id = b.order_order_id
                    AND m.shipment_tracking_number = b.shipment_tracking_number)
    GROUP BY 1, 2
),
classified AS (
    SELECT m.*, b.found_rows, b.first_placed_date, b.last_placed_date, b.bi_quantity,
           CASE WHEN b.found_rows IS NULL THEN 'NOT_FOUND_ON_ANY_DATE'
                WHEN b.first_placed_date IS NULL THEN 'FOUND_WITH_NULL_PLACEMENT_DATE'
                WHEN b.first_placed_date = DATEADD(day, -1, '{{ START_DATE }}'::DATE)
                 AND b.last_placed_date = DATEADD(day, -1, '{{ START_DATE }}'::DATE)
                    THEN 'FOUND_ONLY_ON_PREVIOUS_DAY'
                WHEN b.previous_day_rows > 0 THEN 'FOUND_ON_PREVIOUS_DAY_AND_OTHER_DATES'
                WHEN b.last_placed_date < '{{ START_DATE }}'::DATE THEN 'FOUND_ON_OTHER_EARLIER_DATES'
                WHEN b.first_placed_date > '{{ END_DATE }}'::DATE THEN 'FOUND_ON_LATER_DATES'
                ELSE 'FOUND_ON_MULTIPLE_OUTSIDE_DATES' END AS category
    FROM missing m LEFT JOIN bi_any_date b
      ON m.order_id = b.order_id AND m.shipment_tracking_number = b.shipment_tracking_number
)
SELECT COALESCE(category, 'ALL_OMS_ONLY') AS category,
       COUNT(*) AS pairs,
       COUNT(CASE WHEN found_rows IS NOT NULL THEN 1 END) AS found_in_chewybi_any_date,
       COUNT(CASE WHEN found_rows IS NOT NULL AND oms_quantity IS NOT DISTINCT FROM bi_quantity
                  THEN 1 END) AS equal_quantity_pairs,
       COUNT(CASE WHEN found_rows IS NOT NULL AND oms_quantity IS DISTINCT FROM bi_quantity
                  THEN 1 END) AS different_quantity_pairs,
       MIN(first_placed_date) AS earliest_chewybi_date,
       MAX(last_placed_date) AS latest_chewybi_date,
       MIN(order_id) AS example_order_id
FROM classified
GROUP BY GROUPING SETS ((), (category))
ORDER BY category;
