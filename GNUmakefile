# Copyright (C) 2026 Joseph Maloney <pkgdemonteam@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause
#
# Scanner.app: scans documents and photos with SANE (nextbsd/nextbsd#717).
# Links libsane from NextBSD-gnustep-support (sane-backends: libsane.so.1
# in /usr/lib, its backends in /usr/lib/sane, its configuration in
# /usr/etc/sane.d) and zlib for the PDFs. nextbsd-desktop installs it in
# /System/Applications.
#
# USB scanners: SettingsHelper's UsbGrant gives an administrator at the
# console the USB device Scanner can't open. Its client is Helper/: the
# MIG user stub made from Helper/mig/settingshelper.defs and
# settingshelper_types.h, copied unchanged from nextbsd-userland's
# src/SettingsHelper (as apps-installer's Frameworks/NBSettings copies
# them; message ids never move, so an older copy keeps working).

ifeq ($(GNUSTEP_MAKEFILES),)
 GNUSTEP_MAKEFILES := $(shell gnustep-config --variable=GNUSTEP_MAKEFILES)
endif
include $(GNUSTEP_MAKEFILES)/common.make

APP_NAME = Scanner
Scanner_OBJC_FILES = main.m SCController.m SCScanner.m SCViews.m \
	SCAppearance.m SCPDFWriter.m
Scanner_HEADER_FILES = SCController.h SCScanner.h SCViews.h SCAppearance.h \
	SCPDFWriter.h
Scanner_RESOURCE_FILES = Resources/Scanner.png
Scanner_APPLICATION_ICON = Scanner.png
Scanner_OBJCFLAGS = -Wall -Wextra -Wno-unused-parameter
Scanner_INCLUDE_DIRS = -IHelper -IHelper/mig

# SettingsHelper's client: plain C on Mach, compiled apart from GNUstep's
# flags, as apps-installer's NBSettings is.
MIG ?= mig
MIG_DIR = obj/mig
SYSTEM_DIR = obj/system
SYSTEM_CFLAGS = -fPIC -O2 -g -Wall -Wno-macro-redefined -I$(MIG_DIR) \
	-IHelper/mig -IHelper
SYSTEM_OBJS = $(SYSTEM_DIR)/SCHelperClient.o $(SYSTEM_DIR)/settingshelperUser.o
Scanner_OBJ_FILES += $(SYSTEM_OBJS)

# NextBSD's system libraries live in /usr/lib/system: liblaunch and the
# Mach calls for the helper's client.
SYSTEM_LIBDIR = /usr/lib/system
ADDITIONAL_LDFLAGS += -L$(SYSTEM_LIBDIR) -Wl,-rpath,$(SYSTEM_LIBDIR)
Scanner_GUI_LIBS += -lsane -lz -llaunch -lsystem_kernel

include $(GNUSTEP_MAKEFILES)/application.make

$(MIG_DIR)/settingshelperUser.c $(MIG_DIR)/settingshelperUser.h: \
		Helper/mig/settingshelper.defs Helper/mig/settingshelper_types.h
	@mkdir -p $(MIG_DIR)
	cd $(MIG_DIR) && $(MIG) -I$(CURDIR)/Helper/mig \
		-header settingshelperUser.h -user settingshelperUser.c \
		-server /dev/null -sheader /dev/null \
		$(CURDIR)/Helper/mig/settingshelper.defs

$(SYSTEM_DIR)/SCHelperClient.o: Helper/SCHelperClient.c \
		Helper/SCHelperClient.h $(MIG_DIR)/settingshelperUser.h
	@mkdir -p $(SYSTEM_DIR)
	$(CC) $(SYSTEM_CFLAGS) -c $< -o $@

# MIG's output isn't -Wall clean.
$(SYSTEM_DIR)/settingshelperUser.o: $(MIG_DIR)/settingshelperUser.c
	@mkdir -p $(SYSTEM_DIR)
	$(CC) $(SYSTEM_CFLAGS) -w -c $< -o $@

before-all:: $(SYSTEM_OBJS)

after-clean::
	rm -rf $(MIG_DIR) $(SYSTEM_DIR)
