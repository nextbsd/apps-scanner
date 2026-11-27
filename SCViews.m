/*
 * Copyright (C) 2026 Joseph Maloney <pkgdemonteam@gmail.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "SCViews.h"
#import "SCAppearance.h"
#import "SCScanner.h"
#import "SCPDFWriter.h"

static void
SCRound (NSRect r, CGFloat radius, NSColor *fill)
{
  [fill set];
  [[NSBezierPath bezierPathWithRoundedRect:r xRadius:radius yRadius:radius] fill];
}

/* Words of s in lines no wider than width. */
static NSArray *
SCWrap (NSString *s, NSFont *font, CGFloat width)
{
  NSMutableArray *lines = [NSMutableArray array];
  NSEnumerator *e = [[s componentsSeparatedByString:@" "] objectEnumerator];
  NSMutableString *line = [NSMutableString string];
  NSString *word;

  while ((word = [e nextObject]) != nil)
    {
      NSString *tryLine = [line length]
        ? [NSString stringWithFormat:@"%@ %@", line, word] : word;
      if ([line length] && SCTextSize (tryLine, font).width > width)
        {
          [lines addObject:AUTORELEASE ([line copy])];
          [line setString:word];
        }
      else
        [line setString:tryLine];
    }
  if ([line length])
    [lines addObject:line];
  return lines;
}

static void
SCDrawCentredLines (NSArray *lines, CGFloat midX, CGFloat y, CGFloat lineHeight,
                    NSFont *font, NSColor *color)
{
  NSUInteger i;

  for (i = 0; i < [lines count]; i++)
    {
      NSString *l = [lines objectAtIndex:i];
      SCDrawText (l, NSMakePoint (floor (midX - SCTextSize (l, font).width / 2),
                                  y + i * lineHeight), font, color);
    }
}

/* A small copy of a scan, averaging the pixels each one covers. */
static NSImage *
SCThumbnail (NSBitmapImageRep *rep, CGFloat maxW, CGFloat maxH)
{
  int w = (int)[rep pixelsWide], h = (int)[rep pixelsHigh];
  int spp = (int)[rep samplesPerPixel], bpr = (int)[rep bytesPerRow];
  CGFloat scale = MIN (maxW * 2 / w, maxH * 2 / h);   /* 2x, for sharpness */
  int tw, th, x, y, sx, sy, c;
  const unsigned char *src = [rep bitmapData];
  NSBitmapImageRep *t;
  unsigned char *dst;
  NSImage *image;

  if (scale > 1)
    scale = 1;
  tw = MAX (1, (int)(w * scale));
  th = MAX (1, (int)(h * scale));
  t = AUTORELEASE ([[NSBitmapImageRep alloc]
      initWithBitmapDataPlanes:NULL pixelsWide:tw pixelsHigh:th
                 bitsPerSample:8 samplesPerPixel:spp >= 3 ? 3 : 1 hasAlpha:NO
                      isPlanar:NO
                colorSpaceName:spp >= 3 ? NSCalibratedRGBColorSpace
                                        : NSCalibratedWhiteColorSpace
                   bytesPerRow:0 bitsPerPixel:0]);
  dst = [t bitmapData];
  for (y = 0; y < th; y++)
    for (x = 0; x < tw; x++)
      {
        int x0 = x * w / tw, x1 = MAX (x0 + 1, (x + 1) * w / tw);
        int y0 = y * h / th, y1 = MAX (y0 + 1, (y + 1) * h / th);
        int n = spp >= 3 ? 3 : 1;
        unsigned long sum[3] = { 0, 0, 0 }, count = 0;

        /* At most 4 x 4 samples a pixel: enough for a thumbnail. */
        for (sy = y0; sy < y1; sy += MAX (1, (y1 - y0) / 4))
          for (sx = x0; sx < x1; sx += MAX (1, (x1 - x0) / 4))
            {
              for (c = 0; c < n; c++)
                sum[c] += src[(size_t)sy * bpr + sx * spp + c];
              count++;
            }
        for (c = 0; c < n; c++)
          dst[((size_t)y * tw + x) * n + c] = sum[c] / count;
      }
  image = AUTORELEASE ([[NSImage alloc] initWithSize:NSMakeSize (tw / 2.0, th / 2.0)]);
  [t setSize:NSMakeSize (tw / 2.0, th / 2.0)];
  [image addRepresentation:t];
  return image;
}

