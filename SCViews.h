/*
 * Copyright (C) 2026 Joseph Maloney <pkgdemonteam@gmail.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Scanner's own views, as drawn in the mockup (nextbsd/nextbsd#717): the
 * sidebar of scanners, the preview of the glass with the box dragged on
 * it, the strip of pages for a PDF and the "No scanner found" pane.
 */

#import <AppKit/AppKit.h>

/* ---- the sidebar -------------------------------------------------------- */

@interface SCSidebarView : NSView
{
  NSArray *devices;
  NSInteger selected;
  BOOL searched;
  BOOL enabled;
  CGFloat spin;
  NSTimer *spinner;
  id target;
  SEL action;
}
- (void)setDevices:(NSArray *)list searched:(BOOL)done;
- (NSArray *)devices;
- (NSInteger)selectedIndex;
- (void)setSelectedIndex:(NSInteger)index;
- (void)setEnabled:(BOOL)flag;
- (void)setTarget:(id)t action:(SEL)a;
@end

/* ---- the preview of the glass ------------------------------------------ */

@interface SCPreviewView : NSView
{
  NSSize glass;          /* mm */
  NSImage *image;        /* the overview, the whole glass */
  NSRect selection;      /* mm from the top left; empty: none */
  BOOL metric;
  NSString *message;     /* over the glass: busy, or what went wrong */
  double fraction;       /* < 0: no progress bar */
  /* dragging */
  int dragMode;          /* 0 none, 1 new, 2 move, 3 resize */
  NSPoint anchor;        /* mm */
  NSRect startSelection;
  id target;
  SEL action;
}
- (void)setGlassSize:(NSSize)mm;
- (NSSize)glassSize;
- (void)setImage:(NSImage *)overview;
- (NSRect)selection;
- (void)setSelection:(NSRect)mm;
- (void)setMetric:(BOOL)flag;
- (void)setMessage:(NSString *)text progress:(double)f;
/* Sent when the person drags a box. */
- (void)setTarget:(id)t action:(SEL)a;
@end

/* "4.2 × 2.7 in" or "10.7 × 6.9 cm". */
NSString *SCSizeString (NSSize mm, BOOL metric);

/* ---- the pages of a PDF ------------------------------------------------- */

@interface SCPagesView : NSView
{
  NSMutableArray *pages;     /* SCPage */
  NSMutableArray *thumbs;    /* NSImage */
  NSInteger selected;
  NSInteger dragging;        /* -1: none */
  NSInteger dropIndex;
  NSPoint dragPoint, downPoint;
  double busy;               /* < 0: not scanning */
  id target;
  SEL addAction;
}
- (NSMutableArray *)pages;
- (void)addPage:(id)page;
- (void)removeAllPages;
- (void)setBusy:(double)f;
/* Sent when Add Page is clicked. */
- (void)setTarget:(id)t addAction:(SEL)a;
- (void)tile;
@end

/* ---- no scanner ---------------------------------------------------------- */

@interface SCEmptyView : NSView
{
  NSString *title;
  NSString *text;
  NSButton *button;
}
- (void)setTitle:(NSString *)t text:(NSString *)s;
- (NSButton *)button;
@end
