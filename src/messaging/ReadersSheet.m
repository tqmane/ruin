#import "MessagingPrivateAPI.h"
#import "ReadersSheet.h"
#import "../core/Localization.h"

#import <CoreData/CoreData.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <stdatomic.h>
#import <math.h>
#import <string.h>

#if !defined(RUIN_READERS_SHEET_HOST_CHECK)
#import <UIKit/UIKit.h>
#import "SwiftFields.h"
#import "Features.h"
#import "../core/TargetMetadata.h"
#endif

static atomic_uint_fast64_t gReaderSheets, gReaderContexts, gReaderSchemaRejected;
static atomic_uint_fast64_t gReaderFetchFailures, gReaderABIRejected, gReaderNamesResolved;
static atomic_uint_fast64_t gReaderUnknownNames, gReaderContextMissing;
static atomic_uint_fast64_t gReaderFriendContexts, gReaderRepositoryContexts, gReaderGroupContexts;

static long long RUINReaderMilliseconds(id value)
{
    if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return 0;
    double number = [value doubleValue];
    return isfinite(number) && number > 0 && number <= 253402300799999.0 && floor(number) == number
        ? [value longLongValue] : 0;
}

static NSDateFormatter *RUINReaderDateFormatter(NSTimeZone *timeZone, NSLocale *locale)
{
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.locale = locale ?: NSLocale.currentLocale;
    formatter.calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    formatter.timeZone = timeZone;
    formatter.dateFormat = @"yyyy/MM/dd HH:mm:ss z";
    return formatter;
}

static NSString *RUINReaderDateLabel(NSDictionary *reader, NSDateFormatter *formatter)
{
    id source = reader[@"timeSource"];
    BOOL event = [source isEqual:@"server_event"], range = [source isEqual:@"range"];
    long long read = (event || range) ? RUINReaderMilliseconds(reader[@"readAtMilliseconds"]) : 0;
    long long observed = RUINReaderMilliseconds(reader[@"observedAtMilliseconds"]);
    long long milliseconds = read ?: observed;
    if (!milliseconds) return RUINLocalizedString(@"readers.unknown_date");
    NSString *label = read ? (range ? RUINLocalizedString(@"readers.range_read_at") : RUINLocalizedString(@"readers.read_at")) : RUINLocalizedString(@"readers.observed_at");
    NSString *date = [formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:milliseconds / 1000.0]];
    return date.length ? [NSString stringWithFormat:(RUINLocalizedString(@"common.label_value") ?: @"%@：%@"), label, date] : RUINLocalizedString(@"readers.unknown_date");
}

static BOOL RUINReaderUserSchema(NSEntityDescription *entity)
{
    return [entity.name isEqualToString:@"User"] && [entity.managedObjectClassName isEqualToString:@"ManagedUser"] &&
        entity.attributesByName[@"mid"].attributeType == NSStringAttributeType &&
        entity.attributesByName[@"name"].attributeType == NSStringAttributeType;
}

static NSString *RUINReaderCachedName(NSManagedObject *user, NSEntityDescription *entity)
{
    Class cls = objc_getClass("ManagedUser");
    if (!cls || ![user isKindOfClass:cls] || user.isDeleted || user.entity != entity) return nil;
    // UserDataModel 6: User.mid/name are NSString. Resolve Core Data's dynamic
    // mid getter only after checking both its native property and live schema.
    objc_property_t property = class_getProperty(object_getClass(user), "mid");
    char *type = property ? property_copyAttributeValue(property, "T") : NULL;
    BOOL typed = type && strcmp(type, "@\"NSString\"") == 0;
    free(type);
    SEL midSelector = sel_registerName("mid");
    if (!typed || ![user respondsToSelector:midSelector]) return nil;
    NSMethodSignature *signature = [user methodSignatureForSelector:midSelector];
    if (signature.numberOfArguments != 2 || strcmp(signature.methodReturnType, "@") != 0) return nil;
    id mid = [(id<RUINMessagingUserFields>)user mid];
    if (![mid isKindOfClass:NSString.class] || ![mid length]) return nil;
    // Verified ManagedUser.displayUserName @16@0:8, IMP 0x1088c9928.
    // Normal message dispatch preserves RUIN's installed display-name alias hook.
    SEL display = sel_registerName("displayUserName");
    Method method = class_getInstanceMethod(object_getClass(user), display);
    const char *encoding = method ? method_getTypeEncoding(method) : NULL;
    if (!encoding || strcmp(encoding, "@16@0:8") != 0) {
        atomic_fetch_add(&gReaderABIRejected, 1);
        return nil;
    }
    id value = [(id<RUINMessagingUserFields>)user displayUserName];
    if (![value isKindOfClass:NSString.class]) return nil;
    NSString *name = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    // A native unknown-user fallback may contain the MID: never expose it.
    return name.length && [name rangeOfString:mid options:NSCaseInsensitiveSearch].location == NSNotFound
        ? [name copy] : nil;
}

