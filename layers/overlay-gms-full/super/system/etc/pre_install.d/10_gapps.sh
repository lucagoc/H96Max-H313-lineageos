#!/system/bin/sh
# Layer hook: overlay-gms-full
# Post-setup for Google TV Services & Apps

log -t pre_install_gapps "Configuring Google TV settings, GBoard and optimizations"

# Set Backdrop as default daydream screensaver
settings put secure screensaver_components com.google.android.backdrop/.Backdrop

# Enable and set GBoard as default Input Method (IME)
ime enable com.android.inputmethod.latin/.LatinIME 2>/dev/null || true
ime set com.android.inputmethod.latin/.LatinIME 2>/dev/null || true
settings put secure default_input_method com.android.inputmethod.latin/.LatinIME
settings put secure enabled_input_methods "com.android.inputmethod.latin/.LatinIME"

# AOT compile critical UI components to native machine code for smooth 60fps UI
log -t pre_install_gapps "AOT compiling TVLauncher and GBoard..."
cmd package compile -m speed -f com.google.android.tvlauncher || true
cmd package compile -m speed -f com.android.inputmethod.latin || true
