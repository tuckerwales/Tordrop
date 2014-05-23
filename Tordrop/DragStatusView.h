//
//  DragStatusView.h
//  Tordrop
//
//  Created by Joshua Lee Tucker on 22/05/2014.
//  Copyright (c) 2014 Bandit Labs Cyf. All rights reserved.
//

#import <Cocoa/Cocoa.h>

@protocol DragViewDelegate;

@interface DragStatusView : NSView {
    id delegate;
    NSStatusItem *statusItem;
}

@property (nonatomic, strong) id delegate;
@property (nonatomic, strong) NSStatusItem *statusItem;

@end

@protocol DragViewDelegate <NSObject>

- (void)didDragFiles:(NSArray *)files;

@end
