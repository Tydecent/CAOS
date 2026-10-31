################################################################################
#
# caos-syslinux host installer
#
# Upstream ships pre-generated core/bootloader blobs in the release tarball.
# We build only the unprivileged mtools-based installer with the host compiler
# and install it together with the SYSLINUX MBR.  The target is not modified.
#
################################################################################

CAOS_SYSLINUX_VERSION = 6.03
CAOS_SYSLINUX_SOURCE = syslinux-$(CAOS_SYSLINUX_VERSION).tar.xz
CAOS_SYSLINUX_SITE = https://cdn.kernel.org/pub/linux/utils/boot/syslinux
CAOS_SYSLINUX_LICENSE = GPL-2.0+
CAOS_SYSLINUX_LICENSE_FILES = COPYING

HOST_CAOS_SYSLINUX_DEPENDENCIES = host-mtools

define HOST_CAOS_SYSLINUX_BUILD_CMDS
	mkdir -p $(@D)/caos-host-build
	cd $(@D)/caos-host-build && \
		perl $(@D)/libinstaller/bin2c.pl syslinux_bootsect \
			< $(@D)/bios/core/ldlinux.bss > bootsect_bin.c && \
		perl $(@D)/libinstaller/bin2c.pl syslinux_ldlinux 512 \
			< $(@D)/bios/core/ldlinux.sys > ldlinux_bin.c && \
		perl $(@D)/libinstaller/bin2c.pl syslinux_ldlinuxc32 \
			< $(@D)/bios/com32/elflink/ldlinux/ldlinux.c32 > ldlinuxc32_bin.c
	$(HOSTCC) $(HOST_CFLAGS) $(HOST_LDFLAGS) \
		-std=gnu17 -O2 -D_FILE_OFFSET_BITS=64 \
		-I$(@D)/caos-host-build -I$(@D) -I$(@D)/libinstaller \
		-I$(@D)/libfat -I$(@D)/bios \
		-o $(@D)/caos-host-build/caos-syslinux-installer \
		$(@D)/mtools/syslinux.c \
		$(@D)/libinstaller/fs.c \
		$(@D)/libinstaller/syslxmod.c \
		$(@D)/libinstaller/syslxopt.c \
		$(@D)/libinstaller/setadv.c \
		$(@D)/caos-host-build/bootsect_bin.c \
		$(@D)/caos-host-build/ldlinux_bin.c \
		$(@D)/caos-host-build/ldlinuxc32_bin.c \
		$(@D)/libfat/cache.c \
		$(@D)/libfat/fatchain.c \
		$(@D)/libfat/open.c \
		$(@D)/libfat/searchdir.c
endef

define HOST_CAOS_SYSLINUX_INSTALL_CMDS
	$(INSTALL) -D -m 0755 \
		$(@D)/caos-host-build/caos-syslinux-installer \
		$(HOST_DIR)/bin/caos-syslinux-installer
	$(INSTALL) -D -m 0644 \
		$(@D)/bios/mbr/mbr.bin \
		$(HOST_DIR)/share/caos-syslinux/mbr.bin
endef

$(eval $(host-generic-package))
