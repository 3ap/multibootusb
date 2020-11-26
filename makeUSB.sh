#!/bin/sh

# Description: Script to prepare multiboot USB drive

# Exit if there is an unbound variable or an error
set -o nounset
set -o errexit

# Defaults
scriptname=$(basename "$0")
mnt_dir=""
boot_subdir=boot

# Show usage
showUsage() {
	cat <<- EOF
	Script to prepare multiboot USB drive
	Usage: $scriptname [options] device

	 device                         Device to modify (e.g. /dev/sdb)
	  -h,  --help                   Display this message
	EOF
}

# Clean up when exiting
cleanUp() {
	# Change ownership of files
	{ [ ! -z "${mnt_dir:-}" ] && \
	    chown -R "$normal_user" "${mnt_dir}"/* 2>/dev/null; } \
	    || true
	# Unmount everything
	umount -f "$mnt_dir" 2>/dev/null || true
	# Delete mountpoints
	[ -d "$mnt_dir" ] && rmdir "$mnt_dir"
}

# Make sure USB drive is not mounted
unmountUSB() {
	umount -f "${1}"* 2>/dev/null || true
}

# Trap kill signals (SIGHUP, SIGINT, SIGTERM) to do some cleanup and exit
trap cleanUp EXIT

# Show help before checking for root
[ "$#" -eq 0 ] && showUsage && exit 0
case "$1" in
	-h|--help)
		showUsage
		exit 0
		;;
esac

# Check for root
if [ "$(id -u)" -ne 0 ]; then
	printf 'This script must be run as root. Using sudo...\n' "$scriptname" >&2
	exec sudo -k -- /bin/sh "$0" "$@" || exit 2
fi

# Get original user
normal_user="${SUDO_USER-$(who -m | awk '{print $1}')}"

# Check arguments
while [ "$#" -gt 0 ]; do
	case "$1" in
		/dev/*)
			if [ -b "$1" ]; then
				device=$1
			else
				printf '%s: %s is not a valid device.\n' "$scriptname" "$1" >&2
				exit 1
			fi
			;;
		*)
			printf '%s: %s is not a valid argument.\n' "$scriptname" "$1" >&2
			exit 1
			;;
	esac
	shift
done

# Check for required arguments
if [ -z "${device:-}" ]; then
	printf '%s: No device was provided.\n' "$scriptname" >&2
	showUsage
	exit 1
fi

# Check for GRUB installation binary
grub_cmd=$(command -v grub2-install) \
    || grub_cmd=$(command -v grub-install) \
    || exit 3

# Unmount device
unmountUSB "${device}"

# Confirm the device
printf 'Are you sure you want to use %s? [y/N] ' "${device}"
read -r answer1
case "$answer1" in
	[yY][eE][sS]|[yY])
		printf 'THIS WILL DELETE ALL DATA ON THE DEVICE. Are you sure? [y/N] '
		read -r answer2
		case $answer2 in
			[yY][eE][sS]|[yY])
				true
				;;
			*)
				exit 3
				;;
		esac
		;;
	*)
		exit 3
		;;
esac

# Print all steps
set -o xtrace

sed -e 's/\s*\([\+0-9a-zA-Z]*\).*/\1/' << EOF | /sbin/fdisk "${device}" >&2 || true
  o # clear the in memory partition table
  n # new primary partition "boot" (#1)
  p # primary partition
  1 # partition number 1
    # default - start at beginning of disk
    # rest of disk
  p # print the in-memory partition table
  w # write the partition table
  q # and we're done
EOF

num_part=1
device_part=$(find /dev/ -mindepth 1 -maxdepth 1 | grep -E "${device}[p]?${num_part}$")
if [ -z "${device_part}" ]; then
  printf "There is no %s in your system\n" "${device_part}" >&2
  exit 10
fi

mkfs.vfat "${device_part}" || exit 10

# Create temporary directories
mnt_dir=$(mktemp -d mbusb.XXXX) || exit 10

# Mount partition
mount "${device_part}" "$mnt_dir" || exit 10

{ "${grub_cmd}" --target=x86_64-efi \
	        --efi-directory="${mnt_dir}" \
	        --boot-directory="${mnt_dir}/${boot_subdir}" \
	        --removable --recheck \
    || exit 10; }

{ "${grub_cmd}" --target=i386-pc \
	        --boot-directory="${mnt_dir}/${boot_subdir}" \
	        --recheck "${device}" \
    || exit 10; }

# Create necessary directories
mkdir -p "${mnt_dir}/${boot_subdir}/isos" || exit 10

# Copy files
cp -R ./mbusb.cfg ./mbusb.d "${mnt_dir}/${boot_subdir}"/grub*/ \
    || exit 10
# Copy example configuration for GRUB
cp ./grub.cfg.example "${mnt_dir}/${boot_subdir}"/grub*/ \
    || exit 10

# Rename example configuration
( cd "${mnt_dir}/${boot_subdir}"/grub*/ && cp grub.cfg.example grub.cfg ) \
    || exit 10

# Download memdisk
syslinux_url='https://mirrors.edge.kernel.org/pub/linux/utils/boot/syslinux/syslinux-6.03.tar.gz'
{ wget -qO - "$syslinux_url" 2>/dev/null || curl -sL "$syslinux_url" 2>/dev/null; } \
    | tar -xz -C "${mnt_dir}/${boot_subdir}"/grub*/ --no-same-owner --strip-components 3 \
    'syslinux-6.03/bios/memdisk/memdisk' \
    || exit 10
