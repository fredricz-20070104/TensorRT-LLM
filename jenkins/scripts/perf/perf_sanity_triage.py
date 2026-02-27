#!/usr/bin/env python3
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

import argparse
import json
import os
import re
import sys
import tempfile
import time
from datetime import datetime, timezone

from slack_sdk import WebClient
from slack_sdk.errors import SlackApiError

sys.path.insert(0, sys.path[0] + "/..")
from open_search_db import OpenSearchDB

from perf_utils import (
    classify_test_case,
    generate_post_merge_html,
    get_baseline,
    get_history_data,
)

MAX_QUERY_SIZE = 3000
POST_SLACK_MSG_RETRY_TIMES = 5

# Comparison operators (order matters: >= before >, <= before <, != before =)
COMPARISON_OPERATORS = [">=", "<=", "!=", ">", "<", "="]
COMPARISON_ALLOWED_PREFIXES = ("d_", "l_")
COMPARISON_ALLOWED_FIELDS = ("ts_created",)


# ---------------------------------------------------------------------------
# UPDATE operation helpers (unchanged)
# ---------------------------------------------------------------------------


def _parse_date_string(date_str):
    """Convert date string like 'Feb 18, 2026 @ 22:32:02.960' to millisecond timestamp.

    All date strings are interpreted as UTC to ensure consistent timestamps
    across different environments/timezones.
    """
    date_str = date_str.strip()
    # Try format: "Feb 18, 2026 @ 22:32:02.960"
    try:
        dt = datetime.strptime(date_str, "%b %d, %Y @ %H:%M:%S.%f")
        dt = dt.replace(tzinfo=timezone.utc)
        return int(dt.timestamp() * 1000)
    except ValueError:
        pass
    # Try format: "Feb 18, 2026 @ 22:32:02"
    try:
        dt = datetime.strptime(date_str, "%b %d, %Y @ %H:%M:%S")
        dt = dt.replace(tzinfo=timezone.utc)
        return int(dt.timestamp() * 1000)
    except ValueError:
        pass
    # Try format: "2026/02/18"
    try:
        dt = datetime.strptime(date_str, "%Y/%m/%d")
        dt = dt.replace(tzinfo=timezone.utc)
        return int(dt.timestamp() * 1000)
    except ValueError:
        pass
    raise ValueError(f"Unable to parse date string: {date_str}")


def _can_use_comparison_operator(field_name):
    """Check if a field can use comparison operators (>, <, >=, <=)."""
    if field_name in COMPARISON_ALLOWED_FIELDS:
        return True
    if field_name.startswith(COMPARISON_ALLOWED_PREFIXES):
        return True
    return False


def _parse_value(value):
    value = value.strip()
    if len(value) >= 2 and ((value[0] == value[-1]) and value[0] in ("'", '"')):
        return value[1:-1]
    lower = value.lower()
    if lower == "true":
        return True
    if lower == "false":
        return False
    if re.fullmatch(r"-?\d+", value):
        return int(value)
    if re.fullmatch(r"-?\d+\.\d+", value):
        return float(value)
    return value


def _split_and_clauses(text):
    return [
        part.strip() for part in re.split(r"\s+AND\s+", text, flags=re.IGNORECASE) if part.strip()
    ]


def _parse_assignments(text):
    clauses = _split_and_clauses(text)
    if not clauses:
        return None, "No fields provided"
    result = {}
    for clause in clauses:
        if "=" not in clause:
            return None, f"Invalid clause (missing '='): {clause}"
        key, value = clause.split("=", 1)
        key = key.strip()
        if not key:
            return None, f"Invalid clause (empty field name): {clause}"
        result[key] = _parse_value(value)
    return result, None


