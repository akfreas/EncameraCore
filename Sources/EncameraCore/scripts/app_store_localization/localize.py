#!/usr/bin/env python3
"""
App Store Localization Script
Translates and updates App Store Connect metadata using OpenAI and the App Store Connect API.

Requires the `asc` library: pip install -e scripts/asc
"""

import argparse
import json
import os
import re
import sys
from itertools import islice
from pathlib import Path

import openai
import yaml

try:
    from asc.auth import Credentials
    from asc.client import ASCClient
    from asc.releases import create_version_localization, update_version_localization
except ImportError:
    print("Missing required package 'asc'. Install with: pip install -e ../asc")
    sys.exit(1)

try:
    import getpass

    import inquirer
    import keyring
    from tabulate import tabulate
    from tqdm import tqdm
except ImportError:
    print("Missing required packages. Please install with:")
    print("pip install inquirer tabulate keyring tqdm")
    sys.exit(1)


class AppStoreConnectAPI:
    """Thin wrapper around the asc.ASCClient that returns raw API dicts.

    Exists so the rest of this script can keep using dict-style access on
    responses (loc["attributes"]["locale"] etc.) without changes.
    """

    def __init__(self, credentials: Credentials):
        self._client = ASCClient(credentials)

    def find_app_by_bundle_id(self, bundle_id):
        print(f"🌐 Looking up app by bundle ID: {bundle_id}")
        return self._client.find_app_by_bundle_id(bundle_id)

    def get_app_store_versions(self, app_id, include_all_states=False):
        params = (
            None
            if include_all_states
            else {"filter[appStoreState]": "READY_FOR_SALE,PENDING_RELEASE,IN_REVIEW,WAITING_FOR_REVIEW"}
        )
        try:
            data = self._client.get(f"/v1/apps/{app_id}/appStoreVersions", params=params).get("data", [])
        except Exception as e:
            if not include_all_states and "400" in str(e):
                print("⚠️  Filtered request failed, trying without state filter...")
                return self.get_app_store_versions(app_id, include_all_states=True)
            raise

        if data:
            print(f"📋 Found {len(data)} version(s):")
            for version in data:
                state = version["attributes"].get("appStoreState", "UNKNOWN")
                version_string = version["attributes"].get("versionString", "UNKNOWN")
                print(f"  • Version {version_string}: {state}")
        else:
            print("⚠️  No app store versions found")
        return data

    def get_version_localizations(self, version_id):
        return self._client.get_all(
            f"/v1/appStoreVersions/{version_id}/appStoreVersionLocalizations"
        )

    def update_localization(self, localization_id, **fields):
        return update_version_localization(self._client, localization_id, **fields)

    def create_localization(self, version_id, locale, **fields):
        return create_version_localization(self._client, version_id, locale, **fields)


class LocalizationTranslator:
    """Handles translation using OpenAI API."""
    
    def __init__(self, api_key, model="gpt-4", max_tokens=2000, temperature=0.3):
        self.api_key = api_key
        self.model = model
        self.max_tokens = max_tokens
        self.temperature = temperature
        openai.api_key = api_key
    
    def translate_content(self, content, from_lang, to_lang, context_note=""):
        """Translate content using OpenAI."""
        system_message = f"""Translate the following {from_lang} app store listing content to {to_lang}. 
Maintain the original formatting, line breaks, and bullet points.
Keep any placeholders like %s, {{0}}, etc. unchanged.
Context: {context_note}

Return only the translated text without any additional commentary."""

        try:
            response = openai.chat.completions.create(
                model=self.model,
                messages=[
                    {"role": "system", "content": system_message},
                    {"role": "user", "content": content}
                ],
                temperature=self.temperature,
                max_tokens=self.max_tokens
            )
            
            return response.choices[0].message.content.strip()
        
        except Exception as e:
            print(f"❌ Translation error: {e}")
            return None


# String localization functions integrated from string_diff.py
def load_strings_from_file(file_path):
    """Load strings from a Localizable.strings file."""
    keys_and_values = {}
    with open(file_path, 'r', encoding='utf-8') as file:
        for line in file:
            if '=' in line:
                key, value = line.split('=', 1)
                keys_and_values[key.strip()] = value.strip().rstrip(';').rstrip('"').lstrip('"')
    return keys_and_values


