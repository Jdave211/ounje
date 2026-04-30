#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import re
import unicodedata
from datetime import datetime, timezone
from pathlib import Path
from collections import defaultdict
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

try:
    import psycopg
    from psycopg.types.json import Jsonb
except Exception:  # pragma: no cover - fallback path does not need psycopg
    psycopg = None
    Jsonb = None


ROOT = Path("/Users/davejaga/Desktop/startups/ounje")
TRACE_DIR = ROOT / "server/logs/instacart-runs"
TABLE = "public.instacart_run_logs"
DEFAULT_USER_ID = "debug-user"


def normalize_text(value: object) -> str:
    text = unicodedata.normalize("NFKD", str(value or "")).lower()
    text = re.sub(r"[^\w\s]+", " ", text, flags=re.UNICODE)
    text = re.sub(r"\s+", " ", text).strip()
    return text


def safe_date(value: object) -> datetime | None:
    if value is None:
        return None
    text = str(value).strip()
    if not text:
        return None
    try:
        if text.endswith("Z"):
            text = text[:-1] + "+00:00"
        dt = datetime.fromisoformat(text)
        return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)
    except ValueError:
        return None


def status_kind(trace: dict) -> str:
    if trace.get("success"):
        return "completed"
    if trace.get("partialSuccess"):
        return "partial"
    return "failed"


def summarize_items(items: list[dict]) -> dict:
    resolved_count = 0
    unresolved_count = 0
    shortfall_count = 0
    attempt_count = 0
    first_issue = None

    for item in items:
        final_status = item.get("finalStatus") or {}
        status = normalize_text(final_status.get("status") or final_status.get("decision") or "")
        quantity_added = float(final_status.get("quantityAdded") or 0)
        shortfall = float(final_status.get("shortfall") or 0)
        attempts = item.get("attempts") or []
        attempt_count += len(attempts)

        is_resolved = status in {"exact", "substituted", "saved", "done", "completed"} or quantity_added > 0
        is_unresolved = status in {"unresolved", "failed", "error", "cancelled", "missing"} or quantity_added <= 0

        if is_resolved:
            resolved_count += 1
        if is_unresolved:
            unresolved_count += 1
        if shortfall > 0:
            shortfall_count += int(shortfall)

        if first_issue is None and (is_unresolved or shortfall > 0):
            requested = str(item.get("requested") or item.get("canonicalName") or "item").strip()
            final_status_label = str(final_status.get("status") or "").strip()
            reason = str((attempts[0].get("reason") if attempts else "") or "").strip()
            first_issue = " • ".join([part for part in [requested, final_status_label or None, reason or None] if part])

    return {
        "resolvedCount": resolved_count,
        "unresolvedCount": unresolved_count,
        "shortfallCount": shortfall_count,
        "attemptCount": attempt_count,
        "firstIssue": first_issue,
    }


def collect_matches(raw_text: str, query: str, limit: int = 5) -> list[str]:
    normalized_query = normalize_text(query)
    if not normalized_query:
        return []

    lines = raw_text.splitlines()
    query_tokens = [token for token in normalized_query.split(" ") if token]
    matches: list[str] = []
    seen: set[str] = set()

    for index, line in enumerate(lines):
        normalized_line = normalize_text(line)
        if not normalized_line:
            continue

        exact_hit = normalized_line.find(normalized_query) >= 0
        token_hit = bool(query_tokens) and all(token in normalized_line for token in query_tokens)
        if not exact_hit and not token_hit:
            continue

        start = max(0, index - 1)
        end = min(len(lines), index + 2)
        snippet = "  ".join(entry.strip() for entry in lines[start:end] if entry.strip())
        if not snippet or snippet in seen:
            continue

        seen.add(snippet)
        matches.append(snippet)
        if len(matches) >= limit:
            break

    return matches


