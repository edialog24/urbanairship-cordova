/* Copyright Urban Airship and Contributors */

#import "UACordovaPluginManager.h"

#if __has_include("AirshipLib.h")
#import "AirshipLib.h"
#import "AirshipMessageCenterLib.h"
#else
@import Airship;
#endif

#import "UACordovaEvent.h"
#import "UACordovaDeepLinkEvent.h"
#import "UACordovaInboxUpdatedEvent.h"
#import "UACordovaNotificationOpenedEvent.h"
#import "UACordovaNotificationOptInEvent.h"
#import "UACordovaPushEvent.h"
#import "UACordovaRegistrationEvent.h"
#import "UACordovaShowInboxEvent.h"

// Config keys
NSString *const ProductionAppKeyConfigKey = @"com.urbanairship.production_app_key";
NSString *const ProductionAppSecretConfigKey = @"com.urbanairship.production_app_secret";
NSString *const DevelopmentAppKeyConfigKey = @"com.urbanairship.development_app_key";
NSString *const DevelopmentAppSecretConfigKey = @"com.urbanairship.development_app_secret";
NSString *const ProductionLogLevelKey = @"com.urbanairship.production_log_level";
NSString *const DevelopmentLogLevelKey = @"com.urbanairship.development_log_level";
NSString *const ProductionConfigKey = @"com.urbanairship.in_production";
NSString *const EnablePushOnLaunchConfigKey = @"com.urbanairship.enable_push_onlaunch";
NSString *const ClearBadgeOnLaunchConfigKey = @"com.urbanairship.clear_badge_onlaunch";
NSString *const EnableAnalyticsConfigKey = @"com.urbanairship.enable_analytics";
NSString *const AutoLaunchMessageCenterKey = @"com.urbanairship.auto_launch_message_center";
NSString *const NotificationPresentationAlertKey = @"com.urbanairship.ios_foreground_notification_presentation_alert";
NSString *const NotificationPresentationBadgeKey = @"com.urbanairship.ios_foreground_notification_presentation_badge";
NSString *const NotificationPresentationSoundKey = @"com.urbanairship.ios_foreground_notification_presentation_sound";
NSString *const CloudSiteConfigKey = @"com.urbanairship.site";
NSString *const CloudSiteEUString = @"EU";
NSString *const DataCollectionOptInEnabledConfigKey = @"com.urbanairship.data_collection_opt_in_enabled";

NSString *const UACordovaPluginVersionKey = @"UACordovaPluginVersion";

// Events
NSString *const CategoriesPlistPath = @"UACustomNotificationCategories";


@interface UACordovaPluginManager() <UARegistrationDelegate, UAPushNotificationDelegate, UAMessageCenterDisplayDelegate, UADeepLinkDelegate>
@property (nonatomic, strong) NSDictionary *defaultConfig;
@property (nonatomic, strong) NSMutableArray<NSObject<UACordovaEvent> *> *pendingEvents;
@property (nonatomic, assign) BOOL isAirshipReady;

@end
@implementation UACordovaPluginManager

- (void)dealloc {
    [UAirship push].pushNotificationDelegate = nil;
    [UAirship push].registrationDelegate = nil;
    [UAMessageCenter shared].displayDelegate = nil;
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (instancetype)initWithDefaultConfig:(NSDictionary *)defaultConfig {
    self = [super init];

    if (self) {
        self.defaultConfig = defaultConfig;
        self.pendingEvents = [NSMutableArray array];
    }

    return self;
}

+ (instancetype)pluginManagerWithDefaultConfig:(NSDictionary *)defaultConfig {
    return [[UACordovaPluginManager alloc] initWithDefaultConfig:defaultConfig];
}

- (void)attemptTakeOff {
    if (self.isAirshipReady) {
        return;
    }

    UAConfig *config = [self createAirshipConfig];
    if (![config validate]) {
        return;
    }

    [UAirship takeOff:config];
    [self registerCordovaPluginVersion];

    [UAirship push].userPushNotificationsEnabledByDefault = [[self configValueForKey:EnablePushOnLaunchConfigKey] boolValue];

    if ([[self configValueForKey:ClearBadgeOnLaunchConfigKey] boolValue]) {
        [[UAirship push] resetBadge];
    }

    [self loadCustomNotificationCategories];

    [UAirship push].pushNotificationDelegate = self;
    [UAirship push].registrationDelegate = self;
    [UAMessageCenter shared].displayDelegate = self;
    [UAirship shared].deepLinkDelegate = self;

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(inboxUpdated)
                                                 name:UAInboxMessageListUpdatedNotification
                                               object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(channelRegistrationSucceeded:)
                                                 name:UAChannelUpdatedEvent
                                               object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(channelRegistrationFailed)
                                                 name:UAChannelRegistrationFailedEvent
                                               object:nil];



    self.isAirshipReady = YES;
}

- (void)loadCustomNotificationCategories {
    NSString *categoriesPath = [[NSBundle mainBundle] pathForResource:CategoriesPlistPath ofType:@"plist"];
    NSSet *customNotificationCategories = [UANotificationCategories createCategoriesFromFile:categoriesPath];

    if (customNotificationCategories.count) {
        UA_LDEBUG(@"Registering custom notification categories: %@", customNotificationCategories);
        [UAirship push].customCategories = customNotificationCategories;
        [[UAirship push] updateRegistration];
    }
}

