"""Regression checks for matching shipments across month boundaries."""

import sqlite3
import unittest
from pathlib import Path

from modules.common.sql_runner import render_sql

ROOT = Path(__file__).resolve().parents[1]


class OrderCohortTest(unittest.TestCase):
    def test_shared_cohort_recovers_dates_and_preserves_real_exceptions(self):
        db = sqlite3.connect(":memory:")
        self.addCleanup(db.close)
        db.row_factory = sqlite3.Row
        db.executescript("""
            CREATE TABLE bi(order_order_id INT, shipment_tracking_number TEXT,
                            order_line_quantity INT, order_placed_date TEXT);
            CREATE TABLE items(TIMECREATED TEXT, id INT, orders_id INT, partnumber TEXT);
            CREATE TABLE confirmations(orderitem_id INT, manifest_id INT, quantity INT);
            CREATE TABLE manifests(id INT, trackingid TEXT, status TEXT);
            INSERT INTO bi VALUES
              (1,'T1',2,'2026-08-01'), (2,'T2',3,'2026-08-31'),
              (3,'T3',1,'2026-08-15'), (4,'T4',1,'2026-08-15'),
              (5,'T5',2,'2026-08-10'),
              (6,'T6',1,'2026-07-31'), (6,'T6',1,'2026-08-01');
            INSERT INTO items VALUES
              ('2026-07-31',1,1,'A'), ('2026-09-01',2,2,'B'),
              ('2026-08-15',4,4,'D'), ('2026-08-10',5,5,'E'),
              ('2026-08-01',6,6,'F'), ('2026-08-15',7,7,'G');
            INSERT INTO confirmations VALUES
              (1,1,2),(1,11,2),(2,2,3),(4,4,2),(5,5,2),(5,55,1),(6,6,2),(7,7,1);
            INSERT INTO manifests VALUES
              (1,'T1','S'),(11,'T1','S'),(2,'T2','S'),(4,'T4','S'),
              (5,'T5','S'),(55,'EXTRA','S'),(6,'T6','S'),(7,'T7','S');
        """)

        def compare(start, end):
            sql = render_sql(ROOT / "sql/Query_Testing/OMS_vs_CHEYWBI_ORDERS",
                             {"START_DATE": start, "END_DATE": end})
            # Run relational logic in SQLite; live Snowflake validates its dialect.
            sql = sql.replace("::DATE", "").replace("::TIMESTAMP_NTZ", "")
            for source, local in (
                ("edldb.chewybi.order_line_measures", "bi"),
                ("EDLDB.ORDER_MANAGEMENT_SERVICE.ORDERITEM", "items"),
                ("EDLDB.ORDER_MANAGEMENT_SERVICE.ORDITEMCONF", "confirmations"),
                ("EDLDB.ORDER_MANAGEMENT_SERVICE.MANIFEST", "manifests"),
            ):
                sql = sql.replace(source, local)
            sql = "\n".join(line for line in sql.splitlines() if not line.lstrip().startswith("--"))
            statements = [s for s in sql.split(";") if s.strip()]
            summary = dict(db.execute(statements[0]).fetchone())
            exceptions = [dict(row) for row in db.execute(statements[1]).fetchall()]
            return summary, exceptions

        from datetime import datetime
        from zoneinfo import ZoneInfo

        db.create_function("CONVERT_TIMEZONE", 3, lambda source, target, value:
                           datetime.fromisoformat(value).replace(tzinfo=ZoneInfo(source))
                           .astimezone(ZoneInfo(target)).replace(tzinfo=None).isoformat(" "))
        august, exceptions = compare("2026-08-01", "2026-08-31")
        self.assertEqual(august["TOTAL_KEYS"], 8)
        self.assertEqual(august["MATCHED_KEYS"], 4)
        self.assertEqual(august["KEYS_IN_BOTH_SOURCES"], 5)
        self.assertEqual(august["KEY_COVERAGE_PCT"], 62.5)
        self.assertEqual(august["ONLY_IN_OMS_KEYS"], 2)
        self.assertEqual(august["ONLY_IN_CHEWYBI_KEYS"], 1)
        self.assertEqual(august["QUANTITY_MISMATCH_KEYS"], 1)
        self.assertEqual({row["order_id"] for row in exceptions}, {3, 4, 5, 7})
        july, _ = compare("2026-07-01", "2026-07-31")
        self.assertEqual(july["TOTAL_KEYS"], 2)
        self.assertEqual(july["MATCHED_KEYS"], 2)


if __name__ == "__main__":
    unittest.main()
