/*
 * Copyright (C) 2026 Joseph Maloney <pkgdemonteam@gmail.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * SCScanner: SANE's C API (sane_init, sane_get_devices, sane_open, the
 * options, sane_start and sane_read) on a thread of its own.
 *
 * SANE is not thread-safe, so every call into it is made on that one
 * thread: the main thread asks with -performSelector:onThread:, in order,
 * and hears back with -performSelectorOnMainThread:. The thread looks for
 * scanners every few seconds while it has nothing else to do. With no
 * scanner open it starts SANE afresh first (sane_exit, sane_init), since
 * not every backend notices a USB scanner plugged in after sane_init; with
 * one open, sane_get_devices alone (backends using sanei_usb rescan the
 * bus there).
 *
 * USB scanners: SANE opens them through libusb, on device nodes devfs
 * makes root's. When SANE lists nothing and a USB device is connected
 * that no kernel driver has and Scanner can't open, or sane_open is
 * refused for one, Scanner asks SettingsHelper for that device (UsbGrant,
 * an administrator's right) and looks again.
 */

#import <AppKit/AppKit.h>
#import "SCScanner.h"
#import "SCHelperClient.h"
#import "settingshelper_types.h"

#include <dirent.h>
#include <stdio.h>
#include <unistd.h>
#include <sane/sane.h>
#include <sane/saneopts.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

NSString *const SCDeviceKey = @"device";
NSString *const SCErrorKey = @"error";
NSString *const SCResolutionsKey = @"resolutions";
NSString *const SCGlassWidthKey = @"glassWidth";
NSString *const SCGlassHeightKey = @"glassHeight";
NSString *const SCImageKey = @"image";
NSString *const SCPreviewKey = @"preview";
NSString *const SCCancelledKey = @"cancelled";
NSString *const SCDPIKey = @"dpi";
NSString *const SCKindKey = @"kind";

static const NSTimeInterval SCSearchInterval = 4.0;

/* ---- devices ------------------------------------------------------------ */

@implementation SCDevice

/* "net:host:backend:device", "epson2:net:host", "escl:http://host:port". */
static NSString *
SCNetworkHost (NSString *name)
{
  NSRange r;
  NSString *rest;

  if ([name hasPrefix:@"net:"])
    {
      rest = [name substringFromIndex:4];
      if ([rest hasPrefix:@"["])
        {
          r = [rest rangeOfString:@"]"];
          if (r.location != NSNotFound)
            return [rest substringWithRange:NSMakeRange (1, r.location - 1)];
        }
      r = [rest rangeOfString:@":"];
      return r.location == NSNotFound ? rest : [rest substringToIndex:r.location];
    }
  r = [name rangeOfString:@":net:"];
  if (r.location != NSNotFound)
    {
      rest = [name substringFromIndex:NSMaxRange (r)];
      r = [rest rangeOfString:@":"];
      return r.location == NSNotFound ? rest : [rest substringToIndex:r.location];
    }
  r = [name rangeOfString:@"://"];
  if (r.location != NSNotFound)
    {
      rest = [name substringFromIndex:NSMaxRange (r)];
      r = [rest rangeOfCharacterFromSet:
                  [NSCharacterSet characterSetWithCharactersInString:@":/"]];
      return r.location == NSNotFound ? rest : [rest substringToIndex:r.location];
    }
  return nil;
}

+ (SCDevice *)deviceWithSANEName:(NSString *)name
                          vendor:(NSString *)vendor
                           model:(NSString *)model
{
  SCDevice *d = AUTORELEASE ([[SCDevice alloc] init]);
  NSString *host = SCNetworkHost (name);
  NSString *t;

  ASSIGN (d->saneName, name);
  /* SANE's test backend calls itself "Noname frontend-tester". */
  if ([name hasPrefix:@"test:"])
    {
      int n = [[name substringFromIndex:5] intValue];
      t = n == 0 ? @"Test scanner"
                 : [NSString stringWithFormat:@"Test scanner %d", n + 1];
    }
  else if ([vendor length] == 0 || [vendor isEqual:@"Noname"]
           || [vendor caseInsensitiveCompare:@"unknown"] == NSOrderedSame)
    t = [model length] ? model : name;
  else if ([model hasPrefix:vendor])
    t = model;
  else
    t = [NSString stringWithFormat:@"%@ %@", vendor, model];
  ASSIGN (d->title, t);
  if (host != nil)
    {
      d->network = YES;
      NSString *where = [NSString stringWithFormat:@"Network, %@", host];
      ASSIGN (d->detail, where);
    }
  else if ([name hasPrefix:@"test:"])
    ASSIGN (d->detail, @"SANE test backend");
  else
    ASSIGN (d->detail, @"USB");
  return d;
}

- (void)dealloc
{
  RELEASE (saneName);
  RELEASE (title);
  RELEASE (detail);
  [super dealloc];
}

