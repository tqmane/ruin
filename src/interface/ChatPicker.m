#import "ChatPicker.h"
#import "../core/Localization.h"

static NSArray *PickerSavedKeys(id values) {
    NSMutableOrderedSet *keys = [NSMutableOrderedSet orderedSet];
    if ([values isKindOfClass:NSArray.class]) for (id key in values)
        if ([key isKindOfClass:NSString.class] &&
            (([key hasPrefix:@"chat:"] && [key length] > 5) || ([key hasPrefix:@"squareChat:"] && [key length] > 11))) [keys addObject:key];
    return keys.array;
}
static NSDictionary *PickerSavedAliases(id values) {
    NSMutableDictionary *aliases = [NSMutableDictionary dictionary];
    if ([values isKindOfClass:NSDictionary.class]) for (id key in values)
        if ([key isKindOfClass:NSString.class] && [values[key] isKindOfClass:NSString.class]) aliases[key] = values[key];
    return aliases;
}

// Keep saved entries that are not in the current native list. Their IDs stay
// internal; the user can still remove an old exception or reset an old alias.
static NSArray *PickerRows(NSArray *catalog, BOOL names, NSSet *selected, NSDictionary *aliases) {
    NSMutableArray *chosen = [NSMutableArray array], *others = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    for (NSDictionary *item in catalog) {
        NSString *key = item[names ? @"aliasKey" : @"readKey"];
        if (![key isKindOfClass:NSString.class] || !key.length || [seen containsObject:key]) continue;
        [seen addObject:key];
        NSMutableDictionary *row = [item mutableCopy]; row[@"key"] = key;
        BOOL pinned = names ? [aliases[key] length] > 0 : [selected containsObject:key];
        [(pinned ? chosen : others) addObject:[row copy]];
    }
    NSArray *saved = names ? [aliases.allKeys sortedArrayUsingSelector:@selector(compare:)] :
        [selected.allObjects sortedArrayUsingSelector:@selector(compare:)];
    NSUInteger index = 0;
    for (NSString *key in saved) {
        if ([seen containsObject:key] || (names && ![aliases[key] length])) continue;
        [chosen addObject:@{@"key":key, @"name":@"", @"kind":@"unknown", @"unknownIndex":@(++index)}];
    }
    return [chosen arrayByAddingObjectsFromArray:others];
}

static BOOL PickerContains(NSString *text, NSString *query) {
    return !query.length || [text rangeOfString:query options:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch | NSWidthInsensitiveSearch].location != NSNotFound;
}

static NSString *PickerAvatarRequestKey(NSString *account, NSURL *url) {
    return account.length && url.absoluteString.length ?
        [NSString stringWithFormat:@"%@\n%@", account, url.absoluteString] : nil;
}

static BOOL PickerCanLoadAvatar(NSString *key, NSSet *pending, NSSet *failed) {
    return key.length && ![pending containsObject:key] && ![failed containsObject:key];
}

static void PickerFinishAvatarRequest(NSMutableSet *pending, NSMutableSet *failed,
                                     NSString *key, BOOL success, BOOL accountIsCurrent) {
    if (!key.length) return;
    [pending removeObject:key];
    if (!accountIsCurrent) return;
    if (success) [failed removeObject:key];
    else [failed addObject:key];
}

#if !defined(RUIN_CHAT_PICKER_HOST_CHECK)
#import <UIKit/UIKit.h>
#import "ChatCatalog.h"
#import "../core/Features.h"

@interface RUINChatPicker : UITableViewController <UISearchResultsUpdating>
@property(nonatomic) BOOL names, loading;
@property(nonatomic, copy) NSString *account;
@property(nonatomic, copy) dispatch_block_t changed;
@property(nonatomic, copy) NSArray<NSDictionary *> *catalog, *rows, *visible;
@property(nonatomic, copy) NSDictionary *aliases;
@property(nonatomic, strong) NSMutableSet *selected, *pendingImages, *failedImages;
@property(nonatomic, strong) NSCache *images;
@end

