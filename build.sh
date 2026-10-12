#!/bin/bash
set -e

# ==============================================================================
# Argument handling
# ==============================================================================
BUILD_ALL=false
SELECTED_VARIANT="vanilla"


SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

LIB_DIR="$SCRIPT_DIR/lib"
LAYER_DIR="$SCRIPT_DIR/layers"
LAYERS_CONF="$LAYER_DIR/layers.conf"
BASE_PHOENIX="$SCRIPT_DIR/phoenix.img"
CACHE_DIR="$SCRIPT_DIR/cache"

BOOT_RESOURCE_TOOL="$LIB_DIR/boot_resource.py"
IMGREPACKER="$LIB_DIR/imgrepacker/imgrepacker"

TARGET_DEVICE="H96Max_H313"
OUTPUT_DIR="$SCRIPT_DIR/output"

# Parse configuration file for available variants
declare -A VARIANT_LAYERS
AVAILABLE_VARIANTS=()

if [ -f "$LAYERS_CONF" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [ -z "${line// }" ] && continue

        if [[ "$line" =~ ^([a-zA-Z0-9_-]+)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
            var_name="${BASH_REMATCH[1]}"
            layers_val="${BASH_REMATCH[2]}"
            VARIANT_LAYERS["$var_name"]="$layers_val"
            AVAILABLE_VARIANTS+=("$var_name")
        fi
    done < "$LAYERS_CONF"
fi

show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo "Options:"
    echo "  --variant <name>        Build a specific variant (available: ${AVAILABLE_VARIANTS[*]:-none}) [default: vanilla]"
    echo "  --all                   Build all configured variants sequentially"
    echo "  --help, -h              Show this help message"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --variant)
            SELECTED_VARIANT="$2"
            shift 2
            ;;
        --all)
            BUILD_ALL=true
            shift
            ;;
        --help|-h)
            show_help
            exit 0
            ;;
        *)
            echo "[!] Error: Unknown argument '$1'"
            show_help
            exit 1
            ;;
    esac
done

# Prerequisites check
command -v lpmake >/dev/null 2>&1 || { echo "[!] Error: lpmake is required but not found in PATH."; exit 1; }
command -v lpunpack >/dev/null 2>&1 || { echo "[!] Error: lpunpack is required but not found in PATH."; exit 1; }
command -v simg2img >/dev/null 2>&1 || { echo "[!] Error: simg2img is required but not found in PATH."; exit 1; }
command -v e2fsck >/dev/null 2>&1 || { echo "[!] Error: e2fsck is required but not found in PATH."; exit 1; }
command -v resize2fs >/dev/null 2>&1 || { echo "[!] Error: resize2fs is required but not found in PATH."; exit 1; }
[ -x "$IMGREPACKER" ] || { echo "[!] Error: imgrepacker not found or not executable in $LIB_DIR/imgrepacker"; exit 1; }

# Check and fetch external resources if needed
if [ -f "$SCRIPT_DIR/lib/fetch_resources.sh" ]; then
    "$SCRIPT_DIR/lib/fetch_resources.sh"
fi

if [ ! -f "$BASE_PHOENIX" ]; then
    echo "[!] Error: Missing required base firmware image: $BASE_PHOENIX"
    exit 1
fi

# ==============================================================================
# Helper functions: Cache extraction of stock partitions
# ==============================================================================
ensure_stock_partitions() {
    mkdir -p "$CACHE_DIR"
    local stock_parts_dir="$CACHE_DIR/stock_partitions"
    local cache_marker="$stock_parts_dir/.extracted_ok"

    if [ -f "$cache_marker" ] && [ "$stock_parts_dir" -nt "$BASE_PHOENIX" ]; then
        return 0
    fi

    echo "[*] Extracting stock partitions from $BASE_PHOENIX into cache..."
    rm -rf "$stock_parts_dir"
    mkdir -p "$stock_parts_dir"

    local tmp_dump="$CACHE_DIR/.phoenix_dump_tmp"
    rm -rf "$tmp_dump"
    mkdir -p "$tmp_dump"

    cp "$BASE_PHOENIX" "$tmp_dump/phoenix.img"
    (
        cd "$tmp_dump"
        "$IMGREPACKER" phoenix.img >/dev/null 2>&1
    )

    local super_fex="$tmp_dump/phoenix.img.dump/super.fex"
    if [ ! -f "$super_fex" ]; then
        echo "[!] Error: super.fex not found in phoenix.img dump."
        rm -rf "$tmp_dump"
        exit 1
    fi

    local raw_super="$tmp_dump/super_raw.img"
    if file "$super_fex" | grep -q "sparse image"; then
        simg2img "$super_fex" "$raw_super"
    else
        cp --sparse=always "$super_fex" "$raw_super"
    fi

    lpunpack "$raw_super" "$stock_parts_dir" >/dev/null

    # Cleanup temporary dump
    rm -rf "$tmp_dump"
    touch "$cache_marker"
    echo "[*] Stock partitions extracted successfully."
}

