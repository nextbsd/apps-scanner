/*
 * Copyright (C) 2026 Joseph Maloney <pkgdemonteam@gmail.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "SCController.h"
#import "SCAppearance.h"
#import "SCPDFWriter.h"
#import "SCViews.h"

static const CGFloat SCSidebarWidth = 210, SCInspectorWidth = 300;

enum { SCFormatPDF = 0, SCFormatPNG, SCFormatJPEG, SCFormatTIFF };

/* Paper sizes, in millimetres. */
typedef struct
{
  NSString *name;
  double w, h;
  BOOL metric;
} SCPaper;

static SCPaper SCPapers[] = {
  { @"US Letter", 215.9, 279.4, NO },
  { @"US Legal", 215.9, 355.6, NO },
  { @"A4", 210, 297, YES },
  { @"A5", 148, 210, YES },
  { @"B5", 176, 250, YES },
  { @"Photo 4 × 6 in", 101.6, 152.4, NO },
  { @"Photo 5 × 7 in", 127, 177.8, NO },
  { @"Photo 10 × 15 cm", 100, 150, YES },
};
static const int SCPaperCount = sizeof SCPapers / sizeof SCPapers[0];
enum { SCSizeSelection = 1000, SCSizeWholeGlass = 1001 };
enum { SCFolderOther = 99 };

@interface SCFlippedView : NSView
@end
@implementation SCFlippedView
- (BOOL)isFlipped { return YES; }
@end

/* The pages' pane: the grey the glass sits on, as drawn. */
@interface SCPagesPane : SCFlippedView
@end
@implementation SCPagesPane
- (void)drawRect:(NSRect)r
{
  [SCPreviewColor () set];
  NSRectFill (r);
}
@end

/* Metric unless the locale measures in inches (the United States,
 * Liberia, Myanmar). */
static BOOL
SCLocaleIsMetric (void)
{
  NSLocale *l = [NSLocale currentLocale];
  id v = [l objectForKey:NSLocaleUsesMetricSystem];
  NSString *country;

  if (v != nil)
    return [v boolValue];
  country = [l objectForKey:NSLocaleCountryCode];
  if (country == nil)
    {
      const char *lang = getenv ("LC_ALL");
      if (lang == NULL || *lang == '\0')
        lang = getenv ("LC_MEASUREMENT");
      if (lang == NULL || *lang == '\0')
        lang = getenv ("LANG");
      if (lang != NULL && strlen (lang) >= 5 && lang[2] == '_')
        country = [[NSString stringWithUTF8String:lang]
                    substringWithRange:NSMakeRange (3, 2)];
    }
  return !([country isEqual:@"US"] || [country isEqual:@"LR"]
           || [country isEqual:@"MM"] || country == nil);
}

@implementation SCController

- (id)init
{
  if ((self = [super init]) != nil)
    {
      labels = [[NSMutableArray alloc] init];
      folders = [[NSMutableArray alloc] init];
      paper = -1;
      metric = SCLocaleIsMetric ();
    }
  return self;
}

- (void)dealloc
{
  RELEASE (labels);
  RELEASE (folders);
  RELEASE (current);
  RELEASE (resolutions);
  RELEASE (defaultName);
  RELEASE (scanner);
  RELEASE (window);
  [super dealloc];
}

/* ---- the menu ----------------------------------------------------------- */

static NSMenuItem *
SCItem (NSMenu *menu, NSString *title, SEL action, NSString *key, id target)
{
  NSMenuItem *item = (NSMenuItem *)[menu addItemWithTitle:title action:action
                                            keyEquivalent:key ? key : @""];
  if (target != nil)
    [item setTarget:target];
  return item;
}

static NSMenu *
SCSubmenu (NSMenu *main, NSString *title)
{
  NSMenu *menu = AUTORELEASE ([[NSMenu alloc] initWithTitle:title]);
  NSMenuItem *item = (NSMenuItem *)[main addItemWithTitle:title action:NULL
                                            keyEquivalent:@""];
  [main setSubmenu:menu forItem:item];
  return menu;
}

- (void)buildMenu
{
  NSMenu *main = AUTORELEASE ([[NSMenu alloc] initWithTitle:@"Scanner"]);
  NSMenu *m;

  m = SCSubmenu (main, @"Scanner");
  SCItem (m, @"About Scanner", @selector (orderFrontStandardAboutPanel:), nil, nil);
  SCItem (m, @"Hide", @selector (hide:), @"h", nil);
  SCItem (m, @"Quit", @selector (terminate:), @"q", nil);

  m = SCSubmenu (main, @"File");
  SCItem (m, @"Overview", @selector (overview:), @"", self);
  SCItem (m, @"Scan", @selector (scan:), @"", self);
  SCItem (m, @"Add a Network Scanner…", @selector (addNetworkScanner:), nil, self);
  SCItem (m, @"Close", @selector (performClose:), @"w", nil);

  m = SCSubmenu (main, @"Edit");
  SCItem (m, @"Cut", @selector (cut:), @"x", nil);
  SCItem (m, @"Copy", @selector (copy:), @"c", nil);
  SCItem (m, @"Paste", @selector (paste:), @"v", nil);
  SCItem (m, @"Select All", @selector (selectAll:), @"a", nil);

  m = SCSubmenu (main, @"View");
  SCItem (m, @"Whole Glass", @selector (wholeGlass:), nil, self);

  m = SCSubmenu (main, @"Window");
  SCItem (m, @"Minimize", @selector (performMiniaturize:), @"m", nil);
  SCItem (m, @"Zoom", @selector (performZoom:), nil, nil);
  [NSApp setWindowsMenu:m];

  m = SCSubmenu (main, @"Help");
  SCItem (m, @"Scanner Help", @selector (showHelp:), @"?", nil);

  [NSApp setMainMenu:main];
}

