# CPO / PPO proof of concept

Snowflake SQL and Python modules for common order inputs, ideal scenarios, and costs.

```text
config.yaml               SQL parameters and date range
sql/
  common/                 Shared inputs and order enrichment
  ideal/                  Ideal scenario SQL
  cost/                   Cost calculation SQL
  Query_Testing/          OMS versus ChewyBI validation
modules/
  common/sql_runner.py    Shared template renderer and Snowflake executor
  ideal/                  Ideal scenario Python logic
  cost/                   Cost calculation Python logic
outputs/                  Local results and exports (ignored by Git)
run_sql.py                Command line entry point
orders_sql                Original SQL, retained as a reference
```

## Setup

Use Python 3.10 or later supported by the Snowflake connector.

```sh
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r requirements.txt
```

Edit the `snowflake` section in `config.yaml` with your account, user,
warehouse, database, schema, and role. The default `authenticator: externalbrowser`
opens your browser for SSO. The runner reads this section automatically.

Optional `SNOWFLAKE_*` environment variables or a local `.env` override the YAML
settings. For password authentication, use `authenticator: snowflake` and supply
`SNOWFLAKE_PASSWORD` through the environment or `.env`.

## Run SQL

Check the connection:

```sh
python run_sql.py --file sql/common/00_connection_check.sql
```

Preview the supplied order enrichment query:

```sh
python run_sql.py --file sql/common/12_orders_enriched.sql --config config.yaml --dry-run
```

Set `START_DATE` and `END_DATE` in `config.yaml` to dates in
`YYYY-MM-DD` format, without SQL quotes:

```yaml
START_DATE: "2026-09-01"
END_DATE: "2026-09-30"
OMS_ORDERS_SHIPPED_TABLE: EDLDB_DEV.SC_ORDER_ROUTING_TEAM_SANDBOX.OMS_ORDERS_SHIPPED_TEST
```

Both dates are included, filtering by the order item's `TIMECREATED` converted
from UTC to `America/New_York` (EST/EDT). Stored `TIMECREATED` values remain UTC;
the extraction, batch delete, and comparison all use the same Eastern date.
Use the same date for both values to select a single day. After reviewing the
preview, execute it by removing `--dry-run`. The upstream tables must exist.

The order query stages the selected range, creates `OMS_ORDERS_SHIPPED_TABLE`
if needed, then deletes and reloads only that range. Earlier months remain in
the table, and rerunning a range does not append duplicates. It preserves the
original DISTINCT item/tracking/quantity rows after summing confirmations per
item and manifest. It does not sum again across manifests. The Snowflake role
needs permission to create tables and update the target. Run one loader at a
time against a target table.

Run the separate `sql/common/13_orders_product_dimensions.sql` after loading
the base shipments. It writes `OMS_ORDERS_SHIPPED_DIMENSIONS_TABLE` (default:
`EDLDB_DEV.SC_ORDER_ROUTING_TEAM_SANDBOX.OMS_ORDERS_SHIPPED_DIMENSIONS`). It adds
`ITEM_L`, `ITEM_W`, `ITEM_H`, and `ITEM_WT` by joining saved shipments in the selected date range
to `PRODUCTS_TABLE` on `partnumber = product_part_number`. Dimensions come from the latest `snapshot_date` row in
`PRODUCTS_TABLE` (`EDLDB.CHEWYBI.PRODUCT_LIFECYCLE_SNAPSHOT`), using
`product_packaged_length/width/height/weight`. Pharmacy SKUs are excluded via
`CATEGORY_TABLE` (`EDLDB.CHEWYBI.PRODUCTS`), where the trimmed, uppercased
`product_category_level1` equals `PHARMACY`. All four values come from one row.
The latest snapshot is used regardless of shipment date; no historical as-of
lookup is performed. Equal snapshot-date ties need a business-defined tie-breaker. Unmatched products retain their shipment rows with NULL dimensions.
Values are copied in source units without conversion or multiplication by quantity.
The enrichment replaces only the selected Eastern date range in its own output
and leaves the base shipment table unchanged. It reads the persisted shipment
table because temporary tables do not survive between runner connections.

```sh
python run_sql.py --file sql/common/13_orders_product_dimensions.sql --monthly
```

### Monthly batches

Load September, October, and November one month at a time, comparing each batch:

```sh
python run_sql.py --file sql/common/12_orders_enriched.sql --config config.yaml --start-date 2026-09-01 --end-date 2026-11-30 --monthly --compare
```

Add `--dry-run` to preview all batches without connecting. Command line dates
override the dates in YAML. `config.yaml` is loaded by default;
`--config` selects another file. The existing `--params` flag remains an alias. Each month commits separately; execution stops on
failure and previous successful months remain loaded. To resume, set the start
date to the failed month. Partial first/last months respect the requested range.
Comparison runs after the load commits; a comparison failure leaves that load
in place and stops the run.

For each batch the comparison prints total order/tracking keys, matched keys,
keys missing from either source, quantity mismatch keys, each source's total
quantity, and OMS quantity minus ChewyBI quantity. It then prints up to 20
exception rows. These are shipped-unit totals, not distinct-order counts or
cost calculations.

Compare OMS and ChewyBI directly using the same parameter file (no load needed):

```sh
python run_sql.py --file sql/Query_Testing/OMS_vs_CHEYWBI_ORDERS --config config.yaml
```