- (UAConfig *)createAirshipConfig {
    UAConfig *airshipConfig = [UAConfig config];
    airshipConfig.productionAppKey = [self configValueForKey:ProductionAppKeyConfigKey];
    airshipConfig.productionAppSecret = [self configValueForKey:ProductionAppSecretConfigKey];
    airshipConfig.developmentAppKey = [self configValueForKey:DevelopmentAppKeyConfigKey];
    airshipConfig.developmentAppSecret = [self configValueForKey:DevelopmentAppSecretConfigKey];
    airshipConfig.URLAllowListScopeOpenURL = @[@"*"];

    NSString *cloudSite = [self configValueForKey:CloudSiteConfigKey];
    airshipConfig.site = [UACordovaPluginManager parseCloudSiteString:cloudSite];

    if ([self configValueForKey:DataCollectionOptInEnabledConfigKey] != nil) {
        airshipConfig.dataCollectionOptInEnabled = [[self configValueForKey:DataCollectionOptInEnabledConfigKey] boolValue];
    }

    if ([self configValueForKey:ProductionConfigKey] != nil) {
        airshipConfig.inProduction = [[self configValueForKey:ProductionConfigKey] boolValue];
    }

    airshipConfig.developmentLogLevel = [self parseLogLevel:[self configValueForKey:DevelopmentLogLevelKey]
                                            defaultLogLevel:UALogLevelDebug];

    airshipConfig.productionLogLevel = [self parseLogLevel:[self configValueForKey:ProductionLogLevelKey]
                                           defaultLogLevel:UALogLevelError];

    if ([self configValueForKey:EnableAnalyticsConfigKey] != nil) {
        airshipConfig.analyticsEnabled = [[self configValueForKey:EnableAnalyticsConfigKey] boolValue];
    }

    return airshipConfig;
}

- (void)registerCordovaPluginVersion {
    NSString *version = [NSBundle mainBundle].infoDictionary[UACordovaPluginVersionKey] ?: @"0.0.0";
    [[UAirship analytics] registerSDKExtension:UASDKExtensionCordova version:version];
}

- (id)configValueForKey:(NSString *)key {
    id value = [[NSUserDefaults standardUserDefaults] objectForKey:key];
    if (value != nil) {
        return value;
    }

    return self.defaultConfig[key];
}

- (BOOL)autoLaunchMessageCenter {
    if ([self configValueForKey:AutoLaunchMessageCenterKey] == nil) {
        return YES;
    }

    return [[self configValueForKey:AutoLaunchMessageCenterKey] boolValue];
}

- (void)setAutoLaunchMessageCenter:(BOOL)autoLaunchMessageCenter {
    [[NSUserDefaults standardUserDefaults] setValue:@(autoLaunchMessageCenter) forKey:AutoLaunchMessageCenterKey];
}

- (void)setProductionAppKey:(NSString *)appKey appSecret:(NSString *)appSecret {
    [[NSUserDefaults standardUserDefaults] setValue:appKey forKey:ProductionAppKeyConfigKey];
    [[NSUserDefaults standardUserDefaults] setValue:appSecret forKey:ProductionAppSecretConfigKey];
}

- (void)setDevelopmentAppKey:(NSString *)appKey appSecret:(NSString *)appSecret {
    [[NSUserDefaults standardUserDefaults] setValue:appKey forKey:DevelopmentAppKeyConfigKey];
    [[NSUserDefaults standardUserDefaults] setValue:appSecret forKey:DevelopmentAppSecretConfigKey];
}

- (void)setCloudSite:(NSString *)site {
    [[NSUserDefaults standardUserDefaults] setValue:site forKey:CloudSiteConfigKey];
}

- (void)setDataCollectionOptInEnabled:(BOOL)enabled {
    [[NSUserDefaults standardUserDefaults] setValue:@(enabled) forKey:DataCollectionOptInEnabledConfigKey];
}

- (void)setPresentationOptions:(NSUInteger)options {
    [[NSUserDefaults standardUserDefaults] setValue:@(options & UNNotificationPresentationOptionAlert) forKey:NotificationPresentationAlertKey];
    [[NSUserDefaults standardUserDefaults] setValue:@(options & UNNotificationPresentationOptionBadge) forKey:NotificationPresentationBadgeKey];
    [[NSUserDefaults standardUserDefaults] setValue:@(options & UNNotificationPresentationOptionSound) forKey:NotificationPresentationSoundKey];
}