- (BOOL)validateMenuItem:(id <NSMenuItem>)item
{
  SEL a = [item action];

  if (a == @selector (overview:) || a == @selector (scan:))
    return opened && !busy && [pagesPane isHidden];
  if (a == @selector (wholeGlass:))
    return !busy && !NSIsEmptyRect ([preview selection]);
  if (a == @selector (addNetworkScanner:))
    return !busy;
  return YES;
}

/* ---- building the window ------------------------------------------------ */

- (NSTextField *)label:(NSString *)text frame:(NSRect)f in:(NSView *)v
{
  NSTextField *l = AUTORELEASE ([[NSTextField alloc] initWithFrame:f]);

  [l setStringValue:text];
  [l setEditable:NO];
  [l setSelectable:NO];
  [l setBordered:NO];
  [l setBezeled:NO];
  [l setDrawsBackground:NO];
  [l setFont:SCFont (12, NO)];
  [v addSubview:l];
  return l;
}

- (CGFloat)row:(NSString *)title y:(CGFloat)y
{
  NSTextField *l = [self label:title frame:NSMakeRect (8, y + 4, 104, 17)
                            in:inspector];

  [l setAlignment:NSRightTextAlignment];
  [labels addObject:l];
  return y;
}

- (NSPopUpButton *)popupAt:(CGFloat)y
{
  NSPopUpButton *p = AUTORELEASE ([[NSPopUpButton alloc]
                                     initWithFrame:NSMakeRect (122, y, 162, 24)
                                         pullsDown:NO]);
  [p setFont:SCFont (12, NO)];
  [p setTarget:self];
  [inspector addSubview:p];
  return p;
}

- (NSButton *)checkbox:(NSString *)title y:(CGFloat)y
{
  NSButton *b = AUTORELEASE ([[NSButton alloc]
                                initWithFrame:NSMakeRect (118, y, 182, 22)]);
  [b setButtonType:NSSwitchButton];
  [b setTitle:title];
  [b setFont:SCFont (12, NO)];
  [b setTarget:self];
  [inspector addSubview:b];
  return b;
}

- (NSButton *)button:(NSString *)title frame:(NSRect)f in:(NSView *)v action:(SEL)a
{
  NSButton *b = AUTORELEASE ([[NSButton alloc] initWithFrame:f]);

  [b setTitle:title];
  [b setBezelStyle:NSRoundedBezelStyle];
  [b setTarget:self];
  [b setAction:a];
  [v addSubview:b];
  return b;
}

- (void)buildInspector:(NSRect)f
{
  NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
  CGFloat y = 16, H = NSHeight (f);
  NSBox *line;
  int i;

  inspector = AUTORELEASE ([[SCFlippedView alloc] initWithFrame:f]);
  [inspector setAutoresizingMask:NSViewMinXMargin | NSViewHeightSizable];

  deviceLabel = [self label:@"" frame:NSMakeRect (16, y, 268, 20) in:inspector];
  [deviceLabel setFont:SCFont (14, YES)];
  y += 30;

  [self row:@"Kind" y:y];
  kindControl = AUTORELEASE ([[NSSegmentedControl alloc]
                                initWithFrame:NSMakeRect (122, y, 162, 24)]);
  [kindControl setSegmentCount:3];
  [kindControl setLabel:@"Colour" forSegment:0];
  [kindControl setLabel:@"Grey" forSegment:1];
  [kindControl setLabel:@"B&W" forSegment:2];
  for (i = 0; i < 3; i++)
    [kindControl setWidth:52 forSegment:i];
  [kindControl setSelectedSegment:MAX (0, MIN (2, [d integerForKey:@"SCKind"]))];
  [kindControl setTarget:self];
  [kindControl setAction:@selector (settingChanged:)];
  [inspector addSubview:kindControl];
  y += 31;

  [self row:@"Resolution" y:y];
  resolutionPopup = [self popupAt:y];
  [resolutionPopup setAction:@selector (settingChanged:)];
  y += 31;

  [self row:@"Size" y:y];
  sizePopup = [self popupAt:y];
  [sizePopup setAction:@selector (sizeChosen:)];
  y += 31;

  [self row:@"Format" y:y];
  formatPopup = [self popupAt:y];
  [formatPopup addItemsWithTitles:[NSArray arrayWithObjects:@"PDF", @"PNG",
                                           @"JPEG", @"TIFF", nil]];
  [formatPopup selectItemAtIndex:MAX (0, MIN (3, [d integerForKey:@"SCFormat"]))];
  [formatPopup setAction:@selector (settingChanged:)];
  y += 29;

  combineBox = [self checkbox:@"Combine pages into one PDF" y:y];
  [combineBox setState:[d objectForKey:@"SCCombine"]
                        ? [d boolForKey:@"SCCombine"] : YES];
  [combineBox setAction:@selector (settingChanged:)];
  y += 29;

  [self row:@"Save to" y:y];
  folderPopup = [self popupAt:y];
  [folderPopup setAction:@selector (folderChosen:)];
  y += 31;

  [self row:@"Name" y:y];
  nameField = AUTORELEASE ([[NSTextField alloc]
                              initWithFrame:NSMakeRect (122, y, 162, 24)]);
  [nameField setFont:SCFont (12, NO)];
  [nameField setDelegate:(id)self];
  [inspector addSubview:nameField];
  y += 29;

  openBox = [self checkbox:@"Open in Preview when done" y:y];
  [openBox setState:[d objectForKey:@"SCOpenWhenDone"]
                     ? [d boolForKey:@"SCOpenWhenDone"] : YES];
  [openBox setAction:@selector (settingChanged:)];

  /* The buttons, along the bottom. */
  line = AUTORELEASE ([[NSBox alloc] initWithFrame:NSMakeRect (16, H - 61, 268, 1)]);
  [line setBoxType:NSBoxSeparator];
  [line setTitlePosition:NSNoTitle];
  [line setAutoresizingMask:NSViewMinYMargin];
  [inspector addSubview:line];
  scanButton = [self button:@"Scan" frame:NSMakeRect (300 - 16 - 84, H - 46, 84, 30)
                         in:inspector action:@selector (scan:)];
  [scanButton setKeyEquivalent:@"\r"];
  [scanButton setAutoresizingMask:NSViewMinYMargin];
  overviewButton = [self button:@"Overview"
                          frame:NSMakeRect (300 - 16 - 84 - 8 - 96, H - 46, 96, 30)
                             in:inspector action:@selector (overview:)];
  [overviewButton setAutoresizingMask:NSViewMinYMargin];

  [self fillFolders];
  [self newName];
}

