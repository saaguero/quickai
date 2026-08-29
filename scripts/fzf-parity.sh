#!/bin/bash
# Compare Sources/QuickAI/FuzzySearch.swift (our fzf port) against the real fzf
# binary: same candidate lines, same queries, same expected order.
# Usage: ./scripts/fzf-parity.sh [candidates-file]  (default: the panel's own
# conversation titles, so parity is checked on real data).
set -euo pipefail
cd "$(dirname "$0")/.."

command -v fzf >/dev/null || { echo "fzf not installed (brew install fzf)"; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

CANDIDATES=${1:-}
if [[ -z "$CANDIDATES" ]]; then
  CANDIDATES="$WORK/candidates.txt"
  python3 - "$CANDIDATES" <<'PY'
import json, os, sys
store = os.path.expanduser("~/Library/Application Support/QuickAI/conversations.json")
titles = [(c.get("title") or "Untitled") for c in json.load(open(store))] if os.path.exists(store) else []
titles += ["openai/gpt-oss-120b", "anthropic/claude-sonnet-4.5", "qwen/qwen3-30b-a3b", "openrouter/free"]
open(sys.argv[1], "w").write("\n".join(titles) + "\n")
PY
fi

cat > "$WORK/main.swift" <<'SWIFT'
import Foundation

@main
struct Parity {
    static func main() {
        let query = CommandLine.arguments.dropFirst().joined(separator: " ")
        var lines: [String] = []
        while let line = readLine() { if !line.isEmpty { lines.append(line) } }
        var rows: [(line: String, score: Int)] = []
        for line in lines {
            if let match = fuzzyMatch(query, in: line) { rows.append((line, match.score)) }
        }
        // fzf's order: score desc, then the shorter candidate, then input order
        rows.sort { left, right in
            if left.score != right.score { return left.score > right.score }
            return left.line.count < right.line.count
        }
        for row in rows { print(row.line) }
    }
}
SWIFT

swiftc -O -parse-as-library "$WORK/main.swift" Sources/QuickAI/FuzzySearch.swift -o "$WORK/port" 2>/dev/null

QUERIES=("${@:2}")
if [[ ${#QUERIES[@]} -eq 0 ]]; then
  QUERIES=(ide iden identify Identify defi def output outputshort sen alineacion "defi pug" gptoss gpt-oss sonnet qwen free)
fi

fail=0
for query in "${QUERIES[@]}"; do
  fzf -f "$query" < "$CANDIDATES" > "$WORK/expected.txt" || true
  "$WORK/port" "$query" < "$CANDIDATES" > "$WORK/actual.txt"
  if diff -q "$WORK/expected.txt" "$WORK/actual.txt" >/dev/null; then
    printf 'ok    %-14s (%s hits)\n' "$query" "$(wc -l < "$WORK/expected.txt" | tr -d ' ')"
  else
    fail=1
    printf 'FAIL  %s\n' "$query"
    diff "$WORK/expected.txt" "$WORK/actual.txt" | sed 's/^/      /'
  fi
done
exit $fail