def get_string_translations(keys_and_values, from_lang, to_lang, translator):
    """Translate strings using the existing LocalizationTranslator with progress bar."""
    chunks = [dict(islice(keys_and_values.items(), i, i + 5)) for i in range(0, len(keys_and_values), 5)]
    translations = []
    
    with tqdm(total=len(chunks), desc=f"Translating to {to_lang}", unit="batch") as pbar:
        for chunk in chunks:
            # Convert values to list
            values = list(chunk.values())
            
            # Create content for translation
            content = json.dumps({"translations": values})
            
            # Use the existing translator with custom system message for string translation
            system_message = f"""Translate the following {from_lang} text to {to_lang}. 
Return JSON and preserve the order provided. DO NOT change the order of the strings.
IMPORTANT: Use native characters (not Unicode escape sequences) for languages like Chinese, Japanese, Korean, etc.
Example good response: {{"translations": ["你好", "谢谢"]}}
Example bad response: {{"translations": ["\\u4f60\\u597d", "\\u8c22\\u8c22"]}}"""
            
            try:
                response = openai.chat.completions.create(
                    model="gpt-4",
                    messages=[
                        {"role": "system", "content": system_message},
                        {"role": "user", "content": content}
                    ],
                    response_format={"type": "json_object"},
                    temperature=0.5,
                    max_tokens=512
                )
                
                raw_content = response.choices[0].message.content
                
                try:
                    translation_text = json.loads(raw_content)['translations']
                    translations.extend([f"{key} = \"{translation}\";" for key, translation in zip(chunk.keys(), translation_text)])
                except json.JSONDecodeError as e:
                    # Try multiple approaches to fix JSON parsing issues
                    fixed = False
                    
                    # Approach 1: Fix invalid Unicode escapes
                    try:
                        fixed_content = re.sub(r'\\u([0-9a-fA-F]{0,3}[^0-9a-fA-F])', r'\\\\u\1', raw_content)
                        translation_data = json.loads(fixed_content)['translations']
                        translations.extend([f"{key} = \"{translation}\";" for key, translation in zip(chunk.keys(), translation_data)])
                        fixed = True
                    except Exception:
                        pass
                    
                    # Approach 2: Manual parsing fallback
                    if not fixed:
                        try:
                            match = re.search(r'"translations"\s*:\s*\[(.*?)\]', raw_content, re.DOTALL)
                            if match:
                                translations_str = match.group(1)
                                manual_translations = []
                                parts = translations_str.split('","')
                                for part in parts:
                                    clean_part = part.strip().strip('"').strip("'")
                                    if clean_part:
                                        manual_translations.append(clean_part)
                                
                                translations.extend([f"{key} = \"{translation}\";" for key, translation in zip(chunk.keys(), manual_translations)])
                                fixed = True
                        except Exception:
                            pass
                    
                    if not fixed:
                        # Skip this batch on parsing failure
                        continue
                        
            except Exception as e:
                # Skip this batch on API failure
                continue
                
            pbar.update(1)
    
    return translations


def append_translations_to_file(file_path, translations):
    """Append translations to a Localizable.strings file."""
    with open(file_path, 'a', encoding='utf-8') as file:
        for translation in translations:
            file.write(f"\n{translation}")


def create_new_string_localization(master_keys_and_values, strings_base_path, lang_code, lang_name, translator, from_lang="English"):
    """Create a new localization directory and translate all strings."""
    new_dir = Path(strings_base_path).parent / f"{lang_code}.lproj"
    
    if new_dir.exists():
        print(f"  ⚠️  Localization directory {new_dir.name} already exists!")
        return False
    
    # Create directory
    new_dir.mkdir()
    loc_path = new_dir / "Localizable.strings"
    
    print(f"  📁 Creating new localization: {lang_name} ({lang_code})")
    print(f"  🔄 Translating {len(master_keys_and_values)} strings...")
    
    # Translate all strings
    translations = get_string_translations(master_keys_and_values, from_lang, lang_name, translator)
    
    # Write to new file
    with open(loc_path, 'w', encoding='utf-8') as file:
        file.write(f"/* {lang_name} Localization */\n\n")
        for translation in translations:
            file.write(f"{translation}\n")
    
    print(f"  ✅ Created {loc_path}")
    return True


def find_local_lproj_directories(strings_base_path):
    """Find existing .lproj directories."""
    base_path = Path(strings_base_path).parent
    localizations = {}
    
    for directory in base_path.iterdir():
        if directory.is_dir() and directory.name.endswith('.lproj'):
            loc_path = directory / "Localizable.strings"
            if loc_path.exists():
                lang_code = directory.name.replace('.lproj', '')
                localizations[lang_code] = {
                    'directory': directory,
                    'path': loc_path
                }
    
    return localizations


def map_appstore_to_lproj_locale(appstore_locale):
    """Convert App Store locale to .lproj directory name."""
    # Enhanced mapping for more locales
    mapping = {
        'en-US': 'en',
        'de-DE': 'de',
        'ja-JP': 'ja', 
        'ro-RO': 'ro',
        'ko-KR': 'ko',
        'es-ES': 'es',
        'es-MX': 'es',
        'fr-FR': 'fr',
        'it-IT': 'it',
        'pt-BR': 'pt',
        'ru-RU': 'ru',
        'zh-Hans': 'zh',
        'vi-VN': 'vi',
        'hi-IN': 'hi',
        'ar-SA': 'ar',
        'he-IL': 'he',
        'tr-TR': 'tr',
        'id-ID': 'id',
        'ms-MY': 'ms',
        'nl-NL': 'nl',
        'pl-PL': 'pl',
        'sv-SE': 'sv',
        'th-TH': 'th',
        'tl-PH': 'tl',
        'uk-UA': 'uk'
    }
    
    return mapping.get(appstore_locale, appstore_locale.split('-')[0])