/* ---- the sidebar -------------------------------------------------------- */

@implementation SCSidebarView

static const CGFloat SCRowTop = 30, SCRowHeight = 44;

- (id)initWithFrame:(NSRect)frame
{
  if ((self = [super initWithFrame:frame]) != nil)
    {
      devices = [[NSArray alloc] init];
      selected = -1;
      enabled = YES;
      spinner = RETAIN ([NSTimer scheduledTimerWithTimeInterval:0.1
                                                         target:self
                                                       selector:@selector (turn:)
                                                       userInfo:nil
                                                        repeats:YES]);
    }
  return self;
}

- (void)dealloc
{
  [spinner invalidate];
  RELEASE (spinner);
  RELEASE (devices);
  [super dealloc];
}

- (BOOL)isFlipped { return YES; }

- (CGFloat)spinnerY
{
  CGFloat y = SCRowTop + SCRowHeight * [devices count];
  if ([devices count] == 0 && searched)
    y += 26;
  return y + 12;
}

- (void)turn:(NSTimer *)t
{
  spin += 0.5;
  [self setNeedsDisplayInRect:NSMakeRect (10, [self spinnerY] - 4, 24, 20)];
}

- (void)setDevices:(NSArray *)list searched:(BOOL)done
{
  ASSIGN (devices, list);
  searched = done;
  if (selected >= (NSInteger)[devices count])
    selected = [devices count] ? 0 : -1;
  [self setNeedsDisplay:YES];
}

- (NSArray *)devices { return devices; }
- (NSInteger)selectedIndex { return selected; }

- (void)setSelectedIndex:(NSInteger)index
{
  selected = index;
  [self setNeedsDisplay:YES];
}

- (void)setEnabled:(BOOL)flag { enabled = flag; }

- (void)setTarget:(id)t action:(SEL)a
{
  target = t;
  action = a;
}

- (void)drawRect:(NSRect)r
{
  NSRect b = [self bounds];
  NSUInteger i;
  CGFloat y;
  NSBezierPath *ring;

  [SCSidebarColor () set];
  NSRectFill (r);
  [SCLineColor () set];
  NSRectFillUsingOperation (NSMakeRect (NSMaxX (b) - 1, 0, 1, NSHeight (b)),
                            NSCompositeSourceOver);
  SCDrawText (@"SCANNERS", NSMakePoint (18, 11), SCFont (10.5, YES), SCFaintColor ());

  for (i = 0; i < [devices count]; i++)
    {
      SCDevice *d = [devices objectAtIndex:i];
      NSRect row = NSMakeRect (8, SCRowTop + i * SCRowHeight, NSWidth (b) - 16,
                               SCRowHeight - 4);
      if ((NSInteger)i == selected)
        SCRound (row, 7, SCSelectionColor ());
      SCDrawGlyph (@"scanner", NSMakeRect (18, NSMinY (row) + 10, 20, 20),
                   SCTextColor (), 1.7);
      SCDrawText ([d title], NSMakePoint (47, NSMinY (row) + 4),
                  SCFont (12.5, YES), SCTextColor ());
      if ([[d saneName] hasPrefix:@"test:"])
        SCDrawText ([d detail], NSMakePoint (47, NSMinY (row) + 21),
                    SCFont (11, NO), SCDimColor ());
      else
        {
          SCDrawGlyph ([d isNetwork] ? @"net" : @"usb",
                       NSMakeRect (47, NSMinY (row) + 23, 11, 11), SCDimColor (), 1.8);
          SCDrawText ([d detail], NSMakePoint (62, NSMinY (row) + 21),
                      SCFont (11, NO), SCDimColor ());
        }
    }
  if ([devices count] == 0 && searched)
    SCDrawText (@"None found", NSMakePoint (18, SCRowTop + 2), SCFont (12, NO),
                SCFaintColor ());

  /* Scanner keeps looking: the ring turns all the time. */
  y = [self spinnerY];
  ring = [NSBezierPath bezierPath];
  [ring appendBezierPathWithArcWithCenter:NSMakePoint (23, y + 7)
                                   radius:5
                               startAngle:spin * 57.3
                                 endAngle:spin * 57.3 + 270];
  [ring setLineWidth:2];
  [SCAccentColor () set];
  [ring stroke];
  SCDrawText (@"Looking for scanners…", NSMakePoint (35, y), SCFont (11.5, NO),
              SCDimColor ());
}

