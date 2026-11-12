"""Render trusted SQL templates and run them sequentially in Snowflake."""

import io
import logging
import os
from pathlib import Path

from jinja2 import Environment, StrictUndefined

LOGGER = logging.getLogger(__name__)


def render_sql(path: Path, parameters: dict) -> str:
    environment = Environment(undefined=StrictUndefined, autoescape=False,
                              keep_trailing_newline=True)
    return environment.from_string(path.read_text(encoding="utf-8")).render(parameters)


def connection_options(settings: dict | None = None) -> dict:
    settings = settings or {}
    if not isinstance(settings, dict):
        raise ValueError("The snowflake configuration must be a mapping")
    options = {}
    for key in ("account", "user", "warehouse", "database", "schema", "role",
                "password", "authenticator"):
        value = os.getenv(f"SNOWFLAKE_{key.upper()}") or settings.get(key)
        if value:
            options[key] = value
    missing = [key for key in ("account", "user") if key not in options]
    if missing:
        raise ValueError("Missing Snowflake settings: " + ", ".join(
            f"snowflake.{key} in config.yaml (or SNOWFLAKE_{key.upper()})" for key in missing))
    options.setdefault("authenticator", "externalbrowser")
    options["autocommit"] = False
    return options


def execute_sql(scripts: list[tuple[Path, str]], settings: dict | None = None) -> list[dict]:
    # Import lazily: previews do not require the Snowflake connector or credentials.
    import snowflake.connector

    connection = snowflake.connector.connect(**connection_options(settings))
    results = []
    try:
        for path, sql in scripts:
            LOGGER.info("Running %s", path)
            for cursor in connection.execute_stream(io.StringIO(sql)):
                try:
                    LOGGER.info("Query ID: %s; row count: %s", cursor.sfqid, cursor.rowcount)
                    if cursor.description:
                        columns = [column[0] for column in cursor.description]
                        rows = cursor.fetchmany(21)
                        results.append({"columns": columns, "rows": rows[:20],
                                        "truncated": len(rows) > 20, "query_id": cursor.sfqid})
                        print(" | ".join(columns))
                        for row in rows[:20]:
                            print(" | ".join(str(value) for value in row))
                finally:
                    cursor.close()
        connection.commit()
        return results
    except Exception:
        connection.rollback()
        raise
    finally:
        connection.close()