def map_lproj_to_appstore_locale(lproj_code):
    """Convert .lproj directory name to App Store locale."""
    # Enhanced mapping for more locales
    mapping = {
        'en': 'en-US',
        'de': 'de-DE',
        'ja': 'ja-JP', 
        'ro': 'ro-RO',
        'ko': 'ko-KR',
        'es': 'es-ES',
        'fr': 'fr-FR',
        'it': 'it-IT',
        'pt': 'pt-BR',
        'ru': 'ru-RU',
        'zh': 'zh-Hans',
        'vi': 'vi-VN',
        'hi': 'hi-IN',
        'ar': 'ar-SA',
        'he': 'he-IL',
        'tr': 'tr-TR',
        'id': 'id-ID',
        'ms': 'ms-MY',
        'nl': 'nl-NL',
        'pl': 'pl-PL',
        'sv': 'sv-SE',
        'th': 'th-TH',
        'tl': 'tl-PH',
        'uk': 'uk-UA'
    }
    
    return mapping.get(lproj_code, f"{lproj_code}-{lproj_code.upper()}")


def check_and_create_missing_localizations(api, app_id, version_id, translator, strings_base_path):
    """Check for App Store localizations missing locally and create them."""
    if not strings_base_path or not Path(strings_base_path).exists():
        print("⚠️  Strings path not found, skipping string localization creation")
        return []
    
    print("\n🔍 Checking for missing string localizations...")
    
    # Get App Store localizations
    try:
        existing_localizations = api.get_version_localizations(version_id)
        appstore_locales = set(loc["attributes"]["locale"] for loc in existing_localizations)
    except Exception as e:
        print(f"❌ Error getting App Store localizations: {e}")
        return []
    
    # Get local .lproj directories
    local_localizations = find_local_lproj_directories(strings_base_path)
    local_locales = set(local_localizations.keys())
    
    # Convert App Store locales to .lproj format for comparison
    appstore_lproj_locales = set(map_appstore_to_lproj_locale(locale) for locale in appstore_locales)
    
    # Find missing localizations
    missing_locales = appstore_lproj_locales - local_locales
    
    if not missing_locales:
        print("🎉 All App Store localizations already exist locally!")
        return []
    
    # Load master strings
    master_file = Path(strings_base_path) / "Localizable.strings"
    if not master_file.exists():
        print(f"❌ Master strings file not found: {master_file}")
        return []
    
    master_keys_and_values = load_strings_from_file(master_file)
    if not master_keys_and_values:
        print("❌ No strings found in master file")
        return []
    
    print(f"📍 Found {len(missing_locales)} missing localization(s): {', '.join(sorted(missing_locales))}")
    print(f"📝 Master file has {len(master_keys_and_values)} strings to translate")
    
    # Ask for confirmation
    try:
        questions = [
            inquirer.Confirm('create_missing',
                           message=f"Create {len(missing_locales)} missing string localization(s)?",
                           default=True),
        ]
        
        if not inquirer.prompt(questions)['create_missing']:
            print("⏭️  String localization creation cancelled")
            return []
    except Exception:
        # Fallback if inquirer fails
        response = input(f"Create {len(missing_locales)} missing string localization(s)? (y/n): ").lower()
        if response not in ['y', 'yes']:
            print("⏭️  String localization creation cancelled")
            return []
    
    # Create missing localizations
    created_localizations = []
    language_name_map = {
        'de': 'German', 'ja': 'Japanese', 'ro': 'Romanian', 'ko': 'Korean',
        'es': 'Spanish', 'fr': 'French', 'it': 'Italian', 'pt': 'Portuguese',
        'ru': 'Russian', 'zh': 'Chinese', 'vi': 'Vietnamese', 'hi': 'Hindi',
        'ar': 'Arabic', 'he': 'Hebrew', 'tr': 'Turkish', 'id': 'Indonesian',
        'ms': 'Malay', 'nl': 'Dutch', 'pl': 'Polish', 'sv': 'Swedish',
        'th': 'Thai', 'tl': 'Tagalog', 'uk': 'Ukrainian'
    }
    
    for lang_code in sorted(missing_locales):
        lang_name = language_name_map.get(lang_code, lang_code.title())
        print(f"\n📝 Creating {lang_name} ({lang_code}.lproj)...")
        
        try:
            success = create_new_string_localization(
                master_keys_and_values, strings_base_path, lang_code, lang_name, translator
            )
            if success:
                created_localizations.append(lang_code)
        except Exception as e:
            print(f"  ❌ Error creating {lang_name} localization: {e}")
            continue
    
    if created_localizations:
        print(f"\n🎉 Successfully created {len(created_localizations)} string localization(s)!")
    
    return created_localizations


