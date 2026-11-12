-- START_DATE and END_DATE use YYYY-MM-DD; both dates are included.
-- Date boundaries use America/New_York (EST/EDT); TIMECREATED stays in UTC.
-- Preserve the original DISTINCT item/tracking/quantity rows.
-- Do not sum across manifests here: that changes the original quantity logic.
-- Stage this batch before replacing only its date range in the permanent table.
CREATE OR REPLACE TEMPORARY TABLE OMS_ORDERS_SHIPPED_BATCH AS
WITH target_items AS (
    SELECT DISTINCT TIMECREATED, id, orders_id, partnumber
    FROM EDLDB.ORDER_MANAGEMENT_SERVICE.ORDERITEM
    WHERE DATE(CONVERT_TIMEZONE('UTC', 'America/New_York', TIMECREATED::TIMESTAMP_NTZ))
          BETWEEN TO_DATE('{{ START_DATE }}', 'YYYY-MM-DD')
                                AND TO_DATE('{{ END_DATE }}', 'YYYY-MM-DD')
),
shipment_items AS (
    SELECT c.orderitem_id, c.manifest_id , SUM(c.quantity) AS quantity
    FROM EDLDB.ORDER_MANAGEMENT_SERVICE.ORDITEMCONF c
    INNER JOIN target_items t ON t.id = c.orderitem_id
    GROUP BY c.orderitem_id, c.manifest_id
)
SELECT
    DISTINCT
    oi.TIMECREATED,
    oi.orders_id  AS order_id,
    oi.id         AS order_item_id,
    m.trackingid  AS shipment_tracking_number,
    oi.partnumber,
    si.quantity AS quantity
    FROM target_items oi
INNER JOIN shipment_items si ON si.orderitem_id = oi.id
INNER JOIN EDLDB.ORDER_MANAGEMENT_SERVICE.MANIFEST m ON m.id = si.manifest_id
WHERE m.status <> 'V'
  AND m.trackingid IS NOT NULL;

CREATE TABLE IF NOT EXISTS {{ OMS_ORDERS_SHIPPED_TABLE }} LIKE OMS_ORDERS_SHIPPED_BATCH;

-- These DML statements commit together through the Python runner.
DELETE FROM {{ OMS_ORDERS_SHIPPED_TABLE }}
WHERE DATE(CONVERT_TIMEZONE('UTC', 'America/New_York', TIMECREATED::TIMESTAMP_NTZ))
      BETWEEN TO_DATE('{{ START_DATE }}', 'YYYY-MM-DD')
                           AND TO_DATE('{{ END_DATE }}', 'YYYY-MM-DD');

INSERT INTO {{ OMS_ORDERS_SHIPPED_TABLE }}
    (TIMECREATED, ORDER_ID, ORDER_ITEM_ID, SHIPMENT_TRACKING_NUMBER, PARTNUMBER, QUANTITY)
SELECT TIMECREATED, ORDER_ID, ORDER_ITEM_ID, SHIPMENT_TRACKING_NUMBER, PARTNUMBER, QUANTITY
FROM OMS_ORDERS_SHIPPED_BATCH;