The comparison uses one shared order cohort: the union of orders whose ChewyBI
`order_placed_date` or Eastern OMS `TIMECREATED` date falls in the requested
range. Both sources include all shipment lines for those order IDs, without
another date restriction. Orders selected by just one source are included too.
The comparison reads OMS sources directly, so July 31 or September 1 items are
not lost because of an incomplete date-filtered output table.

It preserves original DISTINCT quantities, aggregates to order + tracking
number, and reports missing keys and quantity differences with a full outer
join. Null tracking numbers and void OMS manifests are excluded. This changes
report scope from two independent date windows to one common set of orders.
`KEY_COVERAGE_PCT` measures how many order/tracking pairs exist in both sources;
`MATCH_RATE_PCT` additionally requires equal quantities. Genuine missing pairs
and quantity mismatches remain visible; 100% matching is not guaranteed.
Adjacent monthly cohorts can overlap when the two source dates cross a month
boundary. Do not add monthly counts to calculate a period total; run the full
range without `--monthly` for a deduplicated total. Earlier reports are historical results.

The loader in `12_orders_enriched.sql` still builds a separate OMS creation-date
dataset using Eastern boundaries; the new comparison does not depend on it.
The previous independent-date comparison is retained in
`sql/Query_Testing/OMS_vs_CHEWYBI_BY_SOURCE_DATES.sql` for diagnostics.

Add numbered `.sql` files to each module and run them in filename order:

```sh
python run_sql.py --module ideal --config config.yaml
python run_sql.py --module cost --config config.yaml
```

The ideal and cost folders start empty, ready for your business logic. Run the
common inputs before any dependent ideal or cost queries; module execution
does not automatically run other modules.

Templates use `{{ NAME }}` placeholders and fail on missing values before any
query executes. Parameters are **trusted SQL fragments**, not bound values:
include SQL quotes around string literals when the template does not already
supply them, e.g. `"'2026-10', '2026-11'"` for a month list. The order query
supplies quotes around `START_DATE` and `END_DATE`. Do not pass untrusted user
input into templates.

The runner supports multiple statements using Snowflake's `execute_stream`,
logs query IDs, and prints up to 20 result rows per statement. DML commits after
all selected scripts succeed and rolls back on failure. Snowflake DDL and
explicit transaction commands can commit independently, so do not assume a
mixed DDL/DML module is atomic. See the
[Snowflake connector documentation](https://docs.snowflake.com/en/developer-guide/python-connector/python-connector-api).

## Markdown comparison report

Comparison runs automatically save a timestamped `.md` report in `outputs/`.
To select a fixed report path, run:

```sh
python run_sql.py --file sql/Query_Testing/OMS_vs_CHEYWBI_ORDERS --monthly --report outputs/oms_comparison.md
```

This compares the shared order cohort directly from sources without reloading OMS. Reports contain each
batch's matched/unmatched counts, match percentage, quantity totals, query IDs,
and up to 20 exception records. Counts cover the complete query results.
Failed runs save completed batches and mark the report as partial. Dry runs
do not create a report. A fixed path is overwritten on the next run.

## Test OMS-only pairs for placement-date differences

```sh
python run_sql.py --file sql/Query_Testing/oms_only_date_mismatch.sql --start-date 2026-08-01 --end-date 2026-08-31
```

This read-only diagnostic identifies OMS-only order/tracking pairs in the
selected range, then searches ChewyBI for those same pairs on any placement
date. It separates previous-day, other earlier-date, later-date, null-date,
and still-missing pairs, and checks whether recovered quantities agree. Each
pair is counted once; placement dates are used as supplied by ChewyBI.

To test the reverse (ChewyBI-only pairs with OMS creation dates outside the range):

```sh
python run_sql.py --file sql/Query_Testing/chewybi_only_date_mismatch.sql --start-date 2026-08-01 --end-date 2026-08-31
```

This searches OMS source tables on all creation dates, preserving the producer's
DISTINCT quantity logic and valid-manifest filters. It can find July 31 pairs
even when July is absent from the loaded output table. Unrecovered pairs mean
not found under those shipment filters, rather than proof the order is absent
from OMS entirely.

## Product dimensions cleanliness

```sh
python run_sql.py --file sql/Query_Testing/product_dimensions_cleanliness.sql --report outputs/product_dimensions_cleanliness.md
```

This read-only audit previews step 13 using saved shipments and current product
records for the configured Eastern date range. It does not require the enriched
table to exist and does not verify a previously loaded enriched table. It excludes pharmacy and checks the latest lifecycle snapshot for
missing product joins, null/nonnumeric/zero/negative values, and row/quantity
preservation in the non-pharmacy join. Historical snapshots are not audited
for conflicts; the existing product-conflict metrics describe selected rows only. Positive values are usable, not proof of physical
accuracy. Strict clean also requires valid selected source values. The four values are
selected together from the latest snapshot, without independent maxima. No arbitrary
outlier limits or source units are assumed. Issue categories can overlap.

To validate the saved dimensions table after running step 13:

```sh
python run_sql.py --file sql/Query_Testing/product_dimensions_output_check.sql
```

This checks pharmacy rows remaining, missing/extra shipment keys, row and quantity
differences, agreement with the latest snapshot, and distinct SKU/order counts
with missing weight or dimensions.