def load_yaml_config(file_path):
    """Load configuration from a YAML file."""
    try:
        with open(file_path, 'r', encoding='utf-8') as file:
            return yaml.safe_load(file)
    except Exception as e:
        print(f"❌ Error loading {file_path}: {e}")
        return None


def get_openai_api_key(config):
    """Get OpenAI API key from keychain or prompt user."""
    service_name = config.get("encamera_translation_openai_key", "encamera_translation_openai_key")
    key_name = config.get("encamera_translation_openai_key", "encamera_translation_openai_key")
    
    try:
        # Try to get the key from keychain
        api_key = keyring.get_password(service_name, key_name)
        
        if api_key:
            print("🔑 Found OpenAI API key in keychain")
            return api_key
        else:
            print("🔑 OpenAI API key not found in keychain")
            
    except Exception as e:
        print(f"⚠️  Could not access keychain: {e}")
    
    # Prompt user for API key
    print("Please enter your OpenAI API key:")
    api_key = getpass.getpass("API Key: ").strip()
    
    if not api_key:
        print("❌ Invalid API key")
        return None
    
    # Ask if user wants to save it to keychain
    try:
        questions = [
            inquirer.Confirm('save_to_keychain',
                           message="Save this API key to keychain for future use?",
                           default=True),
        ]
        
        if inquirer.prompt(questions)['save_to_keychain']:
            try:
                keyring.set_password(service_name, key_name, api_key)
                print(f"✅ API key saved to keychain as '{service_name}'")
            except Exception as e:
                print(f"⚠️  Could not save to keychain: {e}")
        
    except Exception as e:
        # Fallback if inquirer fails
        response = input("Save this API key to keychain for future use? (y/n): ").lower()
        if response in ['y', 'yes']:
            try:
                keyring.set_password(service_name, key_name, api_key)
                print(f"✅ API key saved to keychain as '{service_name}'")
            except Exception as e:
                print(f"⚠️  Could not save to keychain: {e}")
    
    return api_key


def find_existing_localization(target_locale, existing_locales):
    """Find existing localization with flexible matching."""
    # Exact match first
    if target_locale in existing_locales:
        return existing_locales[target_locale]
    
    # Case-insensitive match
    for locale, data in existing_locales.items():
        if locale.lower() == target_locale.lower():
            return data
    
    # Partial match (e.g., 'ja' matches 'ja-JP')
    target_base = target_locale.split('-')[0].lower()
    for locale, data in existing_locales.items():
        locale_base = locale.split('-')[0].lower()
        if target_base == locale_base:
            return data
    
    return None


def display_translation_preview(translations, all_languages):
    """Display a preview of content for all languages (base + translated)."""
    if not translations:
        print("🎉 No content to process!")
        return
    
    print("\n📋 Content Preview (Base Language + Translations)")
    print("=" * 80)
    
    for field_name, field_translations in translations.items():
        print(f"\n📝 {field_name.replace('_', ' ').title()}")
        print("-" * 40)
        
        # Create table data
        table_data = []
        for lang_code in all_languages:
            if lang_code in field_translations:
                content = field_translations[lang_code]
                # Truncate long content for display
                if len(content) > 100:
                    content = content[:97] + "..."
                
                # Determine if this is base language
                base_language_code = all_languages[0] if all_languages else ""
                language_type = "BASE" if lang_code == base_language_code else "TRANSLATED"
                display_name = f"{lang_code} ({language_type})"
                
                table_data.append([display_name, content])
        
        if table_data:
            print(tabulate(table_data, headers=["Language", "Content"], tablefmt="grid"))


def check_description_changed(api, app_id, base_language, local_description, version_id=None):
    """Check if the App Store description differs from the local config.
    
    Returns:
        tuple: (needs_translation: bool, app_store_description: str or None)
    """
    try:
        print("\n🔍 Checking if App Store description matches local config...")
        
        if not version_id:
            # Get app store versions
            versions = api.get_app_store_versions(app_id)
            if not versions:
                print("  ⚠️  No versions found, will proceed with translation")
                return True, None
            
            version_id = versions[0]["id"]
        
        # Get existing localizations
        existing_localizations = api.get_version_localizations(version_id)
        
        # Find base language localization
        app_store_description = None
        for loc in existing_localizations:
            locale = loc["attributes"]["locale"]
            if locale == base_language:
                app_store_description = loc["attributes"].get("description", "")
                break
        
        if app_store_description is None:
            print(f"  ⚠️  No {base_language} localization found in App Store, will proceed with translation")
            return True, None
        
        # Normalize both descriptions for comparison (strip whitespace)
        local_desc_normalized = local_description.strip() if local_description else ""
        app_store_desc_normalized = app_store_description.strip() if app_store_description else ""
        
        if local_desc_normalized == app_store_desc_normalized:
            print("  ✅ App Store description matches local config")
            return False, app_store_description
        else:
            print("  📝 App Store description differs from local config")
            # Show a preview of what changed
            local_preview = local_desc_normalized[:100] + "..." if len(local_desc_normalized) > 100 else local_desc_normalized
            app_store_preview = app_store_desc_normalized[:100] + "..." if len(app_store_desc_normalized) > 100 else app_store_desc_normalized
            print(f"     Local:     {local_preview}")
            print(f"     App Store: {app_store_preview}")
            return True, app_store_description
            
    except Exception as e:
        print(f"  ⚠️  Could not compare descriptions: {e}")
        print("  → Will proceed with translation to be safe")
        return True, None


