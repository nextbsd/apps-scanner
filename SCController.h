/*
 * Copyright (C) 2026 Joseph Maloney <pkgdemonteam@gmail.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * SCController: Scanner's window, as the mockup draws it
 * (nextbsd/nextbsd#717): the scanners on the left, the preview of the
 * glass in the middle and the settings on the right; the pages of a PDF
 * being put together; and "No scanner found".
 */

#import <AppKit/AppKit.h>
#import "SCScanner.h"

@class SCSidebarView, SCPreviewView, SCPagesView, SCEmptyView;

@interface SCController : NSObject <SCScannerDelegate>
{
  NSWindow *window;
  SCScanner *scanner;
  SCSidebarView *sidebar;
  SCPreviewView *preview;
  NSView *inspector;
  NSView *pagesPane;
  SCPagesView *pagesView;
  NSScrollView *pagesScroll;
  NSTextField *pagesTitle, *pagesHint;
  SCEmptyView *emptyPane;

  NSTextField *deviceLabel;
  NSMutableArray *labels;
  NSSegmentedControl *kindControl;
  NSPopUpButton *resolutionPopup, *sizePopup, *formatPopup, *folderPopup;
  NSButton *combineBox, *openBox;
  NSTextField *nameField;
  NSButton *overviewButton, *scanButton;

  NSPanel *networkPanel;
  NSTextField *networkField;

  SCDevice *current;
  NSArray *resolutions;
  BOOL opened;
  BOOL busy;
  BOOL scanningPreview;
  BOOL metric;
  NSInteger paper;          /* the paper size chosen, -1 for a box */
  NSString *defaultName;
  NSMutableArray *folders;  /* extra folders chosen with Other… */
}
@end
