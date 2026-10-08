#!/system/bin/sh
# First-boot automatic setup script (installs standalone user-space apps)

MARKER="/data/.pre_install_done"
LOGFILE="/data/pre_install.log"

if [ -f "$MARKER" ]; then
    exit 0
fi

# Log start
touch "$LOGFILE"
chmod 644 "$LOGFILE"
log -t pre_install "Pre-install started"
echo "=== Pre-install started at $(date) ===" >> "$LOGFILE"

# Wait until Android framework and Package Manager are ready
while [ "$(getprop sys.boot_completed)" != "1" ]; do
    sleep 2
done

# Wait until Package Manager service is responding
while ! pm path android >/dev/null 2>&1; do
    sleep 2
done

# Short delay to allow services to settle
sleep 3

# - Time configuration: enable network NTP sync and disable cellular auto-timezone
# (TV boxes lack cellular basebands, so cellular auto-timezone blocks manual or network TZ updates)
settings put global auto_time 1
settings put global auto_time_zone 0

# - Audio: disable encoded surround sound & bitstream passthrough
# (Allwinner H313 HAL does not support IEC61937 get_render_position, leading to permanent underrun)
settings put global encoded_surround_output 1
settings put global encoded_surround_output_enabled_formats ""

# - UI animation speeds: 0.5x scale for fluid, immediate remote responsiveness
settings put global window_animation_scale 0.5
settings put global transition_animation_scale 0.5
settings put global animator_duration_scale 0.5

# - Screensaver & Power: 15 minutes timeout, enable daydream
# (Disable stay_on_while_plugged_in so screensaver can trigger on AC-powered TV box)
settings put global stay_on_while_plugged_in 0
settings put system screen_off_timeout 900000
settings put secure screensaver_enabled 1
settings put secure screensaver_activate_on_sleep 1
settings put secure screensaver_activate_on_dock 1
settings put secure screensaver_components com.android.dreams.basic/com.android.dreams.basic.Colors

# - Force 1080p UI rendering and 320 TV DPI (xhdpi)
wm size 1920x1080 2>/dev/null || true
wm density 320 2>/dev/null || true

# - Storage I/O read-ahead buffer & kernel VFS / ZRAM VM tuning
if [ -d /sys/block/mmcblk0 ]; then
    echo 512 > /sys/block/mmcblk0/queue/read_ahead_kb 2>/dev/null || true
fi
sysctl -w vm.swappiness=100 2>/dev/null || true
sysctl -w vm.vfs_cache_pressure=100 2>/dev/null || true
sysctl -w vm.dirty_ratio=15 2>/dev/null || true
sysctl -w vm.dirty_background_ratio=5 2>/dev/null || true

# - HBG Voice Remote Audio setup
mkdir -p /data/vendor/HBG /data/HBG
cp -f /vendor/etc/remote.txt /data/vendor/HBG/remote.txt 2>/dev/null || true
cp -f /vendor/etc/remote.txt /data/HBG/remote.txt 2>/dev/null || true
chmod -R 0777 /data/vendor/HBG /data/HBG 2>/dev/null || true
chown -R 1041:1005 /data/vendor/HBG /data/HBG 2>/dev/null || true


APK_DIR="/system/etc/pre_install"

if [ -d "$APK_DIR" ]; then
    # 1. Install standalone single APKs
    for apk in "$APK_DIR"/*.apk; do
        if [ -f "$apk" ]; then
            log -t pre_install "Installing standalone APK: $apk"
            echo "Installing standalone: $apk" >> "$LOGFILE"
            # Install into /data (-r to replace, -d to allow downgrade, -g to grant permissions)
            res=$(pm install -g -r -d "$apk" 2>&1)
            echo "Result: $res" >> "$LOGFILE"
            log -t pre_install "Result for $apk: $res"
        fi
    done

    # 2. Install split / multiple APK packages located in subdirectories
    for app_dir in "$APK_DIR"/*/; do
        if [ -d "$app_dir" ]; then
            base_apk=""
            split_apks=""
            for a in "$app_dir"*.apk; do
                [ -f "$a" ] || continue
                case "$a" in
                    *split*.apk|*config*.apk)
                        split_apks="$split_apks $a"
                        ;;
                    *base*.apk|*Base*.apk)
                        base_apk="$a"
                        ;;
                    *)
                        if [ -z "$base_apk" ]; then
                            base_apk="$a"
                        else
                            split_apks="$split_apks $a"
                        fi
                        ;;
                esac
            done
            if [ -n "$base_apk" ]; then
                log -t pre_install "Installing multi-APK from $app_dir: base=$base_apk splits=$split_apks"
                echo "Installing multi-apk from $app_dir: base=$base_apk splits=$split_apks" >> "$LOGFILE"
                res=$(pm install -g -r -d $base_apk $split_apks 2>&1)
                echo "Result: $res" >> "$LOGFILE"
                log -t pre_install "Result for $app_dir: $res"
            fi
        fi
    done
fi

# - Pre-compile critical UI components (AOT) to eliminate frame drops and stuttering
log -t pre_install "Pre-compiling critical UI packages to native machine code..."
echo "AOT compiling critical UI packages..." >> "$LOGFILE"
cmd package compile -m speed -f com.android.systemui >> "$LOGFILE" 2>&1 || true

# - Execute layer-specific scripts (e.g. from overlay-gapps or other addon layers)
HOOKS_DIR="/system/etc/pre_install.d"
if [ -d "$HOOKS_DIR" ]; then
    for script in "$HOOKS_DIR"/*.sh; do
        if [ -f "$script" ]; then
            log -t pre_install "Executing layer hook: $script"
            echo "Executing layer hook: $script" >> "$LOGFILE"
            /system/bin/sh "$script" >> "$LOGFILE" 2>&1 || true
        fi
    done
fi

# Create marker file to avoid running on subsequent boots
touch "$MARKER"
chmod 644 "$MARKER"
echo "=== Pre-install finished at $(date) ===" >> "$LOGFILE"
log -t pre_install "Pre-install completed successfully"