def _build_api(credentials_path):
    """Load credentials and construct an AppStoreConnectAPI wrapper."""
    creds = Credentials.load(credentials_path)
    if not creds.bundle_id and not creds.app_id:
        raise ValueError("credentials.yml must set app.bundle_id or app.app_id")
    return AppStoreConnectAPI(creds), creds


def _print_401_help(creds):
    print("\n🔍 Troubleshooting 401 Unauthorized Error:")
    print("=" * 80)
    print("Apple rejected the API credentials. Common causes:")
    print()
    print(f"  • Key ID ({creds.key_id}) does not match the .p8 file (filename is AuthKey_<KEY_ID>.p8)")
    print(f"  • Issuer ID ({creds.issuer_id}) is wrong — find it under Users and Access > Integrations")
    print( "  • API key has been revoked, or lacks App Manager / Developer / Admin role")
    print( "  • Private key file is corrupted (whitespace/newlines must be preserved)")
    print()
    print("Verify at: https://appstoreconnect.apple.com/access/integrations/api")
    print("=" * 80)


def preflight_check(credentials_path):
    """Perform preflight checks to ensure App Store Connect API access."""
    print("\n🔍 Performing preflight checks...")

    try:
        api, creds = _build_api(credentials_path)
    except Exception as e:
        print(f"❌ Could not load credentials: {e}")
        return None, None

    try:
        client = api._client
        app_id = client.resolve_app_id()
        if creds.bundle_id:
            print(f"🔍 Testing connection with bundle ID: {creds.bundle_id}")
            app = api.find_app_by_bundle_id(creds.bundle_id)
        else:
            print(f"🔍 Testing connection with app ID: {app_id}")
            app = client.get(f"/v1/apps/{app_id}").get("data", {})
        print(f"✅ Successfully connected! App ID: {app_id}")

        print("🔍 Checking app store versions...")
        versions = api.get_app_store_versions(app_id)
        if not versions:
            print("❌ No app store versions found")
            return None, None
        version = versions[0]
        print(f"✅ Found {len(versions)} version(s). Latest: {version['attributes']['versionString']}")

        print("🔍 Checking existing localizations...")
        existing_localizations = api.get_version_localizations(version["id"])
        existing_locales = [loc["attributes"]["locale"] for loc in existing_localizations]
        print(f"✅ Found {len(existing_localizations)} existing localization(s): {', '.join(existing_locales)}")

        print("🎉 Preflight check passed! App Store Connect API is accessible.\n")
        return api, app

    except Exception as e:
        error_str = str(e)
        print(f"❌ Preflight check failed: {e}")
        if "401" in error_str or "Unauthorized" in error_str or "NOT_AUTHORIZED" in error_str:
            _print_401_help(creds)
        return None, None