- (void)buildPages:(NSRect)f
{
  CGFloat W = NSWidth (f), H = NSHeight (f);
  NSButton *done, *cancel;

  pagesPane = AUTORELEASE ([[SCPagesPane alloc] initWithFrame:f]);
  [pagesPane setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
  pagesTitle = [self label:@"" frame:NSMakeRect (28, 22, W - 56, 20) in:pagesPane];
  [pagesTitle setFont:SCFont (14, YES)];
  [pagesTitle setAutoresizingMask:NSViewWidthSizable];
  pagesHint = [self label:@"Put the next page on the glass and click Add Page, "
                          @"or drag pages to reorder."
                    frame:NSMakeRect (28, 44, W - 56, 17) in:pagesPane];
  [pagesHint setAutoresizingMask:NSViewWidthSizable];
  [labels addObject:pagesHint];

  pagesScroll = AUTORELEASE ([[NSScrollView alloc]
                                initWithFrame:NSMakeRect (28, 74, W - 56, H - 74 - 64)]);
  [pagesScroll setHasVerticalScroller:YES];
  [pagesScroll setAutohidesScrollers:YES];
  [pagesScroll setBorderType:NSNoBorder];
  [pagesScroll setDrawsBackground:NO];
  [pagesScroll setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
  pagesView = AUTORELEASE ([[SCPagesView alloc]
                              initWithFrame:NSMakeRect (0, 0, W - 56 - 16, 200)]);
  [pagesView setTarget:self addAction:@selector (addPage:)];
  [pagesScroll setDocumentView:pagesView];
  [[pagesScroll contentView] setPostsFrameChangedNotifications:YES];
  [[NSNotificationCenter defaultCenter]
    addObserver:self selector:@selector (pagesResized:)
           name:NSViewFrameDidChangeNotification
         object:[pagesScroll contentView]];
  [pagesPane addSubview:pagesScroll];

  done = [self button:@"Done: Save PDF" frame:NSMakeRect (W - 28 - 130, H - 52, 130, 30)
                   in:pagesPane action:@selector (savePages:)];
  [done setAutoresizingMask:NSViewMinXMargin | NSViewMinYMargin];
  [done setKeyEquivalent:@"\r"];
  cancel = [self button:@"Cancel" frame:NSMakeRect (W - 28 - 130 - 8 - 90, H - 52, 90, 30)
                     in:pagesPane action:@selector (cancelPages:)];
  [cancel setAutoresizingMask:NSViewMinXMargin | NSViewMinYMargin];
  [cancel setKeyEquivalent:@"\e"];
  [pagesPane setHidden:YES];
}

- (void)buildWindow
{
  NSRect frame = NSMakeRect (140, 120, 1140, 580);
  NSView *content;
  CGFloat W = NSWidth (frame), H = NSHeight (frame);
  NSRect centre = NSMakeRect (SCSidebarWidth, 0, W - SCSidebarWidth - SCInspectorWidth, H);
  NSRect right = NSMakeRect (SCSidebarWidth, 0, W - SCSidebarWidth, H);

  window = [[NSWindow alloc]
      initWithContentRect:frame
                styleMask:NSTitledWindowMask | NSClosableWindowMask
                          | NSMiniaturizableWindowMask | NSResizableWindowMask
                  backing:NSBackingStoreBuffered
                    defer:NO];
  [window setTitle:@"Scanner"];
  [window setReleasedWhenClosed:NO];
  [window setMinSize:NSMakeSize (900, 520)];
  [window setFrameAutosaveName:@"Scanner"];
  content = AUTORELEASE ([[SCFlippedView alloc] initWithFrame:NSMakeRect (0, 0, W, H)]);
  [window setContentView:content];

  sidebar = AUTORELEASE ([[SCSidebarView alloc]
                            initWithFrame:NSMakeRect (0, 0, SCSidebarWidth, H)]);
  [sidebar setAutoresizingMask:NSViewHeightSizable];
  [sidebar setTarget:self action:@selector (deviceChosen:)];
  [content addSubview:sidebar];

  preview = AUTORELEASE ([[SCPreviewView alloc] initWithFrame:centre]);
  [preview setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
  [preview setMetric:metric];
  [preview setTarget:self action:@selector (selectionChanged:)];
  [content addSubview:preview];

  [self buildInspector:NSMakeRect (W - SCInspectorWidth, 0, SCInspectorWidth, H)];
  [content addSubview:inspector];

  [self buildPages:right];
  [content addSubview:pagesPane];

  emptyPane = AUTORELEASE ([[SCEmptyView alloc] initWithFrame:right]);
  [emptyPane setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
  [[emptyPane button] setTarget:self];
  [[emptyPane button] setAction:@selector (addNetworkScanner:)];
  [emptyPane setTitle:@"Looking for scanners…"
                 text:@"Scanner is looking for scanners connected with USB "
                      @"and on the network."];
  [[emptyPane button] setHidden:YES];
  [content addSubview:emptyPane];

  [self fillSizes];
  [self update];
  [self appearanceChanged:nil];
}

/* ---- appearance --------------------------------------------------------- */

- (void)appearanceChanged:(NSNotification *)note
{
  NSEnumerator *e = [labels objectEnumerator];
  NSTextField *l;

  while ((l = [e nextObject]) != nil)
    [l setTextColor:SCDimColor ()];
  [deviceLabel setTextColor:SCTextColor ()];
  [pagesTitle setTextColor:SCTextColor ()];
  [[window contentView] setNeedsDisplay:YES];
  [sidebar setNeedsDisplay:YES];
  [preview setNeedsDisplay:YES];
  [pagesView setNeedsDisplay:YES];
  [emptyPane setNeedsDisplay:YES];
}

/* ---- launching ---------------------------------------------------------- */

- (void)applicationDidFinishLaunching:(NSNotification *)note
{
  NSImage *icon = [NSImage imageNamed:@"Scanner.png"];

  if (icon != nil)
    [NSApp setApplicationIconImage:icon];
  SCAppearanceStartWatching ();
  [[NSNotificationCenter defaultCenter]
    addObserver:self selector:@selector (appearanceChanged:)
           name:SCAppearanceDidChangeNotification object:nil];
  [self buildMenu];
  [self buildWindow];
  [window makeKeyAndOrderFront:self];
  scanner = [[SCScanner alloc] initWithDelegate:self];
  [scanner start];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app
{
  return YES;
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)app
{
  if ([[pagesView pages] count] > 0
      && NSRunAlertPanel (@"Quit without saving the pages?",
                          @"The pages scanned so far haven't been saved as a PDF.",
                          @"Cancel", @"Quit", nil) == NSAlertDefaultReturn)
    return NSTerminateCancel;
  [scanner cancel];
  return NSTerminateNow;
}

/* ---- the state of the window ------------------------------------------- */

- (NSString *)fileExtension
{
  switch ([formatPopup indexOfSelectedItem])
    {
    case SCFormatPNG: return @"png";
    case SCFormatJPEG: return @"jpg";
    case SCFormatTIFF: return @"tiff";
    default: return @"pdf";
    }
}

- (BOOL)combining
{
  return [formatPopup indexOfSelectedItem] == SCFormatPDF && [combineBox state];
}

/* Which pane: the glass, the pages, or no scanner; and what can be used. */
- (void)update
{
  NSUInteger n = [[pagesView pages] count];
  BOOL havePages = ![pagesPane isHidden];
  BOOL none = current == nil && !havePages;
  NSControl *controls[] = { kindControl, resolutionPopup, sizePopup, formatPopup,
                            folderPopup, nameField, openBox };
  unsigned i;

  [emptyPane setHidden:!none];
  [preview setHidden:none || havePages];
  [inspector setHidden:none || havePages];
  [sidebar setEnabled:!busy];
  for (i = 0; i < sizeof controls / sizeof controls[0]; i++)
    [controls[i] setEnabled:!busy && opened];
  [combineBox setEnabled:!busy && opened
                         && [formatPopup indexOfSelectedItem] == SCFormatPDF];
  [scanButton setEnabled:opened];
  [scanButton setTitle:busy && !scanningPreview ? @"Cancel" : @"Scan"];
  [overviewButton setTitle:busy && scanningPreview ? @"Cancel" : @"Overview"];
  [overviewButton setEnabled:opened && (!busy || scanningPreview)];
  if (busy && scanningPreview)
    [scanButton setEnabled:NO];
  [deviceLabel setStringValue:current ? [current title] : @""];
  [pagesTitle setStringValue:
                [NSString stringWithFormat:@"%@.pdf · %lu page%@",
                          [self fileName], (unsigned long)n, n == 1 ? @"" : @"s"]];
  [window setTitle:havePages && current
                   ? [NSString stringWithFormat:@"Scanner — %@", [current title]]
                   : @"Scanner"];
}

- (void)save:(NSString *)key value:(id)v
{
  [[NSUserDefaults standardUserDefaults] setObject:v forKey:key];
}

- (void)settingChanged:(id)sender
{
  [self save:@"SCKind" value:[NSNumber numberWithInteger:[kindControl selectedSegment]]];
  [self save:@"SCFormat" value:[NSNumber numberWithInteger:[formatPopup indexOfSelectedItem]]];
  [self save:@"SCCombine" value:[NSNumber numberWithBool:[combineBox state] != 0]];
  [self save:@"SCOpenWhenDone" value:[NSNumber numberWithBool:[openBox state] != 0]];
  if ([resolutionPopup selectedItem] != nil)
    [self save:@"SCResolution"
         value:[NSNumber numberWithInteger:[[resolutionPopup selectedItem] tag]]];
  [self update];
}

/* ---- resolution, size, folders, name ----------------------------------- */

- (int)nearest:(int)want
{
  NSEnumerator *e = [resolutions objectEnumerator];
  NSNumber *n;
  int best = want, dist = -1;

  while ((n = [e nextObject]) != nil)
    if (dist < 0 || abs ([n intValue] - want) < dist)
      {
        dist = abs ([n intValue] - want);
        best = [n intValue];
      }
  return best;
}

- (void)fillResolutions
{
  NSEnumerator *e = [resolutions objectEnumerator];
  NSInteger want = [[NSUserDefaults standardUserDefaults] integerForKey:@"SCResolution"];
  NSNumber *n;

  [resolutionPopup removeAllItems];
  while ((n = [e nextObject]) != nil)
    {
      [resolutionPopup addItemWithTitle:[NSString stringWithFormat:@"%d dpi",
                                                  [n intValue]]];
      [[resolutionPopup lastItem] setTag:[n intValue]];
    }
  if ([resolutions count])
    [resolutionPopup selectItemWithTag:[self nearest:want > 0 ? (int)want : 300]];
}

- (void)fillSizes
{
  NSSize glass = [preview glassSize];
  NSRect sel = [preview selection];
  int i, pass;

  [sizePopup removeAllItems];
  if (!NSIsEmptyRect (sel) && paper < 0)
    {
      [sizePopup addItemWithTitle:[NSString stringWithFormat:@"Selection: %@",
                                            SCSizeString (sel.size, metric)]];
      [[sizePopup lastItem] setTag:SCSizeSelection];
    }
  [sizePopup addItemWithTitle:@"Whole glass"];
  [[sizePopup lastItem] setTag:SCSizeWholeGlass];
  /* The locale's papers first; only those that fit on the glass. */
  for (pass = 0; pass < 2; pass++)
    for (i = 0; i < SCPaperCount; i++)
      if ((SCPapers[i].metric == metric) == (pass == 0)
          && SCPapers[i].w <= glass.width + 1 && SCPapers[i].h <= glass.height + 1)
        {
          [sizePopup addItemWithTitle:SCPapers[i].name];
          [[sizePopup lastItem] setTag:i];
        }
  if (!NSIsEmptyRect (sel) && paper < 0)
    [sizePopup selectItemWithTag:SCSizeSelection];
  else if (paper >= 0)
    [sizePopup selectItemWithTag:paper];
  else
    [sizePopup selectItemWithTag:SCSizeWholeGlass];
}

- (void)sizeChosen:(id)sender
{
  NSInteger tag = [[sizePopup selectedItem] tag];
  NSSize glass = [preview glassSize];

  if (tag == SCSizeSelection)
    return;
  if (tag == SCSizeWholeGlass)
    {
      paper = -1;
      [preview setSelection:NSZeroRect];
    }
  else if (tag >= 0 && tag < SCPaperCount)
    {
      paper = tag;
      [preview setSelection:NSMakeRect (0, 0, MIN (glass.width, SCPapers[tag].w),
                                        MIN (glass.height, SCPapers[tag].h))];
    }
  [self fillSizes];
}

- (void)selectionChanged:(id)sender
{
  paper = -1;
  [self fillSizes];
  [self update];
}

- (void)wholeGlass:(id)sender
{
  paper = -1;
  [preview setSelection:NSZeroRect];
  [self fillSizes];
}

- (NSString *)picturesFolder
{
  NSArray *dirs = NSSearchPathForDirectoriesInDomains (NSPicturesDirectory,
                                                       NSUserDomainMask, YES);
  NSFileManager *fm = [NSFileManager defaultManager];
  NSString *home = NSHomeDirectory ();
  NSString *p;

  if ([dirs count] && [fm fileExistsAtPath:[dirs objectAtIndex:0]])
    return [dirs objectAtIndex:0];
  /* NextBSD's home folders have Images; a Mac's have Pictures. */
  p = [home stringByAppendingPathComponent:@"Pictures"];
  if ([fm fileExistsAtPath:p])
    return p;
  p = [home stringByAppendingPathComponent:@"Images"];
  if ([fm fileExistsAtPath:p])
    return p;
  return [dirs count] ? [dirs objectAtIndex:0] : p;
}

- (void)fillFolders
{
  NSString *home = NSHomeDirectory ();
  NSMutableArray *paths = [NSMutableArray arrayWithObjects:
      [home stringByAppendingPathComponent:@"Documents"],
      [self picturesFolder],
      [home stringByAppendingPathComponent:@"Desktop"], nil];
  NSString *chosen = [[NSUserDefaults standardUserDefaults] stringForKey:@"SCFolder"];
  NSArray *extra = [[NSUserDefaults standardUserDefaults] arrayForKey:@"SCFolders"];
  NSUInteger i;

  if (extra != nil && [folders count] == 0)
    [folders addObjectsFromArray:extra];
  [paths addObjectsFromArray:folders];
  [folderPopup removeAllItems];
  for (i = 0; i < [paths count]; i++)
    {
      NSString *p = [paths objectAtIndex:i];
      [folderPopup addItemWithTitle:[[NSFileManager defaultManager]
                                       displayNameAtPath:p]];
      [[folderPopup lastItem] setRepresentedObject:p];
      [[folderPopup lastItem] setTag:i];
    }
  [[folderPopup menu] addItem:[NSMenuItem separatorItem]];
  [folderPopup addItemWithTitle:@"Other…"];
  [[folderPopup lastItem] setTag:SCFolderOther];
  [folderPopup selectItemAtIndex:0];
  for (i = 0; chosen != nil && i < [paths count]; i++)
    if ([[paths objectAtIndex:i] isEqual:chosen])
      [folderPopup selectItemAtIndex:i];
}

- (void)folderChosen:(id)sender
{
  NSString *path;

  if ([[folderPopup selectedItem] tag] == SCFolderOther)
    {
      NSOpenPanel *panel = [NSOpenPanel openPanel];

      [panel setCanChooseDirectories:YES];
      [panel setCanChooseFiles:NO];
      [panel setAllowsMultipleSelection:NO];
      [panel setTitle:@"Save Scans To"];
      [panel setPrompt:@"Choose"];
      if ([panel runModalForDirectory:NSHomeDirectory () file:nil types:nil]
          == NSOKButton && [panel filename] != nil)
        {
          path = [panel filename];
          if (![folders containsObject:path])
            [folders addObject:path];
          [self save:@"SCFolders" value:folders];
          [self save:@"SCFolder" value:path];
        }
      [self fillFolders];
      return;
    }
  path = [[folderPopup selectedItem] representedObject];
  if (path != nil)
    [self save:@"SCFolder" value:path];
}

- (NSString *)folder
{
  NSString *p = [[folderPopup selectedItem] representedObject];

  return p ? p : [NSHomeDirectory () stringByAppendingPathComponent:@"Documents"];
}

/* "Scan 2026-11-27 at 21.30", unless the person typed a name of their own. */
- (void)newName
{
  NSString *name = [[NSCalendarDate calendarDate]
                     descriptionWithCalendarFormat:@"Scan %Y-%m-%d at %H.%M"];

  if (defaultName == nil || [[nameField stringValue] isEqual:defaultName]
      || [[nameField stringValue] length] == 0)
    [nameField setStringValue:name];
  ASSIGN (defaultName, name);
}

- (NSString *)fileName
{
  NSString *n = [[nameField stringValue]
                  stringByTrimmingCharactersInSet:
                    [NSCharacterSet whitespaceAndNewlineCharacterSet]];

  n = [[n componentsSeparatedByString:@"/"] componentsJoinedByString:@"-"];
  return [n length] ? n : @"Scan";
}

- (void)controlTextDidChange:(NSNotification *)note
{
  [self update];
}

/* A path in the folder that doesn't exist yet: "Name 2.pdf" and so on. */
- (NSString *)pathFor:(NSString *)extension
{
  NSFileManager *fm = [NSFileManager defaultManager];
  NSString *dir = [self folder];
  NSString *base = [self fileName];
  NSString *path = [dir stringByAppendingPathComponent:
                          [base stringByAppendingPathExtension:extension]];
  int i;

  for (i = 2; [fm fileExistsAtPath:path]; i++)
    path = [dir stringByAppendingPathComponent:
                  [[NSString stringWithFormat:@"%@ %d", base, i]
                    stringByAppendingPathExtension:extension]];
  return path;
}

/* ---- the scanner -------------------------------------------------------- */

- (void)scannerDevicesChanged:(NSDictionary *)info
{
  NSArray *list = [info objectForKey:@"devices"];
  BOOL searched = [[info objectForKey:@"searched"] boolValue];
  NSUInteger i, found = NSNotFound;

  for (i = 0; current != nil && i < [list count]; i++)
    if ([[[list objectAtIndex:i] saneName] isEqual:[current saneName]])
      found = i;
  [sidebar setDevices:list searched:searched];
  if (found != NSNotFound)
    [sidebar setSelectedIndex:found];
  else if (!busy)
    {
      /* The one in use went away (or there was none): the first. */
      DESTROY (current);
      opened = NO;
      [preview setImage:nil];
      [preview setMessage:nil progress:-1];
      if ([list count])
        {
          [sidebar setSelectedIndex:0];
          [self deviceChosen:sidebar];
        }
      else
        {
          [sidebar setSelectedIndex:-1];
          [scanner openDevice:nil];
        }
    }
  if (searched && [[info objectForKey:@"needsAdmin"] boolValue])
    {
      /* A USB device is there that Scanner may not open. */
      [emptyPane setTitle:@"No scanner found"
                     text:@"An administrator needs to allow USB scanners "
                          @"before Scanner can use the USB device that is "
                          @"connected. Scanner keeps looking."];
      [[emptyPane button] setHidden:NO];
    }
  else if (searched)
    {
      [emptyPane setTitle:@"No scanner found"
                     text:@"Connect a scanner with USB and turn it on, or make "
                          @"sure a network scanner is on the same network. "
                          @"Scanner keeps looking and lists it when it appears."];
      [[emptyPane button] setHidden:NO];
    }
  [self update];
}

- (void)deviceChosen:(id)sender
{
  NSInteger i = [sidebar selectedIndex];
  NSArray *list = [sidebar devices];

  if (busy || i < 0 || i >= (NSInteger)[list count])
    return;
  ASSIGN (current, [list objectAtIndex:i]);
  opened = NO;
  [preview setImage:nil];
  [preview setSelection:NSZeroRect];
  paper = -1;
  [preview setMessage:[NSString stringWithFormat:@"Opening %@…", [current title]]
             progress:-1];
  [scanner openDevice:[current saneName]];
  [self update];
}

- (void)scannerOpened:(NSDictionary *)info
{
  NSString *error = [info objectForKey:SCErrorKey];
  SCDevice *d = [info objectForKey:SCDeviceKey];

  if (d != nil && current != nil && ![[d saneName] isEqual:[current saneName]])
    return;   /* an older choice */
  if (error != nil)
    {
      opened = NO;
      [preview setMessage:error progress:-1];
      [self update];
      return;
    }
  opened = YES;
  ASSIGN (resolutions, [info objectForKey:SCResolutionsKey]);
  [self fillResolutions];
  [preview setGlassSize:NSMakeSize ([[info objectForKey:SCGlassWidthKey] doubleValue],
                                    [[info objectForKey:SCGlassHeightKey] doubleValue])];
  [preview setMessage:nil progress:-1];
  [self fillSizes];
  [self update];
}

- (void)startScan:(BOOL)isPreview
{
  SCScanRequest *r = AUTORELEASE ([[SCScanRequest alloc] init]);
  SCKind kind = (SCKind)[kindControl selectedSegment];

  if (!opened || busy)
    return;
  [window makeFirstResponder:nil];
  r->kind = isPreview && kind == SCKindBlackAndWhite ? SCKindGrey : kind;
  r->preview = isPreview;
  r->dpi = isPreview ? [self nearest:75] : (int)[[resolutionPopup selectedItem] tag];
  if (r->dpi <= 0)
    r->dpi = [self nearest:300];
  r->area = isPreview ? NSZeroRect : [preview selection];
  busy = YES;
  scanningPreview = isPreview;
  if (![pagesPane isHidden])
    [pagesView setBusy:0];
  else
    [preview setMessage:isPreview ? @"Overview…" : @"Scanning…" progress:0];
  [scanner scan:r];
  [self update];
}

- (void)overview:(id)sender
{
  if (busy && scanningPreview)
    [scanner cancel];
  else
    [self startScan:YES];
}

- (void)scan:(id)sender
{
  if (busy && !scanningPreview)
    [scanner cancel];
  else
    [self startScan:NO];
}

- (void)addPage:(id)sender
{
  [self startScan:NO];
}

- (void)scannerProgress:(NSNumber *)fraction
{
  double f = [fraction doubleValue];

  if (!busy)
    return;
  if (![pagesPane isHidden])
    [pagesView setBusy:f];
  else
    [preview setMessage:[NSString stringWithFormat:@"%@ %d%%",
                                  scanningPreview ? @"Overview…" : @"Scanning…",
                                  (int)(f * 100)]
               progress:f];
}

- (void)scannerFinished:(NSDictionary *)result
{
  NSBitmapImageRep *rep = [result objectForKey:SCImageKey];
  NSString *error = [result objectForKey:SCErrorKey];
  BOOL wasPreview = [[result objectForKey:SCPreviewKey] boolValue];
  int dpi = [[result objectForKey:SCDPIKey] intValue];
  SCKind kind = (SCKind)[[result objectForKey:SCKindKey] intValue];

  busy = NO;
  [pagesView setBusy:-1];
  [preview setMessage:nil progress:-1];
  if (error != nil)
    [preview setMessage:error progress:-1];
  else if (rep != nil && wasPreview)
    {
      NSImage *image = AUTORELEASE ([[NSImage alloc] initWithSize:[rep size]]);
      [image addRepresentation:rep];
      [preview setImage:image];
    }
  else if (rep != nil)
    {
      SCPage *page = [SCPage pageWithImage:rep dpi:dpi
                             blackAndWhite:kind == SCKindBlackAndWhite];
      if ([self combining])
        {
          [pagesView addPage:page];
          if ([pagesPane isHidden])
            {
              [pagesPane setHidden:NO];
              [pagesView tile];
            }
        }
      else
        [self saveSingle:page];
    }
  [self update];
}

/* ---- saving ------------------------------------------------------------- */

- (BOOL)makeFolder
{
  NSString *dir = [self folder];
  NSFileManager *fm = [NSFileManager defaultManager];

  if ([fm fileExistsAtPath:dir])
    return YES;
  if ([fm createDirectoryAtPath:dir withIntermediateDirectories:YES
                     attributes:nil error:NULL])
    return YES;
  NSRunAlertPanel (@"Scanner couldn't save the scan",
                   @"The folder %@ doesn't exist and couldn't be made.",
                   @"OK", nil, nil, dir);
  return NO;
}

- (void)wrote:(NSData *)data to:(NSString *)path
{
  if (data == nil || ![data writeToFile:path atomically:YES])
    {
      NSRunAlertPanel (@"Scanner couldn't save the scan",
                       @"It couldn't be written to %@.", @"OK", nil, nil, path);
      return;
    }
  if ([openBox state])
    {
      NSWorkspace *ws = [NSWorkspace sharedWorkspace];
      BOOL ok = NO;

      /* Preview (nextbsd/nextbsd#716) when there is one; else whatever
       * opens the file; else the file in File Viewer. */
      if ([ws fullPathForApplication:@"Preview"] != nil)
        ok = [ws openFile:path withApplication:@"Preview"];
      if (!ok)
        ok = [ws openFile:path];
      if (!ok)
        [ws selectFile:path inFileViewerRootedAtPath:
                              [path stringByDeletingLastPathComponent]];
    }
  [self newName];
}

- (void)saveSingle:(SCPage *)page
{
  NSString *ext = [self fileExtension];
  NSString *path;
  NSData *data;
  NSBitmapImageRep *rep = page->image;

  if (![self makeFolder])
    return;
  path = [self pathFor:ext];
  switch ([formatPopup indexOfSelectedItem])
    {
    case SCFormatPNG:
      data = [rep representationUsingType:NSPNGFileType properties:nil];
      break;
    case SCFormatJPEG:
      data = [rep representationUsingType:NSJPEGFileType
                               properties:[NSDictionary dictionaryWithObject:
                                             [NSNumber numberWithFloat:0.9]
                                             forKey:NSImageCompressionFactor]];
      break;
    case SCFormatTIFF:
      data = [rep TIFFRepresentationUsingCompression:NSTIFFCompressionLZW factor:0];
      break;
    default:
      data = [SCPDFWriter PDFWithPages:[NSArray arrayWithObject:page]
                                 title:[self fileName]];
    }
  [self wrote:data to:path];
}

- (void)savePages:(id)sender
{
  NSArray *pages = [pagesView pages];

  if (busy || [pages count] == 0 || ![self makeFolder])
    return;
  [self wrote:[SCPDFWriter PDFWithPages:pages title:[self fileName]]
           to:[self pathFor:@"pdf"]];
  [pagesView removeAllPages];
  [pagesPane setHidden:YES];
  [self update];
}

- (void)cancelPages:(id)sender
{
  NSUInteger n = [[pagesView pages] count];

  if (busy)
    {
      [scanner cancel];
      return;
    }
  if (n > 0
      && NSRunAlertPanel (@"Discard the pages?",
                          @"The %lu page%@ scanned so far won't be saved.",
                          @"Cancel", @"Discard", nil, (unsigned long)n,
                          n == 1 ? @"" : @"s") == NSAlertDefaultReturn)
    return;
  [pagesView removeAllPages];
  [pagesPane setHidden:YES];
  [self update];
}

- (void)pagesChanged:(id)sender
{
  [self update];
}

- (void)pagesResized:(NSNotification *)note
{
  [pagesView tile];
}

/* ---- a network scanner -------------------------------------------------- */

- (void)addNetworkScanner:(id)sender
{
  NSView *v;
  NSTextField *l;
  NSButton *add, *cancel;

  if (networkPanel == nil)
    {
      networkPanel = [[NSPanel alloc]
          initWithContentRect:NSMakeRect (0, 0, 420, 170)
                    styleMask:NSTitledWindowMask
                      backing:NSBackingStoreBuffered
                        defer:YES];
      [networkPanel setTitle:@"Add a Network Scanner"];
      v = [networkPanel contentView];
      l = [self label:@"Address of the scanner, or of a computer sharing "
                      @"its scanners with SANE (saned):"
                frame:NSMakeRect (20, 108, 380, 36) in:v];
      [l setTextColor:[NSColor controlTextColor]];
      networkField = AUTORELEASE ([[NSTextField alloc]
                                     initWithFrame:NSMakeRect (20, 76, 380, 24)]);
      [networkField setPlaceholderString:@"scanner.local or 192.168.1.20"];
      [v addSubview:networkField];
      l = [self label:@"It is added for your account only." frame:NSMakeRect (20, 52, 380, 17)
                   in:v];
      [l setTextColor:[NSColor disabledControlTextColor]];
      add = AUTORELEASE ([[NSButton alloc] initWithFrame:NSMakeRect (310, 12, 90, 30)]);
      [add setTitle:@"Add"];
      [add setKeyEquivalent:@"\r"];
      [add setTarget:self];
      [add setAction:@selector (networkAdd:)];
      [v addSubview:add];
      cancel = AUTORELEASE ([[NSButton alloc] initWithFrame:NSMakeRect (212, 12, 90, 30)]);
      [cancel setTitle:@"Cancel"];
      [cancel setKeyEquivalent:@"\e"];
      [cancel setTarget:self];
      [cancel setAction:@selector (networkCancel:)];
      [v addSubview:cancel];
    }
  [networkField setStringValue:@""];
  [networkPanel center];
  [networkPanel makeFirstResponder:networkField];
  [NSApp runModalForWindow:networkPanel];
  [networkPanel orderOut:self];
}

- (void)networkAdd:(id)sender
{
  NSString *error = nil;

  if (![SCScanner addNetworkHost:[networkField stringValue] error:&error])
    {
      NSRunAlertPanel (@"Scanner couldn't add it", @"%@", @"OK", nil, nil, error);
      return;
    }
  [NSApp stopModal];
  [scanner reloadConfiguration];
}

- (void)networkCancel:(id)sender
{
  [NSApp stopModal];
}

@end
