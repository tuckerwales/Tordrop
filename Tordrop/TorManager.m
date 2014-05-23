//
//  TorManager.m
//  Tordrop
//
//  Created by Joshua Lee Tucker on 22/05/2014.
//  Copyright (c) 2014 Bandit Labs Cyf. All rights reserved.
//

#import "TorManager.h"

#include "time.h"

@implementation TorManager

@synthesize delegate;

#define LOG 1

- (void)start {
    
    authenticated = NO;
    
    #if LOG
        NSLog(@"Tordrop: Attempting to connect to Tor service...");
    #endif
    
    [self initComms];
    
}

- (void)initComms {
    CFReadStreamRef readStream;
    CFWriteStreamRef writeStream;
    CFStreamCreatePairWithSocketToHost(NULL, (CFStringRef)@"127.0.0.1", 9051, &readStream, &writeStream);
    
    inputStream = (__bridge_transfer NSInputStream *)readStream;
    outputStream = (__bridge_transfer NSOutputStream *)writeStream;
    
    [inputStream setDelegate:self];
    [outputStream setDelegate:self];
    
    [inputStream scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
    [outputStream scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
    
    [inputStream open];
    [outputStream open];
    
    [self writeString:@"authenticate \"\"\n"];
    
}

- (void)didAuthenticate {
    authenticated = YES;
    #if LOG
        NSLog(@"Tordrop: Successfully authenticated with control port!");
    #endif
    [self writeString:@"getinfo status/bootstrap-phase\n"];
}

- (void)didConnectSuccessfully {
    if (connectTimer) {
        [connectTimer invalidate];
        connectTimer = nil;
    }
    #if LOG
        NSLog(@"Tordrop: Successfully connected to Tor!");
    #endif
    if ([delegate respondsToSelector:@selector(didConnectToTor)]) {
        [delegate didConnectToTor];
    }
    [self setupHiddenService];
}

- (void)didDisconnect {
    #if LOG
        NSLog(@"Tordrop: Disconnected from Tor!");
    #endif
    if ([delegate respondsToSelector:@selector(didDisconnectFromTor)]) {
        [delegate didDisconnectFromTor];
    }
}

- (void)failedToConnect {
    #if LOG
        NSLog(@"Tordrop: Couldn't connect to Tor service... Are you sure Tor is running?");
    #endif
    if ([delegate respondsToSelector:@selector(failedToConnect)]) {
        [delegate failedToConnect];
    }
    connectTimer = [NSTimer scheduledTimerWithTimeInterval:10.0f target:self selector:@selector(keepTryingToConnect) userInfo:nil repeats:NO];
}

- (void)keepTryingToConnect {
    [self initComms];
}

- (void)setupHiddenService {
    #if LOG
        NSLog(@"Tordrop: Setting up hidden service...");
    #endif
    srand((unsigned)time(NULL)); // seed is required to generate a truly random port.
    port = (rand() % (65535-1025 + 1) + 1025); // simple diff. formula to generate random port.
    #if LOG
        NSLog(@"Tordrop: Using random port %d.", port);
    #endif
    NSString *hiddenServiceString = [NSString stringWithFormat:@"SETCONF HiddenServiceDir=\"/tmp/tordrop_%d\" HiddenServicePort=\"80 127.0.0.1:%d\"\n", port, port];
    [self writeString:hiddenServiceString];
}

- (void)hiddenServiceSetupComplete {
    NSString *hostnamePath = [NSString stringWithFormat:@"/tmp/tordrop_%d/hostname", port];
    NSString *onionURL = [NSString stringWithFormat:@"http://%@", [NSString stringWithContentsOfFile:hostnamePath encoding:NSUTF8StringEncoding error:nil]];
    #if LOG
        NSLog(@"Tordrop: Onion URL: %@", onionURL);
    #endif
    if ([delegate respondsToSelector:@selector(hiddenServiceSetup:withPort:)]) {
        [delegate hiddenServiceSetup:onionURL withPort:port];
    }
}

- (void)stream:(NSStream *)theStream handleEvent:(NSStreamEvent)streamEvent {
    
    switch (streamEvent) {
        case NSStreamEventOpenCompleted:
            #if LOG
                NSLog(@"Tordrop: %@ stream opened!", (theStream == inputStream) ? @"Input" : @"Output");
            #endif
            break;
            
        case NSStreamEventHasBytesAvailable:
            if (theStream == inputStream) {
                NSString *inString = [self readString];
                if (!authenticated) {
                    if ([inString hasPrefix:@"250"]) {
                        [self didAuthenticate];
                    }
                } else if ([inString rangeOfString:@"-status/bootstrap-phase="].location != NSNotFound) {
                    if ([[self readString] rangeOfString:@"BOOTSTRAP PROGRESS=100"].location != NSNotFound) {
                        [self didConnectSuccessfully];
                    }
                } else {
                    #if LOG
                        NSLog(@"Tordrop: %@", inString);
                    #endif
                    if ([inString rangeOfString:@"250 OK"].location != NSNotFound) {
                        [self hiddenServiceSetupComplete];
                    }
                }
            }
            break;
            
        case NSStreamEventEndEncountered:
            [self didDisconnect];
            break;
            
        case NSStreamEventErrorOccurred:
            if ([[[inputStream streamError] localizedDescription] rangeOfString:@"Connection refused"].location != NSNotFound) {
                [self failedToConnect];
            }
            break;
            
        default:
            break;
            
    }
    
}

- (void)writeString:(NSString *)str {
    NSData *data = [[NSData alloc] initWithData:[str dataUsingEncoding:NSUTF8StringEncoding]];
    [outputStream write:[data bytes] maxLength:[data length]];
}

- (NSString *)readString {
    uint8_t buffer[1024];
    long len;
    NSString *output;
    while ([inputStream hasBytesAvailable]) {
        len = [inputStream read:buffer maxLength:sizeof(buffer)];
        if (len > 0) {
            output = [[NSString alloc] initWithBytes:buffer length:len encoding:NSUTF8StringEncoding];
        }
    }
    return output;
}

@end
