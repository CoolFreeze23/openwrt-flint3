. /lib/upgrade/common.sh

glinet_get_fit_part() {
	local image="$1"
	local name="$2"

	dumpimage -l "$image" 2>/dev/null | \
		sed -n "s/^[[:space:]]*Image \([0-9][0-9]*\) ($name)$/\1/p"
}

glinet_emmc_check_image() {
	[ "$(identify_magic_long "$(get_magic_long "$1")")" != "fit" ] && return 0

	local hlos=$(glinet_get_fit_part "$1" hlos)
	local rootfs=$(glinet_get_fit_part "$1" rootfs)
	[ -n "$hlos" ] && [ -n "$rootfs" ] || {
		v "The factory image must contain hlos and rootfs sections."
		return 1
	}

	# The FIT path writes whole partitions and has nowhere to put a config
	# backup (emmc_copy_config only works after the sysupgrade-tar path), so
	# "keep settings" would be dropped silently. Say so up front.
	type notify_firmware_no_backup >/dev/null 2>&1 && notify_firmware_no_backup
	[ "$SAVE_CONFIG" = 1 ] && {
		v "Factory and stock images cannot keep settings; use sysupgrade -n."
		return 1
	}

	return 0
}

glinet_emmc_staged() {
	echo "/tmp/glinet-emmc-$1.bin"
}

# Extract one FIT section to /tmp and check that it fits its partition.
# Nothing on the eMMC is touched here.
glinet_emmc_stage_fit_part() {
	local image="$1"
	local part="$2"
	local device="$3"
	local name="$4"
	local output="$(glinet_emmc_staged "$name")"
	local size limit

	v "Extracting $name"
	rm -f "$output"
	dumpimage -T flat_dt -p "$part" -o "$output" "$image" >/dev/null 2>&1 &&
		[ -s "$output" ] || {
		v "Unable to extract $name from the image."
		return 1
	}

	size=$(wc -c < "$output")
	limit=$(( $(cat "/sys/class/block/${device##*/}/size" 2>/dev/null || echo 0) * 512 ))
	[ "$size" -le "$limit" ] || {
		v "$name ($size bytes) does not fit $device ($limit bytes)."
		return 1
	}
}

glinet_emmc_write_staged() {
	local name="$1"
	local device="$2"

	v "Writing $name to $device"
	dd if="$(glinet_emmc_staged "$name")" of="$device" bs=1M conv=fsync
}

glinet_emmc_cleanup_staged() {
	rm -f "$(glinet_emmc_staged hlos)" "$(glinet_emmc_staged rootfs)" \
		"$(glinet_emmc_staged wifi_fw)"
}

glinet_emmc_do_fit_upgrade() {
	local image="$1"
	local hlos=$(glinet_get_fit_part "$image" hlos)
	local rootfs=$(glinet_get_fit_part "$image" rootfs)
	local wifi_fw=$(glinet_get_fit_part "$image" wifi_fw)
	local hlos_dev=$(find_mmc_part "$CI_KERNPART" "$CI_ROOTDEV")
	local rootfs_dev=$(find_mmc_part "$CI_ROOTPART" "$CI_ROOTDEV")
	local wifi_fw_dev
	local rootfs_size

	[ -n "$wifi_fw" ] && wifi_fw_dev=$(find_mmc_part "0:WIFIFW" "$CI_ROOTDEV")
	[ -n "$hlos" ] && [ -n "$rootfs" ] && \
		[ -n "$hlos_dev" ] && [ -n "$rootfs_dev" ] || {
		v "Unable to find the required GL.iNet image sections or eMMC partitions."
		return 1
	}
	[ -z "$wifi_fw" ] || [ -n "$wifi_fw_dev" ] || {
		v "Unable to find the GL.iNet Wi-Fi firmware partition."
		return 1
	}

	# Extract and size-check every section first: a failure here (a bad
	# image, /tmp running out of space) leaves the installed system intact.
	glinet_emmc_stage_fit_part "$image" "$hlos" "$hlos_dev" hlos &&
	glinet_emmc_stage_fit_part "$image" "$rootfs" "$rootfs_dev" rootfs &&
	{ [ -z "$wifi_fw" ] ||
		glinet_emmc_stage_fit_part "$image" "$wifi_fw" "$wifi_fw_dev" wifi_fw; } || {
		glinet_emmc_cleanup_staged
		return 1
	}

	# Point of no return. Invalidate the kernel first and write it last, so
	# an interrupted upgrade cannot boot a kernel against a partial rootfs.
	dd if=/dev/zero of="$hlos_dev" bs=512 count=8 conv=fsync || return 1
	glinet_emmc_write_staged rootfs "$rootfs_dev" || return 1

	# The firmware just written looks for its overlay right behind its
	# squashfs, at roundup(size, 64 KiB). Clear that block so neither an
	# old stock overlay nor our previous f2fs is mounted instead of a fresh
	# one (stock's own writer zeroes rootfs + 20 MiB for the same reason).
	# OpenWrt factory images are padded past that point already.
	rootfs_size=$(wc -c < "$(glinet_emmc_staged rootfs)")
	dd if=/dev/zero of="$rootfs_dev" bs=65536 count=1 conv=fsync \
		seek=$(( (rootfs_size + 65535) / 65536 )) 2>/dev/null

	[ -z "$wifi_fw" ] || \
		glinet_emmc_write_staged wifi_fw "$wifi_fw_dev" || return 1
	glinet_emmc_write_staged hlos "$hlos_dev" || return 1
	glinet_emmc_cleanup_staged
}

glinet_emmc_do_upgrade() {
	case "$(identify_magic_long "$(get_magic_long "$1")")" in
	fit)
		glinet_emmc_do_fit_upgrade "$1"
		;;
	*)
		emmc_do_upgrade "$1"
		;;
	esac
}