-(NSInteger)parseLogLevel:(id)logLevel defaultLogLevel:(UALogLevel)defaultValue  {
    if (![logLevel isKindOfClass:[NSString class]] || ![logLevel length]) {
        return defaultValue;
    }

    NSString *normalizedLogLevel = [[logLevel stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];

    if ([normalizedLogLevel isEqualToString:@"verbose"]) {
        return UALogLevelTrace;
    } else if ([normalizedLogLevel isEqualToString:@"debug"]) {
        return UALogLevelDebug;
    } else if ([normalizedLogLevel isEqualToString:@"info"]) {
        return UALogLevelInfo;
    } else if ([normalizedLogLevel isEqualToString:@"warning"]) {
        return UALogLevelWarn;
    } else if ([normalizedLogLevel isEqualToString:@"error"]) {
        return UALogLevelError;
    } else if ([normalizedLogLevel isEqualToString:@"none"]) {
        return UALogLevelNone;
    }

    return defaultValue;
}

+ (UACloudSite)parseCloudSiteString:(NSString *)site {
    if ([CloudSiteEUString caseInsensitiveCompare:site] == NSOrderedSame) {
        return UACloudSiteEU;
    } else {
        return UACloudSiteUS;
    }
}

#pragma mark UAInboxDelegate


- (void)displayMessageCenterForMessageID:(NSString *)messageID animated:(BOOL)animated {
    if (self.autoLaunchMessageCenter) {
        [[UAMessageCenter shared].defaultUI displayMessageCenterForMessageID:messageID animated:true];
    } else {
        [self fireEvent:[UACordovaShowInboxEvent eventWithMessageID:messageID]];
    }
}

- (void)displayMessageCenterAnimated:(BOOL)animated {
    if (self.autoLaunchMessageCenter) {
        [[UAMessageCenter shared].defaultUI displayMessageCenterAnimated:animated];
    } else {
        [self fireEvent:[UACordovaShowInboxEvent event]];
    }
}

- (void)dismissMessageCenterAnimated:(BOOL)animated {
    if (self.autoLaunchMessageCenter) {
        [[UAMessageCenter shared].defaultUI dismissMessageCenterAnimated:animated];
    }
}

- (void)inboxUpdated {
    UA_LDEBUG(@"Inbox updated");
    [self fireEvent:[UACordovaInboxUpdatedEvent event]];
}

#pragma mark UAPushNotificationDelegate

-(void)receivedForegroundNotification:(UANotificationContent *)notificationContent completionHandler:(void (^)(void))completionHandler {
    UA_LDEBUG(@"Received a notification while the app was already in the foreground %@", notificationContent);

    //New code
    [[UAirship push] setBadgeNumber:0]; // zero badge after push received


    [self fireEvent:[UACordovaPushEvent eventWithNotificationContent:notificationContent]];
    completionHandler();
}

- (void)receivedBackgroundNotification:(UANotificationContent *)notificationContent
                     completionHandler:(void (^)(UIBackgroundFetchResult))completionHandler {


        UA_LDEBUG(@"Received a notification while the app was in the background %@", notificationContent);

        NSLog(@"Received a notification while the app was in the background %@", notificationContent);


        /*
         {
         "_" = "c0139700-6cc0-47cb-b686-c5eee46adb0d";
         aps =     {
         alert = "";
         "content-available" = 1;
         };
         "com.urbanairship.metadata" = "eyJ2ZXJzaW9uX2lkIjoxLCJ0aW1lIjoxNTI5NDE4NTQ3NDQ5LCJwdXNoX2lkIjoiYjQ1N2FhODUtNDhhMy00MTQ0LTgyYjItNDk2NDk2MTUzY2E0In0=";
         message = "";
         rid = 103435;
         senderName = " ";
         type = 13;
         }
         */



        UA_LDEBUG(@"rid %@", [notificationContent.notificationInfo objectForKey:@"rid"]);
        UA_LDEBUG(@"opId %@", [notificationContent.notificationInfo objectForKey:@"opId"]);
        UA_LDEBUG(@"title %@", [notificationContent.notificationInfo objectForKey:@"title"]);
        UA_LDEBUG(@"type %@", [notificationContent.notificationInfo objectForKey:@"type"]);
        NSLog(@"New push message type: %@", [notificationContent.notificationInfo objectForKey:@"type"]);



        NSString * createID = [notificationContent.notificationInfo objectForKey:@"rid"];
        NSString * createOpID = [notificationContent.notificationInfo objectForKey:@"opId"];
        NSString * pushNotificationId = [NSString stringWithFormat:@"com.urbanairship.push_received.%@", createID];
        NSString * pushNotificationOpId = [NSString stringWithFormat:@"com.urbanairship.push_received.%@", createOpID];

        //if(pushNotificationId == [NSNull null])
        if(createID == (id)[NSNull null] || createID.length == 0 )
        {
            pushNotificationId = pushNotificationOpId;
        }

        UA_LDEBUG(@"pushNotificationId: %@", pushNotificationId);
        NSLog(@"pushNotificationId: %@", pushNotificationId);

        __block NSString * type = [notificationContent.notificationInfo objectForKey:@"type"];
        __block BOOL foundMessage = false;


        //Get all delivered messages in center
        [[UNUserNotificationCenter currentNotificationCenter] getDeliveredNotificationsWithCompletionHandler:^(NSArray<UNNotification *> * _Nonnull notifications) {



            NSMutableArray *result = [NSMutableArray array];

            //Iterating through all delivered messages
            for(UNNotification *unnotification in notifications) {
                UANotificationContent *content = [UANotificationContent notificationWithUNNotification:unnotification];
                NSString * tempID = [content.notificationInfo objectForKey:@"rid"];
                NSString * tempOpID = [content.notificationInfo objectForKey:@"opId"];

                if ( ( ![tempID isEqual:[NSNull null]] ) && ( [tempID length] != 0 ) )
                {
                    UA_LDEBUG(@"Searching among received for rid:  %@", [content.notificationInfo objectForKey:@"rid"]);
                    NSLog(@"Searching among received for rid:  %@", [content.notificationInfo objectForKey:@"rid"]);
                }
                else if( ( ![tempOpID isEqual:[NSNull null]] ) && ( [tempOpID length] != 0 ) )
                {
                    UA_LDEBUG(@"Searching among received for opid:  %@", [content.notificationInfo objectForKey:@"opId"]);
                    NSLog(@"Searching among received for opid:  %@", [content.notificationInfo objectForKey:@"opId"]);
                }


                if( ( [content.notificationInfo objectForKey:@"rid"] == createID && ((![tempID isEqual:[NSNull null]] ) && ( [tempID length] != 0 ) )) || ([content.notificationInfo objectForKey:@"opId"] == createOpID && ((![tempOpID isEqual:[NSNull null]]) && ([tempOpID length] != 0)) ) )
                {
                    if( ( ![tempID isEqual:[NSNull null]] ) && ( [tempID length] != 0 ) )
                    {
                        UA_LDEBUG(@"rid Found %@", createID);
                        NSLog(@"rid Found %@", createID);
                    }
                    if( ( ![tempOpID isEqual:[NSNull null]] ) && ( [tempOpID length] != 0 ) )
                    {
                        UA_LDEBUG(@"opid Found %@", createOpID);
                        NSLog(@"opid Found %@", createOpID);
                    }
                    foundMessage = true;
                }
                else
                {
                    if( ( ![tempID isEqual:[NSNull null]] ) && ( [tempID length] != 0 ) )
                    {
                        UA_LDEBUG(@"rid did not find %@", createID);
                        NSLog(@"rid did not find %@", createID);
                    }
                    if( ( ![tempOpID isEqual:[NSNull null]] ) && ( [tempOpID length] != 0 ) )
                    {
                        UA_LDEBUG(@"opid did not find %@", createOpID);
                        NSLog(@"opid did not find %@", createOpID);
                    }
                }

            }//iteration done




            if(foundMessage == true && [type isEqualToString:@"14"]) //14 = mp_Message_Taken
            {//Dersom vi skal slette, og har funnet pushen i senteret vårt
                if( ( ![createID isEqual:[NSNull null]] ) && ( [createID length] != 0 ) )
                {
                    UA_LDEBUG(@"Removing rid: %@", createID);
                    NSLog(@"Removing rid: %@", createID);
                }
                else
                {
                    UA_LDEBUG(@"Removing opid: %@", createOpID);
                    NSLog(@"Removing opid: %@", createOpID);
                }

                UA_LDEBUG(@"Removing pushNotificationId: %@", pushNotificationId);
                NSLog(@"Removing pushNotificationId: %@", pushNotificationId);

                NSString * deleteAll = [notificationContent.notificationInfo objectForKey:@"deleteAll"];
                NSLog(@"deleteAll: %@", deleteAll);
                BOOL deleteAllValue = [deleteAll boolValue];
                if(deleteAllValue)
                {
                    NSLog(@"deleting all messsages");
                    [[UNUserNotificationCenter currentNotificationCenter] removeAllPendingNotificationRequests];
                    [[UNUserNotificationCenter currentNotificationCenter] removeAllDeliveredNotifications];
                }

                NSString * deletePrevious = [notificationContent.notificationInfo objectForKey:@"deletePrevious"];
                NSLog(@"deletePrevious: %@", deletePrevious);
                BOOL deletePreviousValue = [deletePrevious boolValue];
                if(deletePreviousValue)
                {

                    [[UNUserNotificationCenter currentNotificationCenter] getDeliveredNotificationsWithCompletionHandler:^(NSArray<UNNotification *> * _Nonnull notifications)
                    {

                        for(UNNotification *unnotification in notifications) {
                            UANotificationContent *tempContent = [UANotificationContent notificationWithUNNotification:unnotification];
                            NSLog(@"content: %@",tempContent);




                            NSString * notId = unnotification.request.identifier;
                            NSLog(@"temp notification id: %@",notId);





                            NSString * tempID = [tempContent.notificationInfo objectForKey:@"rid"];
                            NSLog(@"temp rid: %@",tempID);
                            NSString * tempOpID = [tempContent.notificationInfo objectForKey:@"opId"];
                            NSLog(@"temp opId: %@",tempOpID);

                            if (createID == tempID && ( ![tempID isEqual:[NSNull null]] ) && ( [tempID length] != 0 ) )
                            {
                                NSLog(@"removing %@",tempID);
                                [[UNUserNotificationCenter currentNotificationCenter] removeDeliveredNotificationsWithIdentifiers:@[notId]];
                                [[NSUserDefaults standardUserDefaults] removeObjectForKey:notId];
                            }
                            else if(createOpID == tempOpID && ( ![tempOpID isEqual:[NSNull null]] ) && ( [tempOpID length] != 0 ) )
                            {
                                NSLog(@"removing %@",tempOpID);
                                [[UNUserNotificationCenter currentNotificationCenter] removeDeliveredNotificationsWithIdentifiers:@[notId]];
                                [[NSUserDefaults standardUserDefaults] removeObjectForKey:notId];
                            }
                        }

                    }];

                }

                [[UNUserNotificationCenter currentNotificationCenter] removeDeliveredNotificationsWithIdentifiers:@[pushNotificationId]];
                [[NSUserDefaults standardUserDefaults] removeObjectForKey:pushNotificationId];

                completionHandler(UIBackgroundFetchResultNewData);
                return;
            }
            else if(foundMessage == false && [type isEqualToString:@"13"] )
            {//Dersom vi skal adde chat, og den ikke finnes i senteret fra før


                UNMutableNotificationContent *contentz = [UNMutableNotificationContent new];
                contentz.userInfo = notificationContent.notificationInfo;



                NSString * KPNavn = [notificationContent.notificationInfo objectForKey:@"KPNavn"];
                NSString * avsender = [notificationContent.notificationInfo objectForKey:@"senderName"];
                NSString * tempMessage = [notificationContent.notificationInfo objectForKey:@"message"];


                NSString * chatTitleTemp = [NSString stringWithFormat:@"%@ - %@", KPNavn, avsender];

                NSString * tempMessageShort = [tempMessage substringWithRange:NSMakeRange(0, ([tempMessage length]>20?20:[tempMessage length]))];
                NSString * internalmessage = [NSString stringWithFormat:@"%@", tempMessageShort];

                contentz.title = [NSString localizedUserNotificationStringForKey:chatTitleTemp arguments:nil];
                contentz.body = [NSString localizedUserNotificationStringForKey:internalmessage arguments:nil];


                contentz.sound = [UNNotificationSound soundNamed:@"incomingChat2.wav"];


                /*Icon*/
                NSString *executablePath = [NSString stringWithCString:[[[[NSProcessInfo processInfo] arguments] objectAtIndex:0]
                                                                        fileSystemRepresentation] encoding:NSUTF8StringEncoding];
                NSLog(@"executablePath: %@", executablePath);

                NSString *executablePathFulls = [executablePath substringWithRange:NSMakeRange(0, [executablePath length]-9)];
                NSLog(@"executablePathFulls: %@", executablePathFulls);

                NSString *executablePathWithString = [NSString stringWithFormat:@"%@www/img/chat.png", executablePathFulls];
                NSLog(@"executablePathWithString: %@", executablePathWithString);

                NSString *executablePathFull= [NSString stringWithFormat:@"file://%@", executablePathWithString];
                NSLog(@"executablePathFull: %@", executablePathFull);

                NSURL *imageURL = [NSURL URLWithString:executablePathFull];
                NSLog(@"imageURL: %@", imageURL);

                NSError *error;
                UNNotificationAttachment *icon = [UNNotificationAttachment attachmentWithIdentifier:@"image" URL:imageURL options:nil error:&error];
                if (error)
                {
                    NSLog(@"error while storing image attachment in notification: %@", error);
                }
                if (icon)
                {
                    contentz.attachments = @[icon];
                }



                UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:pushNotificationId content:contentz trigger:nil];

                //present notification now
                UA_LDEBUG(@"Adding rid: %@", createID);
                UA_LDEBUG(@"Adding pushNotificationId: %@", pushNotificationId);
                [[UNUserNotificationCenter currentNotificationCenter] addNotificationRequest:request withCompletionHandler:^(NSError * _Nullable error) {
                    if (!error) {
                        [[NSUserDefaults standardUserDefaults] setObject:pushNotificationId forKey:pushNotificationId];
                    }
                }];
            }
            else if(foundMessage == false && [type isEqualToString:@"16"] )
            {//Dersom vi skal adde email, og den ikke finnes i senteret fra før


                UNMutableNotificationContent *contentz = [UNMutableNotificationContent new];
                //contentz.title = @"Ny e-post!";
                contentz.userInfo = notificationContent.notificationInfo;

                contentz.body = [NSString localizedUserNotificationStringForKey:@"Ny e-post!  " arguments:nil];
                contentz.sound = [UNNotificationSound soundNamed:@"request-email.wav"];

                /*Icon*/
                NSString *executablePath = [NSString stringWithCString:[[[[NSProcessInfo processInfo] arguments] objectAtIndex:0]
                                                                        fileSystemRepresentation] encoding:NSUTF8StringEncoding];
                NSLog(@"executablePath: %@", executablePath);

                NSString *executablePathFulls = [executablePath substringWithRange:NSMakeRange(0, [executablePath length]-9)];
                NSLog(@"executablePathFulls: %@", executablePathFulls);

                NSString *executablePathWithString = [NSString stringWithFormat:@"%@www/img/mail2.png", executablePathFulls];
                NSLog(@"executablePathWithString: %@", executablePathWithString);

                NSString *executablePathFull= [NSString stringWithFormat:@"file://%@", executablePathWithString];
                NSLog(@"executablePathFull: %@", executablePathFull);

                NSURL *imageURL = [NSURL URLWithString:executablePathFull];
                NSLog(@"imageURL: %@", imageURL);

                NSError *error;
                UNNotificationAttachment *icon = [UNNotificationAttachment attachmentWithIdentifier:@"image" URL:imageURL options:nil error:&error];
                if (error)
                {
                    NSLog(@"error while storing image attachment in notification: %@", error);
                }
                if (icon)
                {
                    contentz.attachments = @[icon];
                }


                UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:pushNotificationId content:contentz trigger:nil];

                //present notification now
                UA_LDEBUG(@"Adding rid: %@", createID);
                UA_LDEBUG(@"Adding pushNotificationId: %@", pushNotificationId);
                [[UNUserNotificationCenter currentNotificationCenter] addNotificationRequest:request withCompletionHandler:^(NSError * _Nullable error) {
                    if (!error) {
                        [[NSUserDefaults standardUserDefaults] setObject:pushNotificationId forKey:pushNotificationId];
                    }
                }];
            }
            else if(foundMessage == false && [type isEqualToString:@"17"] )
            {//Dersom vi skal adde offline, og den ikke finnes i senteret fra før


                UNMutableNotificationContent *contentz = [UNMutableNotificationContent new];
                //contentz.title = @"Ny nettbeskjed!";
                contentz.userInfo = notificationContent.notificationInfo;

                contentz.body = [NSString localizedUserNotificationStringForKey:@"Ny nettbeskjed!  " arguments:nil];
                contentz.sound = [UNNotificationSound soundNamed:@"request-netmessage.wav"];

                UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:pushNotificationId content:contentz trigger:nil];

                //present notification now
                UA_LDEBUG(@"Adding rid: %@", createID);
                UA_LDEBUG(@"Adding pushNotificationId: %@", pushNotificationId);
                [[UNUserNotificationCenter currentNotificationCenter] addNotificationRequest:request withCompletionHandler:^(NSError * _Nullable error) {
                    if (!error) {
                        [[NSUserDefaults standardUserDefaults] setObject:pushNotificationId forKey:pushNotificationId];
                    }
                }];
            }
            else if(foundMessage == false && [type isEqualToString:@"18"] )
            {//Dersom vi skal adde sms, og den ikke finnes i senteret fra før


                UNMutableNotificationContent *contentz = [UNMutableNotificationContent new];
                //contentz.title = @"Ny SMS!";
                contentz.userInfo = notificationContent.notificationInfo;

                contentz.body = [NSString localizedUserNotificationStringForKey:@"Ny SMS!  " arguments:nil];
                contentz.sound = [UNNotificationSound soundNamed:@"request-sms.wav"];

                UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:pushNotificationId content:contentz trigger:nil];

                //present notification now
                UA_LDEBUG(@"Adding rid: %@", createID);
                UA_LDEBUG(@"Adding pushNotificationId: %@", pushNotificationId);
                [[UNUserNotificationCenter currentNotificationCenter] addNotificationRequest:request withCompletionHandler:^(NSError * _Nullable error) {
                    if (!error) {
                        [[NSUserDefaults standardUserDefaults] setObject:pushNotificationId forKey:pushNotificationId];
                    }
                }];
            }
            else if(foundMessage == false && [type isEqualToString:@"19"] )
            {//Dersom vi skal adde task, og den ikke finnes i senteret fra før


                UNMutableNotificationContent *contentz = [UNMutableNotificationContent new];
                //contentz.title = @"Ny task!";
                contentz.userInfo = notificationContent.notificationInfo;

                contentz.body = [NSString localizedUserNotificationStringForKey:@"Ny task!  " arguments:nil];
                contentz.sound = [UNNotificationSound soundNamed:@"request-netmessage.wav"];

                UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:pushNotificationId content:contentz trigger:nil];

                //present notification now
                UA_LDEBUG(@"Adding rid: %@", createID);
                UA_LDEBUG(@"Adding pushNotificationId: %@", pushNotificationId);
                [[UNUserNotificationCenter currentNotificationCenter] addNotificationRequest:request withCompletionHandler:^(NSError * _Nullable error) {
                    if (!error) {
                        [[NSUserDefaults standardUserDefaults] setObject:pushNotificationId forKey:pushNotificationId];
                    }
                }];
            }
            else if(foundMessage == false && [type isEqualToString:@"20"] )
            {//Dersom vi skal adde SoMe, og den ikke finnes i senteret fra før

                UNMutableNotificationContent *contentz = [UNMutableNotificationContent new];
                //contentz.title = @"Ny SoMe!";
                contentz.userInfo = notificationContent.notificationInfo;




                NSString * groupName = [notificationContent.notificationInfo objectForKey:@"groupName"];
                NSString * senderName = [notificationContent.notificationInfo objectForKey:@"senderName"];
                NSString * tempMessage = [notificationContent.notificationInfo objectForKey:@"message"];


                NSString * chatTitleTemp = [NSString stringWithFormat:@"%@ - %@", groupName, senderName];

                NSString * tempMessageShort = [tempMessage substringWithRange:NSMakeRange(0, ([tempMessage length]>20?20:[tempMessage length]))];
                NSString * internalmessage = [NSString stringWithFormat:@"%@", tempMessageShort];

                contentz.title = [NSString localizedUserNotificationStringForKey:chatTitleTemp arguments:nil];
                contentz.body = [NSString localizedUserNotificationStringForKey:internalmessage arguments:nil];





                NSString * requestType = [notificationContent.notificationInfo objectForKey:@"requestType"];
                NSLog(@"requestType: %@", requestType);
                NSString * groupType = [notificationContent.notificationInfo objectForKey:@"groupType"];
                NSLog(@"groupType: %@", groupType);
                NSString * messageType = [notificationContent.notificationInfo objectForKey:@"messageType"];
                NSLog(@"messageType: %@", messageType);

                /*Icon*/
                NSString *executablePath = [NSString stringWithCString:[[[[NSProcessInfo processInfo] arguments] objectAtIndex:0]
                                                                        fileSystemRepresentation] encoding:NSUTF8StringEncoding];
                NSLog(@"executablePath: %@", executablePath);

                NSString *executablePathFulls = [executablePath substringWithRange:NSMakeRange(0, [executablePath length]-9)];
                NSLog(@"executablePathFulls: %@", executablePathFulls);

                NSURL *imageURL;
                NSString *executablePathWithString;

                if([requestType isEqualToString:@"10"])
                {//Facebook
                    if([messageType isEqualToString:@"0"])
                    {//Facebook wall
                        //contentz.body = [NSString localizedUserNotificationStringForKey:@"Ny Facebookpost!  " arguments:nil];

                        executablePathWithString = [NSString stringWithFormat:@"%@www/img/face.png", executablePathFulls];
                        NSLog(@"executablePathWithString: %@", executablePathWithString);
                    }
                    else if([messageType isEqualToString:@"1"])
                    {//Messenger
                        //contentz.body = [NSString localizedUserNotificationStringForKey:@"Ny Messengermelding!  " arguments:nil];

                        executablePathWithString = [NSString stringWithFormat:@"%@www/img/FBmessenger.png", executablePathFulls];
                        NSLog(@"executablePathWithString: %@", executablePathWithString);
                    }
                }
                else if([requestType isEqualToString:@"11"])
                {//Twitter
                    if([messageType isEqualToString:@"0"])
                    {//Twitter wall
                        //contentz.body = [NSString localizedUserNotificationStringForKey:@"Ny Tweet!  " arguments:nil];

                        executablePathWithString = [NSString stringWithFormat:@"%@www/img/twitter.png", executablePathFulls];
                        NSLog(@"executablePathWithString: %@", executablePathWithString);
                    }
                    else if([messageType isEqualToString:@"1"])
                    {//Twitter dm
                        //contentz.body = [NSString localizedUserNotificationStringForKey:@"Ny Twitter dm!  " arguments:nil];

                        executablePathWithString = [NSString stringWithFormat:@"%@www/img/TWmessage.png", executablePathFulls];
                        NSLog(@"executablePathWithString: %@", executablePathWithString);
                    }
                }

                NSString *executablePathFull= [NSString stringWithFormat:@"file://%@", executablePathWithString];
                NSLog(@"executablePathFull: %@", executablePathFull);

                imageURL = [NSURL URLWithString:executablePathFull];
                NSLog(@"imageURL: %@", imageURL);

                contentz.sound = [UNNotificationSound soundNamed:@"somerequest.wav"];


                NSError *error;
                UNNotificationAttachment *icon = [UNNotificationAttachment attachmentWithIdentifier:@"image" URL:imageURL options:nil error:&error];
                if (error)
                {
                    NSLog(@"!!!!!!!!!!!!!!!!!!!!!!!error while storing image attachment in notification: %@", error);
                }
                if (icon)
                {
                    contentz.attachments = @[icon];
                }



                UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:pushNotificationId content:contentz trigger:nil];

                //present notification now
                UA_LDEBUG(@"Adding rid: %@", createID);
                UA_LDEBUG(@"Adding pushNotificationId: %@", pushNotificationId);
                [[UNUserNotificationCenter currentNotificationCenter] addNotificationRequest:request withCompletionHandler:^(NSError * _Nullable error) {
                    if (!error) {
                        [[NSUserDefaults standardUserDefaults] setObject:pushNotificationId forKey:pushNotificationId];
                    }
                }];
            }
            else if(foundMessage == false && [type isEqualToString:@"21"] )
            {//Dersom vi skal adde transfer, og den ikke finnes i senteret fra før


                UNMutableNotificationContent *contentz = [UNMutableNotificationContent new];
                //contentz.title = @"Ny dialog satt over!";
                contentz.userInfo = notificationContent.notificationInfo;

                contentz.body = [NSString localizedUserNotificationStringForKey:@"Ny dialog satt over!  " arguments:nil];
                contentz.sound = [UNNotificationSound soundNamed:@"dialogtransfer.wav"];


                UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:pushNotificationId content:contentz trigger:nil];

                //present notification now
                UA_LDEBUG(@"Adding rid: %@", createID);
                UA_LDEBUG(@"Adding pushNotificationId: %@", pushNotificationId);
                [[UNUserNotificationCenter currentNotificationCenter] addNotificationRequest:request withCompletionHandler:^(NSError * _Nullable error) {
                    if (!error) {
                        [[NSUserDefaults standardUserDefaults] setObject:pushNotificationId forKey:pushNotificationId];
                    }
                }];
            }
            else if(foundMessage == false && [type isEqualToString:@"22"] )
            {//Utlogging

                UA_LDEBUG(@"Logging out: %@", pushNotificationId);

                completionHandler(UIBackgroundFetchResultNewData);
                return;

            }
            else if([type isEqualToString:@"23"] )
            {//Internmelding


                UNMutableNotificationContent *contentz = [UNMutableNotificationContent new];
                //contentz.title = @"Ny internmelding!";
                contentz.userInfo = notificationContent.notificationInfo;

                NSDictionary *dict1=[notificationContent.notificationInfo  objectForKey:@"aps"];

                NSString *str=[dict1 objectForKey:@"alert"];
                NSLog(@"alert: %@", str);

                NSDateFormatter *DateFormatter=[[NSDateFormatter alloc] init];
                [DateFormatter setDateFormat:@"yyyy-MM-dd hh:mm:ss"];
                NSLog(@"pre: %@",[DateFormatter stringFromDate:[NSDate date]]);


                if( ( ![str isEqual:[NSNull null]] ) && ( [str length] != 0 ) )
                {
                    //Vi har en alert, og dermed har os laget en push.
                    NSLog(@"vi fant alert: %@", str);

                    //Gå gjennom alle meldinger
                    [[UNUserNotificationCenter currentNotificationCenter] getDeliveredNotificationsWithCompletionHandler:^(NSArray<UNNotification *> * _Nonnull notifications)
                     {
                         for(UNNotification *unnotification in notifications) {
                             UANotificationContent *tempContent = [UANotificationContent notificationWithUNNotification:unnotification];

                             NSString * notId = unnotification.request.identifier;
                             NSLog(@"temp notification id: %@",notId);



                             if([notId rangeOfString:@"com.urbanairship"].location == NSNotFound)
                             {
                                 NSString * tempID = [tempContent.notificationInfo objectForKey:@"rid"];
                                 NSLog(@"temp rid: %@",tempID);
                                 NSString * tempOpID = [tempContent.notificationInfo objectForKey:@"opId"];
                                 NSLog(@"temp opId: %@",tempOpID);

                                 if (createID == tempID && ( ![tempID isEqual:[NSNull null]] ) && ( [tempID length] != 0 ) )
                                 {
                                     NSLog(@"removing %@",tempID);
                                     [[UNUserNotificationCenter currentNotificationCenter] removeDeliveredNotificationsWithIdentifiers:@[notId]];
                                     [[NSUserDefaults standardUserDefaults] removeObjectForKey:notId];
                                 }
                                 else if(createOpID == tempOpID && ( ![tempOpID isEqual:[NSNull null]] ) && ( [tempOpID length] != 0 ) )
                                 {
                                     NSLog(@"removing %@",tempOpID);
                                     [[UNUserNotificationCenter currentNotificationCenter] removeDeliveredNotificationsWithIdentifiers:@[notId]];
                                     [[NSUserDefaults standardUserDefaults] removeObjectForKey:notId];
                                 }
                             }
                             else {
                                 NSLog(@"string contains com.urbanairship!");
                             }
                         }

                     }];

                }

                NSString * avsender = [notificationContent.notificationInfo objectForKey:@"senderName"];
                NSString * tempMessage = [notificationContent.notificationInfo objectForKey:@"message"];
                NSString * tempMessageShort = [tempMessage substringWithRange:NSMakeRange(0, ([tempMessage length]>20?20:[tempMessage length]))];

                NSString * internaltitle = [NSString stringWithFormat:@"Ny melding fra %@", avsender];
                NSString * internalmessage = [NSString stringWithFormat:@"%@", tempMessageShort];

                contentz.title = [NSString localizedUserNotificationStringForKey:internaltitle arguments:nil];
                contentz.body = [NSString localizedUserNotificationStringForKey:internalmessage arguments:nil];

                contentz.sound = [UNNotificationSound soundNamed:@"incoming-message2.wav"];


                /*Icon*/
                NSString *executablePath = [NSString stringWithCString:[[[[NSProcessInfo processInfo] arguments] objectAtIndex:0]
                                                                        fileSystemRepresentation] encoding:NSUTF8StringEncoding];
                NSLog(@"executablePath: %@", executablePath);

                NSString *executablePathFulls = [executablePath substringWithRange:NSMakeRange(0, [executablePath length]-9)];
                NSLog(@"executablePathFulls: %@", executablePathFulls);

                NSString *executablePathWithString = [NSString stringWithFormat:@"%@www/img/internal.png", executablePathFulls];
                NSLog(@"executablePathWithString: %@", executablePathWithString);

                NSString *executablePathFull= [NSString stringWithFormat:@"file://%@", executablePathWithString];
                NSLog(@"executablePathFull: %@", executablePathFull);

                NSURL *imageURL = [NSURL URLWithString:executablePathFull];
                NSLog(@"imageURL: %@", imageURL);

                NSError *error;
                UNNotificationAttachment *icon = [UNNotificationAttachment attachmentWithIdentifier:@"image" URL:imageURL options:nil error:&error];
                if (error)
                {
                    NSLog(@"error while storing image attachment in notification: %@", error);
                }
                if (icon)
                {
                    contentz.attachments = @[icon];
                }






                UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:pushNotificationId content:contentz trigger:nil];

                //present notification now
                UA_LDEBUG(@"Adding rid: %@", createID);
                NSLog(@"Adding rid: %@", createID);
                UA_LDEBUG(@"Adding pushNotificationId: %@", pushNotificationId);
                NSLog(@"Adding pushNotificationId: %@", pushNotificationId);
                [[UNUserNotificationCenter currentNotificationCenter] addNotificationRequest:request withCompletionHandler:^(NSError * _Nullable error) {
                    if (!error) {
                        [[NSUserDefaults standardUserDefaults] setObject:pushNotificationId forKey:pushNotificationId];
                    }
                }];

            }

            /*New code*/
            //id event = [self pushEventFromNotification:notificationContent];
            //[self fireEvent:EventPushReceived data:event];
            /**/

            //NSLog(@"completionHandler done@");
            //completionHandler(UIBackgroundFetchResultNewData);

            UA_LDEBUG(@"Received a background notification %@", notificationContent);

            [self fireEvent:[UACordovaPushEvent eventWithNotificationContent:notificationContent]];

            completionHandler(UIBackgroundFetchResultNewData);
            //completionHandler(UIBackgroundFetchResultNoData);




        }];

    /*

        UA_LDEBUG(@"Received a background notification %@", notificationContent);

        [self fireEvent:[UACordovaPushEvent eventWithNotificationContent:notificationContent]];

        completionHandler(UIBackgroundFetchResultNoData);


     */


}

