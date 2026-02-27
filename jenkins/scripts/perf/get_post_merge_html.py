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
"""Query OpenSearch perf sanity history data and generate an HTML dashboard.

Thin wrapper around perf_utils. See README.md for full documentation.
"""

import argparse
import os
import sys

# Set OPEN_SEARCH_DB_BASE_URL before importing perf_utils, because
# open_search_db captures the env var at module-import time.
if not os.environ.get("OPEN_SEARCH_DB_BASE_URL"):
    os.environ["OPEN_SEARCH_DB_BASE_URL"] = "http://gpuwa.nvidia.com"

from perf_utils import (
    PERF_SANITY_PROJECT_NAME,
    QUERY_LOOKBACK_DAYS,
    classify_test_case,
    generate_post_merge_html,
    get_baseline,
    get_history_data,
)


def main():
    parser = argparse.ArgumentParser(
        description="Query OpenSearch perf sanity history and generate HTML dashboard."
    )
    parser.add_argument(
        "--output",
        type=str,
        default="perf_history.html",
        help="Output HTML file path (default: perf_history.html)",
    )
    args = parser.parse_args()

    print(f"Querying perf data from {PERF_SANITY_PROJECT_NAME} "
          f"(last {QUERY_LOOKBACK_DAYS} days)...")
    grouped = get_history_data(extra_must_clauses=[
        {"term": {"b_is_post_merge": True}},
        {"term": {"s_branch": "main"}},
    ])

    if grouped is None:
        print("ERROR: Failed to query data from OpenSearch (network error).",
              file=sys.stderr)
        sys.exit(1)
    if len(grouped) == 0:
        print("No perf data found in the specified time range.")
        sys.exit(0)

    print(f"Found {len(grouped)} unique test cases.")

    print("Computing baselines (rolling smooth + P95)...")
    get_baseline(grouped)

    print("Classifying regression patterns...")
    classify_test_case(grouped)

    generate_post_merge_html(grouped, args.output)


if __name__ == "__main__":
    main()
