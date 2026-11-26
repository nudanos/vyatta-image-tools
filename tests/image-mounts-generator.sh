#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
set -eu

generator=${1:-../systemd/system-generators/vyatta-image-mounts-generator}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/generated"
touch "$work/unavailable-system-directory"
cat > "$work/vyatta-live-image" <<'EOF'
#!/bin/sh
case "$1" in
    get_live_rootfs_path) echo /run/live/persistence/vda2 ;;
    get_image_path) echo /run/live/persistence/vda2/boot/test-image ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$work/vyatta-live-image"
sed -e "s|/opt/vyatta/sbin/vyatta-live-image|$work/vyatta-live-image|g" \
    -e "s|/lib/systemd/system|$work/unavailable-system-directory|g" \
    "$generator" > "$work/generator"
sh "$work/generator" "$work/generated"

for unit in boot.mount boot-grub.mount device\\x2dcache.mount; do
    test -f "$work/generated/$unit"
    test "$work/generated/config-loaded.target.wants/$unit" -ef "$work/generated/$unit"
done
grep -Fx 'What=/run/live/persistence/vda2/boot/test-image' "$work/generated/boot.mount"
grep -Fx 'What=/run/live/persistence/vda2/boot/grub' "$work/generated/boot-grub.mount"
grep -Fx 'RequiresMountsFor=/boot' "$work/generated/boot-grub.mount"
