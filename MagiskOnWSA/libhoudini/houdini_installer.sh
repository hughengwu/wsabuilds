#!/bin/bash
set -e

# Simplified WSA Image Processing Script
# This script follows the exact logic pattern provided by the user

# Define working directory and mount points
WORK_DIR="$(pwd)"
MOUNT_BASE="$WORK_DIR/mount_temp"

# Get the artifact folder from the build step (passed as argument)
ARTIFACT_FOLDER="$1"
if [ -z "$ARTIFACT_FOLDER" ]; then
    echo "Error: Artifact folder not provided"
    echo "Usage: $0 <artifact_folder>"
    exit 1
fi

WSA_PATH="$WORK_DIR/output/$ARTIFACT_FOLDER"

# Function to abort with error message
abort() {
    echo "Error: $1"
    cleanup_on_error
    exit 1
}

# Function to cleanup on error
cleanup_on_error() {
    echo "Performing cleanup..."
    sudo umount "$MOUNT_BASE/system" 2>/dev/null || true
    sudo umount "$MOUNT_BASE/vendor" 2>/dev/null || true
    sudo rm -rf "$MOUNT_BASE" 2>/dev/null || true
}

# Function to process image following the exact pattern
process_wsa_image() {
    local image_type="$1"  # "system" or "vendor"
    local size="$2"        # target size in bytes
    
    echo "=== Processing $image_type image ==="
    
    # Step 1: Convert vhdx to raw
    echo "Converting $image_type.vhdx to raw format..."
    qemu-img convert -f vhdx -O raw "$WSA_PATH/$image_type.vhdx" "$WSA_PATH/$image_type.img" || abort "Failed to convert $image_type.vhdx"
    
    # Step 2: Remove original vhdx
    echo "Removing original $image_type.vhdx..."
    sudo rm -rf "$WSA_PATH/$image_type.vhdx" || abort "Failed to remove $image_type.vhdx"
    
    # Step 3: Allocate space with fallocate
    echo "Allocating space for $image_type.img (size: $size bytes)..."
    fallocate -l "$size" "$WSA_PATH/$image_type.img" || abort "Failed to allocate space for $image_type.img"
    
    # Step 4: Resize filesystem
    echo "Resizing filesystem for $image_type.img..."
    resize2fs "$WSA_PATH/$image_type.img" || abort "Failed to resize filesystem for $image_type.img"
    
    # Step 5: Unshare blocks to make read-write
    echo "Converting $image_type.img to read-write (unshare blocks)..."
    # Use -p for automatic repair and -f to force check even if filesystem seems clean
    # The -E unshare_blocks option makes the filesystem writable by unsharing copy-on-write blocks
    e2fsck -pf -E unshare_blocks "$WSA_PATH/$image_type.img" || {
        echo "Warning: e2fsck with unshare_blocks failed, trying alternative method..."
        # Alternative method: force check and repair without interaction
        echo "y" | e2fsck -E unshare_blocks "$WSA_PATH/$image_type.img" || {
            echo "Warning: Standard unshare_blocks failed, using fallback method..."
            # Fallback: Just force a filesystem check to ensure it's clean and writable
            e2fsck -fy "$WSA_PATH/$image_type.img" || abort "Failed to prepare filesystem for read-write access"
        }
    }

    # Step 6: Create mount directory and mount
    echo "Creating mount point and mounting $image_type.img..."
    mkdir -p "$MOUNT_BASE/$image_type" || abort "Failed to create mount point for $image_type"
    sudo mount -t ext4 -o loop "$WSA_PATH/$image_type.img" "$MOUNT_BASE/$image_type" || abort "Failed to mount $image_type.img"
    
    echo "$image_type image processed and mounted successfully"
}

# Function to finalize image processing
finalize_wsa_image() {
    local image_type="$1"
    
    echo "=== Finalizing $image_type image ==="
    
    # Step 1: Unmount
    echo "Unmounting $image_type..."
    sudo umount "$MOUNT_BASE/$image_type" || abort "Failed to unmount $image_type"
    
    # Step 2: Check and fix filesystem
    echo "Checking filesystem for $image_type.img..."
    e2fsck -yf "$WSA_PATH/$image_type.img" || abort "Failed to check filesystem for $image_type.img"
    
    # Step 3: Minimize filesystem
    echo "Minimizing $image_type.img to optimal size..."
    resize2fs -M "$WSA_PATH/$image_type.img" || abort "Failed to minimize $image_type.img"
    
    # Step 4: Remove mount directory
    echo "Cleaning up mount directory..."
    sudo rm -rf "$MOUNT_BASE/$image_type" || true
    
    # Step 5: Convert back to vhdx
    echo "Converting $image_type.img back to vhdx format..."
    qemu-img convert -f raw -O vhdx "$WSA_PATH/$image_type.img" "$WSA_PATH/$image_type.vhdx" || abort "Failed to convert $image_type.img to vhdx"
    
    # Step 6: Remove temporary img file
    echo "Removing temporary $image_type.img..."
    rm -f "$WSA_PATH/$image_type.img" || true
    
    echo "$image_type image finalized successfully"
}

