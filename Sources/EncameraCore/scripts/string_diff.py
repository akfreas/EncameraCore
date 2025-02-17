#!/usr/bin/env python3
import argparse
import json
from itertools import islice
from pathlib import Path

import openai


def append_translations_to_file(file_path, translations):
    with open(file_path, 'a', encoding='utf-8') as file:
        for translation in translations:
            file.write(f"\n{translation}")
def load_strings_from_file(file_path):
    keys_and_values = {}
    with open(file_path, 'r', encoding='utf-8') as file:
        for line in file:
            if '=' in line:
                key, value = line.split('=', 1)

                keys_and_values[key.strip()] = value.strip().rstrip(';').rstrip('"').lstrip('"')
    return keys_and_values

def get_translations(keys_and_values, from_lang, to_lang):
    chunks = [dict(islice(keys_and_values.items(), i, i + 5)) for i in range(0, len(keys_and_values), 5)]
    translations = []
    for chunk in chunks:
        # convert values to list
        values = list(chunk.values())
        # prompt = " ".join([f"{value}" for value in values])
        messages = [
                {"role": "system", "content": f"Translate the following {from_lang} text to {to_lang}, return JSON and preserve the order provided. DO NOT change the order of the strings."},
                {"role": "user", "content": json.dumps({"translations": values})}
            ]
        # import ipdb; ipdb.set_trace()
        response = openai.chat.completions.create(
            model="gpt-4o",
            messages=messages,
            response_format={"type": "json_object" },
            temperature=0.5,
            max_tokens=256
        )
        translation_text = json.loads(response.choices[0].message.content)['translations']
        print(translation_text)
        translations.extend([f"{key} = \"{translation}\";" for key, translation in zip(chunk.keys(), translation_text)])
    return translations

def compare_and_translate(master_keys_and_values, directory, master_dir, from_lang, to_lang, silent=False):
    loc_path = Path(directory) / "Localizable.strings"
    if loc_path.exists():
        local_keys_and_values = load_strings_from_file(loc_path)
        local_keys = set(local_keys_and_values.keys())
        master_keys = set(master_keys_and_values.keys())
        missing_keys = master_keys - local_keys
        if missing_keys:
            print(f"Missing translations in {directory.name}:")
            for key in sorted(missing_keys):
                print(f"  {key}")
            if silent or input("Do you want to translate these missing keys? (y/n) ").lower() == "y":
                missing_keys_and_values = {key: master_keys_and_values[key] for key in missing_keys}
                translations = get_translations(missing_keys_and_values, from_lang, to_lang)
                append_translations_to_file(loc_path, translations)

def main():
    parser = argparse.ArgumentParser(description='Compare and translate localization files.')
    parser.add_argument('--master', type=str, help='Path to the master localization directory.')
    parser.add_argument('--api_key', type=str, help='OpenAI API key.')
    parser.add_argument('--silent', action='store_true', help='Automatically translate missing strings without prompting')
    args = parser.parse_args()

    openai.api_key = args.api_key

    master_dir = Path(args.master)
    master_file = master_dir / "Localizable.strings"

    if not master_file.exists():
        print(f"Master file {master_file} does not exist.")
        return

    master_keys_and_values = load_strings_from_file(master_file)
    from_lang = "English"  # Master language assumed to be English
    language_map = {"de.lproj": "German", "es.lproj": "Spanish", "ru.lproj": "Russian", "ko.lproj": "Korean"}

    for directory in master_dir.parent.iterdir():
        if directory.is_dir() and directory != master_dir:
            to_lang = language_map.get(directory.name, "English")
            compare_and_translate(master_keys_and_values, directory, master_dir, from_lang, to_lang, args.silent)

if __name__ == '__main__':
    main()
