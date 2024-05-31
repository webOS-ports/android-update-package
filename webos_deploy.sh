#!/sbin/sh

target_dir=/data/luneos
backup_dir=/data/luneos_bak

tmp_extract=/data/luneos_tmp_extract

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
    /tmp/busybox-static tar --numeric-owner -xzf /data/webos-rootfs.tar.gz -C $tmp_extract
    rc=$?
    if [ $rc -ne 0 ] ; then
        echo "ERROR: Failed to extract LuneOS on the internal memory. Propably not enough free space left to install LuneOS?" >&2
        if ls $tmp_extract/lib/ld-linux-*.so.* $tmp_extract/bin/busybox.nosuid >/dev/null 2>/dev/null; then
            echo "Trying with busybox already unpacked from webos-rootfs (hopefully)"
            rm -rf $tmp_extract-failed
            mv $tmp_extract $tmp_extract-failed
            mkdir $tmp_extract
            LD_LIBRARY_PATH=$tmp_extract-failed/lib/ $tmp_extract-failed/lib/ld-linux-*.so.* $tmp_extract-failed/bin/busybox.nosuid tar -xzf /data/webos-rootfs.tar.gz -C $tmp_extract
            rc=$?
            if [ $rc -ne 0 ] ; then
                echo "ERROR: Failed to extract LuneOS even with busybox from partially unpacked webos-rootfs"
            else
                rm -rf $tmp_extract-failed
            fi
        else
            echo "ERROR: There isn't even partially unpacked $tmp_extract with $tmp_extract/lib/ld-linux-*.so.* and $tmp_extract/bin/busybox.nosuid"
            if ls $target_dir/lib/ld-linux-*.so.* $target_dir/bin/busybox.nosuid >/dev/null 2>/dev/null; then
                echo "Trying with busybox from previous luneos installation in $target_dir"
                rm -rf $tmp_extract-failed
                rm -rf $tmp_extract
                mkdir $tmp_extract
                LD_LIBRARY_PATH=$target_dir/lib/ $target_dir/lib/ld-linux-*.so.* $target_dir/bin/busybox.nosuid tar -xzf /data/webos-rootfs.tar.gz -C $tmp_extract
                rc=$?
                if [ $rc -ne 0 ] ; then
                    echo "ERROR: Failed to extract LuneOS even with busybox from previous luneos installation in $target_dir"
                fi
            else
                echo "ERROR: There isn't busybox and ld-linux from previous luneos installation in $target_dir/lib/ld-linux-*.so.1 and $target_dir/bin/busybox.nosuid"
            fi
        fi
    fi
    if [ $rc -ne 0 ] && [ -x "$(which tar)" ] ; then
        echo "Trying again with tar from Android recovery rootfs ($(which tar))"
        rm -rf $tmp_extract-failed
        rm -rf $tmp_extract
        mkdir $tmp_extract
        tar -xzf /data/webos-rootfs.tar.gz -C $tmp_extract
        rc=$?
        if [ $rc -ne 0 ] ; then
            echo "ERROR: Failed to extract LuneOS even using tar from Android recovery"
        fi
    fi
    if [ $rc -ne 0 ] ; then
        echo "ERROR: couldn't recover from previous errors: exiting with error."
        exit 1
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
