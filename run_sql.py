"""Run one SQL file or every SQL file in a module, in filename order."""

import argparse
import logging
from datetime import date, datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

from dotenv import load_dotenv
import yaml

from modules.common.sql_runner import execute_sql, render_sql
from modules.common.report import write_report, write_dimensions_report

ROOT = Path(__file__).resolve().parent


def monthly_ranges(start: str, end: str) -> list[tuple[str, str]]:
    first, last = date.fromisoformat(start), date.fromisoformat(end)
    if first > last:
        raise ValueError("START_DATE must be on or before END_DATE")
    ranges = []
    while first <= last:
        next_month = (first.replace(day=28) + timedelta(days=4)).replace(day=1)
        batch_end = min(last, next_month - timedelta(days=1))
        ranges.append((first.isoformat(), batch_end.isoformat()))
        first = next_month
    return ranges


def load_parameters(path: Path) -> dict:
    parameters = yaml.safe_load(path.read_text(encoding="utf-8"))
    if not isinstance(parameters, dict):
        raise ValueError("Configuration must be a mapping of parameter names to values")
    # YAML also accepts unquoted dates, which safe_load converts to date objects.
    for key in ("START_DATE", "END_DATE"):
        if isinstance(parameters.get(key), date):
            parameters[key] = parameters[key].isoformat()
    return parameters


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    selection = parser.add_mutually_exclusive_group(required=True)
    selection.add_argument("--file", type=Path, help="SQL file to execute")
    selection.add_argument("--module", choices=["common", "ideal", "cost"])
    parser.add_argument("--config", "--params", dest="config", type=Path,
                        default=ROOT / "config.yaml", help="YAML configuration (default: config.yaml)")
    parser.add_argument("--dry-run", action="store_true", help="Print SQL without connecting")
    parser.add_argument("--monthly", action="store_true", help="Run and commit one calendar-month batch at a time")
    parser.add_argument("--start-date", help="Inclusive YYYY-MM-DD; overrides START_DATE in configuration")
    parser.add_argument("--end-date", help="Inclusive YYYY-MM-DD; overrides END_DATE in configuration")
    parser.add_argument("--compare", action="store_true", help="After each order-load batch, run the OMS/ChewyBI comparison")
    parser.add_argument("--report", type=Path, help="Markdown comparison report path (default: timestamped file in outputs/)")
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")
    load_dotenv(ROOT / ".env")
    report_path = None
    report_batches = []
    report_writer = write_report
    try:
        paths = ([args.file] if args.file else
                 sorted((ROOT / "sql" / args.module).glob("*.sql")))
        if not paths:
            raise ValueError(f"No SQL files found in module {args.module!r}")
        parameters = load_parameters(args.config)
        snowflake_settings = parameters.pop("snowflake", {})
        if not isinstance(snowflake_settings, dict):
            raise ValueError("The snowflake configuration must be a mapping")
        if args.start_date:
            parameters["START_DATE"] = args.start_date
        if args.end_date:
            parameters["END_DATE"] = args.end_date
        if args.compare:
            if not args.file or args.file.resolve() != (ROOT / "sql/common/12_orders_enriched.sql").resolve():
                raise ValueError("--compare requires --file sql/common/12_orders_enriched.sql")
        if args.monthly:
            if not parameters.get("START_DATE") or not parameters.get("END_DATE"):
                raise ValueError("Monthly batches require START_DATE and END_DATE")
            ranges = monthly_ranges(parameters["START_DATE"], parameters["END_DATE"])
        else:
            ranges = [(parameters.get("START_DATE"), parameters.get("END_DATE"))]
        # Validate every template before connecting or executing any statements.
        batches = []
        comparison_path = ROOT / "sql/Query_Testing/OMS_vs_CHEYWBI_ORDERS"
        is_comparison = args.file and args.file.resolve() == comparison_path.resolve()
        is_dimensions_audit = args.file and args.file.resolve() == (ROOT / "sql/Query_Testing/product_dimensions_cleanliness.sql").resolve()
        if is_dimensions_audit:
            report_writer = write_dimensions_report
        if args.report and not (is_comparison or args.compare or is_dimensions_audit):
            raise ValueError("--report requires a comparison or dimensions cleanliness query")
        if not args.dry_run and (is_comparison or args.compare or is_dimensions_audit):
            timestamp = datetime.now(ZoneInfo("America/Los_Angeles")).strftime("%Y%m%d_%H%M%S_%f")
            prefix = "product_dimensions_cleanliness" if is_dimensions_audit else "oms_comparison"
            report_path = args.report or ROOT / "outputs" / f"{prefix}_{timestamp}.md"
        for start, end in ranges:
            batch_parameters = {**parameters, "START_DATE": start, "END_DATE": end}
            scripts = [(path, render_sql(path, batch_parameters)) for path in paths]
            comparison = ([(comparison_path, render_sql(comparison_path, batch_parameters))]
                          if args.compare else [])
            batches.append((start, end, scripts, comparison))
        for start, end, scripts, comparison in batches:
            logging.info("Batch %s through %s", start, end)
            if args.dry_run:
                for path, sql in scripts + comparison:
                    print(f"-- Batch: {start} through {end}; File: {path}\n{sql}")
            else:
                results = execute_sql(scripts, snowflake_settings)
                # Load is committed before comparison, so a comparison failure
                # does not undo an otherwise successful monthly load.
                if comparison:
                    results = execute_sql(comparison, snowflake_settings)
                if report_path:
                    report_batches.append({"start": start, "end": end, "results": results})
                    report_writer(report_path, report_batches, "In progress", ranges[0][0], ranges[-1][1])
        if report_path:
            report_writer(report_path, report_batches, "Complete", ranges[0][0], ranges[-1][1])
            print(f"Markdown report: {report_path}")
    except Exception as error:
        if report_path:
            report_writer(report_path, report_batches, "Failed; only completed batches shown", ranges[0][0], ranges[-1][1])
            print(f"Partial Markdown report: {report_path}")
        parser.exit(1, f"Error: {error}\n")


if __name__ == "__main__":
    main()
