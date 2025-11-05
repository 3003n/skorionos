#!/bin/bash
# shellcheck disable=SC2114

set -e
set -x

source manifest
source sub-manifest

PACKAGES_TO_DELETE+=" ${SUB_PACKAGES_TO_DELETE}"

pacman-key --populate

echo "LANG=en_US.UTF-8" > /etc/locale.conf
locale-gen

# Disable parallel downloads
sed -i '/ParallelDownloads/s/^/#/g' /etc/pacman.conf

# Cannot check space in chroot
sed -i '/CheckSpace/s/^/#/g' /etc/pacman.conf

# update package databases
pacman --noconfirm -Syy

# Disable check and debug for makepkg on the final image
sed -i '/BUILDENV/s/ check/ !check/g' /etc/makepkg.conf
sed -i '/OPTIONS/s/ debug/ !debug/g' /etc/makepkg.conf

# install kernel package
if [ "$KERNEL_PACKAGE_ORIGIN" == "local" ] ; then
	pacman --noconfirm -U --overwrite '*' \
	/override_pkgs/${KERNEL_PACKAGE}-*.pkg.tar.zst
else
	pacman --noconfirm -S "${KERNEL_PACKAGE}" "${KERNEL_PACKAGE}-headers" --needed
fi

for file in ${OWN_PACKAGES_FILE_TO_DELETE}; do
	rm -f /override_pkgs/${file} || true
done

# install override packages
pacman --noconfirm -U --overwrite '*' /override_pkgs/* --needed
rm -rf /var/cache/pacman/pkg


# install packages
pacman --noconfirm -S --overwrite '*' \
    --disable-download-timeout \
    ${PACKAGES} \
    ${SUB_PACKAGES} \
	${AUR_PACKAGES} \
    ${SUB_AUR_PACKAGES} \
    ${SUB_LOCAL_PACKAGES} \
    --needed

rm -rf /var/cache/pacman/pkg

# delete packages
for package in ${PACKAGES_TO_DELETE}; do
    echo "Checking if $package is installed"
	if [[ $(pacman -Qq $package) == "$package" ]]; then
		echo "$package is installed, deleting"
		pacman --noconfirm -Rnsdd $package || true
	fi
done


# Install the new iptables
# See https://gitlab.archlinux.org/archlinux/packaging/packages/iptables/-/issues/1
# Since base package group adds iptables by default
# pacman will ask for confirmation to replace that package
# but the default answer is no.
# doing yes | pacman omitting --noconfirm is a necessity 
yes | pacman -S iptables-nft

# enable services
systemctl enable ${SERVICES}

# enable user services
systemctl --global enable ${USER_SERVICES}

# disable root login
passwd --lock root

# create user
# groupadd -r autologin
# if group autologin does not exist, create it
if ! getent group autologin > /dev/null 2>&1; then
	groupadd -r autologin
fi
# useradd -m ${USERNAME} -G autologin,wheel,i2c,input
if ! getent passwd ${USERNAME} > /dev/null 2>&1; then
	useradd -m ${USERNAME} -G autologin,wheel,i2c,input
fi
echo "${USERNAME}:${USERNAME}" | chpasswd

# set the default editor, so visudo works
echo "export EDITOR=/usr/bin/vim" >> /etc/bash.bashrc

echo "[Autologin]
Session=gamescope-session-steam
User=${USERNAME}
Relogin=true

[General]
DisplayServer=wayland
HideUsers=true
" > /etc/sddm.conf.d/10-skorionos-session.conf

echo "${SYSTEM_NAME}" > /etc/hostname

# enable multicast dns in avahi
sed -i "/^hosts:/ s/resolve/mdns resolve/" /etc/nsswitch.conf

# configure ssh
echo "
AuthorizedKeysFile	.ssh/authorized_keys
PasswordAuthentication yes
ChallengeResponseAuthentication no
UsePAM yes
PrintMotd no # pam does that
Subsystem	sftp	/usr/lib/ssh/sftp-server
" > /etc/ssh/sshd_config

echo "
LABEL=frzr_efi  /boot      vfat      defaults,rw,noatime,nodiratime,nofail		0	2
LABEL=frzr_root /var       btrfs     defaults,subvol=var,rw,noatime,nodatacow,nofail		0	0
LABEL=frzr_root /home      btrfs     defaults,subvol=home,rw,noatime,nodatacow,nofail		0	0
LABEL=frzr_root /frzr_root btrfs     defaults,subvol=/,rw,noatime,nodatacow,x-initrd.mount	0	2
overlay         /etc       overlay   defaults,x-systemd.requires-mounts-for=/frzr_root,x-systemd.requires-mounts-for=/sysroot/frzr_root,x-systemd.rw-only,lowerdir=/sysroot/etc,upperdir=/sysroot/frzr_root/etc,workdir=/sysroot/frzr_root/.etc,index=off,metacopy=off,comment=etcoverlay,x-initrd.mount	0	0
" > /etc/fstab

echo "
LSB_VERSION=1.4
DISTRIB_ID=${SYSTEM_NAME}
DISTRIB_RELEASE=\"${LSB_VERSION}\"
DISTRIB_DESCRIPTION=${SYSTEM_DESC}
" > /etc/lsb-release

echo "NAME=\"${SYSTEM_DESC}\"
VERSION_CODENAME=skorionos
VERSION=\"${DISPLAY_VERSION}\"
VERSION_ID=\"${VERSION_NUMBER}\"
VARIANT_ID=skorionos
BUILD_ID=\"${BUILD_ID}\"
PRETTY_NAME=\"${SYSTEM_DESC} ${DISPLAY_VERSION}\"
ID=\"${SYSTEM_NAME}\"
ID_LIKE=arch
ANSI_COLOR=\"1;31\"
HOME_URL=\"${WEBSITE}\"
DOCUMENTATION_URL=\"${DOCUMENTATION_URL}\"
BUG_REPORT_URL=\"${BUG_REPORT_URL}\"" > /etc/os-release

# install extra certificates
trust anchor --store /extra/*.crt

# run post install hook
postinstallhook

# run sub post install hook
sub_postinstallhook

# pre-download
source /postinstall
postinstall_download

# record installed packages & versions
pacman -Q > /manifest

# preserve installed package database
mkdir -p /usr/var/lib/pacman
cp -r /var/lib/pacman/local /usr/var/lib/pacman/

# move kernel image and initrd to a defualt location if "linux" is not used
if [ ${KERNEL_PACKAGE} != 'linux' ] ; then
	mv /boot/vmlinuz-${KERNEL_PACKAGE} /boot/vmlinuz-linux
	mv /boot/initramfs-${KERNEL_PACKAGE}.img /boot/initramfs-linux.img
	mv /boot/initramfs-${KERNEL_PACKAGE}-fallback.img /boot/initramfs-linux-fallback.img
	rm /etc/mkinitcpio.d/${KERNEL_PACKAGE}.preset
fi

# clean up/remove unnecessary files
rm -rf \
/local_pkgs \
/aur_pkgs \
/override_pkgs \
/extra \
/home \
/var \

rm -rf ${FILES_TO_DELETE}

# create necessary directories
mkdir -p /home
mkdir -p /var
mkdir -p /frzr_root
mkdir -p /efi
mkdir -p /nix