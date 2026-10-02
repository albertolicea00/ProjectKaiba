#!/usr/bin/env bash

# Stop on errors
set -e

# Default targets
TARGET_HD=false
TARGET_SD=false

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --hd) TARGET_HD=true ;;
        --sd) TARGET_SD=true ;;
        -h|--help)
            echo "Usage: $0 [--hd] [--sd]"
            echo "Options:"
            echo "  --hd   Download High Definition images (~421x614) to hd/"
            echo "  --sd   Download Standard Definition images (~177x254) to sd/"
            exit 0
            ;;
        *) echo "Unknown parameter: $1"; exit 1 ;;
    esac
    shift
done

if [ "$TARGET_HD" = false ] && [ "$TARGET_SD" = false ]; then
    echo "Error: You must specify what to download."
    echo "Usage: $0 [--hd] [--sd]"
    echo "Example: ./tools/artwork-dl-ygoprodeck.sh --sd"
    exit 1
fi

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PICS_DIR="$BASE_DIR/data/base/pics"
API_URL="https://db.ygoprodeck.com/api/v7/cardinfo.php"
TMP_JSON="/tmp/ygo_cards.json"
TMP_CURL_CONF="/tmp/ygo_curl_config.txt"

mkdir -p "$PICS_DIR/hd"
mkdir -p "$PICS_DIR/sd"

echo "1/3 Fetching card database from YGOPRODeck..."
curl -s -A "ProjectKaiba/1.0" -o "$TMP_JSON" "$API_URL"

echo "2/3 Parsing card data and checking existing files (Resume check)..."
> "$TMP_CURL_CONF"

# We use a python one-liner just to parse JSON reliably on Mac without needing 'jq'
python3 -c "
import sys, json
try:
    data = json.load(sys.stdin).get('data', [])
    for c in data:
        images = c.get('card_images', [])
        if images:
            print(f\"{c['id']},{images[0].get('image_url','')},{images[0].get('image_url_small','')}\")
except Exception as e:
    print('Error parsing JSON', file=sys.stderr)
    sys.exit(1)
" < "$TMP_JSON" | while IFS=, read -r card_id hd_url sd_url; do
    
    # If HD is requested and the file is missing (or 0 bytes), queue it
    if [ "$TARGET_HD" = true ] && [ -n "$hd_url" ]; then
        dest="$PICS_DIR/hd/${card_id}.jpg"
        if [ ! -s "$dest" ]; then
            echo "url = \"$hd_url\"" >> "$TMP_CURL_CONF"
            echo "output = \"$dest\"" >> "$TMP_CURL_CONF"
            echo "user-agent = \"ProjectKaiba/1.0\"" >> "$TMP_CURL_CONF"
        fi
    fi

    # If SD is requested and the file is missing (or 0 bytes), queue it
    if [ "$TARGET_SD" = true ] && [ -n "$sd_url" ]; then
        dest="$PICS_DIR/sd/${card_id}.jpg"
        if [ ! -s "$dest" ]; then
            echo "url = \"$sd_url\"" >> "$TMP_CURL_CONF"
            echo "output = \"$dest\"" >> "$TMP_CURL_CONF"
            echo "user-agent = \"ProjectKaiba/1.0\"" >> "$TMP_CURL_CONF"
        fi
    fi
done

DOWNLOAD_COUNT=$(grep -c "^url =" "$TMP_CURL_CONF" || true)

if [ "$DOWNLOAD_COUNT" -eq 0 ]; then
    echo "3/3 All requested images are already downloaded! (Resume skipped everything)"
    rm -f "$TMP_JSON" "$TMP_CURL_CONF"
    exit 0
fi

echo "3/3 Starting parallel download of $DOWNLOAD_COUNT missing images..."
echo "--------------------------------------------------------"

# Use curl's native parallel mode (-Z) for max speed and a gorgeous unified progress bar
curl -Z --parallel-max 30 --retry 3 -K "$TMP_CURL_CONF"

echo ""
echo "--------------------------------------------------------"
echo "Download complete! Images are safely stored in $PICS_DIR"
rm -f "$TMP_JSON" "$TMP_CURL_CONF"