// Called only on context.performBlock. Fetch local cached objects, never invoke
// a repository method/closure or any network/authentication/profile lookup API.
static NSDictionary<NSString *, NSString *> *RUINReaderFetchNames(NSManagedObjectContext *context,
                                                                  NSArray<NSString *> *ids)
{
    // The public entity lookup also handles child contexts without reaching
    // across queues to inspect a parent context's coordinator ourselves.
    NSEntityDescription *entity = [NSEntityDescription entityForName:@"User" inManagedObjectContext:context];
    if (!RUINReaderUserSchema(entity)) {
        atomic_fetch_add(&gReaderSchemaRejected, 1);
        return @{};
    }
    atomic_fetch_add(&gReaderContexts, 1);
    NSMutableDictionary *names = [NSMutableDictionary dictionary];
    for (NSUInteger start = 0; start < ids.count; start += 128) {
        NSArray *batch = [ids subarrayWithRange:NSMakeRange(start, MIN((NSUInteger)128, ids.count - start))];
        NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:@"User"];
        request.includesSubentities = NO;
        request.returnsObjectsAsFaults = NO;
        request.predicate = [NSPredicate predicateWithFormat:@"mid IN %@", batch];
        NSError *error = nil;
        NSArray *users = [context executeFetchRequest:request error:&error];
        if (error) { atomic_fetch_add(&gReaderFetchFailures, 1); continue; }
        for (NSManagedObject *user in users) {
            @try {
                if (![user isKindOfClass:NSManagedObject.class] || user.managedObjectContext != context) continue;
                NSString *name = RUINReaderCachedName(user, entity);
                if (!name) continue;
                id mid = [(id<RUINMessagingUserFields>)user mid];
                if ([batch containsObject:mid]) names[mid] = name;
            } @catch (__unused NSException *exception) { atomic_fetch_add(&gReaderFetchFailures, 1); }
        }
    }
    return [names copy];
}

typedef void (^RUINReaderNamesCompletion)(NSDictionary<NSString *, NSString *> *names);
static NSDictionary *RUINReaderNamesWithProfile(NSArray *ids, NSDictionary *names,
                                               NSDictionary *profile, NSDictionary *aliases)
{
    id mid = profile[@"mid"];
    if (![mid isKindOfClass:NSString.class] || ![mid length] || ![ids containsObject:mid] || names[mid]) return names;
    id alias = aliases[[@"user:" stringByAppendingString:mid]], candidate = profile[@"name"];
    if ([alias isKindOfClass:NSString.class] && [alias length]) candidate = alias;
    if (![candidate isKindOfClass:NSString.class]) return names;
    NSString *name = [candidate stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!name.length || name.length > 512 || [name rangeOfString:mid options:NSCaseInsensitiveSearch].location != NSNotFound) return names;
    NSMutableDictionary *merged = [names mutableCopy]; merged[mid] = name;
    return [merged copy];
}
static void RUINReaderResolveNames(NSArray<NSManagedObjectContext *> *contexts, NSUInteger index,
    NSArray<NSString *> *ids, NSDictionary<NSString *, NSString *> *names, RUINReaderNamesCompletion completion)
{
    NSMutableArray *missing = [NSMutableArray array];
    for (NSString *mid in ids) if (!names[mid]) [missing addObject:mid];
    if (index >= contexts.count || !missing.count) {
        NSDictionary *resolved = names;
#if !defined(RUIN_READERS_SHEET_HOST_CHECK)
        @try {
            NSUserDefaults *profile = [[NSUserDefaults alloc] initWithSuiteName:@"group.com.linecorp.line"];
            resolved = RUINReaderNamesWithProfile(ids, names,
                @{@"mid":[profile objectForKey:@"mid"] ?: NSNull.null, @"name":[profile objectForKey:@"name"] ?: NSNull.null},
                [NSUserDefaults.standardUserDefaults dictionaryForKey:RUINLocalNamesByIdentityDefaultsKey] ?: @{});
        } @catch (__unused NSException *exception) { /* Keep cached native names. */ }
#endif
        dispatch_async(dispatch_get_main_queue(), ^{ completion(resolved); });
        return;
    }
    NSManagedObjectContext *context = contexts[index];
    [context performBlock:^{
        NSMutableDictionary *merged = [names mutableCopy];
        @try { [merged addEntriesFromDictionary:RUINReaderFetchNames(context, missing)]; }
        @catch (__unused NSException *exception) { atomic_fetch_add(&gReaderFetchFailures, 1); }
        RUINReaderResolveNames(contexts, index + 1, ids, [merged copy], completion);
    }];
}

