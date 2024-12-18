#!/usr/bin/env python3
import argparse
import base64
import json
import os
import struct
import subprocess

import nacl.encoding
from nacl.bindings.crypto_secretstream import (
    crypto_secretstream_xchacha20poly1305_init_pull,
    crypto_secretstream_xchacha20poly1305_pull)
from nacl.exceptions import CryptoError
from rich.console import Console
from rich.progress import Progress

HEADER_SIZE = 24
BLOCK_SIZE_SIZE = 8

console = Console()

def fetch_key_from_keychain(keychain_item):
    try:
        result = subprocess.run(
            ["security", "find-generic-password", "-w", "-s", keychain_item],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True
        )
        if result.returncode != 0:
            raise ValueError(f"Failed to fetch key: {result.stderr.strip()}")
        base64_key = result.stdout.strip()
        decoded = json.loads(base64.b64decode(base64_key))
        name = decoded.get('name')
        console.log(f'[green]Decoded: {name}[/green]')
        return bytes(decoded['keyBytes'])
    except Exception as e:
        console.log(f"[red]Error fetching key from keychain: {e}[/red]")
        raise

def decrypt_file(file_path, output_path, key):
    try:
        with open(file_path, 'rb') as f:
            # Read header
            header = f.read(HEADER_SIZE)
            if len(header) < HEADER_SIZE:
                raise ValueError("Invalid header in file")

            # Read block size
            block_size_info = f.read(BLOCK_SIZE_SIZE)
            if block_size_info is None or len(block_size_info) < 8:
                raise Exception("Invalid block size info in file")

            block_size = struct.unpack("<I", block_size_info[:4])[0]
            # Initialize the SecretStream with the key
            state = nacl.bindings.crypto_secretstream.crypto_secretstream_xchacha20poly1305_state()
            crypto_secretstream_xchacha20poly1305_init_pull(state, header, key)

            with open(output_path, 'wb') as output_file:
                while chunk := f.read(block_size):
                    try:
                        decrypted_data, tag  = crypto_secretstream_xchacha20poly1305_pull(state, chunk)
                        output_file.write(decrypted_data)
                    except CryptoError as e:
                        raise ValueError(f"Decryption failed: {e}")

                        # decrypted_data = box.decrypt(chunk, nonce=header)
                        output_file.write(decrypted_data)
                    except CryptoError as e:
                        raise ValueError(f"Decryption failed: {e}")

        console.log(f"[green]Successfully decrypted: {file_path}[/green]")
    except (ValueError, CryptoError) as e:
        console.log(f"[red]Failed to decrypt {file_path}: {e}[/red]")
        raise e
    except Exception as e:
        console.log(f"[red]Unexpected error decrypting {file_path}: {e}[/red]")


def decrypt_directory(target_directory, output_directory, key):
    if not os.path.exists(output_directory):
        os.makedirs(output_directory)

    files_to_decrypt = []
    for root, _, files in os.walk(target_directory):
        for file in files:
            input_path = os.path.join(root, file)
            output_path = os.path.join(output_directory, file)
            files_to_decrypt.append((input_path, output_path))

    with Progress() as progress:
        task = progress.add_task("Decrypting files...", total=len(files_to_decrypt))

        for input_path, output_path in files_to_decrypt:
            console.log(f"[blue]Decrypting: {input_path}[/blue]")
            decrypt_file(input_path, output_path, key)
            progress.advance(task)


def main():
    parser = argparse.ArgumentParser(description="Decrypt files in a directory.")
    parser.add_argument("target_directory", help="Directory containing files to decrypt")
    parser.add_argument("output_directory", help="Directory to save decrypted files")
    parser.add_argument("--keychain-item", required=True, help="Keychain item name to fetch the decryption key")

    args = parser.parse_args()

    console.log(f"[cyan]Fetching decryption key from keychain item: {args.keychain_item}[/cyan]")
    key = fetch_key_from_keychain(args.keychain_item)

    console.log(f"[cyan]Starting decryption for directory: {args.target_directory}[/cyan]")
    decrypt_directory(args.target_directory, args.output_directory, key)


if __name__ == "__main__":
    main()