def _parse_where_clauses(text):
    """Parse WHERE clauses supporting =, >, <, >=, <= operators.

    Returns a list of tuples: (field_name, operator, value)
    Only d_*, l_*, and ts_created fields can use comparison operators.
    """
    clauses = _split_and_clauses(text)
    if not clauses:
        return None, "No fields provided"

    result = []
    for clause in clauses:
        m = re.match(r"^\s*(\w+)\s*(>=|<=|!=|>|<|=)\s*(.*)", clause)
        if not m:
            return None, f"Invalid clause (missing operator): {clause}"

        key = m.group(1).strip()
        found_op = m.group(2)
        value = _parse_value(m.group(3))

        if not key:
            return None, f"Invalid clause (empty field name): {clause}"

        if found_op not in ("=", "!=") and not _can_use_comparison_operator(key):
            return None, (
                f"Comparison operator '{found_op}' not allowed for field '{key}'. "
                f"Only fields starting with 'd_', 'l_', or field 'ts_created' can use >, <, >=, <= operators."
            )

        if key == "ts_created" and isinstance(value, str):
            try:
                value = _parse_date_string(value)
            except ValueError as e:
                return None, str(e)

        result.append((key, found_op, value))

    return result, None


def _build_opensearch_clause(field, operator, value):
    """Build OpenSearch query clause from field, operator, and value.

    Returns a tuple (clause_type, clause) where clause_type is "must" or "must_not".
    """
    if operator == "=":
        return ("must", {"term": {field: value}})

    if operator == "!=":
        return ("must_not", {"term": {field: value}})

    op_map = {
        ">": "gt",
        "<": "lt",
        ">=": "gte",
        "<=": "lte",
    }
    return ("must", {"range": {field: {op_map[operator]: value}}})


def parse_update_operation(operation):
    match = re.match(
        r"^\s*UPDATE\s+SET\s+(.+?)(?:\s+WHERE\s+(.+))?\s*$", operation, flags=re.IGNORECASE
    )
    if not match:
        return None, None, "Invalid UPDATE operation format"
    set_text = match.group(1).strip()
    where_text = match.group(2).strip() if match.group(2) else ""
    set_values, error = _parse_assignments(set_text)
    if error:
        return None, None, f"Invalid SET clause: {error}"
    where_clauses = []
    if match.group(2) is not None:
        if not where_text:
            return None, None, "Invalid WHERE clause: empty scope"
        where_clauses, error = _parse_where_clauses(where_text)
        if error:
            return None, None, f"Invalid WHERE clause: {error}"
    return set_values, where_clauses, None


def update_perf_data_fields(data_list, set_values):
    updated_list = []
    for data in data_list:
        updated_data = data.copy()
        for key, value in set_values.items():
            updated_data[key] = value
        updated_list.append(updated_data)
    return updated_list


def post_perf_data(data_list, project_name):
    if not data_list:
        print(f"No data to post to {project_name}")
        return False
    try:
        print(f"Ready to post {len(data_list)} data to {project_name}")
        return OpenSearchDB.postToOpenSearchDB(data_list, project_name)
    except Exception as e:
        print(f"Failed to post data to {project_name}, error: {e}")
        return False


# ---------------------------------------------------------------------------
# Slack messaging
# ---------------------------------------------------------------------------


def send_message(msg, channel_id, bot_token):
    """Send message to Slack channel using slack_sdk."""
    client = WebClient(token=bot_token)

    attachments = [
        {
            "title": "Perf Sanity Regression Report",
            "color": "#ff0000",
            "text": msg,
        }
    ]

    for attempt in range(1, POST_SLACK_MSG_RETRY_TIMES + 1):
        try:
            result = client.chat_postMessage(
                channel=channel_id,
                attachments=attachments,
            )
            assert result["ok"] is True, json.dumps(result.data)
            print(f"Message sent successfully to channel {channel_id}")
            return
        except SlackApiError as e:
            print(
                f"Attempt {attempt}/{POST_SLACK_MSG_RETRY_TIMES}: Error sending message to Slack: {e}"
            )
        except Exception as e:
            print(f"Attempt {attempt}/{POST_SLACK_MSG_RETRY_TIMES}: Unexpected error: {e}")

        if attempt < POST_SLACK_MSG_RETRY_TIMES:
            time.sleep(1)

    print(
        f"Failed to send message to channel {channel_id} after {POST_SLACK_MSG_RETRY_TIMES} attempts"
    )