-(void)receivedNotificationResponse:(UANotificationResponse *)notificationResponse completionHandler:(void (^)(void))completionHandler {
    UA_LDEBUG(@"The application was launched or resumed from a notification %@", notificationResponse);

    UACordovaNotificationOpenedEvent *event = [UACordovaNotificationOpenedEvent eventWithNotificationResponse:notificationResponse];
    self.lastReceivedNotificationResponse = event.data;
    [self fireEvent:event];

    completionHandler();
}

- (UNNotificationPresentationOptions)extendPresentationOptions:(UNNotificationPresentationOptions)options notification:(UNNotification *)notification {
    if ([[self configValueForKey:NotificationPresentationAlertKey] boolValue]) {
        options = options | UNNotificationPresentationOptionAlert;
    }

    if ([[self configValueForKey:NotificationPresentationBadgeKey] boolValue]) {
        options = options | UNNotificationPresentationOptionBadge;
    }

    if ([[self configValueForKey:NotificationPresentationSoundKey] boolValue]) {
        options = options | UNNotificationPresentationOptionSound;
    }

    return options;
}

#pragma mark UADeepLinkDelegate

-(void)receivedDeepLink:(NSURL *_Nonnull)url completionHandler:(void (^_Nonnull)(void))completionHandler {
    self.lastReceivedDeepLink = [url absoluteString];
    [self fireEvent:[UACordovaDeepLinkEvent eventWithDeepLink:url]];
    completionHandler();
}