NSDictionary<NSString *, id> *RUINReadersSheetDiagnostics(void)
{
    return @{@"presentedSheets": @(atomic_load(&gReaderSheets)),
        @"validUserContextQueries": @(atomic_load(&gReaderContexts)),
        @"userSchemaRejected": @(atomic_load(&gReaderSchemaRejected)),
        @"fetchFailures": @(atomic_load(&gReaderFetchFailures)),
        @"displayNameABIMismatch": @(atomic_load(&gReaderABIRejected)),
        @"namesResolved": @(atomic_load(&gReaderNamesResolved)),
        @"unknownNames": @(atomic_load(&gReaderUnknownNames)),
        @"contextProbeUnavailable": @(atomic_load(&gReaderContextMissing)),
        @"contextCandidateCounts": @{@"friend": @(atomic_load(&gReaderFriendContexts)),
            @"repository": @(atomic_load(&gReaderRepositoryContexts)),
            @"group": @(atomic_load(&gReaderGroupContexts))}};
}

#if !defined(RUIN_READERS_SHEET_HOST_CHECK)

static BOOL RUINReaderTargetMatches(void)
{
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    return RUINTargetMetadataMatchesInfo(info);
}

static NSArray<NSManagedObjectContext *> *RUINReaderContexts(UIViewController *source)
{
    NSMutableArray *contexts = [NSMutableArray array];
    if (!RUINReaderTargetMatches() || object_getClass(source) != objc_getClass("_TtC15LineMessagingUI18ChatViewController")) return contexts;
    id chatContext = RUINCopySwiftField(source, "chatContext");
    if (object_getClass(chatContext) != objc_getClass("_TtC15LineMessagingUI11ChatContext")) return contexts;
    BOOL (^addContext)(id) = ^BOOL(id context) {
        if (![context isKindOfClass:NSManagedObjectContext.class] || [contexts containsObject:context]) return NO;
        [contexts addObject:context];
        return YES;
    };
    // ChatContext.friend field 0x10ae8d3f8 is an Optional managed object.
    id friend = RUINCopySwiftField(chatContext, "friend");
    Class userClass = objc_getClass("ManagedUser");
    if (userClass && [friend isKindOfClass:userClass] && [friend isKindOfClass:NSManagedObject.class] &&
        addContext([(NSManagedObject *)friend managedObjectContext])) atomic_fetch_add(&gReaderFriendContexts, 1);
    // The foreground controller stores the V2 model; ChatContext may retain a legacy model.
    id model = RUINCopySwiftField(source, "chatViewModel");
    if (!model) model = RUINCopySwiftField(chatContext, "chatViewModel");
    if (object_getClass(model) == objc_getClass("_TtC17LineMessagingUIV213ChatViewModel")) {
        // UserRepository protocol field 0x10ae9d7c8; verified conformance
        // 0x109b5b8a8 -> SocialGraphUserCoreDataRepository (a Swift struct).
        // Fields 0x10ae8745c/68 are actual NSManagedObjectContext references.
        // Preserve the struct inside Swift while following the complete path.
        if (addContext(RUINCopySwiftField(model, "userRepository.backgroundContext"))) atomic_fetch_add(&gReaderRepositoryContexts, 1);
        if (addContext(RUINCopySwiftField(model, "userRepository.viewContext"))) atomic_fetch_add(&gReaderRepositoryContexts, 1);
    }
    id group = RUINCopySwiftField(chatContext, "group");
    Class groupClass = objc_getClass("ManagedUnifiedGroup");
    if (groupClass && [group isKindOfClass:groupClass] && [group isKindOfClass:NSManagedObject.class] &&
        addContext([(NSManagedObject *)group managedObjectContext])) atomic_fetch_add(&gReaderGroupContexts, 1);
    // Every candidate is checked against the live User schema on its own queue.
    return [contexts copy];
}