- (NSString *)saneName { return saneName; }
- (NSString *)title { return title; }
- (NSString *)detail { return detail; }
- (BOOL)isNetwork { return network; }

- (BOOL)isEqual:(id)other
{
  return [other isKindOfClass:[SCDevice class]]
         && [saneName isEqual:[other saneName]]
         && [title isEqual:[other title]];
}

- (NSUInteger)hash { return [saneName hash]; }

@end

@implementation SCScanRequest
@end

/* ---- options ------------------------------------------------------------ */

static SANE_Int
SCFindOption (SANE_Handle h, const char *name,
              const SANE_Option_Descriptor **descOut)
{
  SANE_Int count = 0, i;
  const SANE_Option_Descriptor *d;

  if (sane_control_option (h, 0, SANE_ACTION_GET_VALUE, &count, NULL)
      != SANE_STATUS_GOOD)
    return -1;
  for (i = 1; i < count; i++)
    {
      d = sane_get_option_descriptor (h, i);
      if (d != NULL && d->name != NULL && strcmp (d->name, name) == 0)
        {
          if (descOut)
            *descOut = d;
          return i;
        }
    }
  return -1;
}

static BOOL
SCUsable (const SANE_Option_Descriptor *d)
{
  return SANE_OPTION_IS_ACTIVE (d->cap) && SANE_OPTION_IS_SETTABLE (d->cap);
}

static double
SCWordValue (const SANE_Option_Descriptor *d, SANE_Word w)
{
  return d->type == SANE_TYPE_FIXED ? SANE_UNFIX (w) : (double)w;
}

static SANE_Word
SCWordFor (const SANE_Option_Descriptor *d, double v)
{
  return d->type == SANE_TYPE_FIXED ? SANE_FIX (v) : (SANE_Word)lround (v);
}

/* The allowed value nearest v. */
static SANE_Word
SCConstrain (const SANE_Option_Descriptor *d, double v)
{
  if (d->constraint_type == SANE_CONSTRAINT_RANGE)
    {
      const SANE_Range *r = d->constraint.range;
      double lo = SCWordValue (d, r->min), hi = SCWordValue (d, r->max);
      double q = SCWordValue (d, r->quant);

      if (v < lo)
        v = lo;
      if (v > hi)
        v = hi;
      if (q > 0)
        v = lo + floor ((v - lo) / q + 0.5) * q;
      if (v > hi)
        v = hi;
      return SCWordFor (d, v);
    }
  if (d->constraint_type == SANE_CONSTRAINT_WORD_LIST)
    {
      const SANE_Word *list = d->constraint.word_list;
      SANE_Word best = list[0] > 0 ? list[1] : SCWordFor (d, v);
      double bestDist = -1;
      int i;

      for (i = 1; i <= list[0]; i++)
        {
          double dist = fabs (SCWordValue (d, list[i]) - v);
          if (bestDist < 0 || dist < bestDist)
            {
              bestDist = dist;
              best = list[i];
            }
        }
      return best;
    }
  return SCWordFor (d, v);
}

static BOOL
SCSetNumber (SANE_Handle h, const char *name, double v)
{
  const SANE_Option_Descriptor *d = NULL;
  SANE_Int i = SCFindOption (h, name, &d);
  SANE_Word w;
  SANE_Int info = 0;

  if (i < 0 || !SCUsable (d) || d->size != sizeof (SANE_Word))
    return NO;
  if (d->type == SANE_TYPE_BOOL)
    w = v != 0 ? SANE_TRUE : SANE_FALSE;
  else if (d->type == SANE_TYPE_INT || d->type == SANE_TYPE_FIXED)
    w = SCConstrain (d, v);
  else
    return NO;
  return sane_control_option (h, i, SANE_ACTION_SET_VALUE, &w, &info)
         == SANE_STATUS_GOOD;
}

static BOOL
SCSetString (SANE_Handle h, const char *name, const char *value)
{
  const SANE_Option_Descriptor *d = NULL;
  SANE_Int i = SCFindOption (h, name, &d);
  char *buf;
  BOOL ok;

  if (i < 0 || !SCUsable (d) || d->type != SANE_TYPE_STRING)
    return NO;
  buf = calloc (1, d->size + 1);
  strncpy (buf, value, d->size);
  ok = sane_control_option (h, i, SANE_ACTION_SET_VALUE, buf, NULL)
       == SANE_STATUS_GOOD;
  free (buf);
  return ok;
}

