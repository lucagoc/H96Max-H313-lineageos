#!/usr/bin/env python3
"""
boot_resource.py - Utility to inspect, extract, and update bootlogo.bmp in Allwinner boot-resource.fex
"""

import sys
import os
import struct
import argparse
from pathlib import Path

def get_fat16_info(data):
    boot = data[:512]
    bytes_per_sec = struct.unpack('<H', boot[11:13])[0]
    sec_per_clus = boot[13]
    cluster_size = bytes_per_sec * sec_per_clus
    res_sec = struct.unpack('<H', boot[14:16])[0]
    fats = boot[16]
    root_ent = struct.unpack('<H', boot[17:19])[0]
    sec_per_fat = struct.unpack('<H', boot[22:24])[0]
    
    fat_offset = res_sec * bytes_per_sec
    root_dir_offset = fat_offset + fats * sec_per_fat * bytes_per_sec
    data_offset = root_dir_offset + root_ent * 32
    
    return {
        'bytes_per_sec': bytes_per_sec,
        'sec_per_clus': sec_per_clus,
        'cluster_size': cluster_size,
        'res_sec': res_sec,
        'fats': fats,
        'root_ent': root_ent,
        'sec_per_fat': sec_per_fat,
        'fat_offset': fat_offset,
        'root_dir_offset': root_dir_offset,
        'data_offset': data_offset,
    }

def convert_to_bmp_if_needed(image_path, target_width=1280, target_height=720):
    """Ensure the image is in 1280x720 24-bit uncompressed BMP format."""
    with open(image_path, 'rb') as f:
        header = f.read(54)
    
    # Check if already a valid BMP of target dimensions, 24bpp, and standard 54-byte header
    is_valid_bmp = False
    if len(header) >= 54 and header[:2] == b'BM':
        offset = struct.unpack('<I', header[10:14])[0]
        info_size = struct.unpack('<I', header[14:18])[0]
        w, h, planes, bpp, comp = struct.unpack('<iiHHI', header[18:34])
        if w == target_width and abs(h) == target_height and bpp == 24 and comp == 0 and offset == 54 and info_size == 40:
            is_valid_bmp = True

    if is_valid_bmp:
        with open(image_path, 'rb') as f:
            return f.read()

    # Otherwise convert with Pillow
    try:
        from PIL import Image
    except ImportError:
        raise RuntimeError(
            f"Image '{image_path}' is not a 1280x720 24-bit uncompressed BMP, "
            "and Python Pillow (PIL) is not installed to auto-convert it. "
            "Please convert it to 1280x720 24-bit BMP manually."
        )

    print(f"[*] Converting '{image_path}' to {target_width}x{target_height} 24-bit BMP...")
    img = Image.open(image_path).convert('RGB')
    if img.size != (target_width, target_height):
        img = img.resize((target_width, target_height), Image.Resampling.LANCZOS)
    
    import io
    buf = io.BytesIO()
    img.save(buf, format='BMP')
    return buf.getvalue()

def update_bootlogo(fex_path, image_path, out_fex_path=None, target_name="BOOTLOGO", target_ext="BMP"):
    if out_fex_path is None:
        out_fex_path = fex_path

    with open(fex_path, 'rb') as f:
        fex_data = bytearray(f.read())

    info = get_fat16_info(fex_data)
    cluster_size = info['cluster_size']
    fat_offset = info['fat_offset']
    root_dir_offset = info['root_dir_offset']
    data_offset = info['data_offset']
    fats = info['fats']
    sec_per_fat = info['sec_per_fat']
    bytes_per_sec = info['bytes_per_sec']

    new_bmp_bytes = convert_to_bmp_if_needed(image_path)
    new_size = len(new_bmp_bytes)

    target_bytes_name = target_name.encode('latin1').ljust(8)[:8]
    target_bytes_ext = target_ext.encode('latin1').ljust(3)[:3]

    entry_offset = None
    orig_cluster = None
    orig_size = None

    for i in range(info['root_ent']):
        ent_off = root_dir_offset + i * 32
        e = fex_data[ent_off:ent_off+32]
        if e[0] in (0x00, 0xe5) or e[11] == 0x0f:
            continue
        if e[:8] == target_bytes_name and e[8:11] == target_bytes_ext:
            entry_offset = ent_off
            orig_cluster = struct.unpack('<H', e[26:28])[0]
            orig_size = struct.unpack('<I', e[28:32])[0]
            break

    if entry_offset is None:
        raise ValueError(f"Entry {target_name}.{target_ext} not found in root directory of {fex_path}")

    clus = orig_cluster
    orig_clusters = []
    while clus < 0xfff8 and clus != 0:
        orig_clusters.append(clus)
        fat_ent_off = fat_offset + clus * 2
        clus = struct.unpack('<H', fex_data[fat_ent_off:fat_ent_off+2])[0]

    needed_clusters = (new_size + cluster_size - 1) // cluster_size

    if needed_clusters > len(orig_clusters):
        raise ValueError(
            f"New image size ({new_size} bytes, {needed_clusters} clusters) "
            f"exceeds available clusters ({len(orig_clusters)} clusters, {len(orig_clusters) * cluster_size} bytes)."
        )

    # Write data chunks to clusters
    for i in range(needed_clusters):
        c = orig_clusters[i]
        c_offset = data_offset + (c - 2) * cluster_size
        chunk = new_bmp_bytes[i*cluster_size:(i+1)*cluster_size]
        fex_data[c_offset:c_offset+len(chunk)] = chunk
        if len(chunk) < cluster_size:
            fex_data[c_offset+len(chunk):c_offset+cluster_size] = b'\x00' * (cluster_size - len(chunk))

    # Update FAT chains
    for f_idx in range(fats):
        cur_fat_off = fat_offset + f_idx * sec_per_fat * bytes_per_sec
        for i in range(len(orig_clusters)):
            c = orig_clusters[i]
            ent_pos = cur_fat_off + c * 2
            if i < needed_clusters - 1:
                fex_data[ent_pos:ent_pos+2] = struct.pack('<H', orig_clusters[i+1])
            elif i == needed_clusters - 1:
                fex_data[ent_pos:ent_pos+2] = struct.pack('<H', 0xffff)
            else:
                fex_data[ent_pos:ent_pos+2] = struct.pack('<H', 0x0000)

    # Update directory entry file size
    fex_data[entry_offset+28:entry_offset+32] = struct.pack('<I', new_size)

    with open(out_fex_path, 'wb') as out_f:
        out_f.write(fex_data)

    print(f"[+] Successfully replaced {target_name}.{target_ext} in {out_fex_path} ({new_size} bytes)")

