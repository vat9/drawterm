#define Cursor OSXCursor
#define Point OSXPoint
#define Rect OSXRect

#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#undef Cursor
#undef Point
#undef Rect

#include <u.h>
#include <libc.h>
#include "kern/mem.h"
#include "kern/dat.h"
#include "error.h"
#include "user.h"

#define Image IMAGE

#include <draw.h>
#include <memdraw.h>
#include <keyboard.h>
#include <cursor.h>
#include "kern/screen.h"

#include "macos-screen.h"
#include "osx-keycodes.h"
#include "drawterm.h"
#include "devdraw.h"
#include "bigarrow.h"
#include "docpng.h"

/*
AUTOFRAMEWORK(Cocoa)
AUTOFRAMEWORK(Metal)
AUTOFRAMEWORK(QuartzCore)
*/

#define LOG	if(0)NSLog
#define LOGG 	if(0)printf
#define LOGM	if(0)printf

static uint keycvt(uint);
static uint msec(void);
static Memimage* initimg(void);

@class DevDrawView;
@class DrawLayer;

@interface AppDelegate : NSObject<NSApplicationDelegate>
+ (void)callservep9p:(id)arg;
+ (void)makewin:(NSValue *)v;
+ (void)callkicklabel:(NSString *)v;
+ (void)callsetNeedsDisplayInRect:(NSValue *)v;
+ (void)callsetcursor:(NSValue *)v;
@end

@interface DevDrawView : NSView<NSTextInputClient,NSWindowDelegate>
- (void)topwin;
- (void)clearInput;
- (void)getmouse:(NSEvent *)e;
- (void)sendmouse:(NSUInteger)b;
- (void)setmouse:(Point)p;
- (void)resetLastInputRect;
- (void)enlargeLastInputRect:(NSRect)r;
@end

@interface DrawLayer : CAMetalLayer
@property (nonatomic, retain) id<MTLCommandQueue> cmd;
@property (nonatomic, retain) id<MTLTexture> texture;
@end

static AppDelegate *myApp = NULL;
static DevDrawView *myContent = NULL;
static NSWindow *win = NULL;
static NSCursor *currentCursor = NULL;

static NSCursor* makecursor(Cursor*);

static DrawLayer *layer;
static id<MTLDevice> device;
static id<MTLCommandQueue> commandQueue;
static id<MTLTexture> texture;

static Memimage *img = NULL;
static CGFloat scaleimg;

static QLock snarfl;
extern Cursorinfo cursor;

Memimage	*gscreen;
Screeninfo	screeninfo;

@implementation AppDelegate

+ (void)callservep9p:(id)arg
{
	initcpu();
	[NSApp terminate:self];
}

+ (void)makewin:(NSValue *)v
{
	NSRect r, sr;
	Rectangle wr;
	int set;
	char *s;
	id<MTLLibrary> library;
	NSError *error;
	NSArray *allDevices;

	const NSWindowStyleMask Winstyle = NSWindowStyleMaskTitled
		| NSWindowStyleMaskClosable
		| NSWindowStyleMaskMiniaturizable
		| NSWindowStyleMaskResizable;

	s = [v pointerValue];
	sr = [[NSScreen mainScreen] frame];
	r = [[NSScreen mainScreen] visibleFrame];

	LOG(@"makewin(%s)", s);
	if(s && *s){
		if(parsewinsize(s, &wr, &set) < 0)
			sysfatal("%r");
	}else{
		wr = Rect(0, 0, sr.size.width*2/3, sr.size.height*2/3);
		set = 0;
	}

	r.origin.x = wr.min.x;
	r.origin.y = sr.size.height-wr.max.y;	/* winsize is top-left-based */
	r.size.width = fmin(Dx(wr), r.size.width);
	r.size.height = fmin(Dy(wr), r.size.height);
	r = [NSWindow contentRectForFrameRect:r styleMask:Winstyle];

	win = [[NSWindow alloc] initWithContentRect:r
									  styleMask:Winstyle
										backing:NSBackingStoreBuffered
										  defer:NO
										 screen:[NSScreen mainScreen]];
	[win setTitle:@"devdraw"];

	if(!set)
		[win center];
	[win setCollectionBehavior:NSWindowCollectionBehaviorFullScreenPrimary];
	[win setContentMinSize:NSMakeSize(64,64)];
	[win setOpaque:YES];
	[win setRestorable:NO];
	[win setAcceptsMouseMovedEvents:YES];

	myContent = [DevDrawView new];
	[win setContentView:myContent];
	[myContent setWantsLayer:YES];
	[myContent setLayerContentsRedrawPolicy:NSViewLayerContentsRedrawOnSetNeedsDisplay];
	[win setDelegate:myContent];

	device = nil;
	allDevices = MTLCopyAllDevices();
	for(id mtlDevice in allDevices) {
		if ([mtlDevice isLowPower] && ![mtlDevice isRemovable]) {
			device = mtlDevice;
			break;
		}
	}
	if(!device)
		device = MTLCreateSystemDefaultDevice();

	layer = (DrawLayer *)[myContent layer];
	layer.device = device;
	layer.cmd = [device newCommandQueue];
	layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
	layer.framebufferOnly = YES;
	layer.opaque = YES;

	// We use a default transparent layer on top of the CAMetalLayer.
	// This seems to make fullscreen applications behave.
	// Specifically, without this code if you enter full screen with Cmd-Ctrl-F,
	// the screen goes black until the first mouse click.
	if(1){
		CALayer *stub = [CALayer layer];
		stub.frame = CGRectMake(0, 0, 1, 1);
		[stub setNeedsDisplay];
		[layer addSublayer:stub];
	}
	[NSEvent setMouseCoalescingEnabled:NO];

	[myContent topwin];
	mouseset(Pt(0,0));
}

