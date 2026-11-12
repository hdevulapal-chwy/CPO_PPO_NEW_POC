"""Save comparison results as Markdown without fetching all exception rows."""

from pathlib import Path


def write_dimensions_report(path: Path, batches: list[dict], status: str, start, end) -> None:
    lines = ["# Product dimensions cleanliness", "",
             f"Requested range: {start} through {end} (inclusive, OMS Eastern creation dates).", "",
             f"Run status: **{status}**. Completed batches: {len(batches)}.", "",
             "This read-only report previews step 13 using saved non-pharmacy shipments and the "
             "latest lifecycle snapshot per SKU. Pharmacy is excluded using CATEGORY_TABLE. "
             "It does not certify the contents of a previously materialized dimensions table.", "",
             "Usable means all four selected snapshot values are numeric and greater than zero. "
             "Strict clean additionally requires no conflicting non-null values per SKU, "
             "no null/nonpositive/nonnumeric values in any matched source product row, "
             "and a selected source product row containing the complete dimension tuple.", "",
             "All four values come from one latest snapshot row, regardless of shipment date. "
             "The product conflict checks describe selected rows, not historical snapshot differences. "
             "Snapshot-date ties require a business-defined tie-breaker. "
             "No physical plausibility limits or unit conversions are assumed. "
             "Issue categories can overlap; do not add them together.", ""]
    for batch in batches:
        lines.extend([f"## {batch['start']} through {batch['end']}", ""])
        for result in batch["results"]:
            columns, rows = result["columns"], result["rows"]
            section_index = columns.index("REPORT_SECTION")
            section = rows[0][section_index] if rows else "Example SKUs needing review"
            indices = [i for i in range(len(columns)) if i != section_index]
            lines.extend([f"### {section}", "", f"Query ID: `{result['query_id']}`", ""])
            if not rows:
                lines.extend(["No records returned.", ""])
                continue
            if len(rows) == 1 and section != "Example SKUs needing review":
                lines.extend(["| Metric | Value |", "| --- | ---: |"])
                lines.extend(f"| {cell(columns[i])} | {cell(rows[0][i])} |" for i in indices)
            else:
                lines.extend(["| " + " | ".join(cell(columns[i]) for i in indices) + " |",
                              "| " + " | ".join("---" for _ in indices) + " |"])
                lines.extend("| " + " | ".join(cell(row[i]) for i in indices) + " |" for row in rows)
            lines.append("")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines), encoding="utf-8")


def cell(value) -> str:
    return ("N/A" if value is None else str(value)).replace("|", "\\|").replace("\n", "<br>").replace("\r", "")


def write_report(path: Path, batches: list[dict], status: str, start, end) -> None:
    lines = ["# OMS versus ChewyBI comparison", "",
             f"Requested range: {start} through {end} (inclusive).", "",
             f"Run status: **{status}**. Completed batches: {len(batches)}.", "",
             "Each comparison row is one order ID + shipment tracking number pair. "
             "A match requires the pair in both sources with equal summed quantity.", "",
             "Unmatched = only in OMS + only in ChewyBI + quantity mismatch. "
             "Match percentage = matched / total pairs × 100; N/A means no pairs.", "",
             "Shared cohort: orders selected by either ChewyBI order_placed_date or the Eastern "
             "date of UTC OMS TIMECREATED in the requested range. All shipment lines for those "
             "order IDs are compared across both sources, without a second date restriction. OMS data is read "
             "directly from source tables, preserving the original DISTINCT quantity logic.", "",
             "Coverage includes orders selected from either source, including source-only orders. "
             "KEY_COVERAGE_PCT measures pairs present in both sources regardless of quantity; "
             "MATCH_RATE_PCT additionally requires equal quantities. Neither is guaranteed to be 100%. "
             "Adjacent monthly cohorts may overlap, so monthly counts must not be summed. "
             "Null tracking numbers and void OMS manifests are excluded. "
             "A timezone conversion changes a timestamp's timezone; it does not make item "
             "creation and order placement the same event.", ""]
    for batch in batches:
        lines.extend([f"## {batch['start']} through {batch['end']}", ""])
        for result in batch["results"]:
            summary = "TOTAL_KEYS" in result["columns"]
            lines.extend(["### Counts and quantities" if summary else "### Unmatched records (sample)", "",
                          f"Query ID: `{result['query_id']}`", ""])
            if not result["rows"]:
                lines.extend(["No records returned.", ""])
                continue
            lines.append("| " + " | ".join(cell(c) for c in result["columns"]) + " |")
            lines.append("| " + " | ".join("---" for _ in result["columns"]) + " |")
            lines.extend("| " + " | ".join(cell(v) for v in row) + " |" for row in result["rows"])
            lines.append("")
            if result["truncated"]:
                lines.extend(["Showing the first 20 records; summary counts cover all records.", ""])
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines), encoding="utf-8")
