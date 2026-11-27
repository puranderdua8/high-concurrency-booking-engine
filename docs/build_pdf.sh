#!/bin/sh
# Builds the submission PDF: SOLUTION.md followed by the full SQL files.
# Needs pandoc and Google Chrome (set CHROME to use another Chromium binary).
set -eu
cd "$(dirname "$0")"

CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
OUT="High-Concurrency-Booking-Engine.pdf"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

{
    cat SOLUTION.md
    printf '\n## Appendix: SQL for P1 and P2 {.appendix}\n\nRun the files in this order on MySQL 8.0.16 or later.\n'
    for f in 01_schema 02_seed 03_p2_shows_by_date 04_booking_flow; do
        case $f in
            01_schema)            title='P1: schema' ;;
            02_seed)              title='P1: sample data' ;;
            03_p2_shows_by_date)  title='P2: shows by date' ;;
            04_booking_flow)      title='P1: locking, expiry and webhooks' ;;
        esac
        printf '\n### %s (`sql/%s.sql`)\n\n```sql\n' "$title" "$f"
        cat "../sql/$f.sql"
        printf '```\n'
    done
} > "$TMP/full.md"

pandoc "$TMP/full.md" --from gfm+attributes --standalone --embed-resources \
    --resource-path=. --css style.css --syntax-highlighting=none \
    --metadata pagetitle="High-Concurrency Booking Engine" -o "$TMP/full.html"

"$CHROME" --headless --disable-gpu --no-pdf-header-footer \
    --print-to-pdf="$PWD/$OUT" "file://$TMP/full.html" 2>/dev/null

echo "Wrote docs/$OUT"
