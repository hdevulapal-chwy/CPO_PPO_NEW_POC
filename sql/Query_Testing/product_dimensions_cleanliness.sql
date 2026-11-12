-- Read-only audit of latest lifecycle snapshot enrichment in step 13, excluding pharmacy.
-- Uses saved shipments and current products, so the dimensions output table
-- does not need to exist. This is an enrichment preview, not a stored-table audit.
{% set audit_ctes %}
WITH pharmacy_skus AS (
    SELECT DISTINCT product_part_number AS partnumber
    FROM {{ CATEGORY_TABLE }}
    WHERE UPPER(TRIM(product_category_level1)) = 'PHARMACY'
      AND product_part_number IS NOT NULL
),
batch_orders AS (
    SELECT s.partnumber, COUNT(*) AS shipment_rows, SUM(s.quantity) AS shipment_quantity
    FROM {{ OMS_ORDERS_SHIPPED_TABLE }} s
    WHERE DATE(CONVERT_TIMEZONE('UTC', 'America/New_York', TIMECREATED::TIMESTAMP_NTZ))
          BETWEEN '{{ START_DATE }}'::DATE AND '{{ END_DATE }}'::DATE
      AND NOT EXISTS (SELECT 1 FROM pharmacy_skus p WHERE p.partnumber = s.partnumber)
    GROUP BY s.partnumber
),
ranked_snapshots AS (
    SELECT p.product_part_number AS partnumber,
           p.product_packaged_length AS item_l,
           p.product_packaged_width AS item_w,
           p.product_packaged_height AS item_h,
           p.product_packaged_weight AS item_wt,
           ROW_NUMBER() OVER (PARTITION BY p.product_part_number
                              ORDER BY p.snapshot_date DESC NULLS LAST) AS latest_row
    FROM {{ PRODUCTS_TABLE }} p
    WHERE EXISTS (SELECT 1 FROM batch_orders b WHERE b.partnumber = p.product_part_number)
),
product_source AS (
    SELECT partnumber, item_l, item_w, item_h, item_wt
    FROM ranked_snapshots WHERE latest_row = 1
),
dimensions AS (
    SELECT partnumber, COUNT(*) AS product_rows,
           MAX(item_l) AS item_l, MAX(item_w) AS item_w,
           MAX(item_h) AS item_h, MAX(item_wt) AS item_wt,
           COUNT(DISTINCT item_l) AS length_versions,
           COUNT(DISTINCT item_w) AS width_versions,
           COUNT(DISTINCT item_h) AS height_versions,
           COUNT(DISTINCT item_wt) AS weight_versions,
           SUM(CASE WHEN
               TRY_TO_DOUBLE(item_l::VARCHAR) IS NULL OR TRY_TO_DOUBLE(item_l::VARCHAR) <= 0 OR
               TRY_TO_DOUBLE(item_w::VARCHAR) IS NULL OR TRY_TO_DOUBLE(item_w::VARCHAR) <= 0 OR
               TRY_TO_DOUBLE(item_h::VARCHAR) IS NULL OR TRY_TO_DOUBLE(item_h::VARCHAR) <= 0 OR
               TRY_TO_DOUBLE(item_wt::VARCHAR) IS NULL OR TRY_TO_DOUBLE(item_wt::VARCHAR) <= 0
               THEN 1 ELSE 0 END) AS invalid_source_rows
    FROM product_source GROUP BY partnumber
),
tuple_matches AS (
    -- Independent MAX values can produce a combination that never existed.
    SELECT d.partnumber, COUNT(p.partnumber) AS matching_tuple_rows
    FROM dimensions d LEFT JOIN product_source p
      ON p.partnumber = d.partnumber
     AND p.item_l IS NOT DISTINCT FROM d.item_l
     AND p.item_w IS NOT DISTINCT FROM d.item_w
     AND p.item_h IS NOT DISTINCT FROM d.item_h
     AND p.item_wt IS NOT DISTINCT FROM d.item_wt
    GROUP BY d.partnumber
),
audit AS (
    SELECT b.*, d.product_rows, d.item_l, d.item_w, d.item_h, d.item_wt,
           d.invalid_source_rows,
           COALESCE(t.matching_tuple_rows, 0) AS matching_tuple_rows,
           CASE WHEN d.length_versions > 1 OR d.width_versions > 1 OR
                     d.height_versions > 1 OR d.weight_versions > 1 THEN 1 ELSE 0 END AS conflicting_values,
           CASE WHEN TRY_TO_DOUBLE(d.item_l::VARCHAR) > 0 AND TRY_TO_DOUBLE(d.item_w::VARCHAR) > 0
                 AND TRY_TO_DOUBLE(d.item_h::VARCHAR) > 0 AND TRY_TO_DOUBLE(d.item_wt::VARCHAR) > 0
                THEN 1 ELSE 0 END AS usable_dimensions
    FROM batch_orders b LEFT JOIN dimensions d ON b.partnumber = d.partnumber
    LEFT JOIN tuple_matches t ON b.partnumber = t.partnumber
)
{% endset %}

