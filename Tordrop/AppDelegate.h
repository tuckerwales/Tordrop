//
//  AppDelegate.h
//  Tordrop
//
//  Created by Joshua Lee Tucker on 22/05/2014.
//  Copyright (c) 2014 Bandit Labs Cyf. All rights reserved.
//

#import <Cocoa/Cocoa.h>

#import "DragStatusView.h"
#import "TorManager.h"
#import "GCDWebServer.h"
#import "GCDWebServerDataResponse.h"

@interface AppDelegate : NSObject <NSApplicationDelegate, NSMenuDelegate, NSUserNotificationCenterDelegate, DragViewDelegate, TorManagerDelegate> {
    NSMenu *statusMenu;
    NSStatusItem *statusItem;
    TorManager *torManager;
    GCDWebServer *webServer;
    int onionPort;
    NSString *onionURL;
    BOOL hasShownFailedNotification;
    NSString *filePath;
}

@property (nonatomic, strong) TorManager *torManager;

@property (nonatomic, strong) NSString *filePath;

@property (assign) IBOutlet NSWindow *window;

@end
