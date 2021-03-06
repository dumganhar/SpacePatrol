/* Copyright (c) 2012 Scott Lembcke and Howling Moon Software
 * 
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 * 
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 * 
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 */

#import <CoreMotion/CoreMotion.h>

#import "SpacePatrolLayer.h"
#import "ChipmunkAutoGeometry.h"
#import "ChipmunkDebugNode.h"

#import "Physics.h"
#import "DeformableTerrainSprite.h"
#import "SpaceBuggy.h"

enum Z_ORDER {
	Z_WORLD,
	Z_TERRAIN,
	Z_BUGGY,
	Z_EFFECTS,
	Z_DEBUG,
	Z_MENU,
};


@implementation SpacePatrolLayer {
	// Used for grabbing the accelerometer data
	CMMotionManager *_motionManager;
	
	// The Chipmunk space for the physics simulation.
	ChipmunkSpace *_space;
	// Manages multi-touch grabbable objects.
	ChipmunkMultiGrab *_multiGrab;
	
	// The debug node for drawing the the physics debug overlay.
	ChipmunkDebugNode *_debugNode;
	// The menu buttons for controlling the car.
	CCMenuItemSprite *_goButton, *_stopButton;
	
	// The CCNode that we'll be adding the terrain and car to.
	CCNode *_world;
	// The custom "sprite" that draws the terrain and parallax background.
	DeformableTerrainSprite *_terrain;
	
	// The current UITouch object we are tracking to deform the terrain.
	UITouch *_currentDeformTouch;
	// True if we are digging dirt, false if we are filling
	BOOL _currentDeformTouchRemoves;
	// Location of the last place we deformed the terrain to avoid duplicates
	CGPoint _lastDeformLocation;
	
	// The all important Super Space Ranger certified space buggy.
	SpaceBuggy *_spaceBuggy;
	
	// Timer values for implementing a fixed timestep for the physics.
	ccTime _accumulator, _fixedTime;
}

+(CCScene *)scene
{
	CCScene *scene = [CCScene node];
	[scene addChild: [self node]];
	
	return scene;
}

-(id)init
{
	if((self = [super init])){
		_world = [CCNode node];
		[self addChild:_world z:Z_WORLD];
		
		_space = [[ChipmunkSpace alloc] init];
		_space.gravity = cpv(0.0f, -GRAVITY);
		
		_multiGrab = [[ChipmunkMultiGrab alloc] initForSpace:_space withSmoothing:cpfpow(0.8, 60) withGrabForce:1e4];
		// Set a grab radius so that you don't have to touch a shape *exactly* in order to pick it up.
		_multiGrab.grabRadius = 50.0;
		
		_terrain = [[DeformableTerrainSprite alloc] initWithFile:@"Terrain.png" space:_space texelScale:32.0 tileSize:16];
		[_world addChild:_terrain z:Z_TERRAIN];
		
		{
			// We need to find the terrain's ground level so we can drop the buggy at the surface.
			// You can't use a raycast because there is no geometry in space until the tile cache adds it.
			// Instead, we'll sample upwards along the terrain's density to find somewhere where the density is low (where there isn't dirt).
			cpVect pos = cpv(300, 0.0);
			while([_terrain.sampler sample:pos] > 0.5) pos.y += 10.0;
			
			// Add the car just above that level.
			_spaceBuggy = [[SpaceBuggy alloc] initWithPosition:cpvadd(pos, cpv(0, 30))];
			[_world addChild:_spaceBuggy.node z:Z_BUGGY];
			[_space add:_spaceBuggy];
		}
		
		// Add a ChipmunkDebugNode to draw the space.
		_debugNode = [ChipmunkDebugNode debugNodeForChipmunkSpace:_space];
		[_world addChild:_debugNode z:Z_DEBUG];
		_debugNode.visible = FALSE;
		
		// Show some menu buttons.
		CCMenuItemLabel *reset = [CCMenuItemLabel itemWithLabel:[CCLabelTTF labelWithString:@"Reset" fontName:@"Helvetica" fontSize:20] block:^(id sender){
			[[CCDirector sharedDirector] replaceScene:[[SpacePatrolLayer class] scene]];
		}];
		reset.position = ccp(50, 300);
		
		CCMenuItemLabel *showDebug = [CCMenuItemLabel itemWithLabel:[CCLabelTTF labelWithString:@"Show Debug" fontName:@"Helvetica" fontSize:20] block:^(id sender){
			_debugNode.visible ^= TRUE;
		}];
		showDebug.position = ccp(400, 300);
		
		_goButton = [CCMenuItemSprite itemWithNormalSprite:[CCSprite spriteWithFile:@"Button.png"] selectedSprite:[CCSprite spriteWithFile:@"Button.png"]];
		_goButton.selectedImage.color = ccc3(128, 128, 128);
		_goButton.position = ccp(480 - 50, 50);
		
		_stopButton = [CCMenuItemSprite itemWithNormalSprite:[CCSprite spriteWithFile:@"Button.png"] selectedSprite:[CCSprite spriteWithFile:@"Button.png"]];
		_stopButton.selectedImage.color = ccc3(128, 128, 128);
		_stopButton.scaleX = -1.0;
		_stopButton.position = ccp(50, 50);
		
		CCMenu *menu = [CCMenu menuWithItems:reset, showDebug, _goButton, _stopButton, nil];
		menu.position = CGPointZero;
		[self addChild:menu z:Z_MENU];
		
		self.isTouchEnabled = TRUE;
	}
	
	return self;
}

-(void)onEnter
{
	_motionManager = [[CMMotionManager alloc] init];
	_motionManager.accelerometerUpdateInterval = [CCDirector sharedDirector].animationInterval;
	[_motionManager startAccelerometerUpdates];
	
	[self scheduleUpdate];
	[super onEnter];
}