def send_html_to_slack(html_path, channel_id, bot_token):
    """Upload the HTML report to Slack channel(s)."""
    if not channel_id or not bot_token:
        print(f"Slack credentials not provided. HTML report saved to: {html_path}")
        return

    channel_ids = [cid.strip() for cid in channel_id.split(",") if cid.strip()]
    client = WebClient(token=bot_token)

    for cid in channel_ids:
        for attempt in range(1, POST_SLACK_MSG_RETRY_TIMES + 1):
            try:
                result = client.files_upload_v2(
                    channel=cid,
                    file=html_path,
                    title="Perf Sanity Regression Dashboard",
                    initial_comment="Post-merge perf sanity regression analysis report",
                )
                print(f"HTML report uploaded successfully to channel {cid}")
                break
            except SlackApiError as e:
                print(
                    f"Attempt {attempt}/{POST_SLACK_MSG_RETRY_TIMES}: "
                    f"Error uploading to Slack: {e}"
                )
            except Exception as e:
                print(
                    f"Attempt {attempt}/{POST_SLACK_MSG_RETRY_TIMES}: "
                    f"Unexpected error: {e}"
                )

            if attempt < POST_SLACK_MSG_RETRY_TIMES:
                time.sleep(1)
        else:
            print(
                f"Failed to upload to channel {cid} after "
                f"{POST_SLACK_MSG_RETRY_TIMES} attempts"
            )


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def main():
    parser = argparse.ArgumentParser(description="Perf Sanity Triage Script")
    parser.add_argument("--project_name", type=str, required=True, help="OpenSearch project name")
    parser.add_argument("--operation", type=str, required=True, help="Operation to perform")
    parser.add_argument(
        "--channel_id",
        type=str,
        default="",
        help="Slack channel ID(s), comma-separated for multiple channels",
    )
    parser.add_argument("--bot_token", type=str, default="", help="Slack bot token")
    parser.add_argument(
        "--query_job_number", type=int, default=1, help="Number of latest jobs to query"
    )
    parser.add_argument(
        "--output_html", type=str, default="",
        help="Output HTML file path for the regression dashboard"
    )

    args = parser.parse_args()

    print(f"Project Name: {args.project_name}")
    print(f"Operation: {args.operation}")
    print(f"Channel ID: {args.channel_id}")
    print(f"Bot Token: {'***' if args.bot_token else 'Not provided'}")

    if args.operation == "SLACK BOT SENDS MESSAGE":
        # Run the perf-regression-detector pipeline:
        # get_history_data -> get_baseline -> classify_test_case -> generate_post_merge_html
        print("Querying post-merge history data from OpenSearch...")
        grouped = get_history_data(extra_must_clauses=[
            {"term": {"b_is_post_merge": True}},
            {"term": {"s_branch": "main"}},
        ])

        if grouped is None:
            print("Failed to query history data from OpenSearch")
            return
        if len(grouped) == 0:
            print("No post-merge perf data found")
            return

        print(f"Found {len(grouped)} unique test cases.")

        print("Computing baselines (rolling smooth + P95)...")
        get_baseline(grouped)

        print("Classifying regression patterns...")
        classify_test_case(grouped)

        # Generate HTML report
        if args.output_html:
            html_path = args.output_html
        else:
            html_path = os.path.join(
                tempfile.gettempdir(), "perf_sanity_triage_report.html"
            )
        generate_post_merge_html(grouped, html_path)

        # Send HTML to Slack
        send_html_to_slack(html_path, args.channel_id, args.bot_token)

    elif args.operation.strip().upper().startswith("UPDATE"):
        set_values, where_clauses, error = parse_update_operation(args.operation)
        if error:
            print(error)
            return

        must_clauses = []
        must_not_clauses = []
        for field, operator, value in where_clauses:
            clause_type, clause = _build_opensearch_clause(field, operator, value)
            if clause_type == "must":
                must_clauses.append(clause)
            else:
                must_not_clauses.append(clause)

        data_list = OpenSearchDB.queryPerfDataFromOpenSearchDB(
            args.project_name, must_clauses, size=MAX_QUERY_SIZE, must_not_clauses=must_not_clauses
        )
        if data_list is None:
            print("Failed to query data for update")
            return
        if len(data_list) == 0:
            print("No data matched the update scope")
            return

        updated_data_list = update_perf_data_fields(data_list, set_values)
        if not post_perf_data(updated_data_list, args.project_name):
            print("Failed to post updated data")
            return
        print(f"Updated {len(updated_data_list)} entries successfully")
    else:
        print(f"Unknown operation: {args.operation}")


if __name__ == "__main__":
    main()