+ (void)callkicklabel:(NSString *)s
{
	LOG(@"callkicklabel(%@)", s);
	[win setTitle:s];
	[[NSApp dockTile] setBadgeLabel:s];
}


+ (void)callsetNeedsDisplayInRect:(NSValue *)v
{
	NSRect r;
	dispatch_time_t time;

	r = [v rectValue];
	LOGG("callsetNeedsDisplayInRect(%g, %g, %g, %g)", r.origin.x, r.origin.y, r.size.width, r.size.height);
	r = [win convertRectFromBacking:r];
	LOGG("setNeedsDisplayInRect(%g, %g, %g, %g)", r.origin.x, r.origin.y, r.size.width, r.size.height);
	[layer setNeedsDisplayInRect:r];

	time = dispatch_time(DISPATCH_TIME_NOW, 16 * NSEC_PER_MSEC);
	dispatch_after(time, dispatch_get_main_queue(), ^(void){
		[layer setNeedsDisplayInRect:r];
	});

	[myContent enlargeLastInputRect:r];
}

typedef struct Cursors Cursors;
struct Cursors {
	Cursor *c;
	Cursor2 *c2;
};

+ (void)callsetcursor:(NSValue *)v
{
	Cursors *cs;
	Cursor *c;
	Cursor2 *c2;
	NSBitmapImageRep *r, *r2;
	NSImage *i;
	NSPoint p;
	uchar *plane[5], *plane2[5];
	uint b;

	cs = [v pointerValue];
	c = cs->c;
	if(!c)
		c = &bigarrow;
	c2 = cs->c2;
	if(!c2)
		c2 = &bigarrow2;

@autoreleasepool{
	r = [[NSBitmapImageRep alloc]
		initWithBitmapDataPlanes:nil
		pixelsWide:16
		pixelsHigh:16
		bitsPerSample:1
		samplesPerPixel:2
		hasAlpha:YES
		isPlanar:YES
		colorSpaceName:NSDeviceWhiteColorSpace
		bytesPerRow:2
		bitsPerPixel:0];
	[r getBitmapDataPlanes:plane];
	for(b=0; b<nelem(c->set); b++){
		plane[0][b] = ~c->set[b] & c->clr[b];
		plane[1][b] = c->set[b] | c->clr[b];
	}

	r2 = [[NSBitmapImageRep alloc]
		initWithBitmapDataPlanes:nil
		pixelsWide:32
		pixelsHigh:32
		bitsPerSample:1
		samplesPerPixel:2
		hasAlpha:YES
		isPlanar:YES
		colorSpaceName:NSDeviceWhiteColorSpace
		bytesPerRow:4
		bitsPerPixel:0];
	[r2 getBitmapDataPlanes:plane2];
	for(b=0; b<nelem(c2->set); b++){
		plane2[0][b] = ~c2->set[b] & c2->clr[b];
		plane2[1][b] = c2->set[b] | c2->clr[b];
	}

	// For checking out the cursor bitmap image
/*
	static BOOL saveimg = YES;
	if(saveimg){
		NSData *data = [r representationUsingType: NSBitmapImageFileTypeBMP properties: @{}];
		[data writeToFile: @"/tmp/r.bmp" atomically: NO];
		data = [r2 representationUsingType: NSBitmapImageFileTypeBMP properties: @{}];
		[data writeToFile: @"/tmp/r2.bmp" atomically: NO];
		saveimg = NO;
	}
*/

	i = [[NSImage alloc] initWithSize:NSMakeSize(16, 16)];
	[i addRepresentation:r2];
	[i addRepresentation:r];

	p = NSMakePoint(-c->offset.x, -c->offset.y);
	currentCursor = [[NSCursor alloc] initWithImage:i hotSpot:p];

	[win invalidateCursorRectsForView:myContent];
}
}