# ==============================================================================
# Helper functions for overlaying partitions
# ==============================================================================
apply_remove_list() {
    local remove_file="$1"
    local layer_name="$2"
    # TARGET_PARTITIONS is an associative array (part_name -> image_path) in scope

    if [ -f "$remove_file" ]; then
        echo "  [-] Applying removals from $layer_name (${remove_file#$SCRIPT_DIR/})..."
        while IFS= read -r item || [ -n "$item" ]; do
            [[ "$item" =~ ^[[:space:]]*# ]] && continue
            [ -z "${item// }" ] && continue

            local clean_path="${item#/}"
            local target_part="${clean_path%%/*}"
            local rel_in_part="${clean_path#*/}"

            local target_img="${TARGET_PARTITIONS["$target_part"]}"
            local path_in_img=""

            if [ -n "$target_img" ]; then
                # SAR partitions like system have internal root /system/...
                if [ "$target_part" = "system" ]; then
                    path_in_img="/system/$rel_in_part"
                else
                    path_in_img="/$rel_in_part"
                fi
            elif [ -n "${TARGET_PARTITIONS["system"]}" ]; then
                # Fallback to system partition if no prefix matched
                target_img="${TARGET_PARTITIONS["system"]}"
                path_in_img="/system/$clean_path"
                target_part="system"
            else
                echo "      [!] Unknown target partition for item '$item', skipping."
                continue
            fi

            echo "      [-] Removing: $path_in_img ($target_part)"
            subfiles=$(debugfs -R "ls -l $path_in_img" "$target_img" 2>/dev/null | awk '{print $NF}' | grep -v '^\.\.?$' || true)
            for sf in $subfiles; do
                debugfs -w -R "rm $path_in_img/$sf" "$target_img" >/dev/null 2>&1 || true
                debugfs -w -R "rmdir $path_in_img/$sf" "$target_img" >/dev/null 2>&1 || true
            done

            debugfs -w -R "rm $path_in_img" "$target_img" >/dev/null 2>&1 || true
            debugfs -w -R "rmdir $path_in_img" "$target_img" >/dev/null 2>&1 || true
        done < "$remove_file"
    fi
}

apply_partition_overlay() {
    local part_dir="$1"
    local part="$2"
    local layer_label="$3"

    local target_img="${TARGET_PARTITIONS["$part"]}"
    if [ -z "$target_img" ] || [ ! -f "$target_img" ]; then
        echo "      [!] Target image for partition '$part' not found, skipping overlay."
        return 0
    fi

    [ -d "$part_dir" ] || return 0
    [ -n "$(ls -A "$part_dir" 2>/dev/null)" ] || return 0

    local default_dir_ctx="u:object_r:system_file:s0"
    local default_file_ctx="u:object_r:system_file:s0"

    case "$part" in
        vendor)
            default_dir_ctx="u:object_r:vendor_file:s0"
            default_file_ctx="u:object_r:vendor_file:s0"
            ;;
        *)
            default_dir_ctx="u:object_r:system_file:s0"
            default_file_ctx="u:object_r:system_file:s0"
            ;;
    esac

    echo "  [+] Applying overlay files for partition '$part': $layer_label"

    cd "$part_dir"
    find . -type f | while read -r file; do
        [[ "$file" =~ README.* ]] && continue
        [[ "$file" == "./remove.list" ]] && continue
        [[ "$file" == "./selinux.list" ]] && continue

        rel_path="${file#./}"

        local path_in_img=""
        if [ "$part" = "system" ]; then
            path_in_img="/system/$rel_path"
        else
            path_in_img="/$rel_path"
        fi

        dir_path="$(dirname "$path_in_img")"
        if [ "$dir_path" != "/" ]; then
            IFS='/' read -ra PARTS <<< "${dir_path#/}"
            curr=""
            for p in "${PARTS[@]}"; do
                curr="$curr/$p"
                debugfs -w -R "mkdir $curr" "$target_img" >/dev/null 2>&1 || true
                debugfs -w -R "ea_set $curr security.selinux $default_dir_ctx" "$target_img" >/dev/null 2>&1 || true
            done
        fi

        local file_ctx="$default_file_ctx"
        local lookup_full="/$part/$rel_path"
        local lookup_in_img="$path_in_img"

        if [ -n "${selinux_overrides["$lookup_full"]}" ]; then
            file_ctx="${selinux_overrides["$lookup_full"]}"
        elif [ -n "${selinux_overrides["$lookup_in_img"]}" ]; then
            file_ctx="${selinux_overrides["$lookup_in_img"]}"
        elif [ -n "${selinux_overrides["/$rel_path"]}" ]; then
            file_ctx="${selinux_overrides["/$rel_path"]}"
        fi

        echo "     [+] Writing: $path_in_img [$file_ctx] ($part)"
        debugfs -w -R "rm $path_in_img" "$target_img" >/dev/null 2>&1 || true
        debugfs -w -R "write $part_dir/$rel_path $path_in_img" "$target_img" >/dev/null 2>&1
        if [[ "$rel_path" =~ (^|/)bin/ ]] || [ -x "$part_dir/$rel_path" ]; then
            debugfs -w -R "set_inode_field $path_in_img mode 0100755" "$target_img" >/dev/null 2>&1
        else
            debugfs -w -R "set_inode_field $path_in_img mode 0100644" "$target_img" >/dev/null 2>&1
        fi
        debugfs -w -R "ea_set $path_in_img security.selinux $file_ctx" "$target_img" >/dev/null 2>&1 || true
    done
    cd "$PROJECT_ROOT"
}

