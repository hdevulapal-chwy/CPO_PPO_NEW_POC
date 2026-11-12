-- Read-only comparison of the original DISTINCT logic and the project SUM logic.
WITH target_items AS (
    SELECT DISTINCT 'UTC' AS date_basis, TIMECREATED, id, orders_id, partnumber
    FROM EDLDB.ORDER_MANAGEMENT_SERVICE.ORDERITEM
    WHERE DATE(TIMECREATED) BETWEEN '{{ START_DATE }}'::DATE AND '{{ END_DATE }}'::DATE
    UNION ALL
    SELECT DISTINCT 'EASTERN', TIMECREATED, id, orders_id, partnumber
    FROM EDLDB.ORDER_MANAGEMENT_SERVICE.ORDERITEM
    WHERE DATE(CONVERT_TIMEZONE('UTC', 'America/New_York', TIMECREATED::TIMESTAMP_NTZ))
          BETWEEN '{{ START_DATE }}'::DATE AND '{{ END_DATE }}'::DATE
),
shipment_items AS (
    SELECT t.date_basis, c.orderitem_id, c.manifest_id, SUM(c.quantity) AS quantity
    FROM EDLDB.ORDER_MANAGEMENT_SERVICE.ORDITEMCONF c
    JOIN target_items t ON t.id = c.orderitem_id
    GROUP BY 1, 2, 3
),
joined_rows AS (
    SELECT oi.date_basis, oi.TIMECREATED, oi.orders_id AS order_id,
           oi.id AS order_item_id, m.trackingid AS shipment_tracking_number,
           oi.partnumber, si.quantity
    FROM target_items oi
    JOIN shipment_items si ON si.date_basis = oi.date_basis AND si.orderitem_id = oi.id
    JOIN EDLDB.ORDER_MANAGEMENT_SERVICE.MANIFEST m ON m.id = si.manifest_id
    WHERE m.status <> 'V' AND m.trackingid IS NOT NULL
),
original_rows AS (SELECT DISTINCT * FROM joined_rows),
a AS (
    SELECT 'ORIGINAL_DISTINCT' AS logic, date_basis, order_id, shipment_tracking_number,
           SUM(quantity) AS quantity, COUNT(*) AS source_rows
    FROM original_rows GROUP BY 1, 2, 3, 4
    UNION ALL
    SELECT 'PROJECT_SUM', date_basis, order_id, shipment_tracking_number,
           SUM(quantity), COUNT(*)
    FROM joined_rows GROUP BY 1, 2, 3, 4
),
b AS (
    SELECT order_order_id AS order_id, shipment_tracking_number,
           SUM(order_line_quantity) AS quantity
    FROM edldb.chewybi.order_line_measures
    WHERE order_placed_date BETWEEN '{{ START_DATE }}'::DATE AND '{{ END_DATE }}'::DATE
    GROUP BY 1, 2
),
variants AS (SELECT DISTINCT logic, date_basis FROM a),
expanded_b AS (SELECT v.logic, v.date_basis, b.* FROM variants v CROSS JOIN b),
results AS (
    SELECT COALESCE(a.logic, b.logic) AS logic,
           COALESCE(a.date_basis, b.date_basis) AS date_basis,
           CASE WHEN a.source_rows IS NULL THEN 'ONLY_IN_CHEWYBI'
                WHEN b.order_id IS NULL THEN 'ONLY_IN_OMS'
                WHEN a.quantity IS DISTINCT FROM b.quantity THEN 'QUANTITY_MISMATCH'
                ELSE 'MATCH' END AS status
    FROM a FULL OUTER JOIN expanded_b b
      ON a.logic = b.logic AND a.date_basis = b.date_basis
     AND a.order_id = b.order_id
     AND a.shipment_tracking_number IS NOT DISTINCT FROM b.shipment_tracking_number
)
SELECT logic, date_basis, COUNT(*) AS total_keys,
       COUNT(CASE WHEN status = 'MATCH' THEN 1 END) AS matched_keys,
       COUNT(CASE WHEN status = 'QUANTITY_MISMATCH' THEN 1 END) AS inner_join_quantity_mismatches,
       COUNT(CASE WHEN status = 'ONLY_IN_OMS' THEN 1 END) AS only_in_oms,
       COUNT(CASE WHEN status = 'ONLY_IN_CHEWYBI' THEN 1 END) AS only_in_chewybi
FROM results GROUP BY 1, 2 ORDER BY 1, 2;