- (void)applicationDidFinishLaunching:(id)arg
{
	NSMenu *m, *sm;
	NSMenuItem *item;
	NSData *d;
	NSImage *i;

	LOG(@"applicationDidFinishLaunching");

	m = [NSMenu new];
	[m addItemWithTitle:@"DEVDRAW" action:nil keyEquivalent:@""];
	[m addItemWithTitle:@"Edit" action:nil keyEquivalent:@""];
	[m addItemWithTitle:@"View" action:nil keyEquivalent:@""];
	[m addItemWithTitle:@"Window" action:nil keyEquivalent:@""];

	sm = [NSMenu new];
	[sm addItemWithTitle:@"Hide" action:@selector(hide:) keyEquivalent:@"h"];
	[sm addItemWithTitle:@"Quit" action:@selector(terminate:) keyEquivalent:@"q"];
	[m itemWithTitle:@"DEVDRAW"].submenu = sm;

	sm = [NSMenu new];
	[sm setTitle:@"Edit"];
	[sm addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
	[sm addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
	[sm addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
	[m itemWithTitle:@"Edit"].submenu = sm;

	sm = [NSMenu new];
	[sm setTitle:@"View"];
	item = [sm addItemWithTitle:@"Toggle Full Screen" action:@selector(toggleFullScreen:) keyEquivalent:@"f"];
	[item setKeyEquivalentModifierMask:(NSEventModifierFlagCommand | NSEventModifierFlagControl)];
	[m itemWithTitle:@"View"].submenu = sm;

	sm = [NSMenu new];
	[sm setTitle:@"Window"];
	[sm addItemWithTitle:@"Minimize" action:@selector(miniaturize:) keyEquivalent:@"m"];
	[sm addItemWithTitle:@"Zoom" action:@selector(zoom:) keyEquivalent:@""];
	[m itemWithTitle:@"Window"].submenu = sm;

	[NSApp setMainMenu:m];
	[NSMenu setMenuBarVisible:YES];

	d = [[NSData alloc] initWithBytes:doc_png length:(sizeof doc_png)];
	i = [[NSImage alloc] initWithData:d];
	[NSApp setApplicationIconImage:i];
	[[NSApp dockTile] display];

	initcpu();

/*
	[NSThread
		detachNewThreadSelector:@selector(callservep9p:)
		toTarget:[self class] withObject:nil];
*/
}

- (NSApplicationPresentationOptions)window:(id)arg
		willUseFullScreenPresentationOptions:(NSApplicationPresentationOptions)proposedOptions {
	NSApplicationPresentationOptions o;
	o = proposedOptions;
	o &= ~(NSApplicationPresentationAutoHideDock | NSApplicationPresentationAutoHideMenuBar);
	o |= NSApplicationPresentationHideDock | NSApplicationPresentationHideMenuBar;
	return o;
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)theApplication {
	return YES;
}

@end

@implementation DevDrawView
{
	NSMutableString *_tmpText;
	NSRange _markedRange;
	NSRange _selectedRange;
	NSRect _lastInputRect;	// The view is flipped, this is not.
	BOOL _tapping;
	NSUInteger _tapFingers;
	NSUInteger _tapTime;
}

- (id)init
{
	LOG(@"View init");
	self = [super init];
	[self setAllowedTouchTypes:NSTouchTypeMaskDirect|NSTouchTypeMaskIndirect];
	_tmpText = [[NSMutableString alloc] initWithCapacity:2];
	_markedRange = NSMakeRange(NSNotFound, 0);
	_selectedRange = NSMakeRange(0, 0);
	return self;
}

- (CALayer *)makeBackingLayer { return [DrawLayer layer]; }
- (BOOL)wantsUpdateLayer { return YES; }
- (BOOL)isOpaque { return YES; }
- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }

- (void)windowDidResize:(NSNotification *)notification
{
	if(![self inLiveResize] && img) {
		resizeimg();
	}
}

- (void)windowDidBecomeKey:(NSNotification *)notification
{
	CGPoint q;
	Point sp;

	q = [self.window convertPointToBacking:
		[self.window mouseLocationOutsideOfEventStream]];
	sp = Pt(round(q.x/scaleimg), Dy(mouserect) - round(q.y/scaleimg));
	LOGG("(%g, %g) <- windowDidBecomeKey (%d, %d)\n)", q.x, q.y, sp.x, sp.y);
	mousetrack(sp.x, sp.y, 0, msec());

	[self sendmouse:0];
}

- (void)windowDidResignKey:(id)arg
{
	abortcompose();
}

/* attemp to solve refresh error in macOS 13 beta */
- (void)windowDidEnterFullScreen:(NSNotification *)notification;
{
	self.needsDisplay = YES;
}

- (void)windowDidExitFullScreen:(NSNotification *)notification;
{
	self.needsDisplay = YES;
}

- (void)topwin {
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)mouseMoved:(NSEvent*)e{ [self getmouse:e];}
- (void)mouseDown:(NSEvent*)e{ [self getmouse:e];}
- (void)mouseDragged:(NSEvent*)e{ [self getmouse:e];}
- (void)mouseUp:(NSEvent*)e{ [self getmouse:e];}
- (void)otherMouseDown:(NSEvent*)e{ [self getmouse:e];}
- (void)otherMouseDragged:(NSEvent*)e{ [self getmouse:e];}
- (void)otherMouseUp:(NSEvent*)e{ [self getmouse:e];}
- (void)rightMouseDown:(NSEvent*)e{ [self getmouse:e];}
- (void)rightMouseDragged:(NSEvent*)e{ [self getmouse:e];}
- (void)rightMouseUp:(NSEvent*)e{ [self getmouse:e];}

- (void)scrollWheel:(NSEvent*)e
{
	NSInteger s;

	s = [e scrollingDeltaY];
	if(s > 0)
		[self sendmouse:8];
	else if (s < 0)
		[self sendmouse:16];
}

- (void)keyDown:(NSEvent*)e
{
	LOG(@"keyDown to interpret");

	[self interpretKeyEvents:[NSArray arrayWithObject:e]];

	[self resetLastInputRect];
}

- (void)flagsChanged:(NSEvent*)e
{
	static NSEventModifierFlags omod;
	NSEventModifierFlags m;
	uint b;

	LOG(@"flagsChanged");
	m = [e modifierFlags];

	b = [NSEvent pressedMouseButtons];
	b = (b&~6) | (b&4)>>1 | (b&2)<<1;
	if(b){
		if(m & ~omod & NSEventModifierFlagControl)
			b |= 1;
		if(m & ~omod & NSEventModifierFlagOption)
			b |= 2;
		if(m & ~omod & NSEventModifierFlagCommand)
			b |= 4;
		[self sendmouse:b];
	}else if(m & ~omod & NSEventModifierFlagOption)
		keystroke(Kalt);

	omod = m;
}

- (void)magnifyWithEvent:(NSEvent*)e
{
	if(fabs([e magnification]) > 0.02)
		[[self window] toggleFullScreen:nil];
}

- (void)touchesBeganWithEvent:(NSEvent*)e
{
	_tapping = YES;
	_tapFingers = [e touchesMatchingPhase:NSTouchPhaseTouching inView:nil].count;
	_tapTime = msec();
}
- (void)touchesMovedWithEvent:(NSEvent*)e
{
	_tapping = NO;
}
- (void)touchesEndedWithEvent:(NSEvent*)e
{
	if(_tapping
		&& [e touchesMatchingPhase:NSTouchPhaseTouching inView:nil].count == 0
		&& msec() - _tapTime < 250){
		switch(_tapFingers){
		case 3:
			[self sendmouse:2];
			[self sendmouse:0];
			break;
		case 4:
			[self sendmouse:2];
			[self sendmouse:1];
			[self sendmouse:0];
			break;
		}
		_tapping = NO;
	}
}
- (void)touchesCancelledWithEvent:(NSEvent*)e
{
	_tapping = NO;
}

- (void)getmouse:(NSEvent *)e
{
	NSUInteger b;
	NSEventModifierFlags m;

	b = [NSEvent pressedMouseButtons];
	b = (b&~6) | (b&4)>>1 | (b&2)<<1;
	b = mouseswap(b);

	if(b == 1){
		m = [e modifierFlags];
		if(m & NSEventModifierFlagOption){
			abortcompose();
			b = 2;
		}else
		if(m & NSEventModifierFlagCommand)
			b = 4;
	}
	[self sendmouse:b];
}

- (void)sendmouse:(NSUInteger)b
{
	NSPoint q;
	Point sp;

	q = [self.window convertPointToBacking:
		[self.window mouseLocationOutsideOfEventStream]];
	sp = Pt(round(q.x/scaleimg), Dy(mouserect) - round(q.y/scaleimg));
    if (ptinrect(sp, mouserect)) {
		Point p, dp;
		p = mousexy();
		dp = Pt(sp.x - p.x, sp.y - p.y);
		LOGM("(%g, %g) <- sendmouse(%d)", q.x, q.y, (uint)b);
		LOGM(" -> (%d, %d)\n", sp.x, sp.y);
		LOGM("	(%d, %d) <- mousetrack(%lu)\n", dp.x, dp.y, b);
		mousetrack(dp.x, dp.y, b, msec());
    }

	if(b && _lastInputRect.size.width && _lastInputRect.size.height)
		[self resetLastInputRect];
}

- (void)setmouse:(Point)p {
	@autoreleasepool{
		NSPoint q, sp;
		
		sp = NSMakePoint(p.x*scaleimg, (Dy(mouserect) - p.y)*scaleimg);
		
		LOGM("setmouse(%d,%d) <- (%g,%g)\n", p.x, p.y, sp.x, sp.y);
		q = [self.window convertPointFromBacking:sp];
		LOGM("	(%g, %g) <- fromBacking[win]\n", q.x, q.y);
		q = [self.window convertPointToScreen:q];
		LOGM("	(%g, %g) <- toScreen\n", q.x, q.y);
		// Quartz has the origin of the "global display
		// coordinate space" at the top left of the primary
		// screen with y increasing downward, while Cocoa has
		// the origin at the bottom left of the primary screen
		// with y increasing upward.  We flip the coordinate
		// with a negative sign and shift upward by the height
		// of the primary screen.
		q.y = NSScreen.screens[0].frame.size.height - q.y;
		LOGM("	(%g, %g) <- warpMouse\n", q.x, q.y);
		CGWarpMouseCursorPosition(NSPointToCGPoint(q));
		CGAssociateMouseAndMouseCursorPosition(true);
	}
}

- (void)resetCursorRects {
	[super resetCursorRects];
	[self addCursorRect:self.bounds cursor:currentCursor];
}

- (void)viewDidEndLiveResize
{
	[super viewDidEndLiveResize];
	if(img)
		resizeimg();
}

- (void)viewDidChangeBackingProperties
{
	[super viewDidChangeBackingProperties];
	if(img)
		resizeimg();
}

// conforms to protocol NSTextInputClient
- (BOOL)hasMarkedText
{
	LOG(@"hasMarkedText");
	return _markedRange.location != NSNotFound;
}
- (NSRange)markedRange
{
	LOG(@"markedRange");
	return _markedRange;
}
- (NSRange)selectedRange
{
	LOG(@"selectedRange");
	return _selectedRange;
}
- (void)setMarkedText:(id)string
	selectedRange:(NSRange)sRange
	replacementRange:(NSRange)rRange
{
	NSString *str;

	LOG(@"setMarkedText: %@ (%ld, %ld) (%ld, %ld)", string,
		sRange.location, sRange.length,
		rRange.location, rRange.length);

	[self clearInput];

	if([string isKindOfClass:[NSAttributedString class]])
		str = [string string];
	else
		str = string;

	if(rRange.location == NSNotFound){
		if(_markedRange.location != NSNotFound){
			rRange = _markedRange;
		}else{
			rRange = _selectedRange;
		}
	}

	if(str.length == 0){
		[_tmpText deleteCharactersInRange:rRange];
		[self unmarkText];
	}else{
		_markedRange = NSMakeRange(rRange.location, str.length);
		[_tmpText replaceCharactersInRange:rRange withString:str];
	}
	_selectedRange.location = rRange.location + sRange.location;
	_selectedRange.length = sRange.length;

	if(_tmpText.length){
		uint i;
		LOG(@"text length %ld", _tmpText.length);
		for(i = 0; i <= _tmpText.length; ++i){
			if(i == _markedRange.location)
				keystroke('[');
			if(_selectedRange.length){
				if(i == _selectedRange.location)
					keystroke('{');
				if(i == NSMaxRange(_selectedRange))
					keystroke('}');
				}
			if(i == NSMaxRange(_markedRange))
				keystroke(']');
			if(i < _tmpText.length)
				keystroke([_tmpText characterAtIndex:i]);
		}
		int l;
		l = 1 + _tmpText.length - NSMaxRange(_selectedRange)
			+ (_selectedRange.length > 0);
		LOG(@"move left %d", l);
		for(i = 0; i < l; ++i)
			keystroke(Kleft);
	}

	LOG(@"text: \"%@\"  (%ld,%ld)  (%ld,%ld)", _tmpText,
		_markedRange.location, _markedRange.length,
		_selectedRange.location, _selectedRange.length);
}
- (void)unmarkText
{
	//NSUInteger i;
	NSUInteger len;

	LOG(@"unmarkText");
	len = [_tmpText length];
	//for(i = 0; i < len; ++i)
	//	keystroke([_tmpText characterAtIndex:i]);
	[_tmpText deleteCharactersInRange:NSMakeRange(0, len)];
	_markedRange = NSMakeRange(NSNotFound, 0);
	_selectedRange = NSMakeRange(0, 0);
}
- (NSArray<NSAttributedStringKey> *)validAttributesForMarkedText
{
	LOG(@"validAttributesForMarkedText");
	return @[];
}
- (NSAttributedString *)attributedSubstringForProposedRange:(NSRange)r
	actualRange:(NSRangePointer)actualRange
{
	NSRange sr;
	NSAttributedString *s;

	LOG(@"attributedSubstringForProposedRange: (%ld, %ld) (%ld, %ld)",
		r.location, r.length, actualRange->location, actualRange->length);
	sr = NSMakeRange(0, [_tmpText length]);
	sr = NSIntersectionRange(sr, r);
	if(actualRange)
		*actualRange = sr;
	LOG(@"use range: %ld, %ld", sr.location, sr.length);
	if(sr.length)
		s = [[NSAttributedString alloc]
			initWithString:[_tmpText substringWithRange:sr]];
	LOG(@"	return %@", s);
	return s;
}
- (void)insertText:(id)s
	replacementRange:(NSRange)r
{
	NSUInteger i;
	NSUInteger len;

	LOG(@"insertText: %@ replacementRange: %ld, %ld", s, r.location, r.length);

	[self clearInput];

	len = [s length];
	for(i = 0; i < len; ++i)
		keystroke([s characterAtIndex:i]);
	[_tmpText deleteCharactersInRange:NSMakeRange(0, _tmpText.length)];
	_markedRange = NSMakeRange(NSNotFound, 0);
	_selectedRange = NSMakeRange(0, 0);
}
- (NSUInteger)characterIndexForPoint:(NSPoint)point
{
	LOG(@"characterIndexForPoint: %g, %g", point.x, point.y);
	return 0;
}
- (NSRect)firstRectForCharacterRange:(NSRange)r
	actualRange:(NSRangePointer)actualRange
{
	LOG(@"firstRectForCharacterRange: (%ld, %ld) (%ld, %ld)",
		r.location, r.length, actualRange->location, actualRange->length);
	if(actualRange)
		*actualRange = r;
	return [[self window] convertRectToScreen:_lastInputRect];
}
- (void)doCommandBySelector:(SEL)s
{
	NSEvent *e;
	NSEventModifierFlags m;
	uint c, k;

	LOG(@"doCommandBySelector (%@)", NSStringFromSelector(s));

	e = [NSApp currentEvent];
	m = [e modifierFlags];
	c = [[e characters] characterAtIndex:0];

	if(m & NSEventModifierFlagControl)
		k = c;
	else
		k = keycvt(c);

	LOG(@"keyDown: character0: 0x%x -> 0x%x", c, k);
	// printf("keyDown: character0: 0x%x -> 0x%x", c, k);
	// printf("\tkeyCode: 0x%x\n", [e keyCode]);

	if(m & NSEventModifierFlagCommand){
		if((m & NSEventModifierFlagShift) && 'a' <= k && k <= 'z')
			k += 'A' - 'a';
		if(' '<=k && k<='~')
			k += Kcmd;
	}
	if(k>0)
		keystroke(k);
}

// Helper for managing input rect approximately
- (void)resetLastInputRect
{
	LOG(@"resetLastInputRect");
	_lastInputRect.origin.x = 0.0;
	_lastInputRect.origin.y = 0.0;
	_lastInputRect.size.width = 0.0;
	_lastInputRect.size.height = 0.0;
}

- (void)enlargeLastInputRect:(NSRect)r
{
	r.origin.y = [self bounds].size.height - r.origin.y - r.size.height;
	_lastInputRect = NSUnionRect(_lastInputRect, r);
	LOG(@"update last input rect (%g, %g, %g, %g)",
		_lastInputRect.origin.x, _lastInputRect.origin.y,
		_lastInputRect.size.width, _lastInputRect.size.height);
}

- (void)clearInput
{
	if(_tmpText.length){
		uint i;
		int l;
		l = 1 + _tmpText.length - NSMaxRange(_selectedRange)
			+ (_selectedRange.length > 0);
		LOG(@"move right %d", l);
		for(i = 0; i < l; ++i)
			keystroke(Kright);
		l = _tmpText.length+2+2*(_selectedRange.length > 0);
		LOG(@"backspace %d", l);
		for(uint i = 0; i < l; ++i)
			keystroke(Kbs);
	}
}

@end

@implementation DrawLayer

- (void)display
{
	LOG(@"display");
	LOG(@"display query drawable");

@autoreleasepool{
	id<CAMetalDrawable> drawable;

	drawable = [layer nextDrawable];
	if(!drawable){
		LOG(@"display couldn't get drawable");
		[self setNeedsDisplay];
		return;
	}

	LOG(@"display got drawable");
	
	id<MTLCommandBuffer> cbuf = [self.cmd commandBuffer];
	id<MTLBlitCommandEncoder> blit = [cbuf blitCommandEncoder];
	[blit copyFromTexture:texture
		sourceSlice:0
		sourceLevel:0
		sourceOrigin:MTLOriginMake(0, 0, 0)
		sourceSize:MTLSizeMake(texture.width, texture.height, texture.depth)
		toTexture:drawable.texture
		destinationSlice:0
		destinationLevel:0
		destinationOrigin:MTLOriginMake(0, 0, 0)];
	[blit endEncoding];

	[cbuf presentDrawable:drawable];
	drawable = nil;
	[cbuf addCompletedHandler:^(id<MTLCommandBuffer> cmdBuff){
		if(cmdBuff.error){
			NSLog(@"command buffer finished with error: %@",
				cmdBuff.error.localizedDescription);
		}else
			LOG(@"command buffer finishes present drawable");
	}];
	[cbuf commit];
	}
	LOG(@"display commit");
}

@end

static uint
msec(void)
{
	return nsec()/1000000;
}

static uint
keycvt(uint code)
{
	switch(code){
	case '\r':
	case KEY_KPENTER:
	case 0x3:
			return '\n';
	case 127: return '\b';
	case NSUpArrowFunctionKey: return Kup;
	case NSDownArrowFunctionKey: return Kdown;
	case NSLeftArrowFunctionKey: return Kleft;
	case NSRightArrowFunctionKey: return Kright;
	case NSInsertFunctionKey: return Kins;
	case NSDeleteFunctionKey: return Kdel;
	case NSHomeFunctionKey: return Khome;
	case NSEndFunctionKey: return Kend;
	case NSPageUpFunctionKey: return Kpgup;
	case NSPageDownFunctionKey: return Kpgdown;
	case NSF1FunctionKey: return KF|1;
	case NSF2FunctionKey: return KF|2;
	case NSF3FunctionKey: return KF|3;
	case NSF4FunctionKey: return KF|4;
	case NSF5FunctionKey: return KF|5;
	case NSF6FunctionKey: return KF|6;
	case NSF7FunctionKey: return KF|7;
	case NSF8FunctionKey: return KF|8;
	case NSF9FunctionKey: return KF|9;
	case NSF10FunctionKey: return KF|10;
	case NSF11FunctionKey: return KF|11;
	case NSF12FunctionKey: return KF|12;
	case NSBeginFunctionKey:
	case NSPrintScreenFunctionKey:
	case NSScrollLockFunctionKey:
	case NSF13FunctionKey:
	case NSF14FunctionKey:
	case NSF15FunctionKey:
	case NSF16FunctionKey:
	case NSF17FunctionKey:
	case NSF18FunctionKey:
	case NSF19FunctionKey:
	case NSF20FunctionKey:
	case NSF21FunctionKey:
	case NSF22FunctionKey:
	case NSF23FunctionKey:
	case NSF24FunctionKey:
	case NSF25FunctionKey:
	case NSF26FunctionKey:
	case NSF27FunctionKey:
	case NSF28FunctionKey:
	case NSF29FunctionKey:
	case NSF30FunctionKey:
	case NSF31FunctionKey:
	case NSF32FunctionKey:
	case NSF33FunctionKey:
	case NSF34FunctionKey:
	case NSF35FunctionKey:
	case NSPauseFunctionKey:
	case NSSysReqFunctionKey:
	case NSBreakFunctionKey:
	case NSResetFunctionKey:
	case NSStopFunctionKey:
	case NSMenuFunctionKey:
	case NSUserFunctionKey:
	case NSSystemFunctionKey:
	case NSPrintFunctionKey:
	case NSClearLineFunctionKey:
	case NSClearDisplayFunctionKey:
	case NSInsertLineFunctionKey:
	case NSDeleteLineFunctionKey:
	case NSInsertCharFunctionKey:
	case NSDeleteCharFunctionKey:
	case NSPrevFunctionKey:
	case NSNextFunctionKey:
	case NSSelectFunctionKey:
	case NSExecuteFunctionKey:
	case NSUndoFunctionKey:
	case NSRedoFunctionKey:
	case NSFindFunctionKey:
	case NSHelpFunctionKey:
	case NSModeSwitchFunctionKey: return 0;
	default: return code;
	}
}

Memimage*
_attachscreen(char *label, char *winsize)
{
	LOGG("_attachscreen(%s, %s\n)", label, winsize);
	[AppDelegate
		performSelectorOnMainThread:@selector(makewin:)
		withObject:[NSValue valueWithPointer:winsize]
		waitUntilDone:YES];
	kicklabel(label);
	setcursors(nil, nil);
	mouseresized = 0;
	return initimg();
}

uchar *
attachscreen(Rectangle *r, ulong *chan, int *depth, int *width, int *softscreen, void **X)
{
	if(gscreen == nil){
		screeninit();
		if(gscreen == nil)
			panic("cannot create macOS screen");
	}

	if(X != nil)
		*X = gscreen->X;

	LOGG("attachscreen %d %d %d %d\n",
		gscreen->r.min.x, gscreen->r.min.y, Dx(gscreen->r), Dy(gscreen->r));
	*r = gscreen->r;
	*chan = gscreen->chan;
	*depth = gscreen->depth;
	*width = gscreen->width;
	*softscreen = 1;

	return gscreen->data->bdata;
}

/*
 * The bitmap fonts used in rio's rasterizaton were set up to be correct at
 * 72ppi e.g., /lib/font/bit/pelm/unicode.9.font is only displayed as a 9pt
 * font when rendered based on 72ppi.  Using a scaling of 1.333 (96/72) gets
 * close to the visual representation on old CRTs and normal viewing.  That
 * effectively makes the display size a 12pt font and does not bring out too
 * many additional artifacts.
 */

static Memimage*
initimg(void)
{
@autoreleasepool{
	NSDictionary *description = [[win screen] deviceDescription];
	NSSize devSize = [[description objectForKey:NSDeviceSize] sizeValue];
	CGSize scrSize = CGDisplayScreenSize(
            [[description objectForKey:@"NSScreenNumber"] unsignedIntValue]);
	CGFloat ppi = devSize.width / (scrSize.width / 25.4f);  // scrSize is mm
	NSSize bounds, size, scaledSize;
	MTLTextureDescriptor *textureDesc;

	LOGG("devSize(%g,%g) screenSize(%g,%g)\n", devSize.width, devSize.height, scrSize.width, scrSize.height);

	bounds = [myContent bounds].size;

	if([win backingScaleFactor] == 1.0) {
		displaydpi = 72;
		scaleimg = 96.0f / 72.0f;
		size = [myContent bounds].size;
	} else {
		displaydpi = ppi;
		scaleimg = ppi / 72.0f;
		size = [myContent convertSizeToBacking:[myContent bounds].size];
	}
	scaledSize = NSMakeSize(round(size.width / scaleimg), round(size.height / scaleimg));
	LOGG("sizes: bounds(%g, %g) size(%g, %g), scaledSize(%g, %g)\n",
		bounds.width, bounds.height, size.width, size.height, scaledSize.width, scaledSize.height);

	LOGM("mouserect: size(%.0f, %.0f) -> scaled(%.1f, %.1f)\n", size.width, size.height, scaledSize.width, scaledSize.height);
	mouserect = Rect(0, 0, scaledSize.width, scaledSize.height);

	LOGG("allocmemimage(%d,%d)\n", Dx(mouserect), Dy(mouserect));
	img = allocmemimage(mouserect, XRGB32);
	if(img == nil)
		panic("allocmemimage: %r");
	if(img->data == nil)
		panic("img->data == nil");

	textureDesc = [MTLTextureDescriptor
		texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
		width:scaledSize.width
		height:scaledSize.height
		mipmapped:NO];
	textureDesc.allowGPUOptimizedContents = YES;
	textureDesc.usage = MTLTextureUsageShaderRead;
	textureDesc.cpuCacheMode = MTLCPUCacheModeWriteCombined;
	texture = [device newTextureWithDescriptor:textureDesc];

	[layer setDrawableSize:scaledSize];
	[layer setContentsScale:scaleimg];

	LOGG("backingScaleFactor: %g -> %g\n", [win.screen backingScaleFactor], scaleimg);
	LOGG("display: (ppi %f)\n", ppi);
}
	LOG(@"initimg return");

	return img;
}

void
resizeimg(void)
{
	zlock();
	gscreen = initimg();
	
	termreplacescreenimage(gscreen);
	drawreplacescreenimage(gscreen);

	mouseresized = 1;
	zunlock();
	flushmemscreen(mouserect);
	myContent.needsDisplay = YES;
	[myContent sendmouse:0];
}

void
flushmemscreen(Rectangle r)
{
	LOG(@"flushmemscreen(%d,%d,%d,%d)", r.min.x, r.min.y, Dx(r), Dy(r));
	if(!rectinrect(r, Rect(0, 0, texture.width, texture.height))){
		LOG(@"Rectangle is out of bounds, return.");
		return;
	}

	@autoreleasepool{
		[texture
			replaceRegion:MTLRegionMake2D(r.min.x, r.min.y, Dx(r), Dy(r))
			mipmapLevel:0
			withBytes:byteaddr(img, Pt(r.min.x, r.min.y))
			bytesPerRow:img->width*sizeof(u32int)];
		[AppDelegate
			performSelectorOnMainThread:@selector(callsetNeedsDisplayInRect:)
			withObject:[NSValue valueWithRect:NSMakeRect(r.min.x, r.min.y, Dx(r), Dy(r))]
			waitUntilDone:NO];
	}
}

char*
getsnarf(void)
{
	NSPasteboard *pb;
	NSString *s;

	@autoreleasepool{
		pb = [NSPasteboard generalPasteboard];

		qlock(&snarfl);
		s = [pb stringForType:NSPasteboardTypeString];
		qunlock(&snarfl);

		if(s)
			return strdup((char *)[s UTF8String]);
		else
			return nil;
	}
}

void
putsnarf(char *s)
{
	NSArray *t;
	NSPasteboard *pb;
	NSString *str;

	if(strlen(s) >= SnarfSize)
		return;

	@autoreleasepool{
		t = [NSArray arrayWithObject:NSPasteboardTypeString];
		pb = [NSPasteboard generalPasteboard];
		str = [[NSString alloc] initWithUTF8String:s];

		qlock(&snarfl);
		[pb declareTypes:t owner:nil];
		[pb setString:str forType:NSPasteboardTypeString];
		qunlock(&snarfl);
	}
}

void
kicklabel(char *label)
{
	NSString *s;

	LOG(@"kicklabel(%s)", label);
	if(label == nil)
		return;

	@autoreleasepool{
		s = [[NSString alloc] initWithUTF8String:label];
		[AppDelegate
			performSelectorOnMainThread:@selector(callkicklabel:)
			withObject:s
			waitUntilDone:NO];
	}
}

void
setcursors(Cursor *c, Cursor2 *c2)
{
	Cursors cs;
	
	cs.c = c;
	cs.c2 = c2;

	[AppDelegate
		performSelectorOnMainThread:@selector(callsetcursor:)
		withObject:[NSValue valueWithPointer:&cs]
		waitUntilDone:YES];
}

static NSCursor*
makecursor(Cursor *c)
{
	NSBitmapImageRep *r;
	NSCursor *d;
	NSImage *i;
	NSPoint p;
	int b;
	uchar *plane[5];

@autoreleasepool{
	r = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
		pixelsWide:16
		pixelsHigh:16
		bitsPerSample:1
		samplesPerPixel:2
		hasAlpha:YES
		isPlanar:YES
		colorSpaceName:NSCalibratedWhiteColorSpace
		bytesPerRow:2
		bitsPerPixel:1];

	[r getBitmapDataPlanes:plane];

	for(b=0; b<2*16; b++){
		plane[0][b] = c->set[b] ^ 0xFF;
		plane[1][b] = c->set[b] | c->clr[b];
	}

	p = NSMakePoint(-c->offset.x, -c->offset.y);

	i = [[NSImage alloc] initWithSize:NSMakeSize(16, 16)];
	[i addRepresentation:r];

	d = [[NSCursor alloc] initWithImage:i hotSpot:p];
	return d;
	}
}

void
topwin(void)
{
	if(myContent != nil)
		dispatch_sync(dispatch_get_main_queue(), ^(void) {
			[myContent topwin];
		});
	else
		panic("topwin: no view");
}

void
screeninit(void)
{
	/*
	 * Create window in main thread, else no cursor
	 * change while resizing.
	 */
	[AppDelegate performSelectorOnMainThread:@selector(makewin:)
							 	  withObject:nil
							   waitUntilDone:YES];

	memimageinit();
	setcursors(nil, nil);
	mouseresized = 0;
	gscreen = initimg();
	terminit();
}

// PAL - no palette handling.  Don't intend to either.
void
getcolor(ulong i, ulong *r, ulong *g, ulong *b)
{
	LOG(@"getcolor %d", i);
// PAL: Certainly wrong to return a grayscale.
	 *r = i;
	 *g = i;
	 *b = i;
}

void
setcolor(ulong index, ulong red, ulong green, ulong blue)
{
	assert(0);
}

void
mousectl(Cmdbuf *cb)
{
	NSLog(@"mousectl");
}

void
mouseset(Point xy)
{
	NSPoint p, q;

	p = [win mouseLocationOutsideOfEventStream];
	q = [win.contentView convertPoint:p fromView:nil];
	
	LOGM("mouseset (%d,%d) <- (%g,%g)\n", xy.x, xy.y, q.x, q.y);
	if(win.isKeyWindow /* && !eqpt(xy, m) */) {
		LOGM("	(%g, %g) <- outside\n", p.x, p.y);
		LOGM("	(%g, %g) <- content\n", q.x, q.y);
		dispatch_async(dispatch_get_main_queue(), ^(void){
			[myContent setmouse:xy];  // was Pt(q.x, q.y)
		});
	}
}

char*
clipread(void)
{
	return getsnarf();
}

int
clipwrite(char *snarf)
{
	putsnarf(snarf);
	return 0;
}

void
resizewindow(Rectangle r)
{
	LOG(@"resizewindow %d %d %d %d", r.min.x, r.min.y, Dx(r), Dy(r));
	dispatch_async(dispatch_get_main_queue(), ^(void){
		NSSize s;

		s = [myContent convertSizeFromBacking:NSMakeSize(Dx(r), Dy(r))];
		[win setContentSize:s];
	});
}

/* required bits to be shared in cocoa-srv.c */

int
cursoron(int dolock)
{
	Point p;
	LOGM("cursoron(%d)\n", dolock);
	if(dolock)
		lock(&cursor.lk);
	p = mousexy();
	mouseset(p);
	if(dolock)
		unlock(&cursor.lk);
	return 0;
}

void
cursoroff(int d)
{
//	Point p = mousexy();
//	LOGM("cursoroff(%d) <- (%d,%d)\n", d, p.x, p.y);
}

void
setcursor(Cursor *c)
{
	@autoreleasepool{
		currentCursor = makecursor(c);
		[win invalidateCursorRectsForView:myContent];
	}
}

QLock lk;
void
zlock(void)
{
	qlock(&lk);
}

void
zunlock(void)
{
	qunlock(&lk);
}