static NSURL *PickerAvatarURL(NSDictionary *item) {
    NSString *value = item[@"pictureStatus"];
    if (![value isKindOfClass:NSString.class] || !value.length) value = item[@"pictureURL"];
    if (![value isKindOfClass:NSString.class] || !value.length || value.length > 2048) return nil;
    if (![value containsString:@"://"]) {
        NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-/"];
        if ([value rangeOfCharacterFromSet:allowed.invertedSet].location != NSNotFound || [value containsString:@".."]) return nil;
        value = [@"https://profile.line-scdn.net/" stringByAppendingString:[value stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]]];
    }
    NSURL *url = [NSURL URLWithString:value];
    if (![url.scheme.lowercaseString isEqual:@"https"] || url.user || url.password || url.fragment ||
        ![@[@"profile.line-scdn.net", @"static.line-scdn.net", @"obs.line-scdn.net"] containsObject:url.host.lowercaseString]) return nil;
    // LINE's profile CDN provides 51px avatars at /small.
    if ([url.host isEqual:@"profile.line-scdn.net"] && ![@[@"small", @"large"] containsObject:url.lastPathComponent])
        url = [url URLByAppendingPathComponent:@"small"];
    return url;
}

@implementation RUINChatPicker
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = RUINLocalizedString(self.names ? @"settings.chat_names" : @"settings.read_exceptions");
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    UISearchController *search = [[UISearchController alloc] initWithSearchResultsController:nil];
    search.searchResultsUpdater = self; search.obscuresBackgroundDuringPresentation = NO;
    search.searchBar.placeholder = RUINLocalizedString(@"chat_picker.search_placeholder");
    self.navigationItem.searchController = search; self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;
    self.images = [NSCache new]; self.images.countLimit = 200;
    self.pendingImages = [NSMutableSet set];
    self.failedImages = [NSMutableSet set];
    self.tableView.rowHeight = UITableViewAutomaticDimension; self.tableView.estimatedRowHeight = 70;
    self.refreshControl = [UIRefreshControl new];
    [self.refreshControl addTarget:self action:@selector(loadChats) forControlEvents:UIControlEventValueChanged];
    [self loadChats];
}
- (void)loadChats {
    // loadChats is called at entry and by the explicit pull-to-refresh control.
    [self.failedImages removeAllObjects];
    self.loading = YES; [self applySearch];
    __weak typeof(self) weak = self;
    RUINLoadChatCatalog(^(NSArray *items, NSString *account) {
        RUINChatPicker *owner = weak; if (!owner) return;
        owner.loading = NO; owner.catalog = items; owner.account = account;
        owner.selected = [NSMutableSet setWithArray:PickerSavedKeys([NSUserDefaults.standardUserDefaults objectForKey:RUINReadExceptionsDefaultsKey])];
        owner.aliases = PickerSavedAliases([NSUserDefaults.standardUserDefaults objectForKey:RUINLocalNamesByIdentityDefaultsKey]);
        owner.rows = account.length ? PickerRows(items, owner.names, owner.selected, owner.aliases) : @[];
        [owner.refreshControl endRefreshing]; [owner applySearch];
    });
}
- (NSString *)nameForRow:(NSDictionary *)row {
    NSString *alias = self.aliases[row[@"aliasKey"] ?: row[@"key"]];
    if (alias.length) return alias;
    NSString *name = row[@"name"];
    return name.length ? name : [NSString stringWithFormat:RUINLocalizedString(@"chat_picker.unlisted_count"), (unsigned long)[row[@"unknownIndex"] unsignedIntegerValue]];
}
- (void)applySearch {
    NSString *query = self.navigationItem.searchController.searchBar.text ?: @"";
    NSMutableArray *rows = [NSMutableArray array];
    for (NSDictionary *row in self.rows)
        if (PickerContains([self nameForRow:row], query) || PickerContains(row[@"name"] ?: @"", query)) [rows addObject:row];
    self.visible = rows;
    self.navigationItem.prompt = self.names ? nil : [NSString stringWithFormat:RUINLocalizedString(@"chat_picker.selected_count"), (unsigned long)self.selected.count];
    UILabel *empty = [UILabel new]; empty.numberOfLines = 0; empty.textAlignment = NSTextAlignmentCenter;
    empty.textColor = UIColor.secondaryLabelColor; empty.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    empty.text = self.loading ? RUINLocalizedString(@"chat_picker.loading") :
        self.catalog.count ? RUINLocalizedString(@"chat_picker.empty") :
        RUINLocalizedString(@"chat_picker.open_list_first");
    self.tableView.backgroundView = rows.count ? nil : empty;
    [self.tableView reloadData];
}
- (void)updateSearchResultsForSearchController:(__unused UISearchController *)search { [self applySearch]; }
- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(__unused NSInteger)section { return self.visible.count; }
- (NSString *)tableView:(__unused UITableView *)tableView titleForFooterInSection:(__unused NSInteger)section {
    return self.names ? RUINLocalizedString(@"settings.chat_names_footer") :
        RUINLocalizedString(@"chat_picker.read_exceptions_help");
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)index {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"chat"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"chat"];
    NSDictionary *row = self.visible[index.row];
    UIListContentConfiguration *content = cell.defaultContentConfiguration;
    content.text = [self nameForRow:row];
    content.textProperties.numberOfLines = 2;
    NSString *native = row[@"name"];
    if (self.names && native.length && ![native isEqual:content.text])
        content.secondaryText = [NSString stringWithFormat:RUINLocalizedString(@"names.original_name"), native];
    else if ([row[@"kind"] isEqual:@"group"]) content.secondaryText = RUINLocalizedString(@"chat_picker.group_chat");
    else if ([row[@"kind"] isEqual:@"square"]) content.secondaryText = RUINLocalizedString(@"chat_picker.open_chat");
    else if ([row[@"kind"] isEqual:@"oneOnOne"]) content.secondaryText = RUINLocalizedString(@"chat_picker.direct_chat");
    NSURL *url = PickerAvatarURL(row);
    NSString *account = [self.account copy];
    NSString *requestKey = PickerAvatarRequestKey(account, url);
    content.image = requestKey ? [self.images objectForKey:requestKey] : nil;
    if (!content.image) content.image = [UIImage systemImageNamed:[row[@"kind"] isEqual:@"group"] ? @"person.2.circle.fill" : @"person.crop.circle.fill"
        withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:44 weight:UIImageSymbolWeightRegular]];
    content.imageProperties.maximumSize = CGSizeMake(44, 44); content.imageProperties.cornerRadius = 22;
    content.imageProperties.reservedLayoutSize = CGSizeMake(44, 44);
    content.imageProperties.tintColor = UIColor.secondaryLabelColor;
    cell.contentConfiguration = content;
    cell.accessoryType = self.names ? UITableViewCellAccessoryDisclosureIndicator :
        [self.selected containsObject:row[@"key"]] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    cell.accessibilityTraits = UIAccessibilityTraitButton |
        (!self.names && [self.selected containsObject:row[@"key"]] ? UIAccessibilityTraitSelected : 0);
    if (url && requestKey && ![self.images objectForKey:requestKey] &&
        PickerCanLoadAvatar(requestKey, self.pendingImages, self.failedImages)) {
        [self.pendingImages addObject:requestKey];
        __weak typeof(self) weak = self;
        [[NSURLSession.sharedSession dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            UIImage *image = !error && data.length <= 4 * 1024 * 1024 && [response.MIMEType hasPrefix:@"image/"] ? [UIImage imageWithData:data] : nil;
            if (image.size.width > 4096 || image.size.height > 4096) image = nil;
            dispatch_async(dispatch_get_main_queue(), ^{
                RUINChatPicker *owner = weak; if (!owner) return;
                BOOL accountIsCurrent = [owner.account isEqualToString:account] &&
                    [RUINChatCatalogAccount() isEqualToString:account];
                PickerFinishAvatarRequest(owner.pendingImages, owner.failedImages, requestKey,
                    image != nil, accountIsCurrent);
                if (!accountIsCurrent || !image) return;
                [owner.images setObject:image forKey:requestKey];
                // Reconfigure current rows; never assign a late avatar to a reused cell.
                [owner.tableView reloadData];
            });
        }] resume];
    }
    return cell;
}
- (BOOL)accountIsCurrent {
    if (self.account.length && [self.account isEqual:RUINChatCatalogAccount()]) return YES;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"RUIN"
        message:RUINLocalizedString(@"chat_picker.account_changed") preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:RUINLocalizedString(@"common.confirm") style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
    return NO;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)index {
    [tableView deselectRowAtIndexPath:index animated:YES];
    if (![self accountIsCurrent]) return;
    NSDictionary *row = self.visible[index.row]; NSString *key = row[@"key"];
    if (!self.names) {
        NSMutableOrderedSet *saved = [NSMutableOrderedSet orderedSetWithArray:PickerSavedKeys([NSUserDefaults.standardUserDefaults objectForKey:RUINReadExceptionsDefaultsKey])];
        if ([saved containsObject:key]) [saved removeObject:key]; else [saved addObject:key];
        [NSUserDefaults.standardUserDefaults setObject:saved.array forKey:RUINReadExceptionsDefaultsKey];
        self.selected = [NSMutableSet setWithArray:saved.array];
        if (self.changed) self.changed(); else RUINInstallFeatures();
        [self applySearch];
        return;
    }
    UIAlertController *prompt = [UIAlertController alertControllerWithTitle:[self nameForRow:row]
        message:RUINLocalizedString(@"settings.chat_names_footer") preferredStyle:UIAlertControllerStyleAlert];
    [prompt addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = RUINLocalizedString(@"names.local_display_name");
        field.text = [self.aliases[key] length] ? self.aliases[key] : row[@"name"];
    }];
    __weak typeof(self) weak = self; __weak UIAlertController *weakPrompt = prompt;
    void (^save)(NSString *) = ^(NSString *name) {
        RUINChatPicker *owner = weak; if (!owner || ![owner accountIsCurrent]) return;
        RUINSetLocalName(key, name); if (owner.changed) owner.changed();
        owner.aliases = PickerSavedAliases([NSUserDefaults.standardUserDefaults objectForKey:RUINLocalNamesByIdentityDefaultsKey]);
        owner.rows = PickerRows(owner.catalog, YES, owner.selected, owner.aliases); [owner applySearch];
    };
    [prompt addAction:[UIAlertAction actionWithTitle:RUINLocalizedString(@"common.cancel") style:UIAlertActionStyleCancel handler:nil]];
    [prompt addAction:[UIAlertAction actionWithTitle:RUINLocalizedString(@"common.save") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        save([weakPrompt.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"");
    }]];
    [prompt addAction:[UIAlertAction actionWithTitle:RUINLocalizedString(@"names.reset_action") style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) { save(@""); }]];
    [self presentViewController:prompt animated:YES completion:nil];
}
@end

