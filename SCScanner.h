/*
 * Copyright (C) 2026 Joseph Maloney <pkgdemonteam@gmail.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * SCScanner: Scanner.app's side of SANE (nextbsd/nextbsd#717). Every SANE
 * call is made on one thread of its own, so finding scanners, opening
 * them and scanning never hold up the window; results come back to the
 * delegate on the main thread.
 */

#import <Foundation/Foundation.h>

@class NSBitmapImageRep;

typedef enum
{
  SCKindColour = 0,
  SCKindGrey = 1,
  SCKindBlackAndWhite = 2
} SCKind;

/* A scanner SANE lists. */
@interface SCDevice : NSObject
{
  NSString *saneName;
  NSString *title;
  NSString *detail;
  BOOL network;
}
+ (SCDevice *)deviceWithSANEName:(NSString *)name
                          vendor:(NSString *)vendor
                           model:(NSString *)model;
- (NSString *)saneName;
/* What the sidebar shows: "Canon LiDE 300"; "USB" or "Network, host". */
- (NSString *)title;
- (NSString *)detail;
- (BOOL)isNetwork;
@end

/* What to scan. area is in millimetres from the top left of the glass;
 * an empty area is the whole glass. */
@interface SCScanRequest : NSObject
{
@public
  SCKind kind;
  int dpi;
  BOOL preview;
  NSRect area;
}
@end

/* Keys of the dictionaries the delegate gets. */
extern NSString *const SCDeviceKey;       /* SCDevice */
extern NSString *const SCErrorKey;        /* NSString, when it failed */
extern NSString *const SCResolutionsKey;  /* NSArray of NSNumber (dpi) */
extern NSString *const SCGlassWidthKey;   /* NSNumber, mm */
extern NSString *const SCGlassHeightKey;  /* NSNumber, mm */
extern NSString *const SCImageKey;        /* NSBitmapImageRep */
extern NSString *const SCPreviewKey;      /* NSNumber BOOL */
extern NSString *const SCCancelledKey;    /* NSNumber BOOL */
extern NSString *const SCDPIKey;          /* NSNumber */
extern NSString *const SCKindKey;         /* NSNumber SCKind */

@protocol SCScannerDelegate
/* The scanners now found; searched is NO until the first search ends;
 * needsAdmin: a USB device Scanner may not open is connected, and the
 * person isn't allowed to have it (not an administrator). */
- (void)scannerDevicesChanged:(NSDictionary *)info;
/* A device was opened (or failed to open): resolutions and the glass. */
- (void)scannerOpened:(NSDictionary *)info;
- (void)scannerProgress:(NSNumber *)fraction;
- (void)scannerFinished:(NSDictionary *)result;
@end

@interface SCScanner : NSObject
{
  id delegate;
  NSThread *thread;
  NSCondition *ready;
  BOOL isReady;
  /* Worker thread only. */
  void *handle;
  NSString *openName;
  NSArray *devices;
  BOOL searched;
  BOOL initialised;
  NSDate *lastProgress;
  NSMutableSet *usbAsked;   /* "bus.address" asked of SettingsHelper */
  BOOL needsAdmin;
  /* Set from the main thread. */
  volatile BOOL cancelRequested;
}

- (id)initWithDelegate:(id)aDelegate;
/* Starts the thread, SANE and the search, which goes on every few
 * seconds for as long as Scanner runs. */
- (void)start;
/* Opens the device (nil closes the one open). */
- (void)openDevice:(NSString *)saneName;
- (void)scan:(SCScanRequest *)request;
/* Stops the scan going on, between two reads. */
- (void)cancel;
/* SANE again from its configuration (after a network scanner is added). */
- (void)reloadConfiguration;

/* The person's own SANE configuration directory: the first of
 * SANE_CONFIG_DIR when it is set, else Scanner's directory in their
 * Library, which -start puts first in SANE_CONFIG_DIR before SANE's own. */
+ (NSString *)userConfigDirectory;
/* Adds host to the person's net.conf (a copy of the system's the first
 * time), for SANE's net backend; NO and *error when it can't. */
+ (BOOL)addNetworkHost:(NSString *)host error:(NSString **)error;
@end
