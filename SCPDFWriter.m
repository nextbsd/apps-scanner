/*
 * Copyright (C) 2026 Joseph Maloney <pkgdemonteam@gmail.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * SCPDFWriter: a small PDF writer for scans.
 *
 * A scanned page is one picture, so the PDF needs no more than a page
 * with a picture on it: each page is an image XObject drawn over the
 * whole page. Colour and grey pages are JPEG (DCTDecode, at quality
 * 0.85, from NSBitmapImageRep), as scanners and Preview on a Mac save
 * them; black and white pages are one bit a pixel, deflated (zlib). The
 * pixels go in as scanned, at their resolution, without passing through
 * the drawing back end (GNUstep's PDF printing goes through the back end
 * and a print view, and would scale and re-encode every page).
 */

#import <AppKit/AppKit.h>
#import "SCPDFWriter.h"

#include <zlib.h>

@implementation SCPage

+ (SCPage *)pageWithImage:(NSBitmapImageRep *)image
                      dpi:(int)dpi
            blackAndWhite:(BOOL)bw
{
  SCPage *p = AUTORELEASE ([[SCPage alloc] init]);

  ASSIGN (p->image, image);
  p->dpi = dpi > 0 ? dpi : 300;
  p->blackAndWhite = bw;
  return p;
}

- (void)dealloc
{
  RELEASE (image);
  [super dealloc];
}

@end

@implementation SCPDFWriter

static void
SCAppend (NSMutableData *pdf, NSString *format, ...)
{
  va_list ap;
  NSString *s;

  va_start (ap, format);
  s = [[NSString alloc] initWithFormat:format arguments:ap];
  va_end (ap);
  [pdf appendData:[s dataUsingEncoding:NSISOLatin1StringEncoding
                  allowLossyConversion:YES]];
  RELEASE (s);
}

static NSData *
SCDeflate (const unsigned char *bytes, size_t length)
{
  uLongf size = compressBound (length);
  NSMutableData *out = [NSMutableData dataWithLength:size];

  if (compress2 ([out mutableBytes], &size, bytes, length, 6) != Z_OK)
    return nil;
  [out setLength:size];
  return out;
}

/* A PDF text string: printable ASCII as is, escaped. */
static NSString *
SCPDFString (NSString *s)
{
  NSMutableString *out = [NSMutableString stringWithString:@"("];
  NSUInteger i;

  for (i = 0; i < [s length]; i++)
    {
      unichar c = [s characterAtIndex:i];
      if (c == '(' || c == ')' || c == '\\')
        [out appendFormat:@"\\%C", c];
      else if (c >= 32 && c < 127)
        [out appendFormat:@"%C", c];
      else
        [out appendString:@"?"];
    }
  [out appendString:@")"];
  return out;
}

/* The image's data and its dictionary entries. */
static NSData *
SCImageStream (SCPage *page, NSString **entries)
{
  NSBitmapImageRep *rep = page->image;
  int w = (int)[rep pixelsWide], h = (int)[rep pixelsHigh];
  int spp = (int)[rep samplesPerPixel];
  int bpr = (int)[rep bytesPerRow];
  const unsigned char *src = [rep bitmapData];
  NSData *data;
  int x, y;

  if (page->blackAndWhite && spp == 1)
    {
      int rowBytes = (w + 7) / 8;
      NSMutableData *bits = [NSMutableData dataWithLength:(size_t)rowBytes * h];
      unsigned char *b = [bits mutableBytes];

      /* DeviceGray at one bit: 1 is white. */
      for (y = 0; y < h; y++)
        for (x = 0; x < w; x++)
          if (src[(size_t)y * bpr + x] >= 128)
            b[(size_t)y * rowBytes + (x >> 3)] |= 0x80 >> (x & 7);
      data = SCDeflate (b, [bits length]);
      *entries = @"/ColorSpace /DeviceGray /BitsPerComponent 1 "
                 @"/Filter /FlateDecode";
      return data;
    }
  data = [rep representationUsingType:NSJPEGFileType
                           properties:[NSDictionary dictionaryWithObject:
                                         [NSNumber numberWithFloat:0.85]
                                         forKey:NSImageCompressionFactor]];
  if ([data length] > 0)
    {
      *entries = [NSString stringWithFormat:
                             @"/ColorSpace /%@ /BitsPerComponent 8 "
                             @"/Filter /DCTDecode",
                             spp >= 3 ? @"DeviceRGB" : @"DeviceGray"];
      return data;
    }
  /* No JPEG: the pixels, deflated. */
  {
    int n = spp >= 3 ? 3 : 1;
    NSMutableData *raw = [NSMutableData dataWithLength:(size_t)w * h * n];
    unsigned char *o = [raw mutableBytes];

    for (y = 0; y < h; y++)
      for (x = 0; x < w; x++)
        memcpy (o + ((size_t)y * w + x) * n, src + (size_t)y * bpr + x * spp, n);
    *entries = [NSString stringWithFormat:
                           @"/ColorSpace /%@ /BitsPerComponent 8 "
                           @"/Filter /FlateDecode",
                           n == 3 ? @"DeviceRGB" : @"DeviceGray"];
    return SCDeflate (o, [raw length]);
  }
}