/* The mode in the device's list that means kind, or NULL. */
static const char *
SCModeFor (SANE_Handle h, SCKind kind)
{
  static const char *colour[] = { "Color", "Colour", "24bit Color", "color", NULL };
  static const char *grey[] = { "Gray", "Grey", "Grayscale", "gray", NULL };
  static const char *bw[] = { "Lineart", "Binary", "Black & White", "lineart",
                              "Halftone", NULL };
  const char **want = kind == SCKindColour ? colour : kind == SCKindGrey ? grey : bw;
  const SANE_Option_Descriptor *d = NULL;
  const SANE_String_Const *list;
  int w, i;

  if (SCFindOption (h, SANE_NAME_SCAN_MODE, &d) < 0 || !SCUsable (d)
      || d->constraint_type != SANE_CONSTRAINT_STRING_LIST)
    return NULL;
  list = d->constraint.string_list;
  for (w = 0; want[w] != NULL; w++)
    for (i = 0; list[i] != NULL; i++)
      if (strcasecmp (list[i], want[w]) == 0)
        return list[i];
  /* "24bit Color[Fast]" and the like. */
  for (i = 0; list[i] != NULL; i++)
    if (strcasestr (list[i], kind == SCKindColour ? "colo"
                             : kind == SCKindGrey ? "gr" : "line") != NULL)
      return list[i];
  return NULL;
}

/* Common resolutions within a range, or the device's own list. */
static NSArray *
SCResolutions (SANE_Handle h)
{
  static const int common[] = { 50, 75, 100, 150, 200, 300, 400, 600, 1200,
                                2400, 4800, 0 };
  const SANE_Option_Descriptor *d = NULL;
  NSMutableArray *out = [NSMutableArray array];
  int i;

  if (SCFindOption (h, SANE_NAME_SCAN_RESOLUTION, &d) < 0)
    return out;
  if (d->constraint_type == SANE_CONSTRAINT_WORD_LIST)
    {
      for (i = 1; i <= d->constraint.word_list[0]; i++)
        {
          int v = (int)lround (SCWordValue (d, d->constraint.word_list[i]));
          NSNumber *n = [NSNumber numberWithInt:v];
          if (v > 0 && ![out containsObject:n])
            [out addObject:n];
        }
    }
  else if (d->constraint_type == SANE_CONSTRAINT_RANGE)
    {
      double lo = SCWordValue (d, d->constraint.range->min);
      double hi = SCWordValue (d, d->constraint.range->max);
      for (i = 0; common[i] != 0; i++)
        if (common[i] >= lo && common[i] <= hi)
          [out addObject:[NSNumber numberWithInt:common[i]]];
      if ([out count] == 0)
        [out addObject:[NSNumber numberWithInt:(int)lround (hi)]];
    }
  [out sortUsingSelector:@selector (compare:)];
  return out;
}

static double
SCRangeMax (SANE_Handle h, const char *name, double fallback)
{
  const SANE_Option_Descriptor *d = NULL;

  if (SCFindOption (h, name, &d) < 0)
    return fallback;
  if (d->constraint_type == SANE_CONSTRAINT_RANGE)
    return SCWordValue (d, d->constraint.range->max);
  if (d->constraint_type == SANE_CONSTRAINT_WORD_LIST
      && d->constraint.word_list[0] > 0)
    return SCWordValue (d, d->constraint.word_list[d->constraint.word_list[0]]);
  return fallback;
}

/* ---- pixels ------------------------------------------------------------- */

/* One channel or interleaved samples of a frame, to 8 bits a sample with
 * no padding. SANE's 1-bit data is 1 for black; 16-bit is host order. */
static void
SCTo8Bit (const unsigned char *src, int depth, int bpl, int samplesPerLine,
          int lines, unsigned char *dst)
{
  int y, x;

  for (y = 0; y < lines; y++)
    {
      const unsigned char *row = src + (size_t)y * bpl;
      unsigned char *out = dst + (size_t)y * samplesPerLine;

      if (depth == 8)
        memcpy (out, row, samplesPerLine);
      else if (depth == 16)
        for (x = 0; x < samplesPerLine; x++)
          out[x] = ((const uint16_t *)row)[x] >> 8;
      else
        for (x = 0; x < samplesPerLine; x++)
          out[x] = (row[x >> 3] & (0x80 >> (x & 7))) ? 0 : 255;
    }
}

/* ---- USB devices Scanner can't open ------------------------------------- */

/* "bus.address" of every USB device some kernel driver has (an interface
 * of it, or a hub): its %location names it, ugen=ugen<bus>.<address>. */
static NSSet *
SCClaimedUSB (void)
{
  NSMutableSet *claimed = [NSMutableSet set];
  FILE *f = popen ("/sbin/sysctl dev 2>/dev/null", "r");
  char line[1024], *u;

  if (f == NULL)
    return claimed;
  while (fgets (line, sizeof line, f) != NULL)
    if (strstr (line, ".%location:") != NULL
        && (u = strstr (line, "ugen=ugen")) != NULL)
      {
        unsigned bus, address;
        if (sscanf (u, "ugen=ugen%u.%u", &bus, &address) == 2)
          [claimed addObject:[NSString stringWithFormat:@"%u.%u", bus, address]];
      }
  pclose (f);
  return claimed;
}