@interface RUINReadersSheetController : UITableViewController
@property(nonatomic, copy) NSArray<NSDictionary *> *readers;
@property(nonatomic, copy) NSDictionary<NSString *, NSString *> *names;
@property(nonatomic, copy) RUINReaderProfileAction profileAction;
@property(nonatomic, strong) NSDateFormatter *dateFormatter;
@property(nonatomic) BOOL resolving;
@property(nonatomic, weak) UIViewController *source;
@property(nonatomic, copy) RUINReaderLoader loader;
@property(nonatomic) BOOL loading;
@property(nonatomic) BOOL loadFailed;
@property(nonatomic) BOOL started;
@property(nonatomic) NSUInteger nameGeneration;
- (void)applyReaders:(NSArray<NSDictionary *> *)readers;
@end

@implementation RUINReadersSheetController
- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = RUINLocalizedString(@"readers.title");
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:RUINLocalizedString(@"common.close")
        style:UIBarButtonItemStyleDone target:self action:@selector(close)];
    if (self.loader) self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:RUINLocalizedString(@"common.refresh")
        style:UIBarButtonItemStylePlain target:self action:@selector(refreshReaders)];
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 82;
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (!self.started) { self.started = YES; [self refreshReaders]; }
}
- (NSString *)tableView:(__unused UITableView *)tableView titleForHeaderInSection:(__unused NSInteger)section {
    if (self.loading) return RUINLocalizedString(@"readers.loading");
    if (self.loadFailed) return RUINLocalizedString(@"readers.fetch_failed");
    return nil;
}
- (void)refreshReaders {
    if (!self.loader || self.loading) return;
    self.loading = YES; self.loadFailed = NO;
    self.navigationItem.leftBarButtonItem.enabled = NO;
    [self.tableView reloadData];
    __weak typeof(self) weakSelf = self;
    self.loader(^(NSArray<NSDictionary *> *readers, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            RUINReadersSheetController *sheet = weakSelf;
            if (!sheet || !sheet.viewIfLoaded.window || sheet.isBeingDismissed || sheet.navigationController.isBeingDismissed) return;
            sheet.loading = NO; sheet.loadFailed = error != nil;
            sheet.navigationItem.leftBarButtonItem.enabled = YES;
            if (!error) [sheet applyReaders:readers];
            else [sheet.tableView reloadData];
        });
    });
}
- (void)applyReaders:(NSArray<NSDictionary *> *)readers {
    NSMutableArray *rows = [NSMutableArray array];
    NSMutableOrderedSet *ids = [NSMutableOrderedSet orderedSet];
    for (id item in [readers isKindOfClass:NSArray.class] ? readers : @[]) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        id mid = item[@"readerID"];
        if (![mid isKindOfClass:NSString.class] || ![mid length] || [mid length] > 256) continue;
        [rows addObject:[item copy]]; [ids addObject:mid];
    }
    self.readers = [rows copy]; self.resolving = ids.count > 0;
    [self.tableView reloadData];
    NSUInteger generation = ++self.nameGeneration;
    __weak typeof(self) weakSelf = self;
    RUINReaderResolveNames(RUINReaderContexts(self.source), 0, ids.array, self.names ?: @{}, ^(NSDictionary *names) {
        RUINReadersSheetController *sheet = weakSelf;
        if (!sheet || sheet.nameGeneration != generation) return;
        sheet.names = names; sheet.resolving = NO;
        [sheet.tableView reloadData];
    });
}
- (void)close { [self.navigationController dismissViewControllerAnimated:YES completion:nil]; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{ (void)tableView; (void)section; return MAX(self.readers.count, 1); }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (!self.readers.count) {
        UITableViewCell *empty = [tableView dequeueReusableCellWithIdentifier:@"empty"];
        if (!empty) empty = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"empty"];
        empty.textLabel.text = RUINLocalizedString(@"common.no_records");
        empty.textLabel.textColor = UIColor.secondaryLabelColor;
        empty.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        empty.textLabel.adjustsFontForContentSizeCategory = YES;
        empty.textLabel.numberOfLines = 0;
        empty.selectionStyle = UITableViewCellSelectionStyleNone;
        return empty;
    }
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"reader"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"reader"];
    NSDictionary *reader = self.readers[indexPath.row];
    cell.textLabel.text = self.names[reader[@"readerID"]] ?: (self.resolving ? RUINLocalizedString(@"readers.names_loading") : RUINLocalizedString(@"readers.unknown_name"));
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    cell.textLabel.adjustsFontForContentSizeCategory = YES;
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.text = RUINReaderDateLabel(reader, self.dateFormatter);
    cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    cell.detailTextLabel.adjustsFontForContentSizeCategory = YES;
    cell.detailTextLabel.numberOfLines = 0;
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    BOOL actionable = self.profileAction && [reader[@"readerID"] length];
    cell.accessoryType = actionable ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
    cell.selectionStyle = actionable ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
    cell.accessibilityHint = actionable ? RUINLocalizedString(@"profile.view_description") : nil;
    return cell;
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    (void)tableView; (void)section;
    return RUINLocalizedString(@"readers.timestamp_help");
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if ((NSUInteger)indexPath.row >= self.readers.count) return;
    NSString *mid = self.readers[indexPath.row][@"readerID"];
    if (self.profileAction && mid.length) self.profileAction(self, mid);
}
@end

