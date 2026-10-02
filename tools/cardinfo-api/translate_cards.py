import json
import os
import sys
import time
import argparse
import requests
from deep_translator import GoogleTranslator, MyMemoryTranslator

EN_JSON_PATH = "cardinfo.ygoprodeck.apiv7.en.json"
BATCH_SIZE = 10

def make_ollama_translator(model_name):
    class OllamaEngine:
        def __init__(self, source='en', target='es'):
            self.source = source
            self.target = target
        def translate(self, text):
            prompt = f"Translate the following text from {self.source} to {self.target}. Reply with ONLY the translated text, do not include any quotes or explanations.\n\nText: {text}"
            res = requests.post('http://localhost:11434/api/generate', json={
                "model": model_name,
                "prompt": prompt,
                "stream": False
            }, timeout=60)
            res.raise_for_status()
            return res.json().get('response', '').strip()
    OllamaEngine.__name__ = f"Ollama_{model_name.replace(':', '_')}"
    return OllamaEngine

# Array of fallback translator classes. 
# You can easily add more here (e.g. PonsTranslator) if you want to extend it.
FALLBACK_ENGINES = [
    GoogleTranslator,
    MyMemoryTranslator,
    make_ollama_translator("translategemma:12b"),
    make_ollama_translator("translategemma:8b"),
    make_ollama_translator("translategemma:4b")
]

def get_engine_target_lang(engine_name, base_lang):
    if engine_name == 'MyMemoryTranslator':
        # MyMemory requires specific regional codes for some languages
        mapping = {
            'es': 'es-ES',
            'ja': 'ja-JP',
            'ru': 'ru-RU',
            'fr': 'fr-FR',
            'de': 'de-DE',
            'it': 'it-IT',
            'pt': 'pt-PT',
            'en': 'en-GB'
        }
        return mapping.get(base_lang, base_lang)
    return base_lang

def translate_with_fallbacks(text, target_lang):
    if not text:
        return text
        
    # Iterate through the array of fallback engines
    for Engine in FALLBACK_ENGINES:
        engine_name = Engine.__name__
        engine_target = get_engine_target_lang(engine_name, target_lang)
        
        # Try each engine up to 2 times
        for attempt in range(2):
            try:
                time.sleep(2)  # Delay to respect rate limits
                return Engine(source='en', target=engine_target).translate(text)
            except Exception as e:
                print(f"    [{engine_name} attempt {attempt+1}/2] error: {e}")
                time.sleep(5)  # Backoff before next attempt
                
    # If all engines in the array and their retries fail, return None
    return None

def process_batch(cards, target_lang):
    descriptions = [c.get("desc", "") for c in cards]
    
    translated_texts = []
    batch_success = False
    
    # Try Google batch translation first
    try:
        time.sleep(2)
        res = GoogleTranslator(source='en', target=target_lang).translate_batch(descriptions)
        # Verify the batch was completely successful
        if res and len(res) == len(descriptions) and not any(t is None for t in res):
            translated_texts = res
            batch_success = True
    except Exception as e:
        print(f"  -> Google batch translation failed: {e}")
        
    # If batch failed, fallback to sequential multi-engine translation
    if not batch_success:
        print("  -> Using sequential multi-engine fallback for this batch...")
        for desc in descriptions:
            res = translate_with_fallbacks(desc, target_lang)
            if res is None:
                # Halt immediately. We do not want to save empty or untranslated strings.
                raise RuntimeError("All translation engines and fallbacks failed for a text.")
            translated_texts.append(res)
            
    # Apply translated texts to the cards
    for i, card in enumerate(cards):
        card["desc"] = translated_texts[i]
        
    return cards

def main():
    parser = argparse.ArgumentParser(description="Translate Yu-Gi-Oh! card descriptions from English.")
    parser.add_argument("-t", "--target-lang", required=True, help="Target language code (e.g., es, ja, ru, fr)")
    args = parser.parse_args()

    target_lang = args.target_lang
    out_json_path = f"cardinfo.ygoprodeck.apiv7.{target_lang}.json"

    print(f"Loading {EN_JSON_PATH}...")
    try:
        with open(EN_JSON_PATH, "r", encoding="utf-8") as f:
            data = json.load(f)
    except FileNotFoundError:
        print(f"Error: {EN_JSON_PATH} not found in the current directory.")
        return

    cards = data.get("data", [])
    total_cards = len(cards)
    print(f"Total cards found: {total_cards}")
    print(f"Target language: {target_lang}")
    print(f"Output file will be: {out_json_path}")

    if os.path.exists(out_json_path) and os.path.getsize(out_json_path) > 0:
        print(f"Loading existing {out_json_path} to resume...")
        try:
            with open(out_json_path, "r", encoding="utf-8") as f:
                out_data = json.load(f)
                out_cards = out_data.get("data", [])
                out_cards_dict = {str(c["id"]): c for c in out_cards if "desc" in c}
        except json.JSONDecodeError:
            print("Existing file is corrupted. Starting fresh.")
            out_cards_dict = {}
    else:
        out_cards_dict = {}

    translated_count = 0
    to_translate = []

    for card in cards:
        card_id = str(card["id"])
        # Only skip if it was translated (meaning the description is different from English)
        if card_id in out_cards_dict and out_cards_dict[card_id].get("desc") != card.get("desc"):
            card.update(out_cards_dict[card_id])
            translated_count += 1
        else:
            to_translate.append(card)

    print(f"Already translated: {translated_count}/{total_cards}")
    print(f"To translate: {len(to_translate)}")

    if not to_translate:
        print("All cards translated!")
        return

    print("Starting translation. If an error is unrecoverable, the script will safely abort so you can resume later.")
    
    translated_this_session = 0
    
    for i in range(0, len(to_translate), BATCH_SIZE):
        batch = to_translate[i:i + BATCH_SIZE]
        
        try:
            process_batch(batch, target_lang)
        except RuntimeError as e:
            # Fatal error caught: abort script before saving the current failed batch
            print(f"\n[FATAL] {e}")
            print("Aborting to prevent saving untranslated data. You can re-run the script later to resume.")
            sys.exit(1)
            
        translated_this_session += len(batch)
                        
        print(f"Progress: {translated_count + translated_this_session} / {total_cards}")
        
        # Save every batch ONLY if the batch was completely successful
        with open(out_json_path, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=4)
            
    print(f"Finished translating {translated_this_session} cards in this session.")

if __name__ == "__main__":
    main()
