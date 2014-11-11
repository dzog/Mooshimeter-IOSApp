//
//  mooshimeterAppDelegate.m
//  Mooshimeter
//
//  Created by James Whong on 9/3/13.
//  Copyright (c) 2013 mooshim. All rights reserved.
//

#import "AppDelegate.h"

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
    self->reboot_into_oad = NO;
    
    //dispatch_queue_t high_queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0);
    dispatch_queue_t high_queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0);
    //dispatch_queue_t high_queue = dispatch_queue_create("mooshim.CBqueue", DISPATCH_QUEUE_SERIAL );
    
    // Having cman dispatch to any queue but main causes long delays...
    //self.cman   = [[CBCentralManager alloc]initWithDelegate:self queue:high_queue];
    self.cman   = [[CBCentralManager alloc]initWithDelegate:self queue:nil options:[NSDictionary dictionaryWithObject:[NSNumber numberWithBool:YES] forKey:CBCentralManagerOptionShowPowerAlertKey]];
    self.meters = [[NSMutableArray alloc] init];
    
    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    self.window.backgroundColor = [UIColor blackColor];
    [self.window makeKeyAndVisible];
    
    self.scan_vc = [[ScanViewController alloc] init];
    self.oad_vc  = [[BLETIOADProgressViewController alloc] init];
    
    self.nav = [[SmartNavigationController alloc] initWithRootViewController:self.scan_vc];
    self.nav.app = self;
    
    self.meter_vc = [[MeterViewController alloc] init];
    
    [self.window setRootViewController:self.nav];
    
    // Start scanning for meters
    [self scanForMeters];
    return YES;
}
							
- (void)applicationWillResignActive:(UIApplication *)application
{
    // Sent when the application is about to move from active to inactive state. This can occur for certain types of temporary interruptions (such as an incoming phone call or SMS message) or when the user quits the application and it begins the transition to the background state.
    // Use this method to pause ongoing tasks, disable timers, and throttle down OpenGL ES frame rates. Games should use this method to pause the game.
}

- (void)applicationDidEnterBackground:(UIApplication *)application
{
    // Use this method to release shared resources, save user data, invalidate timers, and store enough application state information to restore your application to its current state in case it is terminated later. 
    // If your application supports background execution, this method is called instead of applicationWillTerminate: when the user quits.
}

- (void)applicationWillEnterForeground:(UIApplication *)application
{
    // Called as part of the transition from the background to the inactive state; here you can undo many of the changes made on entering the background.
}

- (void)applicationDidBecomeActive:(UIApplication *)application
{
    // Restart any tasks that were paused (or not yet started) while the application was inactive. If the application was previously in the background, optionally refresh the user interface.
}

- (void)applicationWillTerminate:(UIApplication *)application
{
    // Called when the application is about to terminate. Save data if appropriate. See also applicationDidEnterBackground:.
}

#pragma mark - Random utility functions

-(AppDelegate*)getApp {
    return (AppDelegate*)[UIApplication sharedApplication].delegate;
}

-(UINavigationController*)getNav {
    AppDelegate* t = [self getApp];
    return t.window.rootViewController.navigationController;
}

- (void)scanForMeters
{
    uint16 tmp = CFSwapInt16(OAD_SERVICE_UUID);
    
    NSArray* services = [NSArray arrayWithObjects:[BLEUtility expandToMooshimUUID:METER_SERVICE_UUID], [BLEUtility expandToMooshimUUID:OAD_SERVICE_UUID], [CBUUID UUIDWithData:[NSData dataWithBytes:&tmp length:2]], nil];
    NSLog(@"Refresh requested");
    [self.cman stopScan];
    [self.meters removeAllObjects];
    // Manually re-add connected meter if we have one
    if(g_meter.p.state == CBPeripheralStateConnected) {
        [self.meters addObject:g_meter];
    }
    [self.cman scanForPeripheralsWithServices:services options:nil];
    [self.scan_vc reloadData];
    [self performSelector:@selector(endScan) withObject:nil afterDelay:10.f];
    [self.scan_vc.refreshControl beginRefreshing];
}

- (void)endScan {
    [self.cman stopScan];
    [self.scan_vc endRefresh];
}

-(void)selectMeter:(MooshimeterDevice*)d {
    if( g_meter != nil && g_meter.p.isConnected ) {
        if( g_meter.p.UUID == d.p.UUID ) {
            NSLog(@"Disconnecting");
            self->reboot_into_oad = NO;
            [self.cman cancelPeripheralConnection:g_meter.p];
            return;
        }
        NSLog(@"Disconnecting old...");
        [self.cman cancelPeripheralConnection:g_meter.p];
    }
    NSLog(@"Connecting new...");
    g_meter = d;
    [self.cman connectPeripheral:d.p options:nil];
    [self.scan_vc reloadData];
}

#pragma mark - CBCentralManager delegate