void RUINPresentReadersSheetWithProfileAction(UIViewController *source, NSArray<NSDictionary *> *readers,
                                             RUINReaderProfileAction profileAction)
{
    RUINPresentReadersSheetWithLoader(source, readers, nil, profileAction);
}

void RUINPresentReadersSheetWithLoader(UIViewController *source, NSArray<NSDictionary *> *readers,
                                      RUINReaderLoader loader, RUINReaderProfileAction profileAction)
{
    if (!NSThread.isMainThread) {
        NSArray *snapshot = [readers copy];
        dispatch_async(dispatch_get_main_queue(), ^{ RUINPresentReadersSheetWithLoader(source, snapshot, loader, profileAction); });
        return;
    }
    if (!source.viewIfLoaded.window || source.presentedViewController || source.isBeingDismissed || source.isBeingPresented) return;
    NSMutableArray *rows = [NSMutableArray array];
    NSMutableOrderedSet *ids = [NSMutableOrderedSet orderedSet];
    for (id item in [readers isKindOfClass:NSArray.class] ? readers : @[]) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        id mid = item[@"readerID"];
        NSString *identifier = [mid isKindOfClass:NSString.class] && [mid length] <= 256 ? [mid copy] : @"";
        id timeSource = item[@"timeSource"];
        NSString *kind = [@[@"server_event", @"range", @"observed", @"unknown"] containsObject:timeSource ?: NSNull.null]
            ? timeSource : @"unknown";
        [rows addObject:@{@"readerID": identifier, @"timeSource": kind,
            @"readAtMilliseconds": @(RUINReaderMilliseconds(item[@"readAtMilliseconds"])),
            @"observedAtMilliseconds": @(RUINReaderMilliseconds(item[@"observedAtMilliseconds"]))}];
        if (identifier.length) [ids addObject:identifier];
    }
    RUINReadersSheetController *controller = [[RUINReadersSheetController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    controller.readers = [rows copy];
    controller.names = @{};
    controller.resolving = ids.count > 0;
    controller.profileAction = profileAction;
    controller.source = source; controller.loader = loader;
    NSString *language = RUINLocalizationDiagnostics()[@"language"];
    controller.dateFormatter = RUINReaderDateFormatter(NSTimeZone.localTimeZone,
        language.length ? [NSLocale localeWithLocaleIdentifier:language] : NSLocale.currentLocale);
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:controller];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    nav.sheetPresentationController.detents = @[UISheetPresentationControllerDetent.mediumDetent, UISheetPresentationControllerDetent.largeDetent];
    nav.sheetPresentationController.prefersGrabberVisible = YES;
    NSArray *contexts = RUINReaderContexts(source);
    if (!contexts.count && ids.count) atomic_fetch_add(&gReaderContextMissing, 1);
    [source presentViewController:nav animated:YES completion:nil];
    atomic_fetch_add(&gReaderSheets, 1);
    NSUInteger generation = ++controller.nameGeneration;
    __weak RUINReadersSheetController *weakController = controller;
    RUINReaderResolveNames(contexts, 0, ids.array, @{}, ^(NSDictionary *names) {
        atomic_fetch_add(&gReaderNamesResolved, names.count);
        atomic_fetch_add(&gReaderUnknownNames, ids.count - names.count);
        RUINReadersSheetController *sheet = weakController;
        if (!sheet || sheet.nameGeneration != generation || sheet.isBeingDismissed || sheet.navigationController.isBeingDismissed) return;
        sheet.names = names;
        sheet.resolving = NO;
        [sheet.tableView reloadData];
    });
}