class Localizer:
    """Translate and push App Store metadata from app_store.yml to App Store Connect.

    Importable from other scripts:

        from app_store_localization.localize import Localizer
        Localizer(config_path, credentials_path).run()
    """

    def __init__(
        self,
        config_path,
        credentials_path,
        *,
        dry_run=False,
        skip_preflight=False,
        auto_create_strings=False,
        force_retranslation=False,
        version_id=None,
        skip_confirmation=False,
    ):
        self.config_path = config_path
        self.credentials_path = credentials_path
        self.dry_run = dry_run
        self.skip_preflight = skip_preflight
        self.auto_create_strings = auto_create_strings
        self.force_retranslation = force_retranslation
        self.version_id = version_id
        self.skip_confirmation = skip_confirmation

    def run(self):
        print("🌍 App Store Localization Manager")
        print("=" * 40)

        if self.auto_create_strings:
            print("⚙️  Auto-create strings mode enabled")

        # Load configurations
        print(f"📁 Loading config from: {self.config_path}")
        app_store_config = load_yaml_config(self.config_path)
        if not app_store_config:
            return False

        print(f"📁 Loading credentials from: {self.credentials_path}")
        credentials_config = load_yaml_config(self.credentials_path)
        if not credentials_config:
            return False

        # Perform preflight check unless skipped
        if not self.skip_preflight:
            api, app = preflight_check(self.credentials_path)
            if not api or not app:
                print("❌ Preflight check failed. Aborting.")
                return False
            app_id = app["id"]
        else:
            print("⚠️  Skipping preflight check as requested")
            api = None
            app = None
            app_id = None

        # Get configurations
        listing = app_store_config.get("listing", {})
        target_languages = app_store_config.get("target_languages", [])
        base_language = app_store_config.get("base_language", "en-US")
        translation_config = app_store_config.get("translation", {})
        strings_path = app_store_config.get("strings_path")
    
        if not target_languages:
            print("❌ No target languages specified in config")
            return False
    
        # Extract base language code from locale (e.g., "en-US" -> "en")
        base_language_code = base_language.split("-")[0] if "-" in base_language else base_language
    
        # Create combined list of all languages to process (base + targets)
        all_languages = [base_language_code] + target_languages
        print(f"📝 Base language: {base_language} (code: {base_language_code})")
        print(f"🎯 Target languages: {', '.join(target_languages)}")
        print(f"🌍 All languages to process: {', '.join(all_languages)}")
    
        # Get OpenAI API key
        openai_config = credentials_config.get("openai", {})
        api_key = get_openai_api_key(openai_config)
        if not api_key:
            return False
    
        # Initialize translator
        translator = LocalizationTranslator(
            api_key=api_key,
            model=openai_config.get("model", "gpt-4"),
            max_tokens=openai_config.get("max_tokens", 2000),
            temperature=openai_config.get("temperature", 0.3)
        )
    
        # Check and create missing string localizations if requested
        if self.auto_create_strings:
            if not self.skip_preflight:
                # We have API and app info from preflight
                version = api.get_app_store_versions(app_id)[0] if api else None
                version_id = version["id"] if version else None
            
                if api and version_id and strings_path:
                    created_localizations = check_and_create_missing_localizations(
                        api, app_id, version_id, translator, strings_path
                    )
                else:
                    print("⚠️  Cannot create string localizations: missing API connection or strings path")
            else:
                print("⚠️  Cannot create string localizations when skipping preflight check")
    
        print(f"📋 Fields to process: {', '.join(listing.keys())}")
    
        # Check if description needs retranslation (to save OpenAI API tokens)
        skip_description_translation = False
        if not self.skip_preflight and api and app_id:
            local_description = listing.get("description", "")
        
            if self.force_retranslation:
                print("\n🔄 Force retranslation flag set - will translate all content")
            else:
                needs_translation, _ = check_description_changed(api, app_id, base_language, local_description, version_id=self.version_id)
                if not needs_translation:
                    skip_description_translation = True
                    print("  ⏭️  Will skip description translation to save API tokens")
                    print("     (Use --force-retranslation to override)")
    
        # Process content for all languages (translate for targets, use original for base)
        translations = {}
        context_note = translation_config.get("context_note", "")
    
        for field_name, content in listing.items():
            # Handle keywords specially - it's a dict keyed by locale
            if field_name == "keywords":
                if not content or not isinstance(content, dict):
                    continue

                print(f"\n🔄 Processing '{field_name}'...")
                field_translations = {}

                # Get base language keywords
                base_keywords = content.get(base_language)
                if not base_keywords:
                    print(f"  ⚠️  No base language keywords found for {base_language}")
                    continue

                # Check for pre-defined locale keywords first, translate the rest
                field_translations[base_language_code] = base_keywords
                print(f"  → {base_language_code} (base): ✅ Using original keywords")

                keywords_limit = app_store_config.get("limits", {}).get("keywords", 100)

                for lang_code in target_languages:
                    # Check if keywords are already defined for this locale in the config
                    if lang_code in content:
                        field_translations[lang_code] = content[lang_code]
                        print(f"  → {lang_code}: ✅ Using pre-defined keywords from config")
                    else:
                        print(f"  → {lang_code}...", end=" ")
                        keyword_context = (
                            f"{context_note} "
                            f"These are App Store keywords (comma-separated, max {keywords_limit} characters total including commas). "
                            f"Return ONLY the translated comma-separated keywords, no extra text. "
                            f"Keep the same number of keywords if possible. Do not add spaces after commas."
                        )
                        translated = translator.translate_content(
                            content=base_keywords,
                            from_lang="English",
                            to_lang=lang_code,
                            context_note=keyword_context
                        )

                        if translated:
                            # Ensure keywords fit within the character limit
                            if len(translated) > keywords_limit:
                                # Trim keywords from the end until within limit
                                parts = translated.split(",")
                                while len(",".join(parts)) > keywords_limit and len(parts) > 1:
                                    parts.pop()
                                translated = ",".join(parts)
                            field_translations[lang_code] = translated
                            print("✅")
                        else:
                            print("❌")

                if field_translations:
                    translations[field_name] = field_translations
                continue

            if not content or not content.strip():
                continue

            # Skip description translation if App Store content matches local config
            if field_name == "description" and skip_description_translation:
                print(f"\n⏭️  Skipping '{field_name}' translation - App Store content matches local config")
                continue

            print(f"\n🔄 Processing '{field_name}'...")
            field_translations = {}

            # Add base language content (no translation needed)
            field_translations[base_language_code] = content
            print(f"  → {base_language_code} (base): ✅ Using original content")

            # Translate for target languages
            for lang_code in target_languages:
                print(f"  → {lang_code}...", end=" ")

                translated = translator.translate_content(
                    content=content,
                    from_lang="English",  # Assuming base language is English
                    to_lang=lang_code,
                    context_note=context_note
                )

                if translated:
                    field_translations[lang_code] = translated
                    print("✅")
                else:
                    print("❌")

            if field_translations:
                translations[field_name] = field_translations
    
        # Display translation preview
        display_translation_preview(translations, all_languages)
    
        # Ask for confirmation unless dry run
        if self.dry_run:
            print("\n🔍 Dry run completed. No changes made to App Store.")
            return True
    
        if not translations:
            print("🎉 No translations to upload!")
            return False
    
        # Confirm before updating (skipped when driven by release.py, which
        # has already gated this with its own preflights and prompts)
        if self.skip_confirmation:
            print("⏭️  Skipping update confirmation (skip_confirmation=True)")
        else:
            questions = [
                inquirer.Confirm('proceed',
                               message="Proceed with updating App Store Connect metadata?",
                               default=True),
            ]

            answers = inquirer.prompt(questions)
            if not answers or not answers.get('proceed'):
                print("⏭️  Operation cancelled")
                return False
    
        print("\n🔄 Proceeding with App Store Connect API updates...")
    
        # Use API from preflight check or initialize new one if skipped
        if not api:
            try:
                api, creds = _build_api(self.credentials_path)
                app_id = api._client.resolve_app_id()
                print(f"✅ Using app ID: {app_id}")
            
                # Check and create missing string localizations if requested and API was just initialized
                if self.auto_create_strings:
                    version = api.get_app_store_versions(app_id)[0] if api else None
                    version_id = version["id"] if version else None
                
                    if version_id and strings_path:
                        created_localizations = check_and_create_missing_localizations(
                            api, app_id, version_id, translator, strings_path
                        )
                    else:
                        print("⚠️  Cannot create string localizations: missing version or strings path")
                    
            except Exception as e:
                print(f"❌ App Store Connect API error: {e}")
                return False
    
        # Resolve target version
        if self.version_id:
            version_id = self.version_id
            print(f"🔍 Using pre-resolved version ID: {version_id}")
        else:
            print("🔍 Getting app store versions...")
            try:
                versions = api.get_app_store_versions(app_id)
                if not versions:
                    print("❌ No app store versions found")
                    return False

                version = versions[0]
                version_id = version["id"]
                version_string = version["attributes"]["versionString"]
                print(f"✅ Using version: {version_string} (ID: {version_id})")
            except Exception as e:
                print(f"❌ Error getting app store versions: {e}")
                return False
    
        # Get existing localizations
        print("🔍 Getting existing localizations...")
        try:
            existing_localizations = api.get_version_localizations(version_id)
            existing_locales = {loc["attributes"]["locale"]: loc for loc in existing_localizations}
        
            print(f"📍 Found {len(existing_localizations)} existing localization(s):")
            for locale_code, loc_data in existing_locales.items():
                loc_id = loc_data.get("id", "unknown")
                print(f"  • {locale_code} (ID: {loc_id})")
        
        except Exception as e:
            print(f"❌ Error getting existing localizations: {e}")
            return False
        
        # Update or create localizations
        updated_count = 0
        created_count = 0
    
        for lang_code in all_languages:
            # Map language codes to App Store locales
            locale_mapping = {
                'en': base_language,  # Use the full base language locale (e.g., 'en-US')
                'de': 'de-DE',
                'ja': 'ja-JP', 
                'ro': 'ro-RO',
                'ko': 'ko-KR',
                'es': 'es-ES',
                'fr': 'fr-FR',
                'it': 'it-IT',
                'pt': 'pt-BR',
                'ru': 'ru-RU',
                'zh': 'zh-Hans'
            }
        
            locale = locale_mapping.get(lang_code, lang_code)
        
            # Special handling for base language
            is_base_language = lang_code == base_language_code
        
            if is_base_language:
                print(f"\n📝 Processing {lang_code} ({locale}) - BASE LANGUAGE...")
            else:
                print(f"\n📝 Processing {lang_code} ({locale}) - TRANSLATED...")
        
            # Try to find existing localization with flexible matching
            existing_loc = find_existing_localization(locale, existing_locales)
        
            if existing_loc:
                print(f"  📍 Found existing localization in cache")
            else:
                print(f"  📍 No existing localization found, will create new one")
                print(f"  🔍 Available locales: {list(existing_locales.keys())}")
                print(f"  🎯 Looking for: {locale}")
        
            # Prepare update data
            update_data = {}
            for field_name, field_translations in translations.items():
                if lang_code in field_translations:
                    if field_name == "description":
                        update_data["description"] = field_translations[lang_code]
                    elif field_name == "promotional_text":
                        update_data["promotional_text"] = field_translations[lang_code]
                    elif field_name == "whats_new":
                        update_data["whats_new"] = field_translations[lang_code]
                    elif field_name == "keywords":
                        update_data["keywords"] = field_translations[lang_code]
        
            if not update_data:
                if is_base_language:
                    print(f"  ⏭️  No content to update for base language {lang_code}")
                else:
                    print(f"  ⏭️  No translations for {lang_code}")
                continue
        
            try:
                if existing_loc:
                    # Update existing localization
                    localization_id = existing_loc["id"]
                    if is_base_language:
                        print(f"  🔄 Updating base language localization...")
                    else:
                        print(f"  🔄 Updating translated localization...")
                
                    result = api.update_localization(localization_id, **update_data)
                    updated_count += 1
                
                    if is_base_language:
                        print(f"  ✅ Updated base language localization for {locale}")
                    else:
                        print(f"  ✅ Updated translated localization for {locale}")
            
                else:
                    # Create new localization
                    if is_base_language:
                        print(f"  📝 Creating base language localization...")
                    else:
                        print(f"  📝 Creating new translated localization...")
                
                    result = api.create_localization(version_id, locale, **update_data)
                    created_count += 1
                
                    if is_base_language:
                        print(f"  ✅ Created base language localization for {locale}")
                    else:
                        print(f"  ✅ Created translated localization for {locale}")
        
            except Exception as e:
                # Handle 409 Conflict - localization already exists but wasn't in our list
                if "409" in str(e) and "Conflict" in str(e):
                    print(f"  ⚠️  Localization already exists (409 Conflict), refreshing and retrying...")
                
                    try:
                        # Refresh the existing localizations list
                        updated_localizations = api.get_version_localizations(version_id)
                        updated_locales = {loc["attributes"]["locale"]: loc for loc in updated_localizations}
                    
                        # Try to find it with flexible matching in the refreshed list
                        refreshed_loc = find_existing_localization(locale, updated_locales)
                    
                        if refreshed_loc:
                            # Found it now, update it
                            localization_id = refreshed_loc["id"]
                            actual_locale = None
                            for loc_key, loc_data in updated_locales.items():
                                if loc_data["id"] == localization_id:
                                    actual_locale = loc_key
                                    break
                        
                            print(f"  🔄 Found existing localization ({actual_locale}), updating...")
                        
                            result = api.update_localization(localization_id, **update_data)
                            updated_count += 1
                        
                            if is_base_language:
                                print(f"  ✅ Updated base language localization for {actual_locale or locale}")
                            else:
                                print(f"  ✅ Updated translated localization for {actual_locale or locale}")
                        
                            # Update our local cache for future iterations
                            if actual_locale:
                                existing_locales[actual_locale] = refreshed_loc
                        else:
                            print(f"  ❌ Still can't find localization for {locale} after refresh")
                            print(f"  🔍 Available after refresh: {list(updated_locales.keys())}")
                            continue
                        
                    except Exception as retry_error:
                        print(f"  ❌ Error on retry for {locale}: {retry_error}")
                        continue
                else:
                    # Other error
                    if is_base_language:
                        print(f"  ❌ Error processing base language {locale}: {e}")
                    else:
                        print(f"  ❌ Error processing translated {locale}: {e}")
                    continue
    
        print(f"\n🎉 Completed! Updated: {updated_count}, Created: {created_count} localizations")
        return True



