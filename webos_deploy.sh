#!/sbin/sh

target_dir=/data/luneos
backup_dir=/data/luneos_bak

tmp_extract=/data/luneos_tmp_extract

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

deploy_luneos() {
    echo "Cleaning up left over artifacts ..."
    cleanup_artifacts

    echo "Remove firstboot flag"
    if [ -f /data/luneos-data/.firstboot_done ]; then
        rm -f /data/luneos-data/.firstboot_done
    fi

    echo "Deploying LuneOS ..."
    if [ -d $tmp_extract ]; then
        rm -rf $tmp_extract
    fi
    mkdir $tmp_extract

    echo "Extracting /data/webos-rootfs.tar.gz to $tmp_extract"
    $bb tar --numeric-owner -xzf /data/webos-rootfs.tar.gz -C $tmp_extract
    if [ $? -ne 0 ] ; then
        echo "ERROR: Failed to extract LuneOS on the internal memory. Not enough free space left to install LuneOS, or the busybox ($bb) does not work on this recovery?" >&2
        if ls $tmp_extract/lib/ld-linux-*.so.1 $tmp_extract/bin/busybox.nosuid >/dev/null 2>/dev/null; then
            echo "Trying with busybox already unpacked from webos-rootfs (hopefully)"
            rm -rf $tmp_extract-failed
            mv $tmp_extract $tmp_extract-failed
            mkdir $tmp_extract
            LD_LIBRARY_PATH=$tmp_extract-failed/lib/ $tmp_extract-failed/lib/ld-linux-*.so.1 $tmp_extract-failed/bin/busybox.nosuid tar -xzf /data/webos-rootfs.tar.gz -C $tmp_extract
            if [ $? -ne 0 ] ; then
                echo "ERROR: Failed to extract LuneOS even with busybox from partially unpacked webos-rootfs, giving up"
                echo "Leaving $tmp_extract-failed behind, so that you can check what went wrong"
                exit 1
            else
                rm -rf $tmp_extract-failed
            fi
        else
            echo "ERROR: There isn't even partially unpacked $tmp_extract with $tmp_extract/lib/ld-linux-*.so.1 and $tmp_extract/bin/busybox.nosuid"
            if ls $target_dir/lib/ld-linux-*.so.1 $target_dir/bin/busybox.nosuid >/dev/null 2>/dev/null; then
                echo "Trying with busybox from previous luneos installation in $target_dir"
                rm -rf $tmp_extract-failed
                rm -rf $tmp_extract
                mkdir $tmp_extract
                LD_LIBRARY_PATH=$target_dir/lib/ $target_dir/lib/ld-linux-*.so.1 $target_dir/bin/busybox.nosuid tar -xzf /data/webos-rootfs.tar.gz -C $tmp_extract
                if [ $? -ne 0 ] ; then
                    echo "ERROR: Failed to extract LuneOS even with busybox from previous luneos installation in $target_dir"
                    exit 1
                fi
            else
                echo "ERROR: There isn't busybox and ld-linux from previous luneos installation in $target_dir/lib/ld-linux-*.so.1 and $target_dir/bin/busybox.nosuid"
                exit 1
            fi
        fi
    fi

    echo "Removing /data/webos-rootfs.tar.gz"
    rm /data/webos-rootfs.tar.gz
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

    echo "Done with deploying LuneOS!!!"
}

deploy_luneos

rm -rf $backup_dir
