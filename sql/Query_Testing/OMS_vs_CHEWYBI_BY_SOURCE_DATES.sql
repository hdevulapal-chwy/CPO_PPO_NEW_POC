-- Run sql/common/12_orders_enriched.sql first with the same parameters.
-- Compare shipped quantities at order + tracking number grain.
-- Both dates are inclusive. OMS item creation and ChewyBI order placement
-- are different source dates; boundary differences may require investigation.
-- OMS TIMECREATED is stored in UTC and filtered by its America/New_York date.
-- ChewyBI order_placed_date is used as supplied; no source timezone is assumed.
{% set comparison_query %}
WITH a AS (
    SELECT
        order_id,
        shipment_tracking_number,
        SUM(quantity) AS quantity,
        COUNT(*) AS source_rows
    FROM {{ OMS_ORDERS_SHIPPED_TABLE }}
    WHERE DATE(CONVERT_TIMEZONE('UTC', 'America/New_York', TIMECREATED::TIMESTAMP_NTZ))
          BETWEEN TO_DATE('{{ START_DATE }}', 'YYYY-MM-DD')
                               AND TO_DATE('{{ END_DATE }}', 'YYYY-MM-DD')
      AND shipment_tracking_number IS NOT NULL
    GROUP BY 1, 2
),
b AS (
    SELECT
        order_order_id AS order_id,
        shipment_tracking_number,
        SUM(order_line_quantity) AS quantity,
        COUNT(*) AS source_rows
    FROM edldb.chewybi.order_line_measures
    WHERE DATE(order_placed_date) BETWEEN TO_DATE('{{ START_DATE }}', 'YYYY-MM-DD')
                                    AND TO_DATE('{{ END_DATE }}', 'YYYY-MM-DD')
      AND shipment_tracking_number IS NOT NULL
    GROUP BY 1, 2
),
comparison AS (
    SELECT
        COALESCE(a.order_id, b.order_id) AS order_id,
        COALESCE(
            a.shipment_tracking_number,
            b.shipment_tracking_number
        ) AS shipment_tracking_number,
        a.quantity AS oms_quantity,
        b.quantity AS chewybi_quantity,
        COALESCE(a.quantity, 0) - COALESCE(b.quantity, 0) AS quantity_difference,
        a.source_rows AS oms_rows,
        b.source_rows AS chewybi_rows,
        CASE
            WHEN a.source_rows IS NULL THEN 'ONLY_IN_CHEWYBI'
            WHEN b.source_rows IS NULL THEN 'ONLY_IN_OMS'
            WHEN a.quantity IS DISTINCT FROM b.quantity
                THEN 'QUANTITY_MISMATCH'
            ELSE 'MATCH'
        END AS comparison_status
    FROM a
    FULL OUTER JOIN b
        ON a.order_id = b.order_id
        AND a.shipment_tracking_number
            IS NOT DISTINCT FROM b.shipment_tracking_number
)
SELECT * FROM comparison
{% endset %}

-- Summary includes matches and exceptions, at order + tracking number grain.
WITH results AS ({{ comparison_query }})
SELECT
    '{{ START_DATE }}' AS START_DATE,
    '{{ END_DATE }}' AS END_DATE,
    COUNT(*) AS TOTAL_KEYS,
    COUNT(CASE WHEN comparison_status = 'MATCH' THEN 1 END) AS MATCHED_KEYS,
    COUNT(CASE WHEN comparison_status <> 'MATCH' THEN 1 END) AS UNMATCHED_KEYS,
    ROUND(100.0 * COUNT(CASE WHEN comparison_status = 'MATCH' THEN 1 END)
          / NULLIF(COUNT(*), 0), 2) AS MATCH_RATE_PCT,
    COUNT(CASE WHEN comparison_status = 'ONLY_IN_OMS' THEN 1 END) AS ONLY_IN_OMS_KEYS,
    COUNT(CASE WHEN comparison_status = 'ONLY_IN_CHEWYBI' THEN 1 END) AS ONLY_IN_CHEWYBI_KEYS,
    COUNT(CASE WHEN comparison_status = 'QUANTITY_MISMATCH' THEN 1 END) AS QUANTITY_MISMATCH_KEYS,
    COALESCE(SUM(oms_quantity), 0) AS OMS_QUANTITY,
    COALESCE(SUM(chewybi_quantity), 0) AS CHEWYBI_QUANTITY,
    COALESCE(SUM(oms_quantity), 0) - COALESCE(SUM(chewybi_quantity), 0) AS QUANTITY_DIFFERENCE
FROM results;

WITH results AS ({{ comparison_query }})
SELECT * FROM results
WHERE comparison_status <> 'MATCH'
ORDER BY comparison_status, order_id, shipment_tracking_number;

