/*
 * Copyright (C) 2026 Joseph Maloney <pkgdemonteam@gmail.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * SCHelperClient: Scanner's one call into SettingsHelper
 * (org.nextbsd.SettingsHelper, nextbsd-userland src/SettingsHelper):
 * UsbGrant, which gives the console user one USB device no kernel driver
 * has, if they are an administrator (right org.nextbsd.usb.device). Plain
 * C over the MIG stub the build makes from mig/settingshelper.defs, so
 * the Mach headers stay out of the Objective-C files.
 */

#ifndef _SC_HELPER_CLIENT_H_
#define _SC_HELPER_CLIENT_H_

/* Not an SH_* status: there is no helper to ask. */
#define SCHelperUnavailable 100

/* An SH_* status (settingshelper_types.h), or SCHelperUnavailable. */
int SCHelperUSBGrant (int bus, int address);

#endif