- (void)mouseDown:(NSEvent *)e
{
  NSPoint p = [self convertPoint:[e locationInWindow] fromView:nil];
  NSInteger i = (NSInteger)floor ((p.y - SCRowTop) / SCRowHeight);

  if (!enabled || p.y < SCRowTop || i < 0 || i >= (NSInteger)[devices count]
      || i == selected)
    return;
  selected = i;
  [self setNeedsDisplay:YES];
  [NSApp sendAction:action to:target from:self];
}

@end

/* ---- the preview -------------------------------------------------------- */

NSString *
SCSizeString (NSSize mm, BOOL metric)
{
  if (metric)
    return [NSString stringWithFormat:@"%.1f × %.1f cm",
                     mm.width / 10.0, mm.height / 10.0];
  return [NSString stringWithFormat:@"%.1f × %.1f in",
                   mm.width / 25.4, mm.height / 25.4];
}

@implementation SCPreviewView

- (id)initWithFrame:(NSRect)frame
{
  if ((self = [super initWithFrame:frame]) != nil)
    {
      glass = NSMakeSize (215.9, 297.0);
      fraction = -1;
    }
  return self;
}

- (void)dealloc
{
  RELEASE (image);
  RELEASE (message);
  [super dealloc];
}

- (BOOL)isFlipped { return YES; }

- (void)setGlassSize:(NSSize)mm
{
  if (mm.width > 1 && mm.height > 1)
    glass = mm;
  [self setNeedsDisplay:YES];
}

- (NSSize)glassSize { return glass; }

- (void)setImage:(NSImage *)overview
{
  ASSIGN (image, overview);
  [self setNeedsDisplay:YES];
}

- (NSRect)selection { return selection; }

- (void)setSelection:(NSRect)mm
{
  selection = mm;
  [self setNeedsDisplay:YES];
}

- (void)setMetric:(BOOL)flag { metric = flag; }

- (void)setMessage:(NSString *)text progress:(double)f
{
  ASSIGN (message, text);
  fraction = f;
  [self setNeedsDisplay:YES];
}

- (void)setTarget:(id)t action:(SEL)a
{
  target = t;
  action = a;
}

/* The glass in the view, and the scale in points a millimetre. */
- (NSRect)glassRect:(CGFloat *)scale
{
  NSRect b = [self bounds];
  CGFloat availW = NSWidth (b) - 60, availH = NSHeight (b) - 70;
  CGFloat s = MIN (availW / glass.width, availH / glass.height);
  NSRect g;

  if (s <= 0)
    s = 0.1;
  g.size = NSMakeSize (floor (glass.width * s), floor (glass.height * s));
  g.origin = NSMakePoint (floor (NSMidX (b) - g.size.width / 2),
                          floor (40 + (availH - g.size.height) / 2));
  if (scale)
    *scale = s;
  return g;
}

- (NSRect)viewRectForMM:(NSRect)mm
{
  CGFloat s;
  NSRect g = [self glassRect:&s];

  return NSMakeRect (NSMinX (g) + NSMinX (mm) * s, NSMinY (g) + NSMinY (mm) * s,
                     NSWidth (mm) * s, NSHeight (mm) * s);
}