apply_layer() {
    local layer="$1"
    local layer_work_dir="$2"

    local layer_path="$layer_work_dir/$layer"
    if [ ! -d "$layer_path" ]; then
        echo "  [!] Warning: Layer directory '$layer_path' not found. Skipping."
        return 0
    fi

    echo "  ==> Processing layer: $layer"

    declare -A selinux_overrides

    # Load SELinux overrides from layer super directory or layer root
    local selinux_candidates=(
        "$layer_path/super/selinux.list"
        "$layer_path/selinux.list"
    )
    for cand in "${selinux_candidates[@]}"; do
        if [ -f "$cand" ]; then
            echo "      [*] Loading SELinux overrides from ${cand#$SCRIPT_DIR/}..."
            while IFS= read -r line || [ -n "$line" ]; do
                [[ "$line" =~ ^[[:space:]]*# ]] && continue
                [ -z "${line// }" ] && continue

                pattern=$(echo "$line" | awk '{print $1}')
                context=$(echo "$line" | awk '{print $2}')

                if [ -n "$pattern" ] && [ -n "$context" ]; then
                    clean_p="${pattern#/}"
                    selinux_overrides["/$clean_p"]="$context"
                fi
            done < "$cand"
        fi
    done

    # 1. Apply layer removals
    local remove_candidates=(
        "$layer_path/super/remove.list"
        "$layer_path/remove.list"
    )
    for rcand in "${remove_candidates[@]}"; do
        if [ -f "$rcand" ]; then
            apply_remove_list "$rcand" "$layer"
        fi
    done

    # Also check partition-specific remove.list files (e.g. super/<partition>/remove.list)
    local super_base="$layer_path"
    [ -d "$layer_path/super" ] && super_base="$layer_path/super"

    for part_name in "${ALL_PARTITIONS[@]}"; do
        if [ -f "$super_base/$part_name/remove.list" ]; then
            apply_remove_list "$super_base/$part_name/remove.list" "$layer ($part_name)"
        fi
        if [ -f "$super_base/$part_name/selinux.list" ]; then
            while IFS= read -r line || [ -n "$line" ]; do
                [[ "$line" =~ ^[[:space:]]*# ]] && continue
                [ -z "${line// }" ] && continue

                pattern=$(echo "$line" | awk '{print $1}')
                context=$(echo "$line" | awk '{print $2}')

                if [ -n "$pattern" ] && [ -n "$context" ]; then
                    clean_p="${pattern#/}"
                    # If pattern is relative to partition, prefix with partition name
                    if [[ ! "$clean_p" =~ ^$part_name/ ]]; then
                        selinux_overrides["/$part_name/$clean_p"]="$context"
                    else
                        selinux_overrides["/$clean_p"]="$context"
                    fi
                fi
            done < "$super_base/$part_name/selinux.list"
        fi
    done

    # 2. Apply partition overlay folders
    local applied_partition=false
    for part in "${ALL_PARTITIONS[@]}"; do
        if [ -d "$super_base/$part" ]; then
            apply_partition_overlay "$super_base/$part" "$part" "$layer"
            applied_partition=true
        fi
    done

    # Fallback for legacy layers without partition subdirectories
    if [ "$applied_partition" = false ] && [ -d "$super_base" ]; then
        apply_partition_overlay "$super_base" "system" "$layer"
    fi
}

# ==============================================================================
# Build single variant function
# ==============================================================================
build_variant() {
    local variant="$1"
    local layers_raw="${VARIANT_LAYERS["$variant"]}"

    if [ -z "$layers_raw" ]; then
        echo "[!] Error: Unknown variant '$variant'. Configured variants: ${AVAILABLE_VARIANTS[*]}"
        return 1
    fi

    # Parse layers list (comma or space separated)
    IFS=',' read -ra RAW_LAYERS <<< "$layers_raw"
    local layers_to_apply=()
    for l in "${RAW_LAYERS[@]}"; do
        trimmed="$(echo "$l" | xargs)"
        [ -n "$trimmed" ] && layers_to_apply+=("$trimmed")
    done

    # Setup versioning and naming
    local build_date_tag
    build_date_tag="$(date +"%Y%m%d")"
    local build_date_full
    build_date_full="$(date)"
    local build_epoch
    build_epoch="$(date +%s)"

    local lineage_ver="18.1-${build_date_tag}-UNOFFICIAL-${variant}"
    local final_img="$OUTPUT_DIR/lineage-18.1-${TARGET_DEVICE}-${build_date_tag}-UNOFFICIAL-${variant}.img"

    local build_dir="$SCRIPT_DIR/.build_tmp_${variant}"
    mkdir -p "$build_dir"
    mkdir -p "$OUTPUT_DIR"

    echo ""
    echo "================================================================================"
    echo "  BUILDING VARIANT: $variant"
    echo "  LineageOS Version: $lineage_ver"
    echo "  Layers to apply: ${layers_to_apply[*]}"
    echo "  Output target: $final_img"
    echo "================================================================================"

    # Ensure stock partitions are cached
    ensure_stock_partitions
    local stock_parts_dir="$CACHE_DIR/stock_partitions"

    # Identify all partitions to handle
    declare -A TARGET_PARTITIONS
    ALL_PARTITIONS=()

    # Discover partitions from cached stock partitions
    for part_img in "$stock_parts_dir"/*.img; do
        if [ -f "$part_img" ]; then
            local pname
            pname="$(basename "$part_img" .img)"
            ALL_PARTITIONS+=("$pname")
        fi
    done

    # Discover any additional partitions provided in layers
    for layer in "${layers_to_apply[@]}"; do
        local l_path="$LAYER_DIR/$layer"
        local s_path="$l_path"
        [ -d "$l_path/super" ] && s_path="$l_path/super"

        # Check for standalone *.img files (e.g. system.img)
        for part_img in "$s_path"/*.img; do
            if [ -f "$part_img" ]; then
                local pname
                pname="$(basename "$part_img" .img)"
                if [[ ! " ${ALL_PARTITIONS[*]} " =~ " ${pname} " ]]; then
                    ALL_PARTITIONS+=("$pname")
                fi
            fi
        done

        # Check for partition directories (e.g. super/system, super/vendor, etc.)
        for d in "$s_path"/*; do
            if [ -d "$d" ]; then
                local dname
                dname="$(basename "$d")"
                if [[ ! " ${ALL_PARTITIONS[*]} " =~ " ${dname} " ]]; then
                    ALL_PARTITIONS+=("$dname")
                fi
            fi
        done
    done

    # 1. Prepare images in build_dir
    echo "[1/5] Preparing partition images (${ALL_PARTITIONS[*]})..."
    for part in "${ALL_PARTITIONS[@]}"; do
        local out_part_img="$build_dir/${part}.img"
        local base_source=""

        # Check if layer provides custom base partition image (last layer takes precedence)
        for layer in "${layers_to_apply[@]}"; do
            local l_super="$LAYER_DIR/$layer/super"
            [ ! -d "$l_super" ] && l_super="$LAYER_DIR/$layer"
            if [ -f "$l_super/${part}.img" ]; then
                base_source="$l_super/${part}.img"
            fi
        done

        # Fallback to stock partition from cache
        if [ -z "$base_source" ] && [ -f "$stock_parts_dir/${part}.img" ]; then
            base_source="$stock_parts_dir/${part}.img"
        fi

        if [ -z "$base_source" ]; then
            echo "[!] Error: No base image found for partition '$part'!"
            return 1
        fi

        echo "  [+] Initializing partition '$part' from ${base_source#$SCRIPT_DIR/}..."
        if file "$base_source" | grep -q "Android sparse image"; then
            simg2img "$base_source" "$out_part_img"
        else
            cp --sparse=always "$base_source" "$out_part_img"
        fi

        # Extend partition to provide room for customization
        if [ "$part" = "system" ]; then
            truncate -s "+512M" "$out_part_img"
        else
            truncate -s "+32M" "$out_part_img"
        fi

        e2fsck -fy "$out_part_img" >/dev/null 2>&1 || true
        resize2fs "$out_part_img" >/dev/null 2>&1 || true

        TARGET_PARTITIONS["$part"]="$out_part_img"
    done

    # Copy layers to work dir so we can update build.prop dynamically
    local layers_work_dir="$build_dir/layers_work"
    cp -r "$LAYER_DIR" "$layers_work_dir"

    # Inject LineageOS version and compilation dates into temporary overlay build.prop
    local overlay_prop_candidates=(
        "$layers_work_dir/overlay/super/system/build.prop"
        "$layers_work_dir/overlay/system/build.prop"
    )
    for overlay_prop in "${overlay_prop_candidates[@]}"; do
        if [ -f "$overlay_prop" ]; then
            echo "[*] Injecting LineageOS version ($lineage_ver) into ${overlay_prop#$build_dir/}..."
            sed -i "s|^ro\.lineage\.version=.*|ro.lineage.version=${lineage_ver}|" "$overlay_prop"
            sed -i "s|^ro\.lineage\.display\.version=.*|ro.lineage.display.version=${lineage_ver}|" "$overlay_prop"
            sed -i "s|^ro\.modversion=.*|ro.modversion=${lineage_ver}|" "$overlay_prop"
            sed -i "s|^ro\.build\.date=.*|ro.build.date=${build_date_full}|" "$overlay_prop"
            sed -i "s|^ro\.build\.date\.utc=.*|ro.build.date.utc=${build_epoch}|" "$overlay_prop"
            sed -i "s|^ro\.system\.build\.date=.*|ro.system.build.date=${build_date_full}|" "$overlay_prop"
            sed -i "s|^ro\.system\.build\.date\.utc=.*|ro.system.build.date=${build_epoch}|" "$overlay_prop"
        fi
    done

    # 2. Apply layers
    echo "[2/5] Customizing partitions (${ALL_PARTITIONS[*]})..."
    for layer in "${layers_to_apply[@]}"; do
        apply_layer "$layer" "$layers_work_dir"
    done

    echo "[*] Checking filesystem integrity (e2fsck)..."
    for part in "${ALL_PARTITIONS[@]}"; do
        e2fsck -fy "${TARGET_PARTITIONS["$part"]}" >/dev/null 2>&1 || true
    done

    # 3. Rebuilding super.img
    echo "[3/5] Rebuilding super.img (lpmake)..."
    local super_size=2147483648
    local lpmake_args=(
        --metadata-size 65536
        --super-name super
        --metadata-slots 2
        --device "super:${super_size}"
        --group "main:${super_size}"
        --sparse
        --output "$build_dir/super.fex"
    )

    for part in "${ALL_PARTITIONS[@]}"; do
        local part_file="${TARGET_PARTITIONS["$part"]}"
        local part_size
        part_size=$(stat -c "%s" "$part_file")
        lpmake_args+=(
            --partition "${part}:readonly:${part_size}:main"
            --image "${part}=${part_file}"
        )
    done

    lpmake "${lpmake_args[@]}"

    # 4. Extracting Phoenix image
    echo "[4/5] Extracting base Phoenix image..."
    cp "$BASE_PHOENIX" "$build_dir/phoenix.img"
    cd "$build_dir"
    "$IMGREPACKER" phoenix.img >/dev/null 2>&1

    # 5. Final repack
    echo "[5/5] Repacking Phoenix image..."
    cp "$build_dir/super.fex" "$build_dir/phoenix.img.dump/super.fex"

    # Board / Firmware customizations from layers (searching overlay or last layer)
    local custom_boot=""
    local custom_boot_res=""
    local custom_env=""

    for layer in "${layers_to_apply[@]}"; do
        local l_path="$LAYER_DIR/$layer"
        [ -f "$l_path/boot.img" ] && custom_boot="$l_path/boot.img"
        [ -f "$l_path/boot-resource.fex" ] && custom_boot_res="$l_path/boot-resource.fex"
        [ -f "$l_path/env.fex" ] && custom_env="$l_path/env.fex"
    done

    if [ -n "$custom_boot" ]; then
        echo "  -> Replacing boot.fex with ${custom_boot#$SCRIPT_DIR/}"
        cp "$custom_boot" "$build_dir/phoenix.img.dump/boot.fex"
    fi

    if [ -n "$custom_boot_res" ]; then
        echo "  -> Replacing boot-resource.fex with ${custom_boot_res#$SCRIPT_DIR/}"
        cp "$custom_boot_res" "$build_dir/phoenix.img.dump/boot-resource.fex"
    fi

    if [ -n "$custom_env" ]; then
        echo "  -> Replacing env.fex with ${custom_env#$SCRIPT_DIR/}"
        cp "$custom_env" "$build_dir/phoenix.img.dump/env.fex"
    fi

    "$IMGREPACKER" "$build_dir/phoenix.img.dump" >/dev/null 2>&1

    mv "$build_dir/phoenix.img" "$final_img"
    cd "$PROJECT_ROOT"

    # Generate sha256 checksum
    echo "[*] Generating SHA256 checksum..."
    (cd "$OUTPUT_DIR" && sha256sum "$(basename "$final_img")" > "$(basename "$final_img").sha256")

    # Clean up build dir
    rm -rf "$build_dir"

    echo ""
    echo "================================================================================"
    echo " [✓] SUCCESS: $variant"
    echo " Image : $final_img"
    echo " Size  : $(ls -lh "$final_img" | awk '{print $5}')"
    echo " SHA256: $(cat "${final_img}.sha256" | awk '{print $1}')"
    echo "================================================================================"
}

# ==============================================================================
# Main execution
# ==============================================================================
mkdir -p "$OUTPUT_DIR"

if [ "$BUILD_ALL" = true ]; then
    echo "[*] Building all variants: ${AVAILABLE_VARIANTS[*]}"
    for var in "${AVAILABLE_VARIANTS[@]}"; do
        build_variant "$var"
    done
else
    build_variant "$SELECTED_VARIANT"
fi

echo ""
echo "All requested builds completed successfully!"
