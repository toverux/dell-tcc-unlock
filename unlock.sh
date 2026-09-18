#!/bin/bash
#
# Unlock the Intel TCC offset, end to end. Run it, answer the prompts, reboot when asked,
# then run it again. It works out for itself which half of the job is left:
#
#   lock byte reads 01 -> find the offset, stage a UEFI shell, reboot into it
#   lock byte reads 00 -> apply the offset, install the boot-time service, clean up
#
# This script never writes to firmware. The UEFI shell does that, and only after you have
# seen the value it is about to change.
#
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

ESP="${ESP:-/boot/efi}"    # EFI System Partition mountpoint
LABEL="UEFI Shell (tcc)"   # boot entry label; cleanup.sh looks for the same one
STATE=.tcc-target          # remembers e.g. "CpuSetup:0x1CD" between the two runs

SHELL_URL=https://github.com/pbatard/UEFI-Shell/releases/latest/download/shellx64.efi
# Pinned: the generated .nsh scripts depend on setup_var.efi's 0.3.x "NAME:OFFSET=VALUE"
# grammar, and on a write defaulting to one byte.
SETUP_VAR_URL=https://github.com/datasone/setup_var.efi/releases/download/0.3.1/setup_var.efi

if [ -t 1 ]; then
	BOLD=$'\e[1m'; RED=$'\e[1;91m'; OFF=$'\e[0m'
else
	BOLD=''; RED=''; OFF=''
fi

# Step header.
say() {
	printf '\n%s=== %s%s\n\n' "$BOLD" "$*" "$OFF"
}

# Ask before doing something; answering no stops the script. Enter means yes, end of input
# counts as no.
confirm() {
	if ! read -r -p "$* [Y/n] " answer; then
		printf '\nNo answer given, stopping.\n'
		exit 1
	fi

	case "${answer:-y}" in
	[nN]*) echo "Stopped. Nothing further was changed."; exit 1 ;;
	esac
}

# Ask a question that defaults to yes. Returns 0 for yes, 1 for no, 1 at end of input.
ask_yes() {
	if ! read -r -p "$* [Y/n] " answer; then
		printf '\n'
		return 1
	fi

	case "${answer:-y}" in
	[nN]*) return 1 ;;
	*) return 0 ;;
	esac
}

