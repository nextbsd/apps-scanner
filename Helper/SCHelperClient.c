/*
 * Copyright (C) 2026 Joseph Maloney <pkgdemonteam@gmail.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include "settingshelper_types.h"

#include <mach/mach.h>
#include <servers/bootstrap.h>

#include "settingshelperUser.h"	/* the MIG user stub, made by the build */

#include "SCHelperClient.h"

int
SCHelperUSBGrant (int bus, int address)
{
  mach_port_t port = MACH_PORT_NULL;
  int status = SCHelperUnavailable;

  /* launchd starts the helper on demand. */
  if (bootstrap_look_up (bootstrap_port, SH_SERVICE_NAME, &port)
      != KERN_SUCCESS)
    return SCHelperUnavailable;
  if (sh_usb_grant (port, bus, address, &status) != KERN_SUCCESS)
    status = SCHelperUnavailable;
  (void) mach_port_deallocate (mach_task_self (), port);
  return status;
}