- (NSPoint)mmForPoint:(NSPoint)p
{
  CGFloat s;
  NSRect g = [self glassRect:&s];
  NSPoint mm = NSMakePoint ((p.x - NSMinX (g)) / s, (p.y - NSMinY (g)) / s);

  mm.x = MAX (0, MIN (glass.width, mm.x));
  mm.y = MAX (0, MIN (glass.height, mm.y));
  return mm;
}

- (void)drawRect:(NSRect)r
{
  CGFloat s;
  NSRect g = [self glassRect:&s];

  [SCPreviewColor () set];
  NSRectFill (r);
  SCDrawText (@"Overview · drag a box to scan part of the glass",
              NSMakePoint (14, 12), SCFont (11.5, NO), SCDimColor ());

  /* The glass, with a soft shadow. */
  SCRound (NSOffsetRect (NSInsetRect (g, -2, -2), 0, 2), 3,
           [NSColor colorWithCalibratedWhite:0 alpha:0.18]);
  SCRound (NSOffsetRect (NSInsetRect (g, -1, -1), 0, 1), 2,
           [NSColor colorWithCalibratedWhite:0 alpha:0.18]);
  [SCPaperColor () set];
  NSRectFill (g);
  if (image != nil)
    [image drawInRect:g fromRect:NSZeroRect operation:NSCompositeSourceOver
             fraction:1.0];
  else if (message == nil)
    {
      NSFont *f = SCFont (12, NO);
      SCDrawCentredLines (SCWrap (@"Click Overview for a quick look at "
                                  @"what's on the glass.", f, NSWidth (g) - 40),
                          NSMidX (g), NSMidY (g) - 8, 17, f, SCHex (0x8d929c, 1));
    }

  if (!NSIsEmptyRect (selection))
    {
      NSRect v = NSIntegralRect ([self viewRectForMM:selection]);
      NSBezierPath *box = [NSBezierPath bezierPathWithRect:NSInsetRect (v, 0.75, 0.75)];
      CGFloat dash[2] = { 5, 3 };
      NSString *label = SCSizeString (selection.size, metric);
      NSFont *lf = SCFont (11, YES);
      NSSize ls = SCTextSize (label, lf);
      NSRect pill;
      int i;

      [SCHex (SCIsLight () ? 0x00a3c7 : 0x00d4ff, 0.08) set];
      NSRectFillUsingOperation (v, NSCompositeSourceOver);
      [box setLineDash:dash count:2 phase:0];
      [box setLineWidth:1.5];
      [SCAccentColor () set];
      [box stroke];
      for (i = 0; i < 4; i++)
        {
          NSPoint c = NSMakePoint (i & 1 ? NSMaxX (v) : NSMinX (v),
                                   i & 2 ? NSMaxY (v) : NSMinY (v));
          [SCAccentColor () set];
          [[NSBezierPath bezierPathWithOvalInRect:
                           NSMakeRect (c.x - 4.5, c.y - 4.5, 9, 9)] fill];
        }
      pill = NSMakeRect (NSMaxX (v) + 2 - (ls.width + 14), NSMaxY (v) + 8,
                         ls.width + 14, ls.height + 4);
      SCRound (pill, 5, SCAccentColor ());
      SCDrawText (label, NSMakePoint (NSMinX (pill) + 7, NSMinY (pill) + 2), lf,
                  SCAccentTextColor ());
    }

  if (message != nil)
    {
      NSFont *f = SCFont (12.5, YES);
      NSArray *lines = SCWrap (message, f, MIN (300, NSWidth (g) - 40));
      CGFloat h = 18 * [lines count] + (fraction >= 0 ? 34 : 24);
      CGFloat w = MIN (340, NSWidth (g) - 20);
      NSRect hud = NSMakeRect (floor (NSMidX (g) - w / 2), floor (NSMidY (g) - h / 2),
                               w, h);

      SCRound (hud, 10, [NSColor colorWithCalibratedRed:0.11 green:0.12
                                                   blue:0.14 alpha:0.9]);
      SCDrawCentredLines (lines, NSMidX (hud), NSMinY (hud) + 12, 18, f,
                          SCHex (0xe9ebef, 1));
      if (fraction >= 0)
        {
          NSRect bar = NSMakeRect (NSMinX (hud) + 20, NSMaxY (hud) - 18,
                                   NSWidth (hud) - 40, 5);
          SCRound (bar, 2.5, [NSColor colorWithCalibratedWhite:1 alpha:0.15]);
          bar.size.width = MAX (5, NSWidth (bar) * MIN (1, fraction));
          SCRound (bar, 2.5, SCHex (0x00d4ff, 1));
        }
    }
}