static void OpenPicker(UIViewController *source, BOOL names, dispatch_block_t changed) {
    RUINChatPicker *picker = [[RUINChatPicker alloc] initWithStyle:UITableViewStyleInsetGrouped];
    picker.names = names; picker.changed = changed;
    [source.navigationController pushViewController:picker animated:YES];
}
void RUINOpenReadExceptionPicker(UIViewController *source, dispatch_block_t changed) { OpenPicker(source, NO, changed); }
void RUINOpenLocalNamePicker(UIViewController *source, dispatch_block_t changed) { OpenPicker(source, YES, changed); }

#else
#import <assert.h>
int main(void) {
    @autoreleasepool {
        NSDictionary *row = @{@"readKey":@"chat:internal", @"aliasKey":@"user:internal", @"name":@"Alice"};
        NSArray *rows = PickerRows(@[row], NO, [NSSet setWithObjects:@"chat:internal", @"chat:missing", nil], @{});
        assert(rows.count == 2 && [rows[1][@"unknownIndex"] intValue] == 1);
        assert([rows[1][@"name"] length] == 0); // No raw identifier becomes a display name.
        NSDictionary *aliases = @{@"user:internal":@"Local Alice", @"group:missing":@"Old group"};
        rows = PickerRows(@[row], YES, [NSSet set], aliases);
        assert(rows.count == 2 && [rows[1][@"key"] isEqual:@"group:missing"]);
        assert(PickerContains(@"Alice", @"ALICE") && !PickerContains(@"Alice", @"chat:internal"));
        assert(PickerSavedKeys(@[@"chat:missing", @7, @"squareChat:room", @"user:other", @"chat:missing"]).count == 2);
        assert(PickerSavedAliases(@{@"user:internal":@"Local", @"group:bad":@7}).count == 1);
        NSURL *avatarURL = [NSURL URLWithString:@"https://profile.line-scdn.net/avatar/small"];
        NSString *accountA = PickerAvatarRequestKey(@"u111", avatarURL);
        NSString *accountB = PickerAvatarRequestKey(@"u222", avatarURL);
        assert(![accountA isEqualToString:accountB]);
        NSMutableSet *pending = [NSMutableSet setWithObject:accountA];
        NSMutableSet *failed = [NSMutableSet set];
        assert(!PickerCanLoadAvatar(accountA, pending, failed));
        PickerFinishAvatarRequest(pending, failed, accountA, NO, YES);
        assert(![pending containsObject:accountA] && [failed containsObject:accountA]);
        assert(!PickerCanLoadAvatar(accountA, pending, failed)); // No layout-driven retry loop.
        [failed removeAllObjects]; // Explicit refresh permits retry.
        assert(PickerCanLoadAvatar(accountA, pending, failed));
        [pending addObject:accountA];
        PickerFinishAvatarRequest(pending, failed, accountA, NO, NO);
        assert(![pending containsObject:accountA] && ![failed containsObject:accountA]); // Stale account.
        puts("PASS visual picker keeps unavailable saved rules and aliases; names/search do not expose identifiers");
    }
}
#endif
