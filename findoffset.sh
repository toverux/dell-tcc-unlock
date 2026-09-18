#!/bin/bash
#
# Print the TCC setup options hidden in a BIOS image, with their varstore and byte offset,
# and the value each byte holds on this machine right now.
#
#   ./findoffset.sh                       look up and download this machine's BIOS package
#   ./findoffset.sh XPS_9730_1.27.0.exe   use a Dell .exe, or a raw SPI image
#
# Needs curl, unzip, 7z, and python3 with pip. Everything lands in a temporary directory.
#
set -euo pipefail

ARG="${1:-}"
[ -z "$ARG" ] || IMG="$(readlink -f "$ARG")"

WORK=$(mktemp -d)
trap 'echo "work dir: $WORK"' EXIT
cd "$WORK"

# ---------------------------------------------------------------- get the BIOS package

# With no argument, ask Dell's catalog for the package matching this machine's model and
# BIOS version. The catalog is a 3 MB cab holding one big UTF-16 XML.
if [ -z "$ARG" ]; then
	MODEL=$(tr ' ' '-' < /sys/class/dmi/id/product_name)
	VERSION=$(cat /sys/class/dmi/id/bios_version)

	echo "Looking up $MODEL BIOS $VERSION in the Dell catalog"
	curl -fsSO https://downloads.dell.com/catalog/CatalogPC.cab
	7z x -y CatalogPC.cab >/dev/null

	URL=$(python3 - "$MODEL" "$VERSION" <<'EOF'
import re, sys

model, version = sys.argv[1], sys.argv[2]
found = []

for blk in open('CatalogPC.xml', encoding='utf-16').read().split('<SoftwareComponent ')[1:]:
    blk = blk.split('</SoftwareComponent>')[0]
    if '<ComponentType value="BIOS">' not in blk or f'<![CDATA[{model}]]>' not in blk:
        continue
    head = blk[:blk.find('>')]
    found.append((re.search(r'vendorVersion="([^"]+)"', head).group(1),
                  'https://downloads.dell.com/' + re.search(r'path="([^"]+)"', head).group(1)))

for ver, url in found:
    if ver == version:
        print(url)
        break
else:
    sys.exit(f"no {model} BIOS {version} in the catalog; it lists: "
             + (', '.join(v for v, _ in found) or 'nothing for this model'))
EOF
)
	echo "Downloading $URL"
	curl -fL#O "$URL"
	IMG="$WORK/$(basename "$URL")"
fi

[ -f "$IMG" ] || { echo "usage: $0 [BIOS .exe or .bin]"; exit 1; }

# ---------------------------------------------------------------- unpack it

curl -fsSLO https://github.com/LongSoft/UEFITool/releases/download/A75/UEFIExtract_NE_A75_x64_linux.zip
curl -fsSLO https://github.com/LongSoft/IFRExtractor-RS/releases/download/v1.6.1/ifrextractor_1.6.1_linux.zip
unzip -oq UEFIExtract_NE_A75_x64_linux.zip
unzip -oq ifrextractor_1.6.1_linux.zip

# A Dell update is a Windows executable with the firmware appended, which UEFIExtract
# cannot read. Unwrap it first and take the largest System BIOS image inside.
if [ "$(head -c2 "$IMG")" = "MZ" ]; then
	pip install -q --target pylib --break-system-packages --ignore-installed biosutilities

	PYTHONPATH=pylib python3 - "$IMG" <<'EOF' >/dev/null
import sys

from biosutilities.dell_pfs_extract import DellPfsExtract

DellPfsExtract(input_object=sys.argv[1], extract_path='pfs').parse_format()
EOF

	IMG=$(find pfs -name '*System BIOS*.bin' -printf '%s %p\n' | sort -rn | head -1 | cut -d' ' -f2- || true)
	[ -n "$IMG" ] || { echo "no System BIOS image found in the package"; exit 1; }
fi

# Split the image into its modules, then dump the setup forms (IFR) of every Setup module.
cp "$IMG" image.bin
./uefiextract image.bin >/dev/null

find image.bin.dump -type d -name '*Setup*' -exec find {} -path '*PE32*' -name body.bin \; |
	while IFS= read -r body; do ./ifrextractor "$body" >/dev/null </dev/null || true; done

find image.bin.dump -name '*.ifr.txt' -print -quit | grep -q . ||
	{ echo "No setup forms could be dumped from this image."; exit 1; }

# ---------------------------------------------------------------- report the offsets

# Each dump lists its varstores, then the options that live in them. VarStoreIds are only
# unique within one dump, so the map is cleared per file and an id whose varstore has no
# name is dropped - otherwise a later option inherits an earlier file's varstore name and
# the offset gets attributed to the wrong variable.
find image.bin.dump -name '*.ifr.txt' -exec awk '
FNR == 1 { delete store }

/VarStore(Efi)? Guid:/ {
	id = name = ""
	if (match($0, /VarStoreId: 0x[0-9A-Fa-f]+/)) id = substr($0, RSTART+12, RLENGTH-12)
	if (match($0, /Name: "[^"]+"/)) name = substr($0, RSTART+7, RLENGTH-8)
	if (id != "" && name != "") store[id] = name
	else if (id != "") delete store[id]
}
/Prompt: "Tcc (Activation Offset|Offset Lock Enable)"/ {
	# Cleared every time: an option line missing one of these fields must not inherit the
	# value from the line before, which is how a right-looking row ends up with a wrong
	# offset. varid is kept separate from the id used in the varstore block, for the same
	# reason.
	prompt = varid = offset = ""
	if (match($0, /Prompt: "[^"]+"/)) prompt = substr($0, RSTART+9, RLENGTH-10)
	if (match($0, /VarStoreId: 0x[0-9A-Fa-f]+/)) varid = substr($0, RSTART+12, RLENGTH-12)
	if (match($0, /VarOffset: 0x[0-9A-Fa-f]+/)) offset = substr($0, RSTART+11, RLENGTH-11)

	if (prompt != "" && varid != "" && offset != "" && varid in store)
		printf "%s %s %s\n", store[varid], offset, prompt
}' {} + | sort -u | while IFS= read -r varstore off prompt; do
	# Ignore anything that is not a hex offset, so it can never reach the arithmetic below.
	case "$off" in 0x[0-9A-Fa-f]*) ;; *) continue ;; esac

	# The cross-check: read the same byte out of the live variable on this machine.
	# efivarfs files begin with 4 attribute bytes, hence the +4.
	file=$(find /sys/firmware/efi/efivars -maxdepth 1 -name "$varstore-*" | head -1)

	if [ -z "$file" ]; then
		now="no $varstore variable on this machine"
	elif ! now=$(cat "$file" | od -An -tx1 -j $((4 + off)) -N1 2>/dev/null | tr -d ' ') || [ -z "$now" ]; then
		now="offset is past the end of $varstore - wrong BIOS?"
	fi

	printf '%s:%s   %-24s live: %s\n' "$varstore" "$off" "$prompt" "$now"
done
