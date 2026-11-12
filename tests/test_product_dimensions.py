"""Product enrichment must preserve shipment rows and quantities."""

import sqlite3
import unittest
from pathlib import Path

from modules.common.sql_runner import render_sql

ROOT = Path(__file__).resolve().parents[1]


class ProductDimensionsTest(unittest.TestCase):
    def test_latest_snapshot_excludes_pharmacy_and_preserves_other_shipments(self):
        sql = render_sql(ROOT / "sql/common/13_orders_product_dimensions.sql", {
            "START_DATE": "2026-08-01", "END_DATE": "2026-08-31",
            "OMS_ORDERS_SHIPPED_TABLE": "shipments",
            "OMS_ORDERS_SHIPPED_DIMENSIONS_TABLE": "enriched_shipments",
            "PRODUCTS_TABLE": "products", "CATEGORY_TABLE": "categories",
        })
        start = sql.index("CREATE OR REPLACE TEMPORARY TABLE OMS_ORDERS_SHIPPED_DIMENSIONS_BATCH")
        end = sql.index("CREATE TABLE IF NOT EXISTS enriched_shipments", start)
        enrichment = sql[start:end].replace("CREATE OR REPLACE TEMPORARY TABLE", "CREATE TEMPORARY TABLE")
        enrichment = enrichment.replace("::TIMESTAMP_NTZ", "")
        db = sqlite3.connect(":memory:")
        self.addCleanup(db.close)
        from datetime import datetime
        from zoneinfo import ZoneInfo
        db.create_function("TO_DATE", 2, lambda value, fmt: value)
        db.create_function("CONVERT_TIMEZONE", 3, lambda source, target, value:
                           datetime.fromisoformat(value).replace(tzinfo=ZoneInfo(source))
                           .astimezone(ZoneInfo(target)).replace(tzinfo=None).isoformat(" "))
        db.executescript("""
            CREATE TABLE shipments(order_id INT, partnumber TEXT, quantity INT, TIMECREATED TEXT);
            INSERT INTO shipments VALUES (1,'A',2,'2026-08-15'),(2,'A',3,'2026-08-15'),
                (3,'MISSING',4,'2026-08-15'),(4,'A',99,'2026-09-15'),(5,'PHARMA',100,'2026-08-15');
            CREATE TABLE categories(product_part_number TEXT, product_category_level1 TEXT);
            INSERT INTO categories VALUES ('PHARMA',' pharmacy ');
            CREATE TABLE products(product_part_number TEXT, snapshot_date TEXT,
                product_packaged_length INT, product_packaged_width INT,
                product_packaged_height INT, product_packaged_weight INT);
            INSERT INTO products VALUES ('A','2026-01-01',10,20,30,40),('A','2026-02-01',12,18,35,39);
        """)
        db.executescript(enrichment)
        rows = db.execute("SELECT order_id, partnumber, quantity, item_l, item_w, item_h, item_wt FROM OMS_ORDERS_SHIPPED_DIMENSIONS_BATCH ORDER BY order_id").fetchall()
        self.assertEqual(rows, [(1,'A',2,12,18,35,39),(2,'A',3,12,18,35,39),
                                (3,'MISSING',4,None,None,None,None)])
        self.assertEqual(sum(row[2] for row in rows), 9)
        self.assertEqual(db.execute("SELECT COUNT(*) FROM shipments").fetchone()[0], 5)


if __name__ == "__main__":
    unittest.main()