def build_search_text(trace: dict, raw_text: str) -> str:
    segments: list[object] = [
        trace.get("runId"),
        trace.get("userId"),
        trace.get("selectedStore"),
        trace.get("preferredStore"),
        trace.get("strictStore"),
        trace.get("sessionSource"),
        trace.get("cartUrl"),
        trace.get("error"),
        trace.get("topIssue"),
        trace.get("cartReset", {}).get("error"),
        trace.get("finalizer", {}).get("status"),
        trace.get("finalizer", {}).get("summary"),
        trace.get("finalizer", {}).get("topIssue"),
        trace.get("finalizer", {}).get("nextAction"),
        raw_text,
    ]

    for item in trace.get("items") or []:
        final_status = item.get("finalStatus") or {}
        segments.extend([
            item.get("requested"),
            item.get("canonicalName"),
            item.get("normalizedQuery"),
            final_status.get("status"),
            final_status.get("decision"),
            final_status.get("reason"),
        ])
        for attempt in item.get("attempts") or []:
            segments.extend([
                attempt.get("store"),
                attempt.get("query"),
                attempt.get("matchedLabel"),
                attempt.get("decision"),
                attempt.get("matchType"),
                attempt.get("reason"),
            ])

    for key in ("missingItems", "mismatchedItems", "extraItems", "duplicateItems", "unresolvedItems"):
        for item in trace.get("finalizer", {}).get(key) or []:
            segments.extend([
                item.get("name"),
                item.get("issue"),
                item.get("reason"),
                item.get("severity"),
                item.get("expected"),
                item.get("observed"),
            ])

    segments.extend([
        trace.get("cartReset", {}).get("beforeCount"),
        trace.get("cartReset", {}).get("afterCount"),
        "cart_reset_cleared" if trace.get("cartReset", {}).get("cleared") else "cart_reset_pending",
    ])

    return "\n".join(str(value).strip() for value in segments if str(value or "").strip())


def summarize_trace(trace: dict, raw_text: str) -> dict:
    items = trace.get("items") or []
    item_summary = summarize_items(items)
    started_at = safe_date(trace.get("startedAt"))
    completed_at = safe_date(trace.get("completedAt"))
    duration_seconds = None
    if started_at and completed_at:
        duration_seconds = max(0, round((completed_at - started_at).total_seconds()))

    total_items = len(items)
    progress = round(item_summary["resolvedCount"] / total_items, 3) if total_items else 0
    selected_store = (trace.get("selectedStore") or trace.get("preferredStore") or "").strip() or None
    finalizer = trace.get("finalizer") or {}
    finalizer_issue_count = sum(
        len(finalizer.get(key) or [])
        for key in ("missingItems", "mismatchedItems", "extraItems", "duplicateItems", "unresolvedItems")
    )

    matches = collect_matches(raw_text, "")

    return {
        "runId": str(trace.get("runId") or "").strip(),
        "userId": str(trace.get("userId") or "").strip() or None,
        "startedAt": trace.get("startedAt") or None,
        "completedAt": trace.get("completedAt") or None,
        "selectedStore": selected_store,
        "preferredStore": str(trace.get("preferredStore") or "").strip() or None,
        "strictStore": str(trace.get("strictStore") or "").strip() or None,
        "sessionSource": str(trace.get("sessionSource") or "").strip() or None,
        "success": bool(trace.get("success")),
        "partialSuccess": bool(trace.get("partialSuccess")),
        "statusKind": status_kind(trace),
        "itemCount": total_items,
        "resolvedCount": item_summary["resolvedCount"],
        "unresolvedCount": item_summary["unresolvedCount"],
        "shortfallCount": item_summary["shortfallCount"],
        "attemptCount": item_summary["attemptCount"],
        "durationSeconds": duration_seconds,
        "progress": progress,
        "topIssue": item_summary["firstIssue"],
        "finalizerStatus": str(finalizer.get("status") or "").strip() or None,
        "finalizerSummary": str(finalizer.get("summary") or "").strip() or None,
        "finalizerTopIssue": str(finalizer.get("topIssue") or "").strip() or None,
        "finalizerIssueCount": finalizer_issue_count,
        "cartResetCleared": bool(trace.get("cartReset", {}).get("cleared")),
        "cartResetBeforeCount": trace.get("cartReset", {}).get("beforeCount"),
        "cartResetAfterCount": trace.get("cartReset", {}).get("afterCount"),
        "cartResetError": str(trace.get("cartReset", {}).get("error") or "").strip() or None,
        "searchPreview": matches[0] if matches else item_summary["firstIssue"],
        "matches": matches,
        "cartUrl": str(trace.get("cartUrl") or "").strip() or None,
    }


