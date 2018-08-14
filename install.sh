#!/usr/bin/env bash

# set -e

DARKGRAY=$'\e[1;30m'
RED=$'\e[0;31m'
LIGHTRED=$'\e[1;31m'
GREEN=$'\e[0;32m'
YELLOW=$'\e[1;33m'
BLUE=$'\e[0;34m'
PURPLE=$'\e[0;35m'
LIGHTPURPLE=$'\e[1;35m'
CYAN=$'\e[0;36m'
WHITE=$'\e[1;37m'
SET=$'\e[0m'

_pause() {
	read -p "${YELLOW}Press [enter] to continue${SET}"
}

check_binaries() {
	local bins=(sgdisk mkfs.fat grub-install rsync)
	hash ${bins[*]} &> /dev/null || return 1
}

check_grub_platforms() {
	for x in i386-pc x86_64-efi; do
		if ! [ -d "/usr/lib/grub/${x}" ]; then return 1; fi
	done
	return 0
}

# Find a partition on a disk matched an label
declare find_part_out
find_part() {
	if ! [ -e "/dev/${1}" ]; then
		echo "${RED}Error: Invalid disk (${1})${SET}"
	fi
	for x in /dev/${1}[0-9]*; do
		local label=$(lsblk -f $x | tail -n 1 | awk '{ print $3 }')
		if [[ "${label}" == "$2" ]]; then
			find_part_out=$(basename $x)
			return 0
		fi
	done
	return 1
}

initial_disk() {
	local disk=$1
	if ! [ -e "/dev/${disk}" ]; then
		echo "${RED}Error: Invalid disk (${disk})${SET}"
	fi
	echo -e "${RED}Warning! Warning!\nAll data on ($disk) will be lost and unrecoverable.\nAre you sure to continue (y/N)?${SET}"
	read answer
	if [ "$answer" != "y" -a "$answer" != "Y" ]; then
		return 0
	fi
	tmp=$(mktemp)
	sgdisk -Zo \
        -n 1:2048:+300M -t 1:ef00 -c 1:"EFI" \
	    -n 2:+0:+10M -t 2:ef02 -c 2:"BIOS Boot" \
	    -n 3:+0:+2G -t 3:0700 -c 3:"Rescue" \
	    -n 4:+0:-0 -t 4:0700 -c 4:"Data" \
	    -h "1:3:4" \
	    /dev/$disk &> $tmp
	if [ $? -ne 0 ]; then
		echo -e "${RED}Failed to run ${CYAN}sgdisk${RED} on selected disk. Please check the following log:${DARKGRAY}"
		cat $tmp
		echo -e "${SET}"
		return 1
	fi
	partprobe
	echo -e "${GREEN}Formatting partitions...${SET}"
	mkfs.fat -F 32 -n "EFI" "/dev/${disk}1" &> $tmp &&\
	# mkfs.fat -F 32 -n "Rescue" "/dev/${disk}3" &> $tmp &&\
	mkfs.ntfs -f -L "Rescue" "/dev/${disk}3" &> $tmp &&\
	mkfs.ntfs -f -L "Data" "/dev/${disk}4" &> $tmp
	if [ $? -ne 0 ]; then
		echo -e "${RED}Some partitions cannot be formated${DARKGRAY}"
		cat $tmp
		echo -e "${SET}"
		return 1
	fi
	echo -e "${GREEN}Disk initialized successfully!${SET}"
	return 0
}