-(void)centralManagerDidUpdateState:(CBCentralManager *)central {
    if (central.state != CBCentralManagerStatePoweredOn) {
        UIAlertView *alertView = [[UIAlertView alloc]initWithTitle:@"BLE not supported !" message:[NSString stringWithFormat:@"CoreBluetooth return state: %d",central.state] delegate:self cancelButtonTitle:@"OK" otherButtonTitles:nil];
        [alertView show];
    } else {
        NSLog(@"BLE enabled");
    }
}

-(void)centralManager:(CBCentralManager *)central didDiscoverPeripheral:(CBPeripheral *)peripheral advertisementData:(NSDictionary *)advertisementData RSSI:(NSNumber *)RSSI {
    
    uint32 build_time = 0;
    NSData* tmp;
    
    if([RSSI integerValue] < -80 || [RSSI integerValue] >= 0) {
        // Skip super weak signals for now
        return;
    }
    
    NSLog(@"Found a BLE Device : %@",peripheral);
    
    NSLog(@"RSSI: %d", [RSSI integerValue]);
    
    NSLog(@"ADV: %@", advertisementData);
    
    tmp = [advertisementData valueForKey:@"kCBAdvDataManufacturerData"];
    
    if( tmp != nil ) {
        [tmp getBytes:&build_time length:4];
        NSLog(@"Build time %u", build_time);
    } else {
        NSLog(@"No build time");
    }
    
    // Check for repeat
    for(int i = 0; i < self.meters.count; i++) {
        MooshimeterDevice* d = self.meters[i];
        if(CFEqual(peripheral.UUID, d.p.UUID)) {
            NSLog(@"Received duplicate advert.  Updating RSSI and reloading.");
            d.RSSI = RSSI;
            [self.scan_vc reloadData];
            return;
        }
    }

    int insertion_i;
    if([RSSI integerValue] > 0) {
        insertion_i = self.meters.count;
    } else {
        for(insertion_i = 0; insertion_i < self.meters.count; insertion_i++) {
            MooshimeterDevice* d = self.meters[insertion_i];
            if([d.RSSI integerValue] < [RSSI integerValue]) break;
        }
    }
    NSLog(@"Inserting meter at index %d", insertion_i);
    MooshimeterDevice* d = [[MooshimeterDevice alloc] init:peripheral];
    d.RSSI = RSSI;
    d.advBuildTime = [NSNumber numberWithInt:build_time];
    [self.meters insertObject:d atIndex:insertion_i];
    [self.scan_vc reloadData];
}

-(void)meterSetupComplete:(MooshimeterDevice*)d {
    NSLog(@"Setup complete");
    if( g_meter->oad_mode ) {
        // We connected to a meter in OAD mode as requested previously.  Update firmware.
        NSLog(@"Connected in OAD mode");
#ifdef AUTO_UPDATE_FIRMWARE
        if(self.nav.topViewController != self.oad_vc) {
            self.oad_profile = [[BLETIOADProfile alloc]initWithDevice:d];
            self.oad_profile.progressView = [[BLETIOADProgressViewController alloc]init];
            [self.oad_profile makeConfigurationForProfile];
            self.oad_profile.navCtrl = self.nav;
            [self.oad_profile configureProfile];
            self.oad_profile.view = self.nav.topViewController.view;
            [self.oad_profile selectImagePressed:self];
        }
#endif
    }
    else if( g_meter->meter_info.build_time < 1415389647 ) {
#ifdef AUTO_UPDATE_FIRMWARE
        // Require a firmware update!
        NSLog(@"FIRMWARE UPDATE REQUIRED.  Rebooting.");
        self->reboot_into_oad = YES;
        // This will reboot the meter.  We will have 5 seconds to reconnect to it in OAD mode.
        [g_meter setMeterState:METER_SHUTDOWN target:self cb:@selector(delayedDisconnect:) arg:g_meter.p];
#endif
    } else {
        // We have a connected meter with the correct firmware.
        // Display the meter view.
        NSLog(@"Pushing meter view controller");
        [self.nav pushViewController:self.meter_vc animated:YES];
        NSLog(@"Did push meter view controller");
    }
}

-(void) delayedDisconnect:(CBPeripheral*)p {
    [self.cman performSelector:@selector(cancelPeripheralConnection:) withObject:p afterDelay:0.25];
}

-(void)centralManager:(CBCentralManager *)central didConnectPeripheral:(CBPeripheral *)peripheral {
    [self endScan];
    [g_meter setup:self cb:@selector(meterSetupComplete:) arg:g_meter];
    [self.scan_vc reloadData];
}

-(void)centralManager:(CBCentralManager *)central didDisconnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error {
    NSLog(@"Disconnected!");
    if(self->reboot_into_oad) {
        [self.cman connectPeripheral:peripheral options:nil];
    }
    [self.scan_vc reloadData];
}

-(BOOL)shouldAutorotate {
    return NO;
}

- (NSUInteger)supportedInterfaceOrientations {
    return UIInterfaceOrientationPortrait;
}

-(void) didRotateFromInterfaceOrientation:(UIInterfaceOrientation)fromInterfaceOrientation {
    NSLog(@"Signal change to graph here");
}

@end
