# Card Info API Tools

This directory contains tools and scripts for managing, processing, and translating Yu-Gi-Oh! card databases sourced from the YGOProDeck API (v7). The generated data is intended to be processed for use within the Project Kaiba `CardDB` and UI.

## Tools

### `translate_cards.py`
A robust translation script to translate card descriptions (`desc` field) from English to a target language. Because the dataset contains thousands of cards, this script implements a batch processing system with a multi-tiered failover strategy to prevent rate limit blocks.

**Fallback Strategy:**
1. Google Translate (Batch processing)
2. Google Translate (Sequential with delays)
3. MyMemory Translator (Online alternative)
4. Local LLMs via Ollama (`translategemma:12b`, `8b`, `4b`)

Progress is saved continuously. If an unrecoverable error occurs, the script safely halts and preserves progress for resuming later.

**Usage:**
```bash
python3 translate_cards.py -t <language_code>
```
Example (`es` for Spanish, `ja` for Japanese, `ru` for Russian):
```bash
python3 translate_cards.py -t es
```

## JSON Data Structure

The tools expect and generate JSON files (`cardinfo.ygoprodeck.apiv7.<lang>.json`) following the standard YGOProDeck API v7 schema. 

Reference schema:

```json
{
    "data": [
        {
            "id": "(int) Card ID (e.g. 80181649)",
            "name": "(string) Card name",
            "type": "(string) Card type (e.g. 'Spell Card', 'Effect Monster')",
            "humanReadableCardType": "(string) Human readable type (e.g. 'Continuous Spell')",
            "frameType": "(string) Frame type (e.g. 'spell', 'effect')",
            "desc": "(string) Card description or effect text",
            "race": "(string) Monster type or Spell/Trap property (e.g. 'Continuous', 'Warrior')",
            "archetype": "(string) Archetype name (optional, only present if card belongs to one)",
            "ygoprodeck_url": "(string) URL to the card on YGOProDeck",
            "card_sets": [
                {
                    "set_name": "(string) Name of the set",
                    "set_code": "(string) Set code (e.g. 'JUSH-EN040')",
                    "set_rarity": "(string) Rarity name (e.g. 'Super Rare')",
                    "set_rarity_code": "(string) Rarity abbreviation (e.g. '(SR)')",
                    "set_price": "(string) Price in the set"
                }
            ],
            "banlist_info": {
                "ban_tcg": "(string) TCG banlist status (e.g. 'Limited', 'Banned') (optional)",
                "ban_ocg": "(string) OCG banlist status (optional)",
                "ban_goat": "(string) GOAT banlist status (optional)"
            },
            "card_images": [
                {
                    "id": "(int) Image ID (usually same as Card ID or alt artwork ID)",
                    "image_url": "(string) Full size image URL",
                    "image_url_small": "(string) Small size image URL",
                    "image_url_cropped": "(string) Cropped art URL"
                }
            ],
            "card_prices": [
                {
                    "cardmarket_price": "(string) Price on Cardmarket",
                    "tcgplayer_price": "(string) Price on TCGPlayer",
                    "ebay_price": "(string) Price on eBay",
                    "amazon_price": "(string) Price on Amazon",
                    "coolstuffinc_price": "(string) Price on CoolStuffInc"
                }
            ]
        }
    ]
}
```