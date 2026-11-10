#!/sbin/sh

target_dir=/data/luneos
backup_dir=/data/luneos_bak

tmp_extract=/data/luneos_tmp_extract

tarball=/data/webos-rootfs.tar.gz
# Space the unpacked rootfs takes, in KiB, written by the package recipe. It is
# optional: without it the space check is skipped and only the retry after a
# "No space left on device" protects the install.
size_file=/tmp/webos-rootfs.size
tar_log=/tmp/webos-rootfs-tar.log

# Pick the busybox that extracts the rootfs. busybox-static is built against the
# distro glibc, which assumes a newer kernel than some recoveries run (TWRP on a
# 3.4 kernel): there stat, chmod, chown and utimensat fail with ENOSYS and tar
# cannot even create its target directory. So use it only if it can do those on
# this recovery, and otherwise fall back to the recovery's own busybox.
busybox_works() {
    probe=/tmp/busybox-probe
    rm -rf $probe
    mkdir $probe
    $1 chmod 755 $probe >/dev/null 2>&1 &&
        $1 touch -d "2020-01-01 00:00:00" $probe >/dev/null 2>&1 &&
        $1 mkdir -p $probe/. >/dev/null 2>&1
    ret=$?
    rm -rf $probe
    return $ret
}

bb=/tmp/busybox-static
if ! busybox_works $bb; then
    echo "busybox-static does not run on this recovery's kernel, looking for the recovery's busybox"
    for cand in /sbin/busybox /system/bin/busybox /sbin/busybox.static; do
        if [ -x $cand ] && busybox_works $cand; then
            echo "Using $cand"
            bb=$cand
            break
        fi
    done
fi

backup() {
    mkdir -p $backup_dir
    if [ -d $2 ]; then
        echo "Removing previous backout of $1"
        rm -rf $2
    fi
    if [ -d $1 ]; then
        echo "Backing up $1 to $2"
        mv $1 $2
    fi
}

restore() {
    if [ -d $2 ]; then
        echo "Restoring $1 from $2"
        rm -rf $1
        mv $2 $1
    fi
}

cleanup_artifacts() {
    # Before we switched to LuneOS as distro name it was simply webOS and therefore remove
    # the old directory to not take too much of the internal memory for unused things.
    if [ -d /data/webos ] ; then
        echo "Removing unused /data/webos directory"
        rm -rf /data/webos
    fi
}

is_number() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
    esac
    return 0
}

# Free space on /data in KiB. busybox df prints the device on a line of its own
# when its name is long, so take the field from the end of the last line.
data_free_kb() {
    $bb df -k /data | $bb tail -n 1 | $bb awk '{ print $(NF-2) }'
}

# Give up: say why, and take the tarball and any half-unpacked tree with us, so
# that /data is not left full. The exit status makes the updater abort before it
# flashes a kernel that would not match the rootfs.
fail() {
    echo "ERROR: $*"
    rm -rf $tmp_extract $tmp_extract-failed
    rm -f $tarball
    if [ -d $target_dir ]; then
        echo "The previous LuneOS installation in $target_dir was left as it was."
    else
        echo "There is no LuneOS installation on this device any more. Fix the problem above and flash again."
    fi
    echo "LuneOS was NOT installed."
    exit 1
}

# Unpack the tarball into an empty $tmp_extract with the busybox (or loader and
# busybox) given, keeping tar's messages so a failure's cause can be told apart.
extract_with() {
    rm -rf $tmp_extract
    mkdir $tmp_extract
    "$@" tar --numeric-owner -xzf $tarball -C $tmp_extract 2>$tar_log
    ret=$?
    cat $tar_log
    return $ret
}

out_of_space() {
    $bb grep -q "No space left on device" $tar_log
}

# The dynamic loader of an unpacked rootfs: ld-linux-armhf.so.3 on armv7,
# ld-linux-aarch64.so.1 on aarch64, ld-linux-x86-64.so.2 on x86-64.
find_loader() {
    for l in "$1"/lib/ld-linux*.so.[0-9]; do
        if [ -f "$l" ]; then
            echo "$l"
            return 0
        fi
    done
    return 1
}