def build_record(trace: dict, *, fallback_user_id: str) -> dict:
    raw_text = json.dumps(trace, ensure_ascii=False, sort_keys=True)
    summary = summarize_trace(trace, raw_text)
    user_id = summary["userId"] or fallback_user_id
    summary["userId"] = user_id

    return {
        "run_id": summary["runId"],
        "user_id": user_id,
        "status_kind": summary["statusKind"],
        "success": summary["success"],
        "partial_success": summary["partialSuccess"],
        "started_at": summary["startedAt"],
        "completed_at": summary["completedAt"],
        "selected_store": summary["selectedStore"],
        "preferred_store": summary["preferredStore"],
        "strict_store": summary["strictStore"],
        "session_source": summary["sessionSource"],
        "item_count": summary["itemCount"],
        "resolved_count": summary["resolvedCount"],
        "unresolved_count": summary["unresolvedCount"],
        "shortfall_count": summary["shortfallCount"],
        "attempt_count": summary["attemptCount"],
        "duration_seconds": summary["durationSeconds"],
        "progress": summary["progress"],
        "top_issue": summary["topIssue"],
        "search_preview": summary["searchPreview"],
        "matches": summary["matches"],
        "cart_url": summary["cartUrl"],
        "summary_json": {**summary, "matches": []},
        "trace_json": trace,
        "search_text": build_search_text(trace, raw_text),
    }


def prepare_row_for_database(row: dict) -> dict:
    if Jsonb is None:
        return row

    prepared = dict(row)
    prepared["matches"] = Jsonb(prepared["matches"])
    prepared["summary_json"] = Jsonb(prepared["summary_json"])
    prepared["trace_json"] = Jsonb(prepared["trace_json"])
    return prepared


def persist_rows_via_rest(rows: list[dict]) -> dict:
    supabase_url = os.getenv("SUPABASE_URL", "").strip().rstrip("/")
    supabase_anon_key = os.getenv("SUPABASE_ANON_KEY", "").strip()
    if not supabase_url or not supabase_anon_key:
        raise RuntimeError("SUPABASE_URL and SUPABASE_ANON_KEY are required for REST cleanup mode")

    endpoint = f"{supabase_url}/rest/v1/instacart_run_logs?on_conflict=run_id"
    rows_by_user: dict[str, list[dict]] = defaultdict(list)
    for row in rows:
        rows_by_user[str(row.get("user_id") or DEFAULT_USER_ID).strip() or DEFAULT_USER_ID].append(row)

    for user_id, user_rows in rows_by_user.items():
        request = Request(
            endpoint,
            data=json.dumps(user_rows).encode("utf-8"),
            headers={
                "Content-Type": "application/json",
                "apikey": supabase_anon_key,
                "Authorization": f"Bearer {supabase_anon_key}",
                "Prefer": "resolution=merge-duplicates,return=minimal",
                "x-user-id": user_id,
            },
            method="POST",
        )
        try:
            with urlopen(request, timeout=120) as response:
                if response.status < 200 or response.status >= 300:
                    raise RuntimeError(f"Unexpected Supabase REST status {response.status}")
        except HTTPError as exc:
            body = exc.read().decode("utf-8", errors="replace")
            raise RuntimeError(f"Supabase REST cleanup failed for {user_id}: {exc.code} {body}") from exc
        except URLError as exc:
            raise RuntimeError(f"Supabase REST cleanup failed for {user_id}: {exc.reason}") from exc

    return {
        "mode": "rest",
        "updated": len(rows),
        "users": len(rows_by_user),
    }