/* The USB devices no kernel driver has that this process can't open:
 * what SettingsHelper may grant. Root hubs (address 1) aren't asked. */
static NSArray *
SCUnopenableUSB (void)
{
  NSMutableArray *out = [NSMutableArray array];
  NSSet *claimed = nil;
  DIR *d = opendir ("/dev/usb");
  struct dirent *e;

  if (d == NULL)
    return out;
  while ((e = readdir (d)) != NULL)
    {
      unsigned bus, address, ep;
      char path[64];
      NSString *name;

      if (sscanf (e->d_name, "%u.%u.%u", &bus, &address, &ep) != 3
          || ep != 0 || address <= 1)
        continue;
      snprintf (path, sizeof path, "/dev/usb/%s", e->d_name);
      if (access (path, R_OK | W_OK) == 0)
        continue;
      if (claimed == nil)
        claimed = SCClaimedUSB ();
      name = [NSString stringWithFormat:@"%u.%u", bus, address];
      if (![claimed containsObject:name])
        [out addObject:name];
    }
  closedir (d);
  return out;
}

/* bus and address from a SANE name "backend:libusb:BBB:DDD". */
static BOOL
SCUSBAddress (NSString *saneName, int *bus, int *address)
{
  NSRange r = [saneName rangeOfString:@"libusb:"];
  unsigned b, a;

  if (r.location == NSNotFound
      || sscanf ([[saneName substringFromIndex:NSMaxRange (r)] UTF8String],
                 "%u:%u", &b, &a) != 2)
    return NO;
  *bus = b;
  *address = a;
  return YES;
}

/* ---- the scanner -------------------------------------------------------- */

@implementation SCScanner

+ (NSString *)userConfigDirectory
{
  const char *env = getenv ("SANE_CONFIG_DIR");
  NSArray *dirs;

  if (env != NULL && *env != '\0')
    {
      NSString *first = [[[NSString stringWithUTF8String:env]
                           componentsSeparatedByString:@":"] objectAtIndex:0];
      if ([first length] > 0)
        return [first stringByExpandingTildeInPath];
    }
  dirs = NSSearchPathForDirectoriesInDomains (NSApplicationSupportDirectory,
                                              NSUserDomainMask, YES);
  if ([dirs count] == 0)
    dirs = [NSArray arrayWithObject:
                      [NSHomeDirectory () stringByAppendingPathComponent:
                                            @"Library/Application Support"]];
  return [[[dirs objectAtIndex:0] stringByAppendingPathComponent:@"Scanner"]
           stringByAppendingPathComponent:@"sane.d"];
}

/* The net.conf SANE reads now, after the person's own. */
static NSString *
SCSystemNetConf (NSString *userDir)
{
  NSMutableArray *dirs = [NSMutableArray array];
  const char *env = getenv ("SANE_CONFIG_DIR");
  NSEnumerator *e;
  NSString *dir;

  if (env != NULL)
    [dirs addObjectsFromArray:[[NSString stringWithUTF8String:env]
                                componentsSeparatedByString:@":"]];
  [dirs addObject:@"/usr/etc/sane.d"];
  e = [dirs objectEnumerator];
  while ((dir = [e nextObject]) != nil)
    {
      NSString *path = [dir stringByAppendingPathComponent:@"net.conf"];
      if ([dir length] == 0 || [[dir stringByExpandingTildeInPath]
                                 isEqual:userDir])
        continue;
      if ([[NSFileManager defaultManager] isReadableFileAtPath:path])
        return path;
    }
  return nil;
}

