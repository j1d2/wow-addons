#!/usr/bin/env bash
# Speed and memory benchmarks for HouseLedger and Unmaker on synthetic data (bench/).
#
# Usage: scripts/bench.sh --smoke | --full
#   --smoke  small sizes with budgets; the gate runs it, and it exits 1 if a step is over
#   --full   the sizes worth knowing, as a table; takes a minute or two and a few hundred MB
# Environment: LUA (default lua5.1), BENCH_BUDGET_SCALE (multiplies every smoke budget)
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

case "${1:-}" in
    --smoke | --full) ;;
    *)
        echo "usage: scripts/bench.sh --smoke | --full" >&2
        exit 2
        ;;
esac

exec "${LUA:-lua5.1}" bench/bench.lua "$1"