# Retry with the busybox of an unpacked rootfs, for recoveries whose tar is
# broken in a way the busybox_works probe does not catch.
extract_with_rootfs_busybox() {
    loader=$(find_loader "$1") || return 1
    [ -f "$1/bin/busybox.nosuid" ] || return 1
    echo "Trying with the busybox from $1"
    (
        export LD_LIBRARY_PATH="$1/lib/"
        extract_with "$loader" "$1/bin/busybox.nosuid"
    )
}

# Decide before writing anything whether the new rootfs fits next to the old one,
# fits only once the old one is gone, or does not fit at all. Unpacking next to
# the old rootfs needs room for both plus the tarball, which a small /data (the
# 5.7 GB of a 16 GB Nexus 4) does not have.
check_space() {
    size=$(cat $size_file 2>/dev/null)
    if ! is_number "$size"; then
        echo "No rootfs size in the package, skipping the free space check"
        return 0
    fi
    free=$(data_free_kb)
    if ! is_number "$free"; then
        echo "Could not read the free space on /data, skipping the free space check"
        return 0
    fi
    # 10% on top, for the filesystem's own metadata and the estimate's error
    need=$((size + size / 10))
    old=0
    if [ -d $target_dir ]; then
        old=$($bb du -sk $target_dir | $bb awk '{ print $1 }')
        is_number "$old" || old=0
    fi
    echo "Space on /data: $((free / 1024)) MB free, the new rootfs needs $((need / 1024)) MB, the old one takes $((old / 1024)) MB"

    if [ "$need" -le "$free" ]; then
        return 0
    fi
    if [ $need -le $((free + old)) ]; then
        echo "Not enough space to keep the old rootfs while unpacking, removing $target_dir first"
        rm -rf $target_dir
        return 0
    fi
    fail "Not enough space on /data even after removing the old rootfs: $((need / 1024)) MB needed, $(((free + old) / 1024)) MB available. Free up space in /data (for example /data/media) and flash again."
}

deploy_luneos() {
    echo "Cleaning up left over artifacts ..."
    cleanup_artifacts
    rm -rf $tmp_extract $tmp_extract-failed

    echo "Deploying LuneOS ..."
    check_space

    echo "Extracting $tarball to $tmp_extract"
    if ! extract_with $bb; then
        if out_of_space; then
            if [ ! -d $target_dir ]; then
                fail "Ran out of space on /data while unpacking the rootfs."
            fi
            echo "Ran out of space with the old rootfs still in place, removing $target_dir and trying again"
            rm -rf $tmp_extract $target_dir
            extract_with $bb || fail "Ran out of space on /data while unpacking the rootfs, even with the old rootfs removed."
        else
            echo "Failed to extract LuneOS with $bb, trying the busybox of a LuneOS rootfs instead"
            # A partial unpack may already hold a working busybox
            rm -rf $tmp_extract-failed
            mv $tmp_extract $tmp_extract-failed
            if ! extract_with_rootfs_busybox $tmp_extract-failed &&
               ! extract_with_rootfs_busybox $target_dir; then
                fail "Failed to extract LuneOS with $bb, and with the busybox of the partially unpacked or the previously installed rootfs."
            fi
            rm -rf $tmp_extract-failed
        fi
    fi

    echo "Removing $tarball"
    rm $tarball
    if [ -d $target_dir ]; then
        echo "Removing old $target_dir"
        rm -rf $target_dir
    fi
    echo "Moving $tmp_extract to $target_dir"
    mv $tmp_extract $target_dir
    rm -rf $tmp_extract

    # Recreate symlink for Halium
    rm -rf /data/halium-rootfs
    if [ ! -e /data/halium-rootfs ]; then
        echo "Adding /data/halium-rootfs symlink to /data/luneos"
        ln -sf luneos /data/halium-rootfs
    fi

    # Only after the new rootfs is in place, so that a failed install leaves the
    # old one as it was
    echo "Remove firstboot flag"
    if [ -f /data/luneos-data/.firstboot_done ]; then
        rm -f /data/luneos-data/.firstboot_done
    fi

    echo "Done with deploying LuneOS!!!"
}

deploy_luneos

rm -rf $backup_dir