void RUINPresentReadersSheet(UIViewController *source, NSArray<NSDictionary *> *readers)
{
    RUINPresentReadersSheetWithProfileAction(source, readers, nil);
}

#else

#import <assert.h>
@interface ManagedUser : NSManagedObject
@property(nonatomic, copy) NSString *mid;
@property(nonatomic, copy) NSString *name;
- (NSString *)displayUserName;
@end
@implementation ManagedUser
@dynamic mid, name;
- (NSString *)displayUserName
{
    if ([self.mid isEqual:@"fixture-alias"]) return @"この端末の別名";
    return [self.mid isEqual:@"fixture-mid-fallback"] ? self.mid : self.name;
}
@end

static NSManagedObjectContext *RUINReaderTestContext(BOOL userStore)
{
    NSEntityDescription *entity = [NSEntityDescription new];
    entity.name = userStore ? @"User" : @"UnifiedGroup";
    entity.managedObjectClassName = userStore ? @"ManagedUser" : @"NSManagedObject";
    NSMutableArray *attributes = [NSMutableArray array];
    for (NSString *key in @[@"mid", @"name"]) {
        NSAttributeDescription *attribute = [NSAttributeDescription new];
        attribute.name = key; attribute.attributeType = NSStringAttributeType; attribute.optional = YES;
        [attributes addObject:attribute];
    }
    entity.properties = attributes;
    NSManagedObjectModel *model = [NSManagedObjectModel new]; model.entities = @[entity];
    NSPersistentStoreCoordinator *store = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
    assert([store addPersistentStoreWithType:NSInMemoryStoreType configuration:nil URL:nil options:nil error:NULL]);
    NSManagedObjectContext *context = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
    context.persistentStoreCoordinator = store;
    return context;
}

