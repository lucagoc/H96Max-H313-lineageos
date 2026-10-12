#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RESOURCES_LIST="${1:-$PROJECT_ROOT/resources.list}"

if [ ! -f "$RESOURCES_LIST" ]; then
    echo "[!] Resources file not found: $RESOURCES_LIST"
    exit 1
fi

echo "[*] Checking resources from $(basename "$RESOURCES_LIST")..."

while IFS= read -r line || [ -n "$line" ]; do
    # Ignore comments and empty lines
    line="$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [[ -z "$line" || "$line" =~ ^# ]] && continue

    # Parse columns: target_path, url, optional sha256
    read -r target_rel url expected_hash extra <<< "$line"

    if [ -z "$target_rel" ] || [ -z "$url" ]; then
        continue
    fi

    target_path="$PROJECT_ROOT/$target_rel"
    target_dir="$(dirname "$target_path")"

    need_download=false

    if [ ! -f "$target_path" ]; then
        echo "[+] Missing file: $target_rel"
        need_download=true
    elif [ -n "$expected_hash" ]; then
        actual_hash="$(sha256sum "$target_path" | awk '{print $1}')"
        if [ "$actual_hash" != "$expected_hash" ]; then
            echo "[!] Hash mismatch for $target_rel (expected: $expected_hash, got: $actual_hash)"
            need_download=true
        fi
    fi

    if [ "$need_download" = true ]; then
        if [[ "$url" =~ ^https?://example\.com ]]; then
            echo "[!] Cannot download $target_rel: URL is a placeholder ($url)."
            echo "    Please configure a valid URL in $(basename "$RESOURCES_LIST")."
            exit 1
        fi

        mkdir -p "$target_dir"
        echo "[*] Downloading $target_rel from $url..."
        tmp_file="${target_path}.tmp.$$"
        
        if command -v curl >/dev/null 2>&1; then
            curl -fL --progress-bar -o "$tmp_file" "$url"
        elif command -v wget >/dev/null 2>&1; then
            wget --show-progress -O "$tmp_file" "$url"
        else
            echo "[!] Error: Neither curl nor wget is installed."
            rm -f "$tmp_file"
            exit 1
        fi

        if [ -n "$expected_hash" ]; then
            downloaded_hash="$(sha256sum "$tmp_file" | awk '{print $1}')"
            if [ "$downloaded_hash" != "$expected_hash" ]; then
                echo "[!] Error: Hash verification failed for downloaded $target_rel."
                rm -f "$tmp_file"
                exit 1
            fi
        fi

        mv "$tmp_file" "$target_path"
        echo "[✓] Downloaded $target_rel successfully."
    else
        echo "[✓] Resource present: $target_rel"
    fi
done < "$RESOURCES_LIST"

echo "[✓] All resources checked."