+ (BOOL)addNetworkHost:(NSString *)host error:(NSString **)error
{
  NSFileManager *fm = [NSFileManager defaultManager];
  NSString *dir = [self userConfigDirectory];
  NSString *path = [dir stringByAppendingPathComponent:@"net.conf"];
  NSCharacterSet *bad = [[NSCharacterSet characterSetWithCharactersInString:
      @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:[]_"]
                          invertedSet];
  NSMutableString *text;
  NSEnumerator *e;
  NSString *line;

  host = [host stringByTrimmingCharactersInSet:
                 [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  if ([host length] == 0 || [host rangeOfCharacterFromSet:bad].location
                              != NSNotFound)
    {
      *error = @"Type the name or address of the computer or scanner, such "
               @"as scanner.local or 192.168.1.20.";
      return NO;
    }
  if (![fm fileExistsAtPath:dir]
      && ![fm createDirectoryAtPath:dir withIntermediateDirectories:YES
                         attributes:nil error:NULL])
    {
      *error = [NSString stringWithFormat:@"Scanner couldn't make %@.", dir];
      return NO;
    }
  text = [NSMutableString stringWithContentsOfFile:path];
  if (text == nil)
    {
      /* SANE reads the first net.conf it finds, so the person's starts
       * as a copy of the one it read before. */
      NSString *system = SCSystemNetConf (dir);
      text = system ? [NSMutableString stringWithContentsOfFile:system] : nil;
      if (text == nil)
        text = [NSMutableString string];
      [text insertString:@"# SANE's net backend for this account, made by "
                         @"Scanner from the system's net.conf.\n" atIndex:0];
    }
  e = [[text componentsSeparatedByString:@"\n"] objectEnumerator];
  while ((line = [e nextObject]) != nil)
    if ([[line stringByTrimmingCharactersInSet:
                 [NSCharacterSet whitespaceCharacterSet]]
          caseInsensitiveCompare:host] == NSOrderedSame)
      return YES;
  /* A host that doesn't answer would hold up every search for SANE's
   * default of a minute. */
  if ([text rangeOfString:@"\nconnect_timeout"].location == NSNotFound
      && ![text hasPrefix:@"connect_timeout"])
    [text appendString:@"\nconnect_timeout = 5\n"];
  if (![text hasSuffix:@"\n"])
    [text appendString:@"\n"];
  [text appendFormat:@"# Added in Scanner\n%@\n", host];
  if (![text writeToFile:path atomically:YES])
    {
      *error = [NSString stringWithFormat:@"Scanner couldn't write %@.", path];
      return NO;
    }
  return YES;
}

- (id)initWithDelegate:(id)aDelegate
{
  if ((self = [super init]) != nil)
    {
      delegate = aDelegate;
      ready = [[NSCondition alloc] init];
      devices = [[NSArray alloc] init];
    }
  return self;
}

- (void)start
{
  const char *env = getenv ("SANE_CONFIG_DIR");

  /* The person's directory first, then SANE's own (the trailing colon). */
  if (env == NULL || *env == '\0')
    setenv ("SANE_CONFIG_DIR",
            [[[[self class] userConfigDirectory] stringByAppendingString:@":"]
              fileSystemRepresentation], 1);
  thread = [[NSThread alloc] initWithTarget:self
                                   selector:@selector (threadMain:)
                                     object:nil];
  [thread start];
  [ready lock];
  while (!isReady)
    [ready wait];
  [ready unlock];
}

- (void)threadMain:(id)unused
{
  @autoreleasepool
    {
      NSRunLoop *loop = [NSRunLoop currentRunLoop];

      [loop addPort:[NSPort port] forMode:NSDefaultRunLoopMode];
      [ready lock];
      isReady = YES;
      [ready signal];
      [ready unlock];
      [self search:nil];
      [NSTimer scheduledTimerWithTimeInterval:SCSearchInterval
                                       target:self
                                     selector:@selector (search:)
                                     userInfo:nil
                                      repeats:YES];
      for (;;)
        @autoreleasepool
          {
            [loop runMode:NSDefaultRunLoopMode
               beforeDate:[NSDate dateWithTimeIntervalSinceNow:60]];
          }
    }
}

- (void)tell:(SEL)sel with:(id)object
{
  [(NSObject *)delegate performSelectorOnMainThread:sel
                                         withObject:object
                                      waitUntilDone:NO];
}

/* -- worker thread -- */

- (void)saneStart
{
  SANE_Int version = 0;

  if (!initialised && sane_init (&version, NULL) == SANE_STATUS_GOOD)
    initialised = YES;
}

- (void)saneStop
{
  if (handle != NULL)
    {
      sane_close (handle);
      handle = NULL;
    }
  if (initialised)
    sane_exit ();
  initialised = NO;
}

/* What SANE lists now. */
- (NSMutableArray *)listed
{
  const SANE_Device **list = NULL;
  NSMutableArray *found = [NSMutableArray array];
  int i;

  if (initialised && sane_get_devices (&list, SANE_FALSE)
                         == SANE_STATUS_GOOD && list != NULL)
    for (i = 0; list[i] != NULL; i++)
      [found addObject:
               [SCDevice deviceWithSANEName:
                           [NSString stringWithUTF8String:list[i]->name]
                                     vendor:list[i]->vendor
                   ? [NSString stringWithUTF8String:list[i]->vendor] : @""
                                      model:list[i]->model
                   ? [NSString stringWithUTF8String:list[i]->model] : @""]];
  return found;
}

/* Ask SettingsHelper once for each USB device Scanner can't open; YES if
 * one was given. A refusal for want of the right sets needsAdmin, until
 * the devices asked about are gone. */
- (BOOL)askForUSB
{
  NSArray *candidates = SCUnopenableUSB ();
  NSEnumerator *e;
  NSString *name;
  BOOL granted = NO;

  if (usbAsked == nil)
    usbAsked = [[NSMutableSet alloc] init];
  /* Unplugged: forget it (a device plugged in later is asked about). */
  e = [[usbAsked allObjects] objectEnumerator];
  while ((name = [e nextObject]) != nil)
    if (![candidates containsObject:name])
      [usbAsked removeObject:name];
  if ([usbAsked count] == 0)
    needsAdmin = NO;
  e = [candidates objectEnumerator];
  while ((name = [e nextObject]) != nil)
    {
      unsigned bus, address;
      int status;

      if ([usbAsked containsObject:name]
          || sscanf ([name UTF8String], "%u.%u", &bus, &address) != 2)
        continue;
      [usbAsked addObject:name];
      status = SCHelperUSBGrant (bus, address);
      NSLog (@"Scanner: asked SettingsHelper for USB device %@: %d", name,
             status);
      if (status == SH_OK)
        granted = YES;
      else if (status == SH_ERR_DENIED || status == SH_ERR_NOT_CONSOLE
               || status == SH_ERR_AUTH_NEEDED)
        needsAdmin = YES;
    }
  return granted;
}

- (void)search:(NSTimer *)timer
{
  @autoreleasepool
    {
      NSMutableArray *found;
      BOOL first = !searched, wasNeedingAdmin = needsAdmin;
      int i;

      if (handle == NULL)
        [self saneStop];
      [self saneStart];
      found = [self listed];
      /* Nothing usable: perhaps a USB scanner Scanner may not open yet. */
      if ([found count] == 0 && handle == NULL && [self askForUSB])
        {
          [self saneStop];
          [self saneStart];
          found = [self listed];
        }
      /* The one open stays listed even if a backend leaves it out while
       * it is in use. */
      if (handle != NULL && openName != nil)
        {
          NSEnumerator *e = [devices objectEnumerator];
          SCDevice *d;
          BOOL listed = NO;

          for (i = 0; i < (int)[found count]; i++)
            if ([[[found objectAtIndex:i] saneName] isEqual:openName])
              listed = YES;
          while (!listed && (d = [e nextObject]) != nil)
            if ([[d saneName] isEqual:openName])
              {
                [found addObject:d];
                listed = YES;
              }
        }
      searched = YES;
      if (first || ![found isEqualToArray:devices]
          || wasNeedingAdmin != needsAdmin)
        {
          ASSIGN (devices, found);
          [self tell:@selector (scannerDevicesChanged:)
                with:[NSDictionary dictionaryWithObjectsAndKeys:
                                     found, @"devices",
                                     [NSNumber numberWithBool:YES],
                                     @"searched",
                                     [NSNumber numberWithBool:needsAdmin],
                                     @"needsAdmin", nil]];
        }
    }
}

- (SCDevice *)deviceNamed:(NSString *)name
{
  NSEnumerator *e = [devices objectEnumerator];
  SCDevice *d;

  while ((d = [e nextObject]) != nil)
    if ([[d saneName] isEqual:name])
      return d;
  return nil;
}

- (void)workerOpen:(NSString *)name
{
  @autoreleasepool
    {
      NSMutableDictionary *info = [NSMutableDictionary dictionary];
      SANE_Status status;
      SCDevice *device;

      if (handle != NULL && name != nil && [name isEqual:openName])
        return;
      if (handle != NULL)
        {
          sane_close (handle);
          handle = NULL;
        }
      DESTROY (openName);
      if (name == nil)
        return;
      device = [self deviceNamed:name];
      if (device != nil)
        [info setObject:device forKey:SCDeviceKey];
      [self saneStart];
      status = sane_open ([name UTF8String], (SANE_Handle *)&handle);
      if (status == SANE_STATUS_ACCESS_DENIED)
        {
          /* A USB scanner whose nodes are root's: ask for it, and try
           * again once. */
          int bus, address, granted = -1;

          if (SCUSBAddress (name, &bus, &address))
            {
              granted = SCHelperUSBGrant (bus, address);
              NSLog (@"Scanner: asked SettingsHelper for USB device %d.%d: %d",
                     bus, address, granted);
            }
          if (granted == SH_OK)
            status = sane_open ([name UTF8String], (SANE_Handle *)&handle);
        }
      if (status != SANE_STATUS_GOOD)
        {
          handle = NULL;
          [info setObject:status == SANE_STATUS_ACCESS_DENIED
                ? [NSString stringWithFormat:
                     @"An administrator needs to allow USB scanners "
                     @"before Scanner can use %@.",
                     device ? [device title] : name]
                : [NSString stringWithFormat:@"Scanner couldn't open %@: %s.",
                              device ? [device title] : name,
                              sane_strstatus (status)]
                   forKey:SCErrorKey];
          [self tell:@selector (scannerOpened:) with:info];
          return;
        }
      ASSIGN (openName, name);
      [info setObject:SCResolutions (handle) forKey:SCResolutionsKey];
      [info setObject:[NSNumber numberWithDouble:
                                  SCRangeMax (handle, SANE_NAME_SCAN_BR_X, 215.9)]
               forKey:SCGlassWidthKey];
      [info setObject:[NSNumber numberWithDouble:
                                  SCRangeMax (handle, SANE_NAME_SCAN_BR_Y, 297.0)]
               forKey:SCGlassHeightKey];
      [self tell:@selector (scannerOpened:) with:info];
    }
}

- (void)progress:(double)fraction
{
  NSDate *now = [NSDate date];

  if (lastProgress != nil && [now timeIntervalSinceDate:lastProgress] < 0.1
      && fraction < 1.0)
    return;
  ASSIGN (lastProgress, now);
  [self tell:@selector (scannerProgress:)
        with:[NSNumber numberWithDouble:fraction]];
}

- (NSString *)setUp:(SCScanRequest *)r threshold:(BOOL *)threshold
{
  const char *mode = SCModeFor (handle, r->kind);
  double glassW = SCRangeMax (handle, SANE_NAME_SCAN_BR_X, 215.9);
  double glassH = SCRangeMax (handle, SANE_NAME_SCAN_BR_Y, 297.0);
  NSRect a = r->area;

  *threshold = NO;
  if (mode == NULL && r->kind == SCKindBlackAndWhite)
    {
      /* No line-art mode (SANE's test backend): grey, made black and
       * white here. */
      mode = SCModeFor (handle, SCKindGrey);
      *threshold = YES;
    }
  if (mode != NULL)
    SCSetString (handle, SANE_NAME_SCAN_MODE, mode);
  if (mode != NULL && strcasestr (mode, "line") == NULL)
    SCSetNumber (handle, SANE_NAME_BIT_DEPTH, 8);
  SCSetNumber (handle, SANE_NAME_PREVIEW, r->preview ? 1 : 0);
  SCSetNumber (handle, SANE_NAME_SCAN_RESOLUTION, r->dpi);
  if (NSIsEmptyRect (a))
    a = NSMakeRect (0, 0, glassW, glassH);
  /* The far corner out of the way first, so the near one can move. */
  SCSetNumber (handle, SANE_NAME_SCAN_BR_X, glassW);
  SCSetNumber (handle, SANE_NAME_SCAN_BR_Y, glassH);
  SCSetNumber (handle, SANE_NAME_SCAN_TL_X, NSMinX (a));
  SCSetNumber (handle, SANE_NAME_SCAN_TL_Y, NSMinY (a));
  SCSetNumber (handle, SANE_NAME_SCAN_BR_X, NSMaxX (a));
  SCSetNumber (handle, SANE_NAME_SCAN_BR_Y, NSMaxY (a));
  return nil;
}

- (void)workerScan:(SCScanRequest *)r
{
  @autoreleasepool
    {
      NSMutableDictionary *result = [NSMutableDictionary dictionary];
      NSMutableData *planes[3] = { nil, nil, nil };
      NSMutableData *data;
      SANE_Parameters p;
      SANE_Status status = SANE_STATUS_GOOD;
      SANE_Int len;
      unsigned char buf[65536];
      int width = 0, lines = 0, channels = 1, frames = 0, depth = 8, bpl = 0;
      BOOL threshold, cancelled = NO;
      NSString *error = nil;
      unsigned long long got = 0, expected;

      [result setObject:[NSNumber numberWithBool:r->preview] forKey:SCPreviewKey];
      [result setObject:[NSNumber numberWithInt:r->dpi] forKey:SCDPIKey];
      [result setObject:[NSNumber numberWithInt:r->kind] forKey:SCKindKey];
      if (handle == NULL)
        {
          [result setObject:@"No scanner is open." forKey:SCErrorKey];
          [self tell:@selector (scannerFinished:) with:result];
          return;
        }
      [self setUp:r threshold:&threshold];
      [self progress:0];

      for (;;)
        {
          status = sane_start (handle);
          if (status != SANE_STATUS_GOOD)
            break;
          if (sane_get_parameters (handle, &p) != SANE_STATUS_GOOD)
            {
              status = SANE_STATUS_IO_ERROR;
              break;
            }
          frames++;
          width = p.pixels_per_line;
          depth = p.depth;
          bpl = p.bytes_per_line;
          expected = p.lines > 0 ? (unsigned long long)p.lines * bpl : 0;
          if (p.format == SANE_FRAME_RGB || p.format == SANE_FRAME_RED
              || p.format == SANE_FRAME_GREEN || p.format == SANE_FRAME_BLUE)
            channels = 3;
          data = [NSMutableData dataWithCapacity:expected ? expected : 1 << 20];
          got = 0;
          while (status == SANE_STATUS_GOOD)
            {
              if (cancelRequested)
                {
                  cancelled = YES;
                  break;
                }
              status = sane_read (handle, buf, sizeof buf, &len);
              if (status == SANE_STATUS_GOOD && len > 0)
                {
                  [data appendBytes:buf length:len];
                  got += len;
                  if (expected)
                    [self progress:p.format == SANE_FRAME_RGB
                                    || p.format == SANE_FRAME_GRAY
                                      ? (double)got / expected
                                      : ((frames - 1) + (double)got / expected) / 3.0];
                }
            }
          if (cancelled || status != SANE_STATUS_EOF)
            break;
          status = SANE_STATUS_GOOD;
          lines = bpl > 0 ? (int)([data length] / bpl) : 0;
          if (p.format == SANE_FRAME_RED)
            planes[0] = data;
          else if (p.format == SANE_FRAME_GREEN)
            planes[1] = data;
          else if (p.format == SANE_FRAME_BLUE)
            planes[2] = data;
          else
            planes[0] = data;
          if (p.last_frame)
            break;
        }
      sane_cancel (handle);

      if (cancelled || status == SANE_STATUS_CANCELLED)
        [result setObject:[NSNumber numberWithBool:YES] forKey:SCCancelledKey];
      else if (status != SANE_STATUS_GOOD)
        error = [NSString stringWithFormat:@"The scan stopped: %s.",
                          sane_strstatus (status)];
      else if (width <= 0 || lines <= 0 || planes[0] == nil
               || (channels == 3 && frames > 1
                   && (planes[1] == nil || planes[2] == nil)))
        error = @"The scanner sent no picture.";
      else
        {
          int samples = (frames > 1) ? 1 : channels;
          int spp = channels;
          NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
              initWithBitmapDataPlanes:NULL
                            pixelsWide:width
                            pixelsHigh:lines
                         bitsPerSample:8
                       samplesPerPixel:spp
                              hasAlpha:NO
                              isPlanar:NO
                        colorSpaceName:spp == 3 ? NSCalibratedRGBColorSpace
                                                : NSCalibratedWhiteColorSpace
                           bytesPerRow:width * spp
                          bitsPerPixel:8 * spp];
          unsigned char *out = [rep bitmapData];

          if (frames > 1 && channels == 3)
            {
              /* Three passes: one plane each, interleaved here. */
              unsigned char *plane = malloc ((size_t)width * lines);
              int c;
              size_t k;

              for (c = 0; c < 3; c++)
                {
                  int pl = (int)MIN ((NSUInteger)lines,
                                     [planes[c] length] / bpl);
                  memset (plane, 255, (size_t)width * lines);
                  SCTo8Bit ([planes[c] bytes], depth, bpl, width, pl, plane);
                  for (k = 0; k < (size_t)width * lines; k++)
                    out[k * 3 + c] = plane[k];
                }
              free (plane);
            }
          else
            SCTo8Bit ([planes[0] bytes], depth, bpl, width * samples, lines, out);

          /* What was asked for, whatever mode the device scanned in. */
          if (r->kind != SCKindColour && spp == 3)
            {
              NSBitmapImageRep *grey = [[NSBitmapImageRep alloc]
                  initWithBitmapDataPlanes:NULL pixelsWide:width pixelsHigh:lines
                             bitsPerSample:8 samplesPerPixel:1 hasAlpha:NO
                                  isPlanar:NO
                            colorSpaceName:NSCalibratedWhiteColorSpace
                               bytesPerRow:width bitsPerPixel:8];
              unsigned char *g = [grey bitmapData];
              size_t k;

              for (k = 0; k < (size_t)width * lines; k++)
                g[k] = (out[k * 3] * 30 + out[k * 3 + 1] * 59
                        + out[k * 3 + 2] * 11) / 100;
              RELEASE (rep);
              rep = grey;
              out = g;
            }
          if (r->kind == SCKindBlackAndWhite && (threshold || [rep samplesPerPixel] == 1))
            {
              size_t k;
              for (k = 0; k < (size_t)width * lines; k++)
                out[k] = out[k] >= 128 ? 255 : 0;
            }
          if (r->dpi > 0)
            [rep setSize:NSMakeSize (width * 72.0 / r->dpi, lines * 72.0 / r->dpi)];
          [result setObject:rep forKey:SCImageKey];
          RELEASE (rep);
          [self progress:1.0];
        }
      if (error != nil)
        [result setObject:error forKey:SCErrorKey];
      [self tell:@selector (scannerFinished:) with:result];
    }
}

- (void)workerReload
{
  NSString *name = AUTORELEASE (RETAIN (openName));

  [self saneStop];
  DESTROY (openName);
  searched = NO;
  [self search:nil];
  if (name != nil)
    [self workerOpen:name];
}

/* -- main thread -- */

- (void)openDevice:(NSString *)saneName
{
  [self performSelector:@selector (workerOpen:) onThread:thread
             withObject:saneName waitUntilDone:NO];
}

- (void)scan:(SCScanRequest *)request
{
  cancelRequested = NO;
  [self performSelector:@selector (workerScan:) onThread:thread
             withObject:request waitUntilDone:NO];
}

- (void)cancel
{
  cancelRequested = YES;
}

- (void)reloadConfiguration
{
  [self performSelector:@selector (workerReload) onThread:thread
             withObject:nil waitUntilDone:NO];
}

@end