# Function to find correct mount paths
find_correct_mount_paths() {
    local base_system_mount="$MOUNT_BASE/system"
    local base_vendor_mount="$MOUNT_BASE/vendor"
    
    echo "=== Verifying mount point structures ==="
    
    # Check system mount structure
    echo "Checking system mount structure..."
    if [ -d "$base_system_mount/bin" ] || [ -d "$base_system_mount/etc" ] || [ -d "$base_system_mount/lib" ]; then
        SYSTEM_ROOT="$base_system_mount"
        echo "Using direct system mount: $SYSTEM_ROOT"
    elif [ -d "$base_system_mount/system/bin" ] || [ -d "$base_system_mount/system/etc" ] || [ -d "$base_system_mount/system/lib" ]; then
        SYSTEM_ROOT="$base_system_mount/system"
        echo "Using nested system path: $SYSTEM_ROOT"
    else
        echo "Warning: Could not find standard system directories. Available directories:"
        ls -la "$base_system_mount/" 2>/dev/null || echo "Cannot list system mount contents"
        SYSTEM_ROOT="$base_system_mount"
        echo "Defaulting to: $SYSTEM_ROOT"
    fi
    
    # Check vendor mount structure
    echo "Checking vendor mount structure..."
    if [ -d "$base_vendor_mount/bin" ] || [ -d "$base_vendor_mount/etc" ] || [ -d "$base_vendor_mount/lib" ]; then
        VENDOR_ROOT="$base_vendor_mount"
        echo "Using direct vendor mount: $VENDOR_ROOT"
    elif [ -d "$base_vendor_mount/vendor/bin" ] || [ -d "$base_vendor_mount/vendor/etc" ] || [ -d "$base_vendor_mount/vendor/lib" ]; then
        VENDOR_ROOT="$base_vendor_mount/vendor"
        echo "Using nested vendor path: $VENDOR_ROOT"
    else
        echo "Warning: Could not find standard vendor directories. Available directories:"
        ls -la "$base_vendor_mount/" 2>/dev/null || echo "Cannot list vendor mount contents"
        VENDOR_ROOT="$base_vendor_mount"
        echo "Defaulting to: $VENDOR_ROOT"
    fi
    
    echo "Final paths:"
    echo "  System root: $SYSTEM_ROOT"
    echo "  Vendor root: $VENDOR_ROOT"
}

