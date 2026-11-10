#!/sbin/sh

# Based on
# https://forum.xda-developers.com/showthread.php?t=1023150
# Changed the binary name, because in our case the update binary isn't called
# update_binary as on the forum, nor update-binary as in our .zip file, but
# just /tmp/updater, that's why the ps call never catched the right line and
# correct FD
# Also fix the test for empty OUTFD to use -n, otherwise it fails with
# sh: : unknown operand
# when it was really empty (because of missing quotes around $OUTFD)
OUTFD=$(ps | grep -v "grep" | grep -o -E "updater(.*)" | cut -d " " -f 3)


# The exit status of a pipeline is that of its last command, the while loop, so
# the script's own status is passed out through a file. Without it the updater
# could not tell that the deploy failed.
status_file=/tmp/ui-print-wrapper.status
echo 1 > $status_file

{ /sbin/sh "$@" 2>&1; echo $? > $status_file; } | while read -r line; do
    if [ -n "$OUTFD" ] ; then
        echo "ui_print $line" >&$OUTFD;
        echo "ui_print " >&$OUTFD;
    else
        echo "$line"
    fi
done

exit "$(cat $status_file)"
