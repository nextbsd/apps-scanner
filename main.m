/*
 * Copyright (C) 2026 Joseph Maloney <pkgdemonteam@gmail.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Scanner.app: scans documents and photos with SANE, as Image Capture
 * does on a Mac (nextbsd/nextbsd#717).
 */

#import <AppKit/AppKit.h>
#import "SCController.h"

int
main (int argc, const char **argv)
{
  CREATE_AUTORELEASE_POOL (pool);
  SCController *controller;

  [NSApplication sharedApplication];
  controller = [[SCController alloc] init];
  [NSApp setDelegate:controller];
  [NSApp run];
  RELEASE (controller);
  RELEASE (pool);
  return 0;
}
