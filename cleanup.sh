#!/bin/bash
#
# Undo the staging: drop the one-shot UEFI shell boot entry and the files it used.
# unlock.sh runs this at the end; running it by hand is safe at any point.
#
set -euo pipefail

ESP="${ESP:-/boot/efi}"
LABEL="UEFI Shell (tcc)"
FILES="shellx64.efi setup_var.efi tccread.nsh tccunlock.nsh"

[ "$(id -u)" = 0 ] || { echo "run with sudo (keeping ESP= if you set it)"; exit 1; }

entries=$(efibootmgr | grep -F "$LABEL" | cut -c5-8 || true)  # no match is fine
bootnext=$(efibootmgr | awk '/^BootNext:/ { print $2 }')

for entry in $entries; do
	efibootmgr -q -b "$entry" -B  # -B also takes it out of BootOrder

	# Clear BootNext if it points at the entry just deleted: the firmware reuses entry
	# numbers, so a future entry could inherit it and be booted once by surprise.
	[ "$bootnext" != "$entry" ] || efibootmgr -q -N
done

# Only the files staged by unlock.sh: EFI/tools is a shared location that may hold other
# vendors' tools, so the directory itself goes only if it ends up empty.
for file in $FILES; do
	rm -f "$ESP/EFI/tools/$file"
done
rmdir "$ESP/EFI/tools" 2>/dev/null || true

efibootmgr | head -4 || true