# Function to make changes (install Houdini)
make_changes() {
    echo "=== Making Changes (Installing Houdini) ==="
    
    # Find correct mount paths first
    find_correct_mount_paths
    
    local SYSTEM_MNT="$SYSTEM_ROOT"
    local VENDOR_MNT="$VENDOR_ROOT"
    local HOUDINI_LOCAL_PATH="$(realpath ./libhoudini)"
    
    # Check if Houdini files exist
    if [ ! -d "$HOUDINI_LOCAL_PATH" ]; then
        echo "Warning: Houdini directory not found at $HOUDINI_LOCAL_PATH"
        echo "Skipping Houdini installation..."
        return 0
    fi
    
    echo "Installing Houdini files from: $HOUDINI_LOCAL_PATH"
    
    # Verify that we can access the mount points
    echo "Verifying mount point accessibility..."
    if [ ! -d "$SYSTEM_MNT" ]; then
        abort "System mount point not accessible: $SYSTEM_MNT"
    fi
    if [ ! -d "$VENDOR_MNT" ]; then
        abort "Vendor mount point not accessible: $VENDOR_MNT"
    fi
    
    echo "Mount points verified successfully"
    echo "  System mount: $SYSTEM_MNT"
    echo "  Vendor mount: $VENDOR_MNT"
    
    # Create necessary directories with better error handling
    echo "Creating necessary directories..."
    
    # Create vendor directories with robust handling
    sudo mkdir -p "$VENDOR_MNT/etc" || abort "Failed to create vendor etc directory"
    sudo mkdir -p "$VENDOR_MNT/etc/binfmt_misc" || abort "Failed to create binfmt_misc directory"
    sudo mkdir -p "$VENDOR_MNT/lib" || abort "Failed to create vendor lib directory"
    sudo mkdir -p "$VENDOR_MNT/lib64" || abort "Failed to create vendor lib64 directory"
    sudo mkdir -p "$VENDOR_MNT/bin" || abort "Failed to create vendor bin directory"
    
    # Handle system bin directory more carefully
    echo "Checking system bin directory at: $SYSTEM_MNT/bin"
    if [ -e "$SYSTEM_MNT/bin" ]; then
        if [ -d "$SYSTEM_MNT/bin" ]; then
            echo "System bin directory already exists as a directory, continuing..."
        elif [ -f "$SYSTEM_MNT/bin" ]; then
            echo "Warning: $SYSTEM_MNT/bin exists as a file, removing it..."
            sudo rm -f "$SYSTEM_MNT/bin" || abort "Failed to remove file blocking system bin directory creation"
            sudo mkdir -p "$SYSTEM_MNT/bin" || abort "Failed to create system bin directory after removing file"
        else
            echo "Warning: $SYSTEM_MNT/bin exists as an unknown type, attempting to remove..."
            sudo rm -rf "$SYSTEM_MNT/bin" || abort "Failed to remove item blocking system bin directory creation"
            sudo mkdir -p "$SYSTEM_MNT/bin" || abort "Failed to create system bin directory after removing item"
        fi
    else
        sudo mkdir -p "$SYSTEM_MNT/bin" || abort "Failed to create system bin directory"
    fi

    # Copy binfmt_misc files from local directory
    echo "Copying binfmt_misc files from local directory..."
    sudo cp "$HOUDINI_LOCAL_PATH/etc/binfmt_misc/arm64_dyn" "$VENDOR_MNT/etc/binfmt_misc/" || abort "Failed to copy arm64_dyn"
    sudo cp "$HOUDINI_LOCAL_PATH/etc/binfmt_misc/arm64_exe" "$VENDOR_MNT/etc/binfmt_misc/" || abort "Failed to copy arm64_exe"
    sudo cp "$HOUDINI_LOCAL_PATH/etc/binfmt_misc/arm_dyn" "$VENDOR_MNT/etc/binfmt_misc/" || abort "Failed to copy arm_dyn"
    sudo cp "$HOUDINI_LOCAL_PATH/etc/binfmt_misc/arm_exe" "$VENDOR_MNT/etc/binfmt_misc/" || abort "Failed to copy arm_exe"

    # Set SELinux properties for binfmt_misc files
    sudo setfattr -n security.selinux -v "u:object_r:vendor_configs_file:s0" "$VENDOR_MNT/etc/binfmt_misc/arm64_dyn" || abort "Failed to set SELinux context for arm64_dyn"
    sudo setfattr -n security.selinux -v "u:object_r:vendor_configs_file:s0" "$VENDOR_MNT/etc/binfmt_misc/arm64_exe" || abort "Failed to set SELinux context for arm64_exe"
    sudo setfattr -n security.selinux -v "u:object_r:vendor_configs_file:s0" "$VENDOR_MNT/etc/binfmt_misc/arm_dyn" || abort "Failed to set SELinux context for arm_dyn"
    sudo setfattr -n security.selinux -v "u:object_r:vendor_configs_file:s0" "$VENDOR_MNT/etc/binfmt_misc/arm_exe" || abort "Failed to set SELinux context for arm_exe"

    # Copy vendor lib files from local directory
    echo "Copying vendor library files from local directory..."
    sudo cp "$HOUDINI_LOCAL_PATH/lib/libhoudini.so" "$VENDOR_MNT/lib/libhoudini.so" || abort "Failed to copy 32-bit libhoudini.so"
    sudo cp "$HOUDINI_LOCAL_PATH/lib64/libhoudini.so" "$VENDOR_MNT/lib64/libhoudini.so" || abort "Failed to copy 64-bit libhoudini.so"

    # Set proper permissions and ownership for main libhoudini.so files
    sudo chown root:root "$VENDOR_MNT/lib/libhoudini.so" || abort "Failed to set ownership for 32-bit libhoudini.so"
    sudo chown root:root "$VENDOR_MNT/lib64/libhoudini.so" || abort "Failed to set ownership for 64-bit libhoudini.so"
    sudo chmod 644 "$VENDOR_MNT/lib/libhoudini.so" || abort "Failed to set permissions for 32-bit libhoudini.so"
    sudo chmod 644 "$VENDOR_MNT/lib64/libhoudini.so" || abort "Failed to set permissions for 64-bit libhoudini.so"

    # Set SELinux properties for vendor lib files
    sudo setfattr -n security.selinux -v "u:object_r:same_process_hal_file:s0" "$VENDOR_MNT/lib/libhoudini.so" || abort "Failed to set SELinux context for 32-bit libhoudini.so"
    sudo setfattr -n security.selinux -v "u:object_r:same_process_hal_file:s0" "$VENDOR_MNT/lib64/libhoudini.so" || abort "Failed to set SELinux context for 64-bit libhoudini.so"

    # Copy vendor bin files from local directory
    echo "Copying vendor binary files from local directory..."
    sudo cp "$HOUDINI_LOCAL_PATH/bin/houdini" "$VENDOR_MNT/bin/" || abort "Failed to copy houdini to vendor bin"
    sudo cp "$HOUDINI_LOCAL_PATH/bin/houdini64" "$VENDOR_MNT/bin/" || abort "Failed to copy houdini64 to vendor bin"

    # Set SELinux properties for vendor bin files
    sudo setfattr -n security.selinux -v "u:object_r:same_process_hal_file:s0" "$VENDOR_MNT/bin/houdini" || abort "Failed to set SELinux context for vendor houdini"
    sudo setfattr -n security.selinux -v "u:object_r:same_process_hal_file:s0" "$VENDOR_MNT/bin/houdini64" || abort "Failed to set SELinux context for vendor houdini64"

    # Copy to system bin and set SELinux properties
    echo "Copying to system bin..."
    sudo cp "$HOUDINI_LOCAL_PATH/bin/houdini" "$SYSTEM_MNT/bin/" || abort "Failed to copy houdini to system bin"
    sudo cp "$HOUDINI_LOCAL_PATH/bin/houdini64" "$SYSTEM_MNT/bin/" || abort "Failed to copy houdini64 to system bin"

    # Set SELinux properties for system bin files
    sudo setfattr -n security.selinux -v "u:object_r:system_file:s0" "$SYSTEM_MNT/bin/houdini" || abort "Failed to set SELinux context for system houdini"
    sudo setfattr -n security.selinux -v "u:object_r:system_file:s0" "$SYSTEM_MNT/bin/houdini64" || abort "Failed to set SELinux context for system houdini64"

    # Set ownership and permissions for vendor bin files (root:2000, 755)
    sudo chown root:2000 "$VENDOR_MNT/bin/houdini" || abort "Failed to set ownership for vendor houdini"
    sudo chown root:2000 "$VENDOR_MNT/bin/houdini64" || abort "Failed to set ownership for vendor houdini64"
    sudo chmod 755 "$VENDOR_MNT/bin/houdini" || abort "Failed to set permissions for vendor houdini"
    sudo chmod 755 "$VENDOR_MNT/bin/houdini64" || abort "Failed to set permissions for vendor houdini64"

    # Set ownership and permissions for system bin files (root:2000, 755)
    sudo chown root:2000 "$SYSTEM_MNT/bin/houdini" || abort "Failed to set ownership for system houdini"
    sudo chown root:2000 "$SYSTEM_MNT/bin/houdini64" || abort "Failed to set ownership for system houdini64"
    sudo chmod 755 "$SYSTEM_MNT/bin/houdini" || abort "Failed to set permissions for system houdini"
    sudo chmod 755 "$SYSTEM_MNT/bin/houdini64" || abort "Failed to set permissions for system houdini64"

    # Copy ARM library files to vendor directories
    echo "Copying ARM library files to vendor directories..."
    
    # Create ARM directories in vendor
    sudo mkdir -p "$VENDOR_MNT/lib/arm" || abort "Failed to create vendor/lib/arm directory"
    sudo mkdir -p "$VENDOR_MNT/lib64/arm64" || abort "Failed to create vendor/lib64/arm64 directory"
    
    # Copy all ARM library files from libhoudini/lib64/arm64 to vendor/lib64/arm64
    if [ -d "$HOUDINI_LOCAL_PATH/lib64/arm64" ]; then
        echo "Copying ARM libraries to vendor/lib64/arm64..."
        if [ "$(ls -A "$HOUDINI_LOCAL_PATH/lib64/arm64" 2>/dev/null)" ]; then
            sudo cp -r "$HOUDINI_LOCAL_PATH/lib64/arm64/"* "$VENDOR_MNT/lib64/arm64/" || echo "Warning: Copy failed for $HOUDINI_LOCAL_PATH/lib64/arm64"
        else
            echo "Warning: No files found in $HOUDINI_LOCAL_PATH/lib64/arm64"
        fi
        
        # Set permissions and ownership for all files in vendor/lib64/arm64
        sudo find "$VENDOR_MNT/lib64/arm64" -type f -exec chown root:root {} \; 2>/dev/null || true
        sudo find "$VENDOR_MNT/lib64/arm64" -type f -exec chmod 644 {} \; 2>/dev/null || true
        
        # Set SELinux context for all files in vendor/lib64/arm64
        sudo find "$VENDOR_MNT/lib64/arm64" -type f -exec setfattr -n security.selinux -v "u:object_r:same_process_hal_file:s0" {} \; 2>/dev/null || echo "Warning: Failed to set SELinux context for some files in vendor/lib64/arm64"
    else
        echo "Warning: ARM64 library directory $HOUDINI_LOCAL_PATH/lib64/arm64 not found"
    fi
    
    # Copy all files from libhoudini/lib/arm to vendor/lib/arm
    if [ -d "$HOUDINI_LOCAL_PATH/lib/arm" ]; then
        echo "Copying ARM libraries from libhoudini/lib/arm to vendor/lib/arm..."
        if [ "$(ls -A "$HOUDINI_LOCAL_PATH/lib/arm" 2>/dev/null)" ]; then
            sudo cp -r "$HOUDINI_LOCAL_PATH/lib/arm/"* "$VENDOR_MNT/lib/arm/" || echo "Warning: Copy failed for $HOUDINI_LOCAL_PATH/lib/arm"
        else
            echo "Warning: No files found in $HOUDINI_LOCAL_PATH/lib/arm"
        fi
        
        # Set permissions and ownership for all files in vendor/lib/arm
        sudo find "$VENDOR_MNT/lib/arm" -type f -exec chown root:root {} \; 2>/dev/null || true
        sudo find "$VENDOR_MNT/lib/arm" -type f -exec chmod 644 {} \; 2>/dev/null || true
        
        # Set SELinux context for all files in vendor/lib/arm
        sudo find "$VENDOR_MNT/lib/arm" -type f -exec setfattr -n security.selinux -v "u:object_r:same_process_hal_file:s0" {} \; 2>/dev/null || echo "Warning: Failed to set SELinux context for some files in vendor/lib/arm"
    else
        echo "Warning: ARM library directory $HOUDINI_LOCAL_PATH/lib/arm not found"
    fi

    # Edit init.windows_x86_64.rc to add Houdini exec commands after mount bind commands
    echo "Editing init.windows_x86_64.rc for Houdini binary format registration..."
    INIT_WINDOWS_RC="$VENDOR_MNT/etc/init/init.windows_x86_64.rc"
    
    # Check if the init file exists, if not try alternative locations
    if [ ! -f "$INIT_WINDOWS_RC" ]; then
        echo "init.windows_x86_64.rc not found at $INIT_WINDOWS_RC"
        echo "Checking alternative locations..."
        
        # Check if etc/init directory exists but with different file
        if [ -d "$VENDOR_MNT/etc/init" ]; then
            echo "Available files in $VENDOR_MNT/etc/init:"
            ls -la "$VENDOR_MNT/etc/init/" 2>/dev/null || echo "Cannot list init directory"
            
            # Look for any .rc files that might contain windows or x86
            for rc_file in "$VENDOR_MNT/etc/init"/*.rc; do
                if [ -f "$rc_file" ] && (grep -q "windows\|x86" "$rc_file" 2>/dev/null); then
                    echo "Found potential init file: $rc_file"
                    INIT_WINDOWS_RC="$rc_file"
                    break
                fi
            done
        fi
    fi
    
    if [ -f "$INIT_WINDOWS_RC" ]; then
        # Create a backup of the original file
        sudo cp "$INIT_WINDOWS_RC" "$INIT_WINDOWS_RC.backup" || abort "Failed to create backup of init.windows_x86_64.rc"
        
        # Create a temporary file for the modifications
        TEMP_RC="/tmp/init_windows_temp.rc"
        
        # Process the file line by line to add exec commands after mount bind commands
        sudo awk '
        {
            print $0
            if ($0 ~ /mount none \/vendor\/bin\/houdini \/system\/bin\/houdini bind rec/) {
                print "    exec -- /system/bin/sh -c \"echo '"'"':arm_exe:M::\\\\x7f\\\\x45\\\\x4c\\\\x46\\\\x01\\\\x01\\\\x01\\\\x00\\\\x00\\\\x00\\\\x00\\\\x00\\\\x00\\\\x00\\\\x00\\\\x00\\\\x02\\\\x00\\\\x28::/system/bin/houdini:P'"'"' > /proc/sys/fs/binfmt_misc/register\""
                print "    exec -- /system/bin/sh -c \"echo '"'"':arm_dyn:M::\\\\x7f\\\\x45\\\\x4c\\\\x46\\\\x01\\\\x01\\\\x01\\\\x00\\\\x00\\\\x00\\\\x00\\\\x00\\\\x00\\\\x00\\\\x00\\\\x00\\\\x03\\\\x00\\\\x28::/system/bin/houdini:P'"'"' >> /proc/sys/fs/binfmt_misc/register\""
            }
            if ($0 ~ /mount none \/vendor\/bin\/houdini64 \/system\/bin\/houdini64 bind rec/) {
                print "    exec -- /system/bin/sh -c \"echo '"'"':arm64_exe:M::\\\\x7f\\\\x45\\\\x4c\\\\x46\\\\x02\\\\x01\\\\x01\\\\x00\\\\x00\\\\x00\\\\x00\\\\x00\\\\x00\\\\x00\\\\x00\\\\x00\\\\x02\\\\x00\\\\xb7::/system/bin/houdini64:P'"'"' >> /proc/sys/fs/binfmt_misc/register\""
                print "    exec -- /system/bin/sh -c \"echo '"'"':arm64_dyn:M::\\\\x7f\\\\x45\\\\x4c\\\\x46\\\\x02\\\\x01\\\\x01\\\\x00\\\\x00\\\\x00\\\\x00\\\\x00\\\\x00\\\\x00\\\\x00\\\\x00\\\\x03\\\\x00\\\\xb7::/system/bin/houdini64:P'"'"' >> /proc/sys/fs/binfmt_misc/register\""
            }
        }' "$INIT_WINDOWS_RC" > "$TEMP_RC" || abort "Failed to process init.windows_x86_64.rc"
        
        # Replace the original file with the modified version
        sudo mv "$TEMP_RC" "$INIT_WINDOWS_RC" || abort "Failed to replace init.windows_x86_64.rc"
        
        # Set proper SELinux context for the modified init file
        sudo setfattr -n security.selinux -v "u:object_r:vendor_configs_file:s0" "$INIT_WINDOWS_RC" || abort "Failed to set SELinux context for init.windows_x86_64.rc"
        sudo setfattr -n security.selinux -v "u:object_r:vendor_configs_file:s0" "$INIT_WINDOWS_RC.backup" || abort "Failed to set SELinux context for init.windows_x86_64.rc.backup"      
        
        echo "Successfully updated init.windows_x86_64.rc with Houdini exec commands"
    else
        echo "Warning: init.windows_x86_64.rc not found at $INIT_WINDOWS_RC"
    fi

    # Patch build.prop to clear emulator/test-key markers (fixes error 709/607)
    echo "Patching build.prop files (fixDeviceProps)..."
    sudo python3 "$WORK_DIR/scripts/fixDeviceProps.py" "$SYSTEM_MNT" "$VENDOR_MNT" || echo "Warning: fixDeviceProps.py failed, continuing..."

    # ── Install fake sensors HAL (adds accelerometer+gyroscope) ───────────────
    # WSA ships zero sensors; CloudWalk/face-liveness SDKs require an
    # accelerometer/gyroscope and fail with 709 when getDefaultSensor()==null.
    # Inject the AOSP HIDL 2.1 multihal service + fake-subhal (synthetic
    # accel/gyro data) into vendor. SELinux domain hal_sensors_default already
    # exists in WSA's precompiled policy (verified via vendor_file_contexts).
    SENSORS_SRC="$HOUDINI_LOCAL_PATH/sensors"
    if [ -d "$SENSORS_SRC" ]; then
        echo "Installing fake sensors HAL (multihal 2.1 + fake-subhal)..."
        SENSOR_BIN="android.hardware.sensors@2.1-service.multihal"

        # 1) Service binary → /vendor/bin/hw
        sudo mkdir -p "$VENDOR_MNT/bin/hw"
        sudo cp "$SENSORS_SRC/bin_hw/$SENSOR_BIN" "$VENDOR_MNT/bin/hw/" || abort "Failed to copy sensors HAL binary"
        sudo chown root:root "$VENDOR_MNT/bin/hw/$SENSOR_BIN"
        sudo chmod 755 "$VENDOR_MNT/bin/hw/$SENSOR_BIN"
        sudo setfattr -n security.selinux -v "u:object_r:hal_sensors_default_exec:s0" "$VENDOR_MNT/bin/hw/$SENSOR_BIN" || echo "Warning: setfattr sensors binary failed"

        # 2) Shared libs (subhal + sensors HIDL interface libs) → /vendor/lib64
        sudo mkdir -p "$VENDOR_MNT/lib64"
        for so in "$SENSORS_SRC"/lib64/*.so; do
            n=$(basename "$so")
            sudo cp "$so" "$VENDOR_MNT/lib64/$n" || abort "Failed to copy sensors lib $n"
            sudo chown root:root "$VENDOR_MNT/lib64/$n"
            sudo chmod 644 "$VENDOR_MNT/lib64/$n"
            sudo setfattr -n security.selinux -v "u:object_r:vendor_file:s0" "$VENDOR_MNT/lib64/$n" || echo "Warning: setfattr $n failed"
        done

        # 3) init.rc → /vendor/etc/init
        sudo mkdir -p "$VENDOR_MNT/etc/init"
        sudo cp "$SENSORS_SRC/etc_init/$SENSOR_BIN".rc "$VENDOR_MNT/etc/init/$SENSOR_BIN.rc" 2>/dev/null \
            || sudo cp "$SENSORS_SRC"/etc_init/*.rc "$VENDOR_MNT/etc/init/"
        sudo setfattr -n security.selinux -v "u:object_r:vendor_configs_file:s0" "$VENDOR_MNT"/etc/init/android.hardware.sensors@2.1-service-multihal.rc || echo "Warning: setfattr sensors rc failed"

        # 4) VINTF manifest fragment → /vendor/etc/vintf/manifest
        sudo mkdir -p "$VENDOR_MNT/etc/vintf/manifest"
        sudo cp "$SENSORS_SRC"/etc_vintf/*.xml "$VENDOR_MNT/etc/vintf/manifest/"
        sudo setfattr -n security.selinux -v "u:object_r:vendor_configs_file:s0" "$VENDOR_MNT"/etc/vintf/manifest/android.hardware.sensors@2.1-multihal.xml || echo "Warning: setfattr sensors manifest failed"

        # 5) multihal sub-HAL config → /vendor/etc/sensors/hals.conf
        #    /vendor/etc/sensors is a NEW directory — it MUST be labeled too,
        #    or hal_sensors_default cannot search into it (enforcing) and the
        #    multihal logs "Failed to load subHal config file". Use vendor_file:
        #    proven readable by this domain (the subhal .so loaded from it).
        sudo mkdir -p "$VENDOR_MNT/etc/sensors"
        sudo setfattr -n security.selinux -v "u:object_r:vendor_file:s0" "$VENDOR_MNT/etc/sensors" || echo "Warning: setfattr sensors dir failed"
        sudo cp "$SENSORS_SRC/etc_sensors/hals.conf" "$VENDOR_MNT/etc/sensors/hals.conf"
        sudo chown root:root "$VENDOR_MNT/etc/sensors/hals.conf"
        sudo chmod 644 "$VENDOR_MNT/etc/sensors/hals.conf"
        sudo setfattr -n security.selinux -v "u:object_r:vendor_file:s0" "$VENDOR_MNT/etc/sensors/hals.conf" || echo "Warning: setfattr hals.conf failed"

        echo "Fake sensors HAL installed."
    else
        echo "Warning: sensors HAL dir not found at $SENSORS_SRC, skipping"
    fi

    # ── Install AOSP External Camera HAL + usbip auto-attach ──────────────────
    # WSA's built-in camera goes through the CLOSED Windows camera HAL, which
    # cannot satisfy CloudWalk's 640x360 dual-stream request (black preview ->
    # 709). We add the open-source AOSP external camera provider (UVC/V4L2) and
    # attach a Windows webcam over usbip so CloudWalk gets a real camera.
    # Runs in the existing hal_camera_default domain (made permissive by our
    # baked sepolicy); the only cross-domain rule needed is kernel<->usbip sock.
    CAMERA_SRC="$HOUDINI_LOCAL_PATH/camera"
    if [ -d "$CAMERA_SRC" ]; then
        echo "Installing AOSP External Camera HAL (provider@2.4-external)..."
        CAM_SVC="android.hardware.camera.provider@2.4-external-service"

        # 1) service binary -> /vendor/bin/hw  (hal_camera_default domain)
        sudo mkdir -p "$VENDOR_MNT/bin/hw"
        sudo cp "$CAMERA_SRC/bin_hw/$CAM_SVC" "$VENDOR_MNT/bin/hw/"
        sudo chown root:root "$VENDOR_MNT/bin/hw/$CAM_SVC"
        sudo chmod 755 "$VENDOR_MNT/bin/hw/$CAM_SVC"
        sudo setfattr -n security.selinux -v "u:object_r:hal_camera_default_exec:s0" "$VENDOR_MNT/bin/hw/$CAM_SVC" || echo "Warning: setfattr camera svc failed"

        # 2) passthrough impl .so -> /vendor/lib64/hw
        sudo mkdir -p "$VENDOR_MNT/lib64/hw"
        sudo cp "$CAMERA_SRC/lib64_hw/android.hardware.camera.provider@2.4-impl.so" "$VENDOR_MNT/lib64/hw/"
        sudo chown root:root "$VENDOR_MNT/lib64/hw/android.hardware.camera.provider@2.4-impl.so"
        sudo chmod 644 "$VENDOR_MNT/lib64/hw/android.hardware.camera.provider@2.4-impl.so"
        sudo setfattr -n security.selinux -v "u:object_r:vendor_file:s0" "$VENDOR_MNT/lib64/hw/android.hardware.camera.provider@2.4-impl.so" || echo "Warning: setfattr impl.so failed"

        # 3) camera + hidl support libs -> /vendor/lib64
        sudo mkdir -p "$VENDOR_MNT/lib64"
        for so in "$CAMERA_SRC"/lib64/*.so; do
            [ -e "$so" ] || continue
            n=$(basename "$so")
            sudo cp "$so" "$VENDOR_MNT/lib64/$n"
            sudo chown root:root "$VENDOR_MNT/lib64/$n"
            sudo chmod 644 "$VENDOR_MNT/lib64/$n"
            sudo setfattr -n security.selinux -v "u:object_r:vendor_file:s0" "$VENDOR_MNT/lib64/$n" || echo "Warning: setfattr $n failed"
        done

        # 4) external camera config -> /vendor/etc
        sudo cp "$CAMERA_SRC/etc/external_camera_config.xml" "$VENDOR_MNT/etc/external_camera_config.xml"
        sudo chown root:root "$VENDOR_MNT/etc/external_camera_config.xml"
        sudo chmod 644 "$VENDOR_MNT/etc/external_camera_config.xml"
        sudo setfattr -n security.selinux -v "u:object_r:vendor_configs_file:s0" "$VENDOR_MNT/etc/external_camera_config.xml" || echo "Warning: setfattr cam config failed"

        # 5) init .rc files (camera service + usbip auto-attach) -> /vendor/etc/init
        sudo mkdir -p "$VENDOR_MNT/etc/init"
        for rc in "$CAMERA_SRC"/etc_init/*.rc; do
            [ -e "$rc" ] || continue
            n=$(basename "$rc")
            sudo cp "$rc" "$VENDOR_MNT/etc/init/$n"
            sudo chown root:root "$VENDOR_MNT/etc/init/$n"
            sudo chmod 644 "$VENDOR_MNT/etc/init/$n"
            sudo setfattr -n security.selinux -v "u:object_r:vendor_configs_file:s0" "$VENDOR_MNT/etc/init/$n" || echo "Warning: setfattr $n failed"
        done

        # 6) vintf manifest fragment (declares external/0) -> /vendor/etc/vintf/manifest
        sudo mkdir -p "$VENDOR_MNT/etc/vintf/manifest"
        for x in "$CAMERA_SRC"/etc_vintf/*.xml; do
            [ -e "$x" ] || continue
            n=$(basename "$x")
            sudo cp "$x" "$VENDOR_MNT/etc/vintf/manifest/$n"
            sudo chown root:root "$VENDOR_MNT/etc/vintf/manifest/$n"
            sudo chmod 644 "$VENDOR_MNT/etc/vintf/manifest/$n"
            sudo setfattr -n security.selinux -v "u:object_r:vendor_configs_file:s0" "$VENDOR_MNT/etc/vintf/manifest/$n" || echo "Warning: setfattr $n failed"
        done

        # 7) usbip attach client -> /vendor/bin (run by vendor-usbip-cam.rc)
        if [ -f "$HOUDINI_LOCAL_PATH/bin/usbip_attach_min" ]; then
            sudo cp "$HOUDINI_LOCAL_PATH/bin/usbip_attach_min" "$VENDOR_MNT/bin/usbip_attach_min"
            sudo chown root:root "$VENDOR_MNT/bin/usbip_attach_min"
            sudo chmod 755 "$VENDOR_MNT/bin/usbip_attach_min"
            sudo setfattr -n security.selinux -v "u:object_r:vendor_file:s0" "$VENDOR_MNT/bin/usbip_attach_min" || echo "Warning: setfattr usbip client failed"
        fi

        # 8) ueventd rule so /dev/video* are created 0660 cameraserver:camera
        #    (else the cameraserver-uid HAL gets EACCES on the root:root 0600 node).
        #    ueventd only reads fixed paths, so append into /vendor/etc/ueventd.rc.
        if [ -f "$CAMERA_SRC/etc/ueventd-video.rc" ]; then
            UEV="$VENDOR_MNT/etc/ueventd.rc"
            if ! sudo grep -q '/dev/video\*' "$UEV" 2>/dev/null; then
                echo "Appending /dev/video* rule to vendor ueventd.rc"
                sudo sh -c "cat '$CAMERA_SRC/etc/ueventd-video.rc' >> '$UEV'"
            fi
            sudo chown root:root "$UEV"
            sudo chmod 644 "$UEV"
            sudo setfattr -n security.selinux -v "u:object_r:vendor_configs_file:s0" "$UEV" || echo "Warning: setfattr ueventd.rc failed"
        fi

        # 9) Disable WSA's closed Windows camera HAL so our external/0 is the only
        #    camera CloudWalk can pick (it can't deliver 640x360 anyway, and usbip
        #    steals its webcam). Remove its init .rc + vintf manifest fragment.
        for wf in \
            "$VENDOR_MNT/etc/init/android.hardware.camera-service.windows.rc" \
            "$VENDOR_MNT/etc/vintf/manifest/android.hardware.camera-service.windows.xml" ; do
            if [ -f "$wf" ]; then echo "Disabling Windows camera HAL: removing $(basename "$wf")"; sudo rm -f "$wf"; fi
        done

        echo "External Camera HAL + usbip auto-attach installed."
    else
        echo "Warning: camera HAL dir not found at $CAMERA_SRC, skipping"
    fi

    # ── Bake sepolicy: make hal_camera_default permissive + allow kernel<->usbip
    #    socket. Patched precompiled_sepolicy is produced offline (magiskpolicy
    #    --load/--save on a root WSA) and dropped at libhoudini/sepolicy/.
    SEPOL_SRC="$HOUDINI_LOCAL_PATH/sepolicy/precompiled_sepolicy"
    if [ -f "$SEPOL_SRC" ]; then
        echo "Installing patched precompiled_sepolicy (permissive hal_camera_default + usbip sock)..."
        if [ -f "$VENDOR_MNT/etc/selinux/precompiled_sepolicy" ]; then
            CTX=$(getfattr -n security.selinux --only-values "$VENDOR_MNT/etc/selinux/precompiled_sepolicy" 2>/dev/null)
            sudo cp "$SEPOL_SRC" "$VENDOR_MNT/etc/selinux/precompiled_sepolicy"
            sudo chown root:root "$VENDOR_MNT/etc/selinux/precompiled_sepolicy"
            sudo chmod 644 "$VENDOR_MNT/etc/selinux/precompiled_sepolicy"
            sudo setfattr -n security.selinux -v "${CTX:-u:object_r:vendor_configs_file:s0}" "$VENDOR_MNT/etc/selinux/precompiled_sepolicy" || echo "Warning: setfattr sepolicy failed"
        else
            echo "Warning: $VENDOR_MNT/etc/selinux/precompiled_sepolicy not found; skipping sepolicy bake"
        fi
    fi

    # Set timestamps for all files in vendor and system mounts
    echo "Setting timestamps for all files in vendor and system mounts..."
    sudo find "$VENDOR_MNT" -exec touch -hamt 200901010000.00 {} \; 2>/dev/null || echo "Warning: Failed to set timestamps for some vendor files"
    sudo find "$SYSTEM_MNT" -exec touch -hamt 200901010000.00 {} \; 2>/dev/null || echo "Warning: Failed to set timestamps for some system files"

    echo -e "Houdini files installation completed\n"
}

# Calculate target sizes
calculate_sizes() {
    # Get current sizes
    local system_size=$(du --apparent-size -sB1 "$WSA_PATH/system.vhdx" | cut -f1)
    local vendor_size=$(du --apparent-size -sB1 "$WSA_PATH/vendor.vhdx" | cut -f1)
    
    # System: triple the size
    SYSTEM_TARGET_SIZE=$((system_size * 3))
    
    # Vendor: add 600MB for Houdini files
    VENDOR_TARGET_SIZE=$((vendor_size + 629145600))
    
    echo "Calculated target sizes:"
    echo "  System: $SYSTEM_TARGET_SIZE bytes"
    echo "  Vendor: $VENDOR_TARGET_SIZE bytes"
}

# Main execution
echo "Starting simplified WSA image processing..."
echo "Working directory: $WORK_DIR"
echo "WSA path: $WSA_PATH"

# Verify images exist
if [ ! -f "$WSA_PATH/system.vhdx" ] || [ ! -f "$WSA_PATH/vendor.vhdx" ]; then
    abort "WSA images not found in $WSA_PATH"
fi

# Set up cleanup trap
trap cleanup_on_error EXIT

# Calculate target sizes
calculate_sizes

# Process system image
process_wsa_image "system" "$SYSTEM_TARGET_SIZE"

# Process vendor image  
process_wsa_image "vendor" "$VENDOR_TARGET_SIZE"

# Make changes (install Houdini)
make_changes

# Finalize system image
finalize_wsa_image "system"

# Finalize vendor image
finalize_wsa_image "vendor"

# Clean up mount base directory
sudo rm -rf "$MOUNT_BASE" 2>/dev/null || true

# Remove trap since we're done
trap - EXIT

echo "=== Processing Complete ==="
echo "WSA image processing completed successfully!"
echo "Processed images are available at: $WSA_PATH"
