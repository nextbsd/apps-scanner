/*
 * Copyright (C) 2026 Joseph Maloney <pkgdemonteam@gmail.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * SCAppearance: the colours Scanner draws its own views with, Dark or
 * Light as the desktop's NBAppearance says (the NextBSD theme draws the
 * standard controls), and the line glyphs from the mockup.
 */

#import <AppKit/AppKit.h>

/* Posted (locally) when NBAppearance changes. */
extern NSString *const SCAppearanceDidChangeNotification;

void SCAppearanceStartWatching (void);
BOOL SCIsLight (void);

NSColor *SCHex (unsigned rgb, CGFloat alpha);
NSColor *SCTextColor (void);
NSColor *SCDimColor (void);
NSColor *SCFaintColor (void);
NSColor *SCAccentColor (void);
NSColor *SCAccentTextColor (void);
NSColor *SCSidebarColor (void);
NSColor *SCPreviewColor (void);
NSColor *SCSelectionColor (void);
NSColor *SCLineColor (void);
NSColor *SCPaperColor (void);

NSFont *SCFont (CGFloat size, BOOL bold);

/* A glyph from the mockup, drawn in a 24-unit square at rect in a
 * flipped view: scanner, usb, net, plus. */
void SCDrawGlyph (NSString *name, NSRect rect, NSColor *color, CGFloat width);

/* Text in a flipped view, its top left at point. */
void SCDrawText (NSString *s, NSPoint point, NSFont *font, NSColor *color);
NSSize SCTextSize (NSString *s, NSFont *font);
