//
//  TorManager.h
//  Tordrop
//
//  Created by Joshua Lee Tucker on 22/05/2014.
//  Copyright (c) 2014 Bandit Labs Cyf. All rights reserved.
//

#import <Foundation/Foundation.h>

@protocol TorManagerDelegate;

@interface TorManager : NSObject <NSStreamDelegate> {
    id delegate;
    NSInputStream *inputStream;
    NSOutputStream *outputStream;
    BOOL authenticated;
    int port;
    NSTimer *connectTimer;
}

- (void)start;

@property (nonatomic, strong) id delegate;

@end

@protocol TorManagerDelegate <NSObject>

- (void)hiddenServiceSetup:(NSString*)url withPort:(int)port;
- (void)didConnectToTor;
- (void)didDisconnectFromTor;
- (void)failedToConnect;

@end
