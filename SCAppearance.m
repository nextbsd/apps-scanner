/*
 * Copyright (C) 2026 Joseph Maloney <pkgdemonteam@gmail.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "SCAppearance.h"

NSString *const SCAppearanceDidChangeNotification = @"SCAppearanceDidChange";

static BOOL scLight = NO;

static void
SCReadAppearance (void)
{
  id v = [[NSUserDefaults standardUserDefaults] objectForKey:@"NBAppearance"];

  scLight = [v isEqual:@"light"];
}

@interface SCAppearanceWatcher : NSObject
@end

@implementation SCAppearanceWatcher
+ (void)desktopSettingsChanged:(NSNotification *)note
{
  id key = [[note userInfo] objectForKey:@"key"];

  if (key != nil && ![key isEqual:@"NBAppearance"])
    return;
  [[NSUserDefaults standardUserDefaults] synchronize];
  SCReadAppearance ();
  [[NSNotificationCenter defaultCenter]
    postNotificationName:SCAppearanceDidChangeNotification object:nil];
}
@end

void
SCAppearanceStartWatching (void)
{
  SCReadAppearance ();
  /* What Workspace Preferences sends, and the NextBSD theme listens to. */
  [[NSDistributedNotificationCenter defaultCenter]
    addObserver:[SCAppearanceWatcher class]
       selector:@selector (desktopSettingsChanged:)
           name:@"org.nextbsd.DesktopSettingsChanged"
         object:nil];
}

BOOL
SCIsLight (void)
{
  return scLight;
}

NSColor *
SCHex (unsigned rgb, CGFloat alpha)
{
  return [NSColor colorWithCalibratedRed:((rgb >> 16) & 255) / 255.0
                                   green:((rgb >> 8) & 255) / 255.0
                                    blue:(rgb & 255) / 255.0
                                   alpha:alpha];
}

/* The mockup's palette (nextbsd/nextbsd#717), the accent the theme's. */
NSColor *SCTextColor (void) { return SCHex (scLight ? 0x1d1f24 : 0xe9ebef, 1); }
NSColor *SCDimColor (void) { return SCHex (scLight ? 0x5f6470 : 0x9aa0ac, 1); }
NSColor *SCFaintColor (void) { return SCHex (scLight ? 0x8d929c : 0x6b7180, 1); }
NSColor *SCAccentColor (void) { return SCHex (scLight ? 0x00a3c7 : 0x00d4ff, 1); }
NSColor *SCAccentTextColor (void) { return SCHex (scLight ? 0xffffff : 0x04141a, 1); }
NSColor *SCSidebarColor (void) { return SCHex (scLight ? 0xeef0f3 : 0x202227, 1); }
NSColor *SCPreviewColor (void) { return SCHex (scLight ? 0xdfe2e7 : 0x15171b, 1); }
NSColor *SCSelectionColor (void)
{
  return scLight ? SCHex (0x00a3c7, 0.16) : SCHex (0x00d4ff, 0.18);
}
NSColor *SCLineColor (void)
{
  return scLight ? SCHex (0x000000, 0.10) : SCHex (0xffffff, 0.09);
}
NSColor *SCPaperColor (void) { return SCHex (0xfbfaf7, 1); }

NSFont *
SCFont (CGFloat size, BOOL bold)
{
  NSFont *f = bold ? [NSFont boldSystemFontOfSize:size]
                   : [NSFont systemFontOfSize:size];
  return f ? f : [NSFont userFontOfSize:size];
}

void
SCDrawText (NSString *s, NSPoint point, NSFont *font, NSColor *color)
{
  [s drawAtPoint:point
      withAttributes:[NSDictionary dictionaryWithObjectsAndKeys:
                                     font, NSFontAttributeName,
                                     color, NSForegroundColorAttributeName,
                                     nil]];
}

NSSize
SCTextSize (NSString *s, NSFont *font)
{
  return [s sizeWithAttributes:[NSDictionary dictionaryWithObject:font
                                                           forKey:NSFontAttributeName]];
}

void
SCDrawGlyph (NSString *name, NSRect rect, NSColor *color, CGFloat width)
{
  NSBezierPath *p = [NSBezierPath bezierPath];
  NSAffineTransform *t = [NSAffineTransform transform];
  CGFloat s = NSWidth (rect) / 24.0;

  if ([name isEqual:@"scanner"])
    {
      /* M3 13h18v5H3z M5 13l2-6h10l2 6 M7 15.5h4 */
      [p appendBezierPathWithRect:NSMakeRect (3, 13, 18, 5)];
      [p moveToPoint:NSMakePoint (5, 13)];
      [p lineToPoint:NSMakePoint (7, 7)];
      [p lineToPoint:NSMakePoint (17, 7)];
      [p lineToPoint:NSMakePoint (19, 13)];
      [p moveToPoint:NSMakePoint (7, 15.5)];
      [p lineToPoint:NSMakePoint (11, 15.5)];
    }
  else if ([name isEqual:@"usb"])
    {
      [p moveToPoint:NSMakePoint (12, 3)];
      [p lineToPoint:NSMakePoint (12, 17)];
      [p moveToPoint:NSMakePoint (12, 3)];
      [p lineToPoint:NSMakePoint (9.5, 6)];
      [p lineToPoint:NSMakePoint (14.5, 6)];
      [p closePath];
      [p moveToPoint:NSMakePoint (12, 11)];
      [p lineToPoint:NSMakePoint (8, 9)];
      [p lineToPoint:NSMakePoint (8, 7)];
      [p moveToPoint:NSMakePoint (12, 13)];
      [p lineToPoint:NSMakePoint (16, 11)];
      [p lineToPoint:NSMakePoint (16, 9)];
      [p appendBezierPathWithOvalInRect:NSMakeRect (10, 17, 4, 4)];
    }
  else if ([name isEqual:@"net"])
    {
      [p appendBezierPathWithOvalInRect:NSMakeRect (3, 3, 18, 18)];
      [p moveToPoint:NSMakePoint (3, 12)];
      [p lineToPoint:NSMakePoint (21, 12)];
      [p appendBezierPathWithOvalInRect:NSMakeRect (9.6, 3, 4.8, 18)];
    }
  else if ([name isEqual:@"plus"])
    {
      [p moveToPoint:NSMakePoint (12, 5)];
      [p lineToPoint:NSMakePoint (12, 19)];
      [p moveToPoint:NSMakePoint (5, 12)];
      [p lineToPoint:NSMakePoint (19, 12)];
    }
  [t translateXBy:NSMinX (rect) yBy:NSMinY (rect)];
  [t scaleBy:s];
  [p transformUsingAffineTransform:t];
  [p setLineWidth:width * s];
  [p setLineCapStyle:NSRoundLineCapStyle];
  [p setLineJoinStyle:NSRoundLineJoinStyle];
  [color set];
  [p stroke];
}