int main(void)
{
    @autoreleasepool {
        NSString *selfMID = @"uaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
        NSDictionary *profile = @{@"mid":selfMID,@"name":@"自分の名前"};
        assert([RUINReaderNamesWithProfile(@[selfMID], @{}, profile, @{})[selfMID] isEqual:@"自分の名前"]);
        assert(([RUINReaderNamesWithProfile(@[selfMID], @{}, profile,
            @{[@"user:" stringByAppendingString:selfMID]:@"端末内の別名"})[selfMID] isEqual:@"端末内の別名"]));
        assert(([RUINReaderNamesWithProfile(@[selfMID], @{selfMID:@"既存の別名"}, profile, @{})[selfMID] isEqual:@"既存の別名"]));
        assert(!RUINReaderNamesWithProfile(@[@"other"], @{}, profile, @{})[selfMID]);
        assert((!RUINReaderNamesWithProfile(@[selfMID], @{}, @{@"mid":selfMID,@"name":selfMID}, @{})[selfMID]));
        NSDateFormatter *formatter = RUINReaderDateFormatter([NSTimeZone timeZoneWithName:@"Asia/Tokyo"],
            [NSLocale localeWithLocaleIdentifier:@"ja_JP"]);
        NSDictionary *event = @{@"readAtMilliseconds": @1700000000000LL, @"observedAtMilliseconds": @1700000010000LL, @"timeSource": @"server_event"};
        NSString *date = RUINReaderDateLabel(event, formatter);
        assert([date hasPrefix:@"既読日時：2023/11/15 07:13:20"] && [date containsString:@"JST"]);
        assert([RUINReaderDateLabel(@{@"readAtMilliseconds": @1700000000000LL, @"timeSource": @"range"}, formatter) hasPrefix:@"既読日時（範囲情報）："]);
        assert([RUINReaderDateLabel(@{@"readAtMilliseconds": @1700000000000LL, @"timeSource": @"observed"}, formatter) isEqual:@"日時不明"]);
        assert([RUINReaderDateLabel(@{@"readAtMilliseconds": @0, @"observedAtMilliseconds": @1700000010000LL, @"timeSource": @"observed"}, formatter) hasPrefix:@"確認日時：2023/11/15 07:13:30"]);
        assert([RUINReaderDateLabel(@{@"observedAtMilliseconds": @1700000010000LL}, formatter) hasPrefix:@"確認日時："]);
        assert([RUINReaderDateLabel(@{@"readAtMilliseconds": @1700000000000LL}, formatter) isEqual:@"日時不明"]);
        assert([RUINReaderDateLabel(@{}, formatter) isEqual:@"日時不明"]);
        assert(!RUINReaderMilliseconds(@YES) && !RUINReaderMilliseconds(@(-1)) && !RUINReaderMilliseconds(@(NAN)) && !RUINReaderMilliseconds(@"1700000000000"));
        assert([event[@"observedAtMilliseconds"] isEqual:@1700000010000LL]);
        NSDictionary *originalEvent = [event copy];
        for (NSString *language in @[@"ja", @"en", @"ko", @"zh-Hans", @"zh-Hant"]) {
            NSLocale *locale = [NSLocale localeWithLocaleIdentifier:language];
            for (NSString *zone in @[@"Asia/Tokyo", @"Asia/Seoul", @"America/Los_Angeles"]) {
                NSDateFormatter *localized = RUINReaderDateFormatter([NSTimeZone timeZoneWithName:zone], locale);
                assert([localized.locale.localeIdentifier isEqual:locale.localeIdentifier]);
                NSString *stamp = [localized stringFromDate:[NSDate dateWithTimeIntervalSince1970:1700000000]];
                NSString *wall = [zone isEqual:@"America/Los_Angeles"] ? @"2023/11/14 14:13:20" : @"2023/11/15 07:13:20";
                assert([stamp hasPrefix:wall] && stamp.length > wall.length);
                assert(fabs([[localized dateFromString:stamp] timeIntervalSince1970] - 1700000000) < 0.001);
                assert([RUINReaderDateLabel(event, localized) containsString:stamp]);
                assert([event isEqual:originalEvent]);
            }
        }
        assert([RUINReaderDateFormatter(NSTimeZone.localTimeZone, nil).locale.localeIdentifier
            isEqual:NSLocale.currentLocale.localeIdentifier]);
        NSManagedObjectContext *context = RUINReaderTestContext(YES);
        NSManagedObjectContext *wrongStore = RUINReaderTestContext(NO);
        [context performBlockAndWait:^{
            for (NSString *mid in @[@"fixture-alias", @"fixture-normal", @"fixture-mid-fallback"]) {
                ManagedUser *user = [NSEntityDescription insertNewObjectForEntityForName:@"User" inManagedObjectContext:context];
                user.mid = mid; user.name = @"キャッシュの名前";
            }
        }];
        NSManagedObjectContext *child = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
        child.parentContext = context;
        __block BOOL done = NO;
        RUINReaderResolveNames(@[wrongStore, child], 0, @[@"fixture-alias", @"fixture-normal", @"fixture-mid-fallback", @"fixture-missing"], @{}, ^(NSDictionary *names) {
            assert(NSThread.isMainThread && names.count == 2);
            assert([names[@"fixture-alias"] isEqual:@"この端末の別名"] && [names[@"fixture-normal"] isEqual:@"キャッシュの名前"]);
            assert(!names[@"fixture-mid-fallback"] && !names[@"fixture-missing"]);
            done = YES;
        });
        for (NSUInteger attempts = 0; !done && attempts < 100; attempts++)
            [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
        assert(done && atomic_load(&gReaderSchemaRejected) == 1 && !atomic_load(&gReaderFetchFailures));
        puts("PASS read/observation provenance, unknown dates preserved, five date locales/three timezones, cached alias-aware names, raw MID rejection, asynchronous owner-queue fetch, wrong-store rejection");
    }
    return 0;
}
#endif