{{ audit_ctes }}
SELECT 'Summary' AS REPORT_SECTION,
       COALESCE(SUM(shipment_rows), 0) AS SHIPMENT_ROWS,
       COUNT(partnumber) AS DISTINCT_SKUS,
       COALESCE(SUM(CASE WHEN product_rows IS NULL THEN shipment_rows ELSE 0 END), 0) AS NO_PRODUCT_MATCH_ROWS,
       COALESCE(SUM(CASE WHEN usable_dimensions = 1 THEN shipment_rows ELSE 0 END), 0) AS USABLE_DIMENSION_ROWS,
       COALESCE(SUM(CASE WHEN usable_dimensions = 1 AND conflicting_values = 0
                         AND invalid_source_rows = 0 AND matching_tuple_rows > 0
                        THEN shipment_rows ELSE 0 END), 0) AS STRICT_CLEAN_ROWS,
       ROUND(100.0 * SUM(CASE WHEN usable_dimensions = 1 THEN shipment_rows ELSE 0 END)
             / NULLIF(SUM(shipment_rows), 0), 2) AS USABLE_PCT,
       ROUND(100.0 * SUM(CASE WHEN usable_dimensions = 1 AND conflicting_values = 0
                              AND invalid_source_rows = 0 AND matching_tuple_rows > 0
                             THEN shipment_rows ELSE 0 END)
             / NULLIF(SUM(shipment_rows), 0), 2) AS STRICT_CLEAN_PCT
FROM audit;

{{ audit_ctes }},
base_totals AS (
    SELECT COUNT(*) AS source_rows, COALESCE(SUM(quantity), 0) AS source_quantity
    FROM {{ OMS_ORDERS_SHIPPED_TABLE }} s
    WHERE DATE(CONVERT_TIMEZONE('UTC', 'America/New_York', TIMECREATED::TIMESTAMP_NTZ))
          BETWEEN '{{ START_DATE }}'::DATE AND '{{ END_DATE }}'::DATE
      AND NOT EXISTS (SELECT 1 FROM pharmacy_skus p WHERE p.partnumber = s.partnumber)
)
SELECT 'Join preservation (preview)' AS REPORT_SECTION,
       b.source_rows AS INPUT_ROWS,
       COALESCE(SUM(a.shipment_rows), 0) AS ENRICHED_ROWS,
       COALESCE(SUM(a.shipment_rows), 0) - b.source_rows AS ROW_DIFFERENCE,
       b.source_quantity AS INPUT_QUANTITY,
       COALESCE(SUM(a.shipment_quantity), 0) AS ENRICHED_QUANTITY,
       COALESCE(SUM(a.shipment_quantity), 0) - b.source_quantity AS QUANTITY_DIFFERENCE
FROM base_totals b LEFT JOIN audit a ON TRUE
GROUP BY b.source_rows, b.source_quantity;

{{ audit_ctes }}
{% for field, label in [('item_l', 'Length'), ('item_w', 'Width'), ('item_h', 'Height'), ('item_wt', 'Weight')] %}
SELECT 'Field cleanliness' AS REPORT_SECTION, '{{ label }}' AS FIELD,
       COALESCE(SUM(CASE WHEN {{ field }} IS NULL THEN shipment_rows ELSE 0 END), 0) AS NULL_ROWS,
       COALESCE(SUM(CASE WHEN {{ field }} IS NOT NULL AND TRY_TO_DOUBLE({{ field }}::VARCHAR) IS NULL
                        THEN shipment_rows ELSE 0 END), 0) AS NONNUMERIC_ROWS,
       COALESCE(SUM(CASE WHEN TRY_TO_DOUBLE({{ field }}::VARCHAR) = 0 THEN shipment_rows ELSE 0 END), 0) AS ZERO_ROWS,
       COALESCE(SUM(CASE WHEN TRY_TO_DOUBLE({{ field }}::VARCHAR) < 0 THEN shipment_rows ELSE 0 END), 0) AS NEGATIVE_ROWS,
       COALESCE(SUM(CASE WHEN TRY_TO_DOUBLE({{ field }}::VARCHAR) > 0 THEN shipment_rows ELSE 0 END), 0) AS POSITIVE_ROWS
FROM audit
{% if not loop.last %}UNION ALL{% endif %}
{% endfor %};

{{ audit_ctes }}
SELECT 'Product source checks' AS REPORT_SECTION,
       COUNT(CASE WHEN product_rows > 1 THEN 1 END) AS SKUS_WITH_MULTIPLE_PRODUCT_ROWS,
       COUNT(CASE WHEN conflicting_values = 1 THEN 1 END) AS SKUS_WITH_CONFLICTING_VALUES,
       COUNT(CASE WHEN product_rows IS NOT NULL AND matching_tuple_rows = 0 THEN 1 END) AS SKUS_WITH_SYNTHETIC_MAX_TUPLE,
       COUNT(CASE WHEN invalid_source_rows > 0 THEN 1 END) AS SKUS_WITH_INVALID_SOURCE_VALUES,
       COALESCE(SUM(CASE WHEN conflicting_values = 1 THEN shipment_rows ELSE 0 END), 0) AS CONFLICT_AFFECTED_ROWS,
       COALESCE(SUM(CASE WHEN product_rows IS NOT NULL AND matching_tuple_rows = 0 THEN shipment_rows ELSE 0 END), 0) AS SYNTHETIC_TUPLE_AFFECTED_ROWS
FROM audit;

{{ audit_ctes }}
SELECT 'Example SKUs needing review' AS REPORT_SECTION,
       partnumber, shipment_rows, product_rows, item_l, item_w, item_h, item_wt,
       invalid_source_rows, conflicting_values, matching_tuple_rows
FROM audit
WHERE usable_dimensions = 0 OR conflicting_values = 1 OR invalid_source_rows > 0
   OR matching_tuple_rows = 0
ORDER BY shipment_rows DESC, partnumber
LIMIT 20;