- (void)mouseDown:(NSEvent *)e
{
  NSPoint p = [self convertPoint:[e locationInWindow] fromView:nil];
  NSPoint mm = [self mmForPoint:p];
  NSRect g = [self glassRect:NULL];
  int i;

  dragMode = 0;
  if (fraction >= 0 || !NSPointInRect (p, NSInsetRect (g, -8, -8)))
    return;
  if (!NSIsEmptyRect (selection))
    {
      NSRect v = [self viewRectForMM:selection];
      for (i = 0; i < 4; i++)
        {
          NSPoint c = NSMakePoint (i & 1 ? NSMaxX (v) : NSMinX (v),
                                   i & 2 ? NSMaxY (v) : NSMinY (v));
          if (fabs (p.x - c.x) <= 7 && fabs (p.y - c.y) <= 7)
            {
              /* Resize from the opposite corner. */
              anchor = NSMakePoint (i & 1 ? NSMinX (selection) : NSMaxX (selection),
                                    i & 2 ? NSMinY (selection) : NSMaxY (selection));
              dragMode = 3;
              return;
            }
        }
      if (NSPointInRect (p, v))
        {
          anchor = mm;
          startSelection = selection;
          dragMode = 2;
          return;
        }
    }
  anchor = mm;
  dragMode = 1;
}

- (void)mouseDragged:(NSEvent *)e
{
  NSPoint mm = [self mmForPoint:[self convertPoint:[e locationInWindow]
                                          fromView:nil]];

  if (dragMode == 1 || dragMode == 3)
    selection = NSMakeRect (MIN (anchor.x, mm.x), MIN (anchor.y, mm.y),
                            fabs (mm.x - anchor.x), fabs (mm.y - anchor.y));
  else if (dragMode == 2)
    {
      NSRect s = startSelection;
      s.origin.x += mm.x - anchor.x;
      s.origin.y += mm.y - anchor.y;
      s.origin.x = MAX (0, MIN (glass.width - NSWidth (s), NSMinX (s)));
      s.origin.y = MAX (0, MIN (glass.height - NSHeight (s), NSMinY (s)));
      selection = s;
    }
  else
    return;
  [self setNeedsDisplay:YES];
  [NSApp sendAction:action to:target from:self];
}

- (void)mouseUp:(NSEvent *)e
{
  if (dragMode == 0)
    return;
  /* A click, or a box too small to scan: the whole glass again. */
  if (NSWidth (selection) < 3 || NSHeight (selection) < 3)
    selection = NSZeroRect;
  dragMode = 0;
  [self setNeedsDisplay:YES];
  [NSApp sendAction:action to:target from:self];
}

@end

/* ---- the pages ---------------------------------------------------------- */

@implementation SCPagesView

static const CGFloat SCThumbW = 110, SCThumbH = 142, SCGapX = 22, SCGapY = 18,
                     SCCellH = 142 + 26;

- (id)initWithFrame:(NSRect)frame
{
  if ((self = [super initWithFrame:frame]) != nil)
    {
      pages = [[NSMutableArray alloc] init];
      thumbs = [[NSMutableArray alloc] init];
      selected = -1;
      dragging = -1;
      busy = -1;
    }
  return self;
}

- (void)dealloc
{
  RELEASE (pages);
  RELEASE (thumbs);
  [super dealloc];
}

- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }

- (NSMutableArray *)pages { return pages; }

- (void)changed
{
  if ([target respondsToSelector:@selector (pagesChanged:)])
    [target performSelector:@selector (pagesChanged:) withObject:self];
  [self tile];
  [self setNeedsDisplay:YES];
}

- (void)addPage:(id)page
{
  SCPage *p = page;

  [pages addObject:p];
  [thumbs addObject:SCThumbnail (p->image, SCThumbW, SCThumbH)];
  selected = [pages count] - 1;
  [self changed];
}

- (void)removeAllPages
{
  [pages removeAllObjects];
  [thumbs removeAllObjects];
  selected = -1;
  [self changed];
}

- (void)setBusy:(double)f
{
  busy = f;
  [self setNeedsDisplay:YES];
}

- (void)setTarget:(id)t addAction:(SEL)a
{
  target = t;
  addAction = a;
}

- (NSInteger)columns
{
  return MAX (1, (NSInteger)floor ((NSWidth ([self bounds]) + SCGapX)
                                   / (SCThumbW + SCGapX)));
}

- (NSRect)cellRect:(NSInteger)i
{
  NSInteger cols = [self columns];

  return NSMakeRect ((i % cols) * (SCThumbW + SCGapX), 4 + (i / cols) * (SCCellH + SCGapY),
                     SCThumbW, SCCellH);
}

/* Tall enough for every page and Add Page, in the scroll view. */
- (void)tile
{
  NSView *clip = [self superview];
  CGFloat w = clip ? NSWidth ([clip bounds]) : NSWidth ([self frame]);
  NSInteger cols = MAX (1, (NSInteger)floor ((w + SCGapX) / (SCThumbW + SCGapX)));
  NSInteger rows = ([pages count] + 1 + cols - 1) / cols;
  CGFloat h = 8 + rows * (SCCellH + SCGapY);

  if (clip && h < NSHeight ([clip bounds]))
    h = NSHeight ([clip bounds]);
  [self setFrameSize:NSMakeSize (w, h)];
}

- (NSRect)thumbRect:(NSInteger)i inCell:(NSRect)c
{
  NSSize s = [[thumbs objectAtIndex:i] size];
  CGFloat k = MIN (SCThumbW / s.width, SCThumbH / s.height);
  CGFloat w = floor (s.width * k), h = floor (s.height * k);

  return NSMakeRect (NSMidX (c) - floor (w / 2), NSMinY (c) + SCThumbH - h, w, h);
}

- (void)drawPage:(NSInteger)i inCell:(NSRect)c alpha:(CGFloat)alpha
{
  NSRect t = [self thumbRect:i inCell:c];
  NSString *label = [NSString stringWithFormat:@"Page %ld", (long)i + 1];
  NSFont *f = SCFont (11.5, YES);

  if (i == selected && alpha >= 1)
    {
      NSBezierPath *o = [NSBezierPath bezierPathWithRect:NSInsetRect (t, -4, -4)];
      [o setLineWidth:2];
      [SCAccentColor () set];
      [o stroke];
    }
  [[NSColor colorWithCalibratedWhite:0 alpha:0.2 * alpha] set];
  NSRectFillUsingOperation (NSOffsetRect (t, 0, 2), NSCompositeSourceOver);
  [[thumbs objectAtIndex:i] drawInRect:t fromRect:NSZeroRect
                             operation:NSCompositeSourceOver fraction:alpha];
  SCDrawText (label, NSMakePoint (floor (NSMidX (c) - SCTextSize (label, f).width / 2),
                                  NSMinY (c) + SCThumbH + 7), f,
              alpha >= 1 ? SCTextColor () : SCDimColor ());
}

