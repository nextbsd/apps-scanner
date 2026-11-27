/*
 * Copyright (C) 2026 Joseph Maloney <pkgdemonteam@gmail.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * SCPDFWriter: scanned pages into one PDF, a page for each, each page the
 * size the paper was (pixels at the resolution scanned).
 */

#import <Foundation/Foundation.h>

@class NSBitmapImageRep;

/* One page: the picture, the resolution it was scanned at, and whether
 * it is black and white (kept at one bit a pixel). */
@interface SCPage : NSObject
{
@public
  NSBitmapImageRep *image;
  int dpi;
  BOOL blackAndWhite;
}
+ (SCPage *)pageWithImage:(NSBitmapImageRep *)image
                      dpi:(int)dpi
            blackAndWhite:(BOOL)bw;
@end

@interface SCPDFWriter : NSObject
+ (NSData *)PDFWithPages:(NSArray *)pages title:(NSString *)title;
@end