install_grub() {
	local disk=$1
	local tmp=$(mktemp)
	if ! [ -e "/dev/${disk}" ]; then
		echo -e "${RED}/dev/${disk} not found!${SET}"
		return 1
	fi
	if [ -e /mnt/efi ] || [ -e /mnt/rescue ]; then
		# try umounting
		umount /mnt/{efi,rescue} &> /dev/null
		rm -rf /mnt/{efi,rescue} || {
			echo -e "${RED}'/mnt/efi' and/or '/mnt/rescue' is busy?${SET}"
			return 1
		}
	fi
	mkdir /mnt/{efi,rescue}
	local efi_path=""
	local rescue_path=""
	find_part "${disk}" "Rescue" || {
		echo "${RED}Partition with label 'Rescue' not found on disk (${disk}).${SET}"
		return 1
	}
	mount "/dev/$find_part_out" /mnt/rescue && {
		rescue_path="/mnt/rescue"
	} || {
		echo "${RED}${find_part_out} is unmountable.${SET}"
		return 1
	}
	find_part "${disk}" "EFI" && {
		mount "/dev/$find_part_out" /mnt/efi && {
			efi_path="/mnt/efi"
		} || {
			echo "${RED}${find_part_out} is unmountable.${SET}"
			return 1
		}
	} || {
		echo "${RED}Warning: EFI partition path fallback to Rescue partition mount path (${rescue_path}).${SET}"
		efi_path=$rescue_path
	}

	echo "EFI    mount at: ${GREEN}${efi_path}${SET}"
	echo "Rescue mount at: ${GREEN}${rescue_path}${SET}"
	echo "${DARKGRAY}Installing grub...${SET}"
	for platform in "i386-pc" "x86_64-efi"; do
		grub-install --boot-directory="${rescue_path}/boot" --efi-directory="${efi_path}" --target="${platform}" "/dev/${disk}" > $tmp 2>&1 || {
			echo "${RED}Failed to install grub platform '${platform}'.${SET}"
			echo -n "${DARKGRAY}"
			cat $tmp
			echo -n "${SET}"
			return 1
		}
	done
	echo "${GREEN}Installation finished.${SET}"
	umount /mnt/{efi,rescue} &> /dev/null
	rmdir /mnt/{efi,rescue} &> /dev/null
	return 0
}

menu() {
	local disk
	local answer
	while true; do
		clear
		answer=''
		echo -e "${GREEN}[BachNX Edition]${SET} Super rescue disk creator"
		echo -e "-------------------------------------------"
		if [ -z "${disk}" ]; then
			# Prompt disk select
			local default
			echo "Searching for disks..."
			for x in /dev/sd*; do
				x=`basename $x`
				if expr match "${x}" '[a-z]*$'>/dev/null; then
					echo "Found ${CYAN}${x}${SET}"
					default=$x
				fi
			done
			read -p "Select your disk (${default}): " -i "${default}" answer
			answer=${answer:-$default}
			if ! [ -e /dev/${answer} ]; then
				echo "${RED}Selected disk not valid (${answer})${SET}"
				_pause
			else
				disk=$answer
			fi
		else
			echo    "Current disk: ${CYAN}${disk}${SET}.${DARKGRAY}"
			sgdisk -p "/dev/${disk}"
			echo -e "${SET}\n"
			echo    "Please select an item:"
			echo    "[i] Initialize disk (detroy all data)"
			echo    "[g] Install dual-grub on disk"
			echo    "[c] Copy File to disk"
			echo    "[d] Choose another disk"
			echo    "[a] Do everything (i+g+c)"
			echo    "[q] Quit"
			read -p "    Your answer (lowercase): " -n 1 answer
			echo
			case $answer in
				d)
					disk=''
					;;
				i)
					initial_disk $disk
					_pause
					if [ $? -ne 0 ]; then
						exit $?
					fi
					;;
				g)
					install_grub $disk
					_pause
					if [ $? -ne 0 ]; then
						exit $?
					fi
					;;
				q)
					echo "${CYAN}Bye bye${SET}"
					exit 0
					;;
				*)
					if [ -n "${answer}" ]; then
						echo "${RED}Invalid  command (${answer}).${SET}"
						_pause
					fi
				;;
			esac
		fi
	done
}

#
# Pre-flight checks
#

if [ $(id -u) -ne 0 ]; then
	echo "${RED}You must be root to perform this action.${SET}\n"
	exit 1
elif ! check_binaries; then
	echo "${RED}Some binary not found.${SET}\n" ""
	exit 1
elif ! check_grub_platforms; then
	echo "${RED}Some GRUB platforms are missing.${SET}\n"
	exit 1
fi

menu