def main() -> None:
    database_url = os.getenv("DATABASE_URL", "").strip()
    fallback_user_id = os.getenv("INSTACART_BACKFILL_USER_ID", DEFAULT_USER_ID).strip() or DEFAULT_USER_ID

    trace_files = sorted(TRACE_DIR.glob("*.json"))
    if not trace_files:
        print(json.dumps({"backfilled": 0, "updated": 0, "skipped": 0}, indent=2))
        return

    rows = []
    skipped = 0
    for path in trace_files:
        trace = json.loads(path.read_text())
        run_id = str(trace.get("runId") or "").strip()
        if not run_id:
            skipped += 1
            continue
        rows.append(build_record(trace, fallback_user_id=fallback_user_id))

    if database_url and psycopg is not None:
        db_rows = [prepare_row_for_database(row) for row in rows]
        sql = f"""
            insert into {TABLE} (
                run_id, user_id, status_kind, success, partial_success, started_at, completed_at,
                selected_store, preferred_store, strict_store, session_source, item_count, resolved_count,
                unresolved_count, shortfall_count, attempt_count, duration_seconds, progress, top_issue,
                search_preview, matches, cart_url, summary_json, trace_json, search_text
            ) values (
                %(run_id)s, %(user_id)s, %(status_kind)s, %(success)s, %(partial_success)s, %(started_at)s,
                %(completed_at)s, %(selected_store)s, %(preferred_store)s, %(strict_store)s, %(session_source)s,
                %(item_count)s, %(resolved_count)s, %(unresolved_count)s, %(shortfall_count)s, %(attempt_count)s,
                %(duration_seconds)s, %(progress)s, %(top_issue)s, %(search_preview)s, %(matches)s, %(cart_url)s,
                %(summary_json)s, %(trace_json)s, %(search_text)s
            ) on conflict (run_id) do update set
                user_id = excluded.user_id,
                status_kind = excluded.status_kind,
                success = excluded.success,
                partial_success = excluded.partial_success,
                started_at = excluded.started_at,
                completed_at = excluded.completed_at,
                selected_store = excluded.selected_store,
                preferred_store = excluded.preferred_store,
                strict_store = excluded.strict_store,
                session_source = excluded.session_source,
                item_count = excluded.item_count,
                resolved_count = excluded.resolved_count,
                unresolved_count = excluded.unresolved_count,
                shortfall_count = excluded.shortfall_count,
                attempt_count = excluded.attempt_count,
                duration_seconds = excluded.duration_seconds,
                progress = excluded.progress,
                top_issue = excluded.top_issue,
                search_preview = excluded.search_preview,
                matches = excluded.matches,
                cart_url = excluded.cart_url,
                summary_json = excluded.summary_json,
                trace_json = excluded.trace_json,
                search_text = excluded.search_text,
                updated_at = now()
        """

        with psycopg.connect(database_url) as conn:
            with conn.cursor() as cur:
                cur.executemany(sql, db_rows)
            conn.commit()

            with conn.cursor() as cur:
                cur.execute("select count(*) from public.instacart_run_logs")
                total = cur.fetchone()[0]

        print(json.dumps({
            "backfilled": len(rows),
            "skipped": skipped,
            "total_rows": total,
            "fallback_user_id": fallback_user_id,
            "mode": "database",
        }, indent=2))
        return

    rest_result = persist_rows_via_rest(rows)
    print(json.dumps({
        "backfilled": len(rows),
        "skipped": skipped,
        "fallback_user_id": fallback_user_id,
        **rest_result,
    }, indent=2))


if __name__ == "__main__":
    main()
