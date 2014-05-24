//
//  AppDelegate.m
//  Tordrop
//
//  Created by Joshua Lee Tucker on 22/05/2014.
//  Copyright (c) 2014 Bandit Labs Cyf. All rights reserved.
//

#import "AppDelegate.h"

#import <CommonCrypto/CommonDigest.h>

@implementation AppDelegate

@synthesize torManager, filePath;

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification
{
    hasShownFailedNotification = NO;
    [[NSUserNotificationCenter defaultUserNotificationCenter] setDelegate:self];
    
    statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    DragStatusView *dragView = [[DragStatusView alloc] initWithFrame:NSMakeRect(0, 0, 16, 16)]; // handles drag and drop.
    dragView.delegate = self;
    dragView.statusItem = statusItem;
    [statusItem setView:dragView];
    [statusItem setImage:[NSImage imageNamed:@"tor"]]; // tor@1x/tor@2x in Images.xcassets.
    [statusItem setHighlightMode:YES]; // Highlights icon when clicked.
    
    statusMenu = [[NSMenu alloc] initWithTitle:@""];
    statusMenu.delegate = self;
    [statusMenu setAutoenablesItems:YES]; // Enable/disable menu items - NSMenuValidation protocol.
    
    [statusItem setMenu:statusMenu]; // Give the status item a menu to use.
    
    [statusMenu addItemWithTitle:@"Not connected to Tor" action:nil keyEquivalent:@""];
    [statusMenu addItem:[NSMenuItem separatorItem]];
    [statusMenu addItemWithTitle:@"Quit" action:@selector(quit:) keyEquivalent:@"q"];
    
}

- (void)quit:(id)sender
{
    if ([webServer isRunning]) {
        [self stopWebServer];
    }
    exit(EXIT_SUCCESS);
}

#pragma mark Drag View Delegate Methods

- (void)didDragFiles:(NSArray *)files {
    if (torManager) { // reconnect/restart services to share new file.
        [self stopWebServer];
    }
    self.filePath = [files objectAtIndex:0];
    torManager = [[TorManager alloc] init];
    torManager.delegate = self;
    [torManager start];
}

#pragma mark Web Server

- (NSString *)getSHA1 {
    NSData *data = [[NSData alloc] initWithContentsOfFile:filePath];
    uint8_t digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1([data bytes], (int)[data length], digest);
    NSMutableString *output = [NSMutableString stringWithCapacity:CC_SHA1_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) {
        [output appendFormat:@"%02x", digest[i]];
    }
    return output;
}

- (void)setupWebServer {
    webServer = [[GCDWebServer alloc] init];
    __weak typeof (filePath)weakFilePath = filePath; // avoid retain cycle from capturing self within block.
    NSString *sha1 = [self getSHA1]; // returns sha1 of file at filePath.
    [webServer addDefaultHandlerForMethod:@"GET" requestClass:[GCDWebServerRequest class] processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
        NSString *htmlString = [NSString stringWithFormat:@"<html><head><title>Tordrop</title><style type=\"text/css\"> body { margin: 0; padding: 0; background-color: #faf9f0; color: #444; font-family: \"Helvetica\"; } .header { padding: 50px 10px; color: #fff; font-size: 25px; text-align: center; background-color: #fa5b4d; border-bottom: 1px solid #000; text-shadow: 0px 1px 0px #000; } .container { width: 900px; margin: 50px auto; overflow: hidden; text-align: center; } </style></head><body><div class=\"header\"><h1>Tordrop</h1></div><div class=\"container\">Hello, someone has shared %@ with you! <br><br> Please click the following link to download the file: <br><br><a href=\"%@\">Download</a><br><br>SHA1: %@</div></body></html>", [weakFilePath lastPathComponent], [weakFilePath lastPathComponent], sha1];
        return [GCDWebServerDataResponse responseWithHTML:htmlString];
    }];
    [webServer addGETHandlerForPath:[NSString stringWithFormat:@"/%@", [filePath lastPathComponent]] staticData:[[NSData alloc] initWithContentsOfFile:filePath] contentType:@"application/octet-stream" cacheAge:0]; // actually handles download of file.
    [webServer setPort:onionPort];
    [webServer start];
    [statusMenu removeItemAtIndex:2]; // need to do this in a convoluted manner because of the lack of an insertAtIndex: method.
    [statusMenu addItemWithTitle:@"Copy Onion URL" action:@selector(copyURL:) keyEquivalent:@"c"];
    [statusMenu addItemWithTitle:@"Stop sharing" action:@selector(stopWebServer) keyEquivalent:@"s"];
    [statusMenu addItemWithTitle:@"Quit" action:@selector(quit:) keyEquivalent:@"q"];
    NSUserNotification *notification = [[NSUserNotification alloc] init];
    notification.title = @"Tordrop";
    NSString *informativeText = [NSString stringWithFormat:@"Now sharing... Click to copy Onion URL to pasteboard!"];
    notification.informativeText = informativeText;
    [[NSUserNotificationCenter defaultUserNotificationCenter] deliverNotification:notification];
}

- (void)copyURL:(id)sender {
    [[NSPasteboard generalPasteboard] clearContents];
    [[NSPasteboard generalPasteboard] setString:onionURL  forType:NSStringPboardType];
}

- (void)stopWebServer {
    torManager = nil;
    hasShownFailedNotification = NO;
    [[statusMenu itemAtIndex:0] setTitle:@"Not connected to Tor"];
    [webServer stop];
    [statusMenu removeItemAtIndex:3];
    [statusMenu removeItemAtIndex:2];
}

#pragma mark TorManager Delegate Methods

- (void)hiddenServiceSetup:(NSString*)url withPort:(int)port {
    onionPort = port;
    onionURL = url;
    [self setupWebServer];
}

- (void)didConnectToTor {
    [[statusMenu itemAtIndex:0] setTitle:@"Connected to Tor"];
}

- (void)didDisconnectFromTor {
    torManager = nil;
    hasShownFailedNotification = NO;
    [[statusMenu itemAtIndex:0] setTitle:@"Not connected to Tor"];
    [self stopWebServer];
}

- (void)failedToConnect {
    if (!hasShownFailedNotification) {
        NSUserNotification *notification = [[NSUserNotification alloc] init];
        notification.title = @"Tordrop";
        notification.informativeText = @"We couldn't connect to Tor. Are you sure Tor is running?";
        [[NSUserNotificationCenter defaultUserNotificationCenter] deliverNotification:notification];
        hasShownFailedNotification = YES;
    }
}

#pragma mark NSMenuValidation Protocol

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem
{
    if ([statusMenu indexOfItem:menuItem] == 0) {
        return NO; // Provides grayed out look.
    }
    
    if ([menuItem action] == @selector(quit:)) {
        return YES;
    }
    
    if ([menuItem action] == @selector(copyURL:)) {
        return YES;
    }
    
    if ([menuItem action] == @selector(stopWebServer)) {
        return YES;
    }
    
    return NO; // Default.
}

#pragma mark NSUserNotificationCenter Delegate Methods

- (void)userNotificationCenter:(NSUserNotificationCenter *)center didActivateNotification:(NSUserNotification *)notification {
    [self copyURL:self];
}

- (BOOL)userNotificationCenter:(NSUserNotificationCenter *)center shouldPresentNotification:(NSUserNotification *)notification
{
    return YES;
}

@end
