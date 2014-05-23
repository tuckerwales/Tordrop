//
//  DragStatusView.m
//  Tordrop
//
//  Created by Joshua Lee Tucker on 22/05/2014.
//  Copyright (c) 2014 Bandit Labs Cyf. All rights reserved.
//

#import "DragStatusView.h"

@implementation DragStatusView

@synthesize delegate, statusItem;

- (id)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        [self registerForDraggedTypes:[NSArray arrayWithObjects:NSFilenamesPboardType, nil]];
    }
    return self;
}

- (void)mouseDown:(NSEvent *)theEvent {
    [self.statusItem popUpStatusItemMenu:self.statusItem.menu];
    [self.statusItem setHighlightMode:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
    NSImage *img = [NSImage imageNamed:@"tor"];
    [img drawInRect:CGRectMake(0, 3.5, 16, 16)];
}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    return NSDragOperationCopy;
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    NSPasteboard *pboard;
    NSDragOperation sourceDragMask;
    
    sourceDragMask = [sender draggingSourceOperationMask];
    pboard = [sender draggingPasteboard];
    
    if ([[pboard types] containsObject:NSFilenamesPboardType]) {
        NSArray *files = [pboard propertyListForType:NSFilenamesPboardType];
        NSLog(@"Files: %@", files);
        BOOL isDir;
        [[NSFileManager defaultManager] fileExistsAtPath:[files objectAtIndex:0] isDirectory:&isDir]; // we only serve files.
        if (!isDir) {
            if ([delegate respondsToSelector:@selector(didDragFiles:)]) {
                [delegate didDragFiles:files];
            }
        }
    }
    return YES;
}

@end