-(void)onExit
{
	[_motionManager stopAccelerometerUpdates];
	_motionManager = nil;
	
	[super onExit];
}

// A "tick" is a single fixed time-step
// This method is called 240 times per second.
-(void)tick:(ccTime)fixed_dt
{
	// Only terrain geometry that exists inside this "ensure" rect is guaranteed to exist.
	// This keeps the memory and CPU usage very low for the terrain by allowing it to focus only on the important areas.
	// Outside of this rect terrain geometry is not guaranteed to be current or exist at all.
	// I made this rect slightly smaller than the screen so you can see it adding terrain chunks if you turn on debug rendering.
	[_terrain.tiles ensureRect:cpBBNewForCircle(_spaceBuggy.pos, 200)];
	
	// Warning: A mistake I made initially was to ensure the screen's rect, instead of the area around the car.
	// This was bad because the view isn't centered on the car until after the physics is run.
	// If the framerate stuttered enough (like during the first frame or two) the buggy could move out of the ensured rect.
	// It would fall right through terrain that never had collision geometry generated for it.
	
	// Update the throttle values on the space buggy's motors.
	int throttle = _goButton.isSelected - _stopButton.isSelected;
	[_spaceBuggy update:fixed_dt throttle:throttle];
	
	[_space step:fixed_dt];
}

-(void)updateGravity
{
#if TARGET_IPHONE_SIMULATOR
	// The accelerometer always returns (0, 0, 0) on the simulator which is unhelpful.
	// Let's hardcode it to be always down instead.
	CMAcceleration gravity = {-1, 0, 0};
#else
	CMAcceleration gravity = _motionManager.accelerometerData.acceleration;
#endif
	
	_space.gravity = cpvmult(cpv(-gravity.y, gravity.x), GRAVITY);
}

-(CGPoint)touchLocation:(UITouch *)touch
{
	return [_terrain convertTouchToNodeSpace:_currentDeformTouch];
}

-(void)modifyTerrain
{
	if(!_currentDeformTouch) return;
	
	CGFloat radius = 100.0;
	CGFloat threshold = 0.025*radius;
	
	// UITouch objects are persistent and continue to be updated for as long as the touch is occuring.
	// This is handy because we can conveniently poll a touch's location.
	CGPoint location = [self touchLocation:_currentDeformTouch];
	
	if(
		// Skip deforming the terrain if it's very near to the last place the terrain was deformed.
		ccpDistanceSQ(location, _lastDeformLocation) > threshold*threshold &&
		// Skip filling in dirt if it's too near to the car.
		// If you filled in over the car it would fall through the terrain segments.
		(_currentDeformTouchRemoves || ![_space nearestPointQueryNearest:location maxDistance:0.75*radius layers:COLLISION_RULE_BUGGY_ONLY group:nil].shape)
	){
		[_terrain modifyTerrainAt:location radius:radius remove:_currentDeformTouchRemoves];
		_lastDeformLocation = location;
	}
}

-(void)update:(ccTime)dt
{
	[self modifyTerrain];
	[self updateGravity];
	
	// Update the physics on a fixed time step.
	// Because it's a potentially very fast game, I'm using a pretty small timestep.
	// This ensures that everything is very responsive.
	// It also avoids missed collisions as Chipmunk doesn't support swept collisions (yet).
	ccTime fixed_dt = 1.0/240.0;
	
	// Add the current dynamic timestep to the accumulator.
	_accumulator += dt;
	// Subtract off fixed-sized chunks of time from the accumulator and step
	while(_accumulator > fixed_dt){
		[self tick:fixed_dt];
		_accumulator -= fixed_dt;
		_fixedTime += fixed_dt;
	}
	
	// Resync the space buggy's sprites.
	// Take a look at the SpaceBuggy class to see why I don't just use ChipmunkSprites.
	[_spaceBuggy sync];
	
	// Scroll the screen as long as we aren't dragging the car.
	if(_multiGrab.grabCount == 0){
		// Clamp off the position vector so we can't see outside of the terrain sprite.
		CGSize winSize = [CCDirector sharedDirector].winSize;
		cpBB clampingBB = cpBBNew(winSize.width/2.0, winSize.height/2.0, _terrain.width - winSize.width/2.0, _terrain.height - winSize.height/2.0);
		
		// TODO Should smooth this out better to avoid the pops when releasing the buggy.
		_world.position = cpvsub(cpv(240, 160), cpBBClampVect(clampingBB, _spaceBuggy.pos));
	}
}

-(void)ccTouchesBegan:(NSSet *)touches withEvent:(UIEvent *)event
{
	for(UITouch *touch in touches){
		[_multiGrab beginLocation:[_terrain convertTouchToNodeSpace:touch]];
		
		if(!_currentDeformTouch){
			_currentDeformTouch = touch;
			
			// Check the density of the terrain at the touch location to see if we shold be filling or digging.
			cpFloat density = [_terrain.sampler sample:[self touchLocation:_currentDeformTouch]];
			_currentDeformTouchRemoves = (density < 0.5);
		}
	}
}

-(void)ccTouchesMoved:(NSSet *)touches withEvent:(UIEvent *)event
{
	for(UITouch *touch in touches){
		[_multiGrab updateLocation:[_terrain convertTouchToNodeSpace:touch]];
	}
}

-(void)ccTouchesEnded:(NSSet *)touches withEvent:(UIEvent *)event
{
	for(UITouch *touch in touches){
		[_multiGrab endLocation:[_terrain convertTouchToNodeSpace:touch]];
		
		if(touch == _currentDeformTouch){
			_currentDeformTouch = nil;
		}
	}
}

-(void)ccTouchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event
{
	[self ccTouchesEnded:touches withEvent:event];
}

@end
