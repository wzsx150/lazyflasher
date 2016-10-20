#!/sbin/sh
# LazyFlasher boot image patcher script by jcadduono

tmp=/tmp/no-verity-opt-encrypt

console=$(cat /tmp/console)
[ "$console" ] || console=/proc/$$/fd/1

cd "$tmp"
. config.sh

chmod -R 755 "$bin"
rm -rf "$ramdisk" "$split_img"
mkdir "$ramdisk" "$split_img"

print() {
	[ "$1" ] && {
		echo "ui_print - $1" > $console
	} || {
		echo "ui_print  " > $console
	}
	echo
}

abort() {
	[ "$1" ] && {
		print "Error: $1!"
		print "Aborting..."
	}
	exit 1
}

## start install methods

# find the location of the boot block
find_boot() {
	verify_block() {
		boot_block=$(readlink -f "$boot_block")
		# if the boot block is a file, we must use dd
		if [ -f "$boot_block" ]; then
			use_dd=true
		# if the boot block is a block device, we use flash_image when possible
		elif [ -b "$boot_block" ]; then
			case "$boot_block" in
				/dev/block/bml*|/dev/block/mtd*|/dev/block/mmc*)
					use_dd=false ;;
				*)
					use_dd=true ;;
			esac
		# otherwise we have to keep trying other locations
		else
			return 1
		fi
		print "Found boot partition at: $boot_block"
	}
	# if we already have boot block set then verify and use it
	[ "$boot_block" ] && verify_block && return
	# otherwise, time to go hunting!
	[ -f /etc/recovery.fstab ] && {
		# recovery fstab v1
		boot_block=$(awk '$1 == "/boot" {print $3}' /etc/recovery.fstab)
		[ "$boot_block" ] && verify_block && return
		# recovery fstab v2
		boot_block=$(awk '$2 == "/boot" {print $1}' /etc/recovery.fstab)
		[ "$boot_block" ] && verify_block && return
		return 1
	} && return
	[ -f /fstab.qcom ] && {
		# qcom fstab
		boot_block=$(awk '$2 == "/boot" {print $1}' /fstab.qcom)
		[ "$boot_block" ] && verify_block && return
		return 1
	} && return
	[ -f /proc/emmc ] && {
		# emmc layout
		boot_block=$(awk '$4 == "\"boot\"" {print $1}' /proc/emmc)
		[ "$boot_block" ] && boot_block=/dev/block/$(echo "$boot_block" | cut -f1 -d:) && verify_block && return
		return 1
	} && return
	[ -f /proc/mtd ] && {
		# mtd layout
		boot_block=$(awk '$4 == "\"boot\"" {print $1}' /proc/mtd)
		[ "$boot_block" ] && boot_block=/dev/block/$(echo "$boot_block" | cut -f1 -d:) && verify_block && return
		return 1
	} && return
	[ -f /proc/dumchar_info ] && {
		# mtk layout
		boot_block=$(awk '$1 == "/boot" {print $5}' /proc/dumchar_info)
		[ "$boot_block" ] && verify_block && return
		return 1
	} && return
	abort "Unable to find boot block location"
}

# dump boot and unpack the android boot image
dump_boot() {
	print "Dumping & unpacking original boot image..."
	if $use_dd; then
		dd if="$boot_block" of="$tmp/boot.img"
	else
		dump_image "$boot_block" "$tmp/boot.img"
	fi
	[ $? = 0 ] || abort "Unable to read boot partition"
	"$bin/unpackbootimg" -i "$tmp/boot.img" -o "$split_img" || {
		abort "Unpacking boot image failed"
	}
}

# determine the format the ramdisk was compressed in
determine_ramdisk_format() {
	magicbytes=$(hexdump -vn2 -e '2/1 "%x"' "$split_img/boot.img-ramdisk")
	case "$magicbytes" in
		425a) rdformat=bzip2; decompress="$bin/bzip2 -dc"; compress="$bin/bzip2 -9c" ;;
		1f8b|1f9e) rdformat=gzip; decompress="gzip -dc"; compress="gzip -9c" ;;
		0221) rdformat=lz4; decompress="$bin/lz4 -d"; compress="$bin/lz4 -9" ;;
		894c) rdformat=lzo; decompress="lzop -dc"; abort "lzop -9c" ;;
		5d00) rdformat=lzma; decompress="xz -dc"; compress="xz --format=lzma --lzma1=dict=16MiB -9";
			abort "LZMA ramdisks are currently not supported" ;;
		fd37) rdformat=xz; decompress="xz -dc"; compress="xz --check=crc32 --lzma2=dict=16MiB -9";
			abort "XZ ramdisks are currently not supported" ;;
		*) abort "Unknown ramdisk compression format ($magicbytes)" ;;
	esac
	print "Detected ramdisk compression format: $rdformat"
	command -v $decompress || abort "Unable to find archiver for $rdformat"
}