def extract_all(fex_path, out_dir):
    with open(fex_path, 'rb') as f:
        fex_data = f.read()

    info = get_fat16_info(fex_data)
    cluster_size = info['cluster_size']
    fat_offset = info['fat_offset']
    root_dir_offset = info['root_dir_offset']
    data_offset = info['data_offset']
    sec_per_fat = info['sec_per_fat']
    bytes_per_sec = info['bytes_per_sec']

    fat_data = fex_data[fat_offset:fat_offset + sec_per_fat * bytes_per_sec]

    def read_clusters(start_clus, size):
        curr = start_clus
        buf = bytearray()
        while curr < 0xfff8 and len(buf) < size:
            offset = data_offset + (curr - 2) * cluster_size
            buf.extend(fex_data[offset:offset + min(cluster_size, size - len(buf))])
            curr = struct.unpack('<H', fat_data[curr*2:(curr+1)*2])[0]
        return bytes(buf)

    def process_dir(dir_offset, num_entries, current_out):
        os.makedirs(current_out, exist_ok=True)
        entries = fex_data[dir_offset:dir_offset + num_entries * 32]
        lfn = {}
        for i in range(num_entries):
            e = entries[i*32:(i+1)*32]
            if e[0] == 0: break
            if e[0] == 0xe5: continue
            attr = e[11]
            if attr == 0x0f:
                seq = e[0] & 0x1f
                chars = e[1:11] + e[14:26] + e[28:32]
                lfn[seq] = chars.decode('utf-16le', errors='ignore').split('\x00')[0]
                continue
            name = ''.join(lfn[k] for k in sorted(lfn.keys())) if lfn else (e[:8].decode('latin1').strip() + (('.' + e[8:11].decode('latin1').strip()) if e[8:11].strip() else ''))
            lfn.clear()
            start_clus = struct.unpack('<H', e[26:28])[0]
            size = struct.unpack('<I', e[28:32])[0]
            if attr & 0x10:
                if name not in ('.', '..') and start_clus != 0:
                    process_dir(data_offset + (start_clus - 2) * cluster_size, 128, os.path.join(current_out, name))
            else:
                if size > 0 and start_clus != 0:
                    data = read_clusters(start_clus, size)
                    file_path = os.path.join(current_out, name)
                    with open(file_path, 'wb') as out_f:
                        out_f.write(data)
                    print(f"  [>] Extracted: {file_path} ({size} bytes)")

    print(f"[*] Extracting '{fex_path}' to '{out_dir}'...")
    process_dir(root_dir_offset, info['root_ent'], out_dir)
    print("[+] Done.")

def main():
    parser = argparse.ArgumentParser(description="Tool to extract or replace bootlogo in Allwinner boot-resource.fex")
    subparsers = parser.add_subparsers(dest="command", required=True)

    # Extract command
    parser_extract = subparsers.add_parser("extract", help="Extract all files from boot-resource.fex")
    parser_extract.add_argument("fex", help="Path to boot-resource.fex")
    parser_extract.add_argument("-o", "--out", default="boot_resource_dump", help="Destination folder (default: boot_resource_dump)")

    # Replace command
    parser_replace = subparsers.add_parser("replace", help="Replace bootlogo.bmp in boot-resource.fex")
    parser_replace.add_argument("fex", help="Path to boot-resource.fex")
    parser_replace.add_argument("image", help="Path to new image (PNG, JPG, BMP)")
    parser_replace.add_argument("-o", "--out", default=None, help="Output fex path (overwrites original if not specified)")

    args = parser.parse_args()
    if args.command == "extract":
        extract_all(args.fex, args.out)
    elif args.command == "replace":
        update_bootlogo(args.fex, args.image, args.out)

if __name__ == "__main__":
    main()
