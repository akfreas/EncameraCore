#!/usr/bin/env python3
import argparse
from pathlib import Path
import openai
from itertools import islice

def load_strings_from_file(file_path):
    keys = set()
    with open(file_path, 'r', encoding='utf-8') as file:
        for line in file:
            if '=' in line:
                key = line.split('=')[0].strip()
                keys.add(key)
    return keys

def get_translations(keys, from_lang, to_lang):
    chunks = [list(islice(keys, i, i + 5)) for i in range(0, len(keys), 5)]
    translations = []
    for chunk in chunks:
        import ipdb; ipdb.set_trace()
        prompt = " ".join([f"{key} =" for key in chunk])
        response = openai.chat.completions.create(
            model="gpt-4-turbo",
            messages=[
                {"role": "system", "content": f"Translate the following English text to {to_lang} and preserve the format:"},
                {"role": "user", "content": prompt}
            ],
            temperature=0.5,
            max_tokens=256
        )
        # Get the last user message from the response, which contains the translated text

        translation_text = response.choices[0].message.content
        translations.append(translation_text.strip())
    return translations

def append_translations_to_file(file_path, translations):
    with open(file_path, 'a', encoding='utf-8') as file:
        for translation in translations:
            file.write(f"\n{translation}")

def compare_and_translate(master_keys, directory, master_dir, from_lang, to_lang):
    loc_path = Path(directory) / "Localizable.strings"
    if loc_path.exists():
        local_keys = load_strings_from_file(loc_path)
        missing_keys = master_keys - local_keys
        if missing_keys:
            print(f"Missing translations in {directory.name}:")
            for key in sorted(missing_keys):
                print(f"  {key}")
            if input("Do you want to translate these missing keys? (yes/no) ").lower() == "yes":
                translations = get_translations(missing_keys, from_lang, to_lang)
                append_translations_to_file(loc_path, translations)

def main():
    parser = argparse.ArgumentParser(description='Compare and translate localization files.')
    parser.add_argument('--master', type=str, help='Path to the master localization directory.')
    parser.add_argument('--api_key', type=str, help='OpenAI API key.')
    args = parser.parse_args()

    openai.api_key = args.api_key

    master_dir = Path(args.master)
    master_file = master_dir / "Localizable.strings"

    if not master_file.exists():
        print(f"Master file {master_file} does not exist.")
        return

    master_keys = load_strings_from_file(master_file)
    from_lang = "English"  # Master language assumed to be English
    language_map = {"de.lproj": "German", "es.lproj": "Spanish"}  # Map directory names to languages

    for directory in master_dir.parent.iterdir():
        if directory.is_dir() and directory != master_dir:
            to_lang = language_map.get(directory.name, "English")
            compare_and_translate(master_keys, directory, master_dir, from_lang, to_lang)

if __name__ == '__main__':
    main()