def main():
    parser = argparse.ArgumentParser(
        description='Translate and update App Store metadata and create missing string localizations using OpenAI and App Store Connect API.',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Use specific config files
  python localize.py --config ./app_store.yml --credentials ./credentials.yml

  # Auto-detect config files in current directory
  python localize.py

  # Auto-create missing string localizations and update App Store metadata
  python localize.py --auto-create-strings

  # Force retranslation even if App Store description matches local config
  python localize.py --force-retranslation

    """
    )
    parser.add_argument('--config', type=str, help='Path to app_store.yml configuration file')
    parser.add_argument('--credentials', type=str, help='Path to credentials.yml file')
    parser.add_argument('--dry-run', action='store_true', help='Show translations without updating App Store')
    parser.add_argument('--skip-preflight', action='store_true', help='Skip preflight App Store Connect API check')
    parser.add_argument('--auto-create-strings', action='store_true', help='Automatically create missing string localizations from App Store')
    parser.add_argument('--force-retranslation', action='store_true', help='Force retranslation even if App Store description matches local config')
    args = parser.parse_args()

    config_path = args.config
    if not config_path:
        candidate = Path.cwd() / "app_store.yml"
        if candidate.exists():
            config_path = str(candidate)
        else:
            print("❌ Could not find app_store.yml. Please specify --config path.")
            return

    credentials_path = args.credentials
    if not credentials_path:
        candidate = Path.cwd() / "credentials.yml"
        if candidate.exists():
            credentials_path = str(candidate)
        else:
            print("❌ Could not find credentials.yml. Please specify --credentials path.")
            return

    Localizer(
        config_path,
        credentials_path,
        dry_run=args.dry_run,
        skip_preflight=args.skip_preflight,
        auto_create_strings=args.auto_create_strings,
        force_retranslation=args.force_retranslation,
    ).run()


if __name__ == '__main__':
    main()