+ (NSData *)PDFWithPages:(NSArray *)pages title:(NSString *)title
{
  NSMutableData *pdf = [NSMutableData data];
  NSMutableArray *offsets = [NSMutableArray array];
  NSUInteger count = [pages count], i;
  NSMutableString *kids = [NSMutableString string];
  NSUInteger xref;
  NSString *date;

  if (count == 0)
    return nil;
  /* Objects: 1 catalog, 2 pages, 3 info, then for page i:
   * 4+3i page, 5+3i contents, 6+3i image. */
  {
    /* The header, and a comment of high bytes that says it is binary. */
    static const unsigned char head[] = "%PDF-1.4\n%\xe2\xe3\xcf\xd3\n";
    [pdf appendBytes:head length:sizeof head - 1];
  }
#define OBJ(n) do { [offsets addObject:[NSNumber numberWithUnsignedInteger:[pdf length]]]; \
                    SCAppend (pdf, @"%lu 0 obj\n", (unsigned long)(n)); } while (0)
  for (i = 0; i < count; i++)
    [kids appendFormat:@"%lu 0 R ", (unsigned long)(4 + 3 * i)];

  OBJ (1);
  SCAppend (pdf, @"<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");
  OBJ (2);
  SCAppend (pdf, @"<< /Type /Pages /Kids [ %@] /Count %lu >>\nendobj\n",
            kids, (unsigned long)count);
  date = [[NSCalendarDate calendarDate]
           descriptionWithCalendarFormat:@"D:%Y%m%d%H%M%S"];
  OBJ (3);
  SCAppend (pdf, @"<< /Producer (NextBSD Scanner) /Creator (Scanner) "
                 @"/Title %@ /CreationDate (%@) >>\nendobj\n",
            SCPDFString (title ? title : @"Scan"), date);

  for (i = 0; i < count; i++)
    {
      SCPage *page = [pages objectAtIndex:i];
      NSBitmapImageRep *rep = page->image;
      double w = [rep pixelsWide] * 72.0 / page->dpi;
      double h = [rep pixelsHigh] * 72.0 / page->dpi;
      NSString *entries = nil;
      NSData *image = SCImageStream (page, &entries);
      NSString *contents = [NSString stringWithFormat:
                                       @"q %.3f 0 0 %.3f 0 0 cm /Im0 Do Q\n", w, h];

      if (image == nil)
        return nil;
      OBJ (4 + 3 * i);
      SCAppend (pdf, @"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 %.3f %.3f] "
                     @"/Resources << /XObject << /Im0 %lu 0 R >> >> "
                     @"/Contents %lu 0 R >>\nendobj\n",
                w, h, (unsigned long)(6 + 3 * i), (unsigned long)(5 + 3 * i));
      OBJ (5 + 3 * i);
      SCAppend (pdf, @"<< /Length %lu >>\nstream\n%@endstream\nendobj\n",
                (unsigned long)[contents length], contents);
      OBJ (6 + 3 * i);
      SCAppend (pdf, @"<< /Type /XObject /Subtype /Image /Width %ld "
                     @"/Height %ld %@ /Length %lu >>\nstream\n",
                (long)[rep pixelsWide], (long)[rep pixelsHigh], entries,
                (unsigned long)[image length]);
      [pdf appendData:image];
      SCAppend (pdf, @"\nendstream\nendobj\n");
    }
#undef OBJ

  xref = [pdf length];
  SCAppend (pdf, @"xref\n0 %lu\n0000000000 65535 f \n",
            (unsigned long)([offsets count] + 1));
  for (i = 0; i < [offsets count]; i++)
    SCAppend (pdf, @"%010lu 00000 n \n",
              (unsigned long)[[offsets objectAtIndex:i] unsignedIntegerValue]);
  SCAppend (pdf, @"trailer\n<< /Size %lu /Root 1 0 R /Info 3 0 R >>\n"
                 @"startxref\n%lu\n%%EOF\n",
            (unsigned long)([offsets count] + 1), (unsigned long)xref);
  return pdf;
}

@end