# extract the old ramdisk contents
dump_ramdisk() {
	cd "$ramdisk"
	$decompress < "$split_img/boot.img-ramdisk" | cpio -i
	[ $? != 0 ] && abort "Unpacking ramdisk failed"
}

# if the actual boot ramdisk exists inside a parent one, use that instead
dump_embedded_ramdisk() {
	if [ -f "$ramdisk/sbin/ramdisk.cpio" ]; then
		print "Found embedded boot ramdisk!"
		mv "$ramdisk" "$ramdisk-root"
		mkdir "$ramdisk"
		cd "$ramdisk"
		cpio -i < "$ramdisk-root/sbin/ramdisk.cpio" || {
			abort "Failed to unpack embedded boot ramdisk"
		}
	fi
}

# execute all scripts in patch.d
patch_ramdisk() {
	print "Running ramdisk patching scripts..."
	find "$tmp/patch.d/" -type f | sort > "$tmp/patchfiles"
	while read -r patchfile; do
		print "Executing: $(basename "$patchfile")"
		env="$tmp/patch.d-env" sh "$patchfile" || {
			abort "Script failed: $(basename "$patchfile")"
		}
	done < "$tmp/patchfiles"
}

# if we moved the parent ramdisk, we should rebuild the embedded one
build_embedded_ramdisk() {
	if  [ -d "$ramdisk-root" ]; then
		print "Building new embedded boot ramdisk..."
		cd "$ramdisk"
		find | cpio -o -H newc > "$ramdisk-root/sbin/ramdisk.cpio"
		rm -rf "$ramdisk"
		mv "$ramdisk-root" "$ramdisk"
	fi
}

# build the new ramdisk
build_ramdisk() {
	print "Building new ramdisk..."
	cd "$ramdisk"
	find | cpio -o -H newc | $compress > $tmp/ramdisk-new
}

# build the new boot image
build_boot() {
	cd "$split_img"
	kernel=
	for image in zImage zImage-dtb Image Image-dtb Image.gz Image.gz-dtb; do
		if [ -s $tmp/$image ]; then
			kernel="$tmp/$image"
			print "Found replacement kernel $image!"
			break
		fi
	done
	[ "$kernel" ] || kernel="$(ls ./*-kernel)"
	if [ -s $tmp/ramdisk-new ]; then
		rd="$tmp/ramdisk-new"
		print "Found replacement ramdisk image!"
	else
		rd="$(ls ./*-ramdisk)"
	fi
	if [ -s $tmp/dtb.img ]; then
		dtb="$tmp/dtb.img"
		print "Found replacement device tree image!"
	else
		dtb="$(ls ./*-dt)"
	fi
	"$bin/mkbootimg" \
		--kernel "$kernel" \
		--ramdisk "$rd" \
		--dt "$dtb" \
		--second "$(ls ./*-second)" \
		--cmdline "$(cat ./*-cmdline)" \
		--board "$(cat ./*-board)" \
		--base "$(cat ./*-base)" \
		--pagesize "$(cat ./*-pagesize)" \
		--kernel_offset "$(cat ./*-kernel_offset)" \
		--ramdisk_offset "$(cat ./*-ramdisk_offset)" \
		--second_offset "$(cat ./*-second_offset)" \
		--tags_offset "$(cat ./*-tags_offset)" \
		-o $tmp/boot-new.img || {
			abort "Repacking boot image failed"
		}
}

# append Samsung enforcing tag to prevent warning at boot
samsung_tag() {
	if getprop ro.product.manufacturer | grep -iq '^samsung$'; then
		echo "SEANDROIDENFORCE" >> "$tmp/boot-new.img"
	fi
}

# write the new boot image to boot block
write_boot() {
	print "Writing new boot image to memory..."
	if $use_dd; then
		dd if="$tmp/boot-new.img" of="$boot_block"
	else
		flash_image "$boot_block" "$tmp/boot-new.img"
	fi
	[ $? = 0 ] || abort "Failed to write boot image! You may need to restore your boot partition"
}

## end install methods

## start boot image patching

find_boot

dump_boot

determine_ramdisk_format

dump_ramdisk

dump_embedded_ramdisk

patch_ramdisk

build_embedded_ramdisk

build_ramdisk

build_boot

samsung_tag

write_boot

## end boot image patching