- (void)drawRect:(NSRect)r
{
  NSInteger i, n = [pages count];
  NSRect add = [self cellRect:n];
  NSRect tile = NSMakeRect (NSMinX (add), NSMinY (add), SCThumbW, SCThumbH);
  NSBezierPath *dashed = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect (tile, 1, 1)
                                                         xRadius:4 yRadius:4];
  CGFloat dash[2] = { 6, 4 };
  NSFont *f = SCFont (11.5, YES);
  NSString *label = busy >= 0 ? [NSString stringWithFormat:@"Scanning… %d%%",
                                          (int)(busy * 100)]
                              : @"Add Page";

  for (i = 0; i < n; i++)
    [self drawPage:i inCell:[self cellRect:i] alpha:(i == dragging ? 0.35 : 1)];

  [dashed setLineDash:dash count:2 phase:0];
  [dashed setLineWidth:2];
  [SCDimColor () set];
  [dashed stroke];
  if (busy < 0)
    SCDrawGlyph (@"plus", NSMakeRect (NSMidX (tile) - 13, NSMidY (tile) - 13, 26, 26),
                 SCDimColor (), 2);
  else
    {
      NSRect bar = NSMakeRect (NSMinX (tile) + 14, NSMidY (tile) - 3, SCThumbW - 28, 6);
      SCRound (bar, 3, SCLineColor ());
      bar.size.width = MAX (6, NSWidth (bar) * busy);
      SCRound (bar, 3, SCAccentColor ());
    }
  SCDrawText (label, NSMakePoint (floor (NSMidX (add) - SCTextSize (label, f).width / 2),
                                  NSMinY (add) + SCThumbH + 7), f, SCDimColor ());

  if (dragging >= 0)
    {
      /* Where it would go, and the page under the pointer. */
      NSRect c = [self cellRect:dropIndex];
      NSRect t;
      [SCAccentColor () set];
      NSRectFill (NSMakeRect (MAX (0, NSMinX (c) - SCGapX / 2 - 1.5), NSMinY (c),
                              3, SCThumbH));
      t = [self thumbRect:dragging inCell:[self cellRect:dragging]];
      t.origin = NSMakePoint (dragPoint.x - NSWidth (t) / 2,
                              dragPoint.y - NSHeight (t) / 2);
      [[thumbs objectAtIndex:dragging] drawInRect:t fromRect:NSZeroRect
                                        operation:NSCompositeSourceOver
                                         fraction:0.8];
    }
}

- (NSInteger)indexAt:(NSPoint)p
{
  NSInteger i;

  for (i = 0; i <= (NSInteger)[pages count]; i++)
    if (NSPointInRect (p, [self cellRect:i]))
      return i;
  return -1;
}

- (NSInteger)slotAt:(NSPoint)p
{
  NSInteger cols = [self columns];
  NSInteger row = MAX (0, (NSInteger)floor ((p.y - 4) / (SCCellH + SCGapY)));
  NSInteger col = (NSInteger)floor ((p.x + SCThumbW / 2 + SCGapX / 2)
                                    / (SCThumbW + SCGapX));
  NSInteger slot;

  col = MAX (0, MIN (cols, col));
  slot = row * cols + col;
  return MAX (0, MIN ((NSInteger)[pages count], slot));
}

- (void)mouseDown:(NSEvent *)e
{
  NSPoint p = [self convertPoint:[e locationInWindow] fromView:nil];
  NSInteger i = [self indexAt:p];

  [[self window] makeFirstResponder:self];
  downPoint = p;
  dragging = -1;
  if (i == (NSInteger)[pages count])
    {
      if (busy < 0)
        [NSApp sendAction:addAction to:target from:self];
      selected = -1;
    }
  else
    selected = i;
  [self setNeedsDisplay:YES];
}

- (void)mouseDragged:(NSEvent *)e
{
  NSPoint p = [self convertPoint:[e locationInWindow] fromView:nil];

  if (selected < 0 || selected >= (NSInteger)[pages count])
    return;
  if (dragging < 0 && hypot (p.x - downPoint.x, p.y - downPoint.y) < 4)
    return;
  dragging = selected;
  dragPoint = p;
  dropIndex = [self slotAt:p];
  [self setNeedsDisplay:YES];
}

