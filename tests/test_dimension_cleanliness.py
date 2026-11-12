"""Check completeness, conflicting source values, and synthetic MAX tuples."""

import sqlite3
import unittest
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

from modules.common.sql_runner import render_sql

ROOT = Path(__file__).resolve().parents[1]


class DimensionCleanlinessTest(unittest.TestCase):
    def test_detects_dirty_values_without_losing_shipments(self):
        db = sqlite3.connect(":memory:")
        self.addCleanup(db.close)
        db.row_factory = sqlite3.Row

        def try_number(value):
            try:
                return float(value)
            except (ValueError, TypeError):
                return None

        db.create_function("TRY_TO_DOUBLE", 1, try_number)
        db.create_function("CONVERT_TIMEZONE", 3, lambda src, dst, value:
                           datetime.fromisoformat(value).replace(tzinfo=ZoneInfo(src))
                           .astimezone(ZoneInfo(dst)).replace(tzinfo=None).isoformat(" "))
        db.executescript("""
            CREATE TABLE shipments(partnumber TEXT, quantity INT, TIMECREATED TEXT);
            INSERT INTO shipments VALUES ('A',2,'2026-08-15'),('A',3,'2026-08-15'),
                ('B',1,'2026-08-15'),('C',1,'2026-08-15'),('MISSING',1,'2026-08-15'),('PHARMA',99,'2026-08-15');
            CREATE TABLE categories(product_part_number TEXT, product_category_level1 TEXT);
            INSERT INTO categories VALUES ('PHARMA',' pharmacy ');
            CREATE TABLE products(product_part_number TEXT, snapshot_date TEXT,
                product_packaged_length, product_packaged_width,
                product_packaged_height, product_packaged_weight);
            INSERT INTO products VALUES ('A','2026-01-01',10,20,30,40),('A','2026-02-01',12,18,35,39),
                ('B','2026-01-01',1,2,3,4),('B','2026-02-01',1,2,3,4),('C','2026-02-01',0,-1,NULL,'bad');
        """)
        sql = render_sql(ROOT / "sql/Query_Testing/product_dimensions_cleanliness.sql", {
            "START_DATE": "2026-08-01", "END_DATE": "2026-08-31",
            "OMS_ORDERS_SHIPPED_TABLE": "shipments", "PRODUCTS_TABLE": "products", "CATEGORY_TABLE": "categories"})
        for cast in ("::TIMESTAMP_NTZ", "::VARCHAR", "::DATE"):
            sql = sql.replace(cast, "")
        sql = "\n".join(line for line in sql.splitlines() if not line.lstrip().startswith("--"))
        results = [[dict(r) for r in db.execute(s).fetchall()] for s in sql.split(";") if s.strip()]
        summary, preservation, fields, source, samples = results
        self.assertEqual(summary[0]["SHIPMENT_ROWS"], 5)
        self.assertEqual(summary[0]["USABLE_DIMENSION_ROWS"], 3)
        self.assertEqual(summary[0]["STRICT_CLEAN_ROWS"], 3)
        self.assertEqual(summary[0]["NO_PRODUCT_MATCH_ROWS"], 1)
        self.assertEqual(preservation[0]["ROW_DIFFERENCE"], 0)
        self.assertEqual(preservation[0]["QUANTITY_DIFFERENCE"], 0)
        self.assertEqual(source[0]["SKUS_WITH_CONFLICTING_VALUES"], 0)
        self.assertEqual(source[0]["SKUS_WITH_SYNTHETIC_MAX_TUPLE"], 0)
        self.assertEqual(source[0]["SKUS_WITH_INVALID_SOURCE_VALUES"], 1)
        self.assertEqual(next(r for r in fields if r["FIELD"] == "Weight")["NONNUMERIC_ROWS"], 1)
        self.assertEqual({r["partnumber"] for r in samples}, {"C", "MISSING"})


if __name__ == "__main__":
    unittest.main()