# Read one byte of a live EFI variable. $1 is "<varstore>:<offset>", e.g. CpuSetup:0x1CD.
# efivarfs files begin with 4 attribute bytes, which is where the +4 comes from.
live_byte() {
	local file
	file=$(find /sys/firmware/efi/efivars -maxdepth 1 -name "${1%%:*}-*" | head -1)

	[ -n "$file" ] || return 1
	cat "$file" | od -An -tx1 -j $((4 + ${1#*:})) -N1 | tr -d ' '
}

# ---------------------------------------------------------------- find the offset

if [ ! -f "$STATE" ]; then
	say "Step 1 of 4 - find the lock option in your own BIOS"
	cat <<'TXT'
Your firmware hides a setup option, "Tcc Offset Lock Enable", that locks the CPU
register holding the TCC offset. Clearing it needs that option's byte offset, which
differs per model and BIOS version, so it has to come from your own BIOS image.

findoffset.sh downloads your BIOS package, dumps its hidden setup forms, and prints
each TCC option together with the value that byte holds on this machine right now.
It changes nothing.
TXT
	confirm "Run the BIOS analysis now?"

	# tee to stderr so its progress stays visible while stdout is captured.
	output=$(./findoffset.sh | tee /dev/stderr)

	# Only accept an option whose byte reads 01 on this machine: that is the cross-check
	# that the dump belongs to this firmware. Anything else is reported, never guessed at.
	mapfile -t candidates < <(awk '
		/Tcc Offset Lock Enable/ && $1 ~ /^[A-Za-z0-9_]+:0x[0-9A-Fa-f]+$/ && $NF == "01" { print $1 }
	' <<<"$output")

	if [ "${#candidates[@]}" -eq 0 ]; then
		echo "No 'Tcc Offset Lock Enable' option reads 01 on this machine."
		echo "Either the lock is already clear, or this BIOS image is not the one running here."
		exit 1
	elif [ "${#candidates[@]}" -gt 1 ]; then
		echo "More than one locked candidate: ${candidates[*]}"
		echo "Pick the right one, write it to $STATE, and run again."
		exit 1
	fi

	echo "${candidates[0]}" > "$STATE"
fi

TARGET=$(cat "$STATE")

# The state file is meant to be hand-editable, so check it before doing arithmetic on it.
[[ "$TARGET" =~ ^[A-Za-z]+:0x[0-9A-Fa-f]+$ ]] ||
	{ echo "$STATE should hold one line like CpuSetup:0x1CD, not '$TARGET'."; exit 1; }

LOCK=$(live_byte "$TARGET" || echo none)

# ---------------------------------------------------------------- stage the UEFI shell

if [ "$LOCK" = 01 ]; then
	say "Step 2 of 4 - stage a UEFI shell"

	# An unsigned shell will not boot with Secure Boot on, and the firmware just skips it,
	# which looks exactly like nothing happening. Catch it before staging anything.
	if command -v mokutil >/dev/null && mokutil --sb-state 2>/dev/null | grep -qi enabled; then
		echo "Secure Boot is enabled, and the UEFI shell is unsigned, so it will not boot."
		echo "Turn Secure Boot off in the BIOS, then run this again."
		exit 1
	fi

	cat <<TXT
$TARGET reads 01 here, so the lock is set and the offset from the dump lines up with
this machine. Linux cannot clear it: the firmware refuses writes to this variable once
the OS is running. A UEFI shell, run before the OS starts, can.

About to:
  - download the EDK2 UEFI shell and setup_var.efi
  - keep a copy of the current $TARGET variable in ${TARGET%%:*}-backup.bin, for reference
    only: Linux cannot write it back, so recovery is the RTC reset in the README
  - copy both, plus two one-line scripts, to $ESP/EFI/tools
  - add a "$LABEL" boot entry and set BootNext, which applies to the next boot only
TXT
	confirm "Stage it?"

	curl -fsSL -o shellx64.efi "$SHELL_URL"
	curl -fsSL -o setup_var.efi "$SETUP_VAR_URL"

	# Generated so the offset is never retyped by hand at the shell prompt.
	echo "setup_var.efi $TARGET" > tccread.nsh
	printf 'setup_var.efi %s=0x00\nsetup_var.efi %s\n' "$TARGET" "$TARGET" > tccunlock.nsh

	variable=$(find /sys/firmware/efi/efivars -maxdepth 1 -name "${TARGET%%:*}-*" | head -1)
	[ -n "$variable" ] || { echo "The ${TARGET%%:*} variable disappeared; stopping."; exit 1; }
	cat "$variable" > "${TARGET%%:*}-backup.bin"

	sudo mkdir -p "$ESP/EFI/tools"
	for file in shellx64.efi setup_var.efi tccread.nsh tccunlock.nsh; do
		sudo cp "$file" "$ESP/EFI/tools/$file"
		sudo cmp "$file" "$ESP/EFI/tools/$file"
	done

	# efibootmgr wants the disk and the partition number the ESP lives on.
	device=$(findmnt -no SOURCE "$ESP")
	partition=$(cat "/sys/class/block/$(basename "$device")/partition")
	disk="/dev/$(lsblk -no PKNAME "$device")"

	# Drop any entry left over from an earlier attempt, so this run cannot pick the wrong one.
	for stale in $(efibootmgr | grep -F "$LABEL" | cut -c5-8); do
		sudo efibootmgr -q -b "$stale" -B
	done

	order=$(efibootmgr | awk '/^BootOrder:/ { print $2 }')
	sudo efibootmgr -q -c -d "$disk" -p "$partition" -L "$LABEL" -l '\EFI\tools\shellx64.efi'
	[ -z "$order" ] || sudo efibootmgr -q -o "$order"  # -c puts the new entry first; restore the old order

	entry=$(efibootmgr | grep -F "$LABEL" | cut -c5-8 | head -1 || true)
	[ -n "$entry" ] || { echo "The boot entry was not created; nothing will boot the shell."; exit 1; }
	sudo efibootmgr -q -n "$entry"

	# The shell numbers every FAT volume it finds, so the ESP is often not fs0. Its line in
	# `map -r` is the one carrying this partition GUID, printed here in the shell's case.
	esp_guid=$(lsblk -no PARTUUID "$device" | tr 'a-f' 'A-F')

	say "Step 3 of 4 - what to type in the shell after the reboot"
	cat <<TXT
Save these commands before rebooting - photograph the screen, or copy them to your
phone. Once the machine boots into the shell this screen is gone, and the shell has no
way to show it to you.

  Shell> map -r                    lists every volume; yours is the FSx line whose
                                   device path ends with the GUID below
  Shell> fs0:                      usually fs0, but not always
  FS0:\> cd EFI\tools
  FS0:\EFI\tools\> tccread.nsh     expect $TARGET to read 0x01
  FS0:\EFI\tools\> tccunlock.nsh   writes 0x00, then reads it back
  FS0:\EFI\tools\> reset           leaves the shell and boots Linux again

Your ESP is the one containing:  $esp_guid

The table can be long. If you would rather not read it, try the volumes in turn -
'ls fs0:\EFI\tools', 'ls fs1:\EFI\tools' - and use the one listing tccread.nsh.

${RED}If tccread.nsh shows anything other than 0x01, type reset; nothing will have changed.${OFF}

After 'reset' the machine boots back into Linux normally. Log in and run

  $(pwd)/unlock.sh

a second time: it sets the offset, installs the service that restores it at every boot,
and removes the shell files and the boot entry. Do this whether the unlock worked or not.
TXT
	confirm "Commands saved - reboot into the shell now?"
	sudo reboot

# ---------------------------------------------------------------- apply the offset

elif [ "$LOCK" = 00 ]; then
	say "Step 4 of 4 - apply the offset and tidy up"

	sysfs=$(find /sys/devices -name tcc_offset_degree_celsius | head -1)
	[ -n "$sysfs" ] || { echo "No tcc_offset_degree_celsius in sysfs on this machine."; exit 1; }

	cat <<TXT
$TARGET reads 00, so the lock is clear. The offset itself is not kept in firmware, so a
small systemd unit writes it at every boot. Suspend needs no handling: the kernel saves
the offset and restores it on resume.
TXT
	if ! read -r -p "Degrees below TjMax to throttle at (10 means 90C) [10]: " degrees; then
		printf '\nNo answer given, stopping.\n'
		exit 1
	fi
	degrees=${degrees:-10}

	[[ "$degrees" =~ ^[0-9]+$ ]] && [ "$degrees" -le 63 ] ||
		{ echo "The offset has to be a whole number of degrees, 0 to 63."; exit 1; }

	degrees=$((10#$degrees))  # drop leading zeros; sysfs echoes the value back without them

	# A refused write means the unlock did not take. tee's exit status is not proof on its
	# own, so read the value back out of sysfs.
	echo "$degrees" | sudo tee "$sysfs" >/dev/null || true

	if [ "$(cat "$sysfs")" != "$degrees" ]; then
		echo "The firmware still refuses the offset, so the unlock did not take. Nothing is harmed."
		exit 1
	fi
	echo "Offset now reads $(cat "$sysfs") degrees below TjMax."

	sudo tee /etc/systemd/system/tcc-offset.service >/dev/null <<TXT
[Unit]
Description=Set the Intel TCC offset to $degrees (throttle $degrees C below TjMax)

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'echo $degrees > $sysfs'

[Install]
WantedBy=multi-user.target
TXT
	sudo systemctl daemon-reload
	sudo systemctl enable --now tcc-offset.service
	echo "Installed tcc-offset.service, so the offset comes back after every boot."

	if ask_yes "Remove the UEFI shell files and its boot entry now?"; then
		sudo ESP="$ESP" ./cleanup.sh
		rm -f "$STATE" shellx64.efi setup_var.efi tccread.nsh tccunlock.nsh
	else
		echo "Left in place. Run 'sudo ESP=$ESP ./cleanup.sh' whenever you want them gone."
	fi

	say "Done. To see it working, load every core and watch the package temperature:"
	cat <<TXT
  stress-ng --cpu 0 --cpu-method matrixprod --timeout 180s
  sudo turbostat --quiet --show PkgTmp,PkgWatt,Avg_MHz --interval 2

PkgTmp should climb and then hold about $degrees C below TjMax (100C on most laptops),
with Avg_MHz dropping as it holds there. This counter climbs whenever the thermal
control circuit engages, which is the hardware doing it rather than any daemon:

  cat /sys/devices/system/cpu/cpu0/thermal_throttle/package_throttle_count
TXT

else
	echo "$TARGET reads '$LOCK'; expected 01 (locked) or 00 (unlocked)."
	echo "Delete $STATE and run again to redo the BIOS analysis."
	exit 1
fi
