#!/sbin/sh

## start config variables

# if this is changed, it also needs to be set in boot-patcher.sh, update-binary, and patch.d-env
tmp=/tmp/kernel-flasher

# leave device_names empty to allow flashing on any device
device_names=
# leave boot_block empty for automatic (searches recovery.fstab and other locations)
boot_block=

bin=$tmp/tools
ramdisk=$tmp/ramdisk
ramdisk_patch=$ramdisk-patch
split_img=$tmp/split-img
modules=$tmp/modules

## end config variables

case $(getprop ro.product.cpu.abi) in
x86)
	arch=x86
	;;
x86_64)
	arch=x64
	;;
arm64*)
	arch=arm64
	;;
armeabi*)
	arch=armv7
	;;
mips64)
	arch=mips64
	;;
mips)
	arch=mips
	;;
*)
	arch=armv7
	;;
esac

bin=$bin/$arch
