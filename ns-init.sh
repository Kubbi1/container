#!/bin/bash
# ----------------------------------------------------------------------------
# Init-script with pivot_root
# ----------------------------------------------------------------------------
set -e
NEWROOT="MERGED_PATH"
echo "[info] FS mounted at $NEWROOT "
# Делаем propagation приватным, чтобы pivot_root/umount не утекли в mount-namespace хоста
mount --make-rprivate /

# pivot_root требует, чтобы новый корень был mount-point в ТЕКУЩЕМ namespace
mount --bind "$NEWROOT" "$NEWROOT"

cd "$NEWROOT"
mkdir -p oldroot
pivot_root . oldroot

# теперь / этого mount-namespace - это то, что раньше было $NEWROOT
cd /

mount -t proc proc /proc
mount -t sysfs sysfs /sys 2>/dev/null || true
mount -t tmpfs tmpfs /dev 2>/dev/null || true
mkdir -p /dev/pts /dev/shm
mount -t devpts devpts /dev/pts 2>/dev/null || true

# отмнотируем старый корень
umount -l /oldroot
rmdir /oldroot
exec /bin/sleep infinity
