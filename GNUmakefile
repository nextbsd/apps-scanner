# Copyright (C) 2026 Joseph Maloney <pkgdemonteam@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause
#
# Scanner.app: scans documents and photos with SANE (nextbsd/nextbsd#717).
# Links libsane from NextBSD-gnustep-support (sane-backends: libsane.so.1
# in /usr/lib, its backends in /usr/lib/sane, its configuration in
# /usr/etc/sane.d) and zlib for the PDFs. nextbsd-desktop installs it in
# /System/Applications.

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
Scanner_GUI_LIBS += -lsane -lz

include $(GNUSTEP_MAKEFILES)/application.make