- (void)mouseUp:(NSEvent *)e
{
  NSInteger to;
  id page, thumb;

  if (dragging < 0)
    return;
  to = dropIndex > dragging ? dropIndex - 1 : dropIndex;
  if (to != dragging)
    {
      page = RETAIN ([pages objectAtIndex:dragging]);
      thumb = RETAIN ([thumbs objectAtIndex:dragging]);
      [pages removeObjectAtIndex:dragging];
      [thumbs removeObjectAtIndex:dragging];
      [pages insertObject:page atIndex:to];
      [thumbs insertObject:thumb atIndex:to];
      RELEASE (page);
      RELEASE (thumb);
      selected = to;
    }
  dragging = -1;
  [self changed];
}

/* Delete takes the selected page out. */
- (void)keyDown:(NSEvent *)e
{
  NSString *c = [e charactersIgnoringModifiers];
  unichar k = [c length] ? [c characterAtIndex:0] : 0;

  if ((k == NSDeleteCharacter || k == NSBackspaceCharacter
       || k == NSDeleteFunctionKey)
      && selected >= 0 && selected < (NSInteger)[pages count])
    {
      [pages removeObjectAtIndex:selected];
      [thumbs removeObjectAtIndex:selected];
      selected = MIN (selected, (NSInteger)[pages count] - 1);
      [self changed];
      return;
    }
  [super keyDown:e];
}

@end

/* ---- no scanner --------------------------------------------------------- */

@implementation SCEmptyView

- (id)initWithFrame:(NSRect)frame
{
  if ((self = [super initWithFrame:frame]) != nil)
    {
      button = [[NSButton alloc] initWithFrame:NSMakeRect (0, 0, 190, 28)];
      [button setTitle:@"Add a Network Scanner…"];
      [button setBezelStyle:NSRoundedBezelStyle];
      [button sizeToFit];
      [self addSubview:button];
      RELEASE (button);
      [self setTitle:@"No scanner found"
                text:@"Connect a scanner with USB and turn it on, or make "
                     @"sure a network scanner is on the same network. "
                     @"Scanner keeps looking and lists it when it appears."];
    }
  return self;
}

- (void)dealloc
{
  RELEASE (title);
  RELEASE (text);
  [super dealloc];
}

- (BOOL)isFlipped { return YES; }
- (NSButton *)button { return button; }

- (NSArray *)lines
{
  return SCWrap (text, SCFont (12.5, NO), 240);
}

- (CGFloat)top
{
  CGFloat h = 64 + 10 + 20 + 10 + 19 * [[self lines] count] + 14 + NSHeight ([button frame]);
  return floor ((NSHeight ([self bounds]) - h) / 2);
}

- (void)place
{
  NSRect f = [button frame];
  CGFloat y = [self top] + 64 + 10 + 20 + 10 + 19 * [[self lines] count] + 14;

  if (NSWidth (f) < 180)
    f.size.width = 190;
  f.origin = NSMakePoint (floor (NSMidX ([self bounds]) - NSWidth (f) / 2), y);
  [button setFrame:f];
  [self setNeedsDisplay:YES];
}

- (void)setFrameSize:(NSSize)s
{
  [super setFrameSize:s];
  [self place];
}

- (void)setTitle:(NSString *)t text:(NSString *)s
{
  ASSIGN (title, t);
  ASSIGN (text, s);
  [self place];
}

- (void)drawRect:(NSRect)r
{
  CGFloat midX = NSMidX ([self bounds]);
  CGFloat y = [self top];
  NSFont *tf = SCFont (15, YES);

  SCDrawGlyph (@"scanner", NSMakeRect (midX - 32, y, 64, 64), SCFaintColor (), 1.4);
  y += 64 + 10;
  SCDrawText (title, NSMakePoint (floor (midX - SCTextSize (title, tf).width / 2), y),
              tf, SCTextColor ());
  y += 20 + 10;
  SCDrawCentredLines ([self lines], midX, y, 19, SCFont (12.5, NO), SCDimColor ());
}

@end