#pragma mark Channel Registration Events

- (void)channelRegistrationSucceeded:(NSNotification *)notification {
    NSString *channelID = notification.userInfo[UAChannelUpdatedEventChannelKey];
    NSString *deviceToken = [UAirship push].deviceToken;

    UA_LINFO(@"Channel registration successful %@.", channelID);

    [self fireEvent:[UACordovaRegistrationEvent registrationSucceededEventWithChannelID:channelID deviceToken:deviceToken]];
}

- (void)channelRegistrationFailed {
    UA_LINFO(@"Channel registration failed.");
    [self fireEvent:[UACordovaRegistrationEvent registrationFailedEvent]];
}

#pragma mark UARegistrationDelegate

- (void)notificationAuthorizedSettingsDidChange:(UAAuthorizedNotificationSettings)authorizedSettings {
    UACordovaNotificationOptInEvent *event = [UACordovaNotificationOptInEvent eventWithAuthorizedSettings:authorizedSettings];
    [self fireEvent:event];
}

- (void)fireEvent:(NSObject<UACordovaEvent> *)event {
    id strongDelegate = self.delegate;

    if (strongDelegate && [strongDelegate notifyListener:event.type data:event.data]) {
        UA_LTRACE(@"Cordova plugin manager delegate notified with event of type:%@ with data:%@", event.type, event.data);

        return;
    }

    UA_LTRACE(@"No cordova plugin manager delegate available, storing pending event of type:%@ with data:%@", event.type, event.data);

    // Add pending event
    [self.pendingEvents addObject:event];
}

- (void)setDelegate:(id<UACordovaPluginManagerDelegate>)delegate {
    _delegate = delegate;

    if (delegate) {
        @synchronized(self.pendingEvents) {
            UA_LTRACE(@"Cordova plugin manager delegate set:%@", delegate);

            NSDictionary *events = [self.pendingEvents copy];
            [self.pendingEvents removeAllObjects];

            for (NSObject<UACordovaEvent> *event in events) {
                [self fireEvent:event];
            }
        }
    }
}

@end
