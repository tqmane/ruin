SDK := $(shell xcrun --sdk iphoneos --show-sdk-path)
CC := xcrun --sdk iphoneos clang
HEADER_DIRS := $(sort $(dir $(wildcard src/*/*.h))) vendor/fishhook
CPPFLAGS := $(addprefix -I,$(HEADER_DIRS))
CFLAGS := -arch arm64 -isysroot $(SDK) -miphoneos-version-min=18.0 -fobjc-arc -fblocks -Wall -Wextra -O2
SOURCES := $(sort $(wildcard src/*/*.m))
OBJECTS := $(SOURCES:%.m=build/%.o) build/fishhook.o build/SwiftFields.o

.PHONY: all check clean
all: build/RUIN.dylib build/insert_dylib
check: build/check_client_version_advertisement build/check_local_appearance build/check_legacy_messaging_configuration build/check_native_font

check: build/check_native_tab_availability build/check_read_range_codec build/check_native_range_queue build/check_features build/check_history build/check_swift_fields build/check_boundary build/check_unsend build/check_read_users build/check_unsend_operation build/check_mid build/check_reply build/check_marker_ui build/check_theme_shop build/check_readers_sheet build/check_native_title build/check_gif build/check_theme_store_download build/check_theme_version build/check_theme_store_resolver build/emit_theme_store_images build/check_native_theme_images build/check_theme_apply_event build/check_native_theme_registration build/check_native_theme_install build/check_native_theme_local_projection build/check_native_theme_local_policy build/check_native_theme_receipt build/check_native_theme_validation build/check_native_read_positions build/check_local_notifications
	@set -e; for fixture in $^; do codesign --force --sign - "$$fixture"; done
	./build/check_native_tab_availability
	./build/check_read_range_codec
	./build/check_native_range_queue
	./build/check_features
	./build/check_history
	./build/check_native_read_positions
	./build/check_swift_fields
	./build/check_boundary early
	./build/check_boundary late
	./build/check_unsend
	./build/check_read_users
	./build/check_read_users owned
	./build/check_read_users mismatch
	./build/check_unsend_operation
	./build/check_mid
	./build/check_mid mismatch
	./build/check_reply
	./build/check_marker_ui
	./build/check_theme_shop
	./build/check_theme_shop mismatch
	./build/check_readers_sheet
	./build/check_native_title
	./build/check_gif
	./build/check_theme_store_download
	./build/check_theme_version
	./build/check_theme_store_resolver
	./build/emit_theme_store_images > build/theme-store-images.js
	node --check build/theme-store-images.js
	node tests/check_theme_store_images.js build/theme-store-images.js
	./build/check_native_theme_images
	./build/check_theme_apply_event
	./build/check_native_theme_local_projection
	./build/check_native_theme_local_policy
	./build/check_native_theme_receipt
	./build/check_native_theme_validation
	./build/check_local_notifications
	./build/check_client_version_advertisement
	./build/check_local_appearance
	./build/check_legacy_messaging_configuration
	./build/check_native_font
	python3 tests/check_theme_archive.py
	python3 tools/patch_theme_persistence.py --check build/unsigned/Payload/LINE.app/LINE
	./build/check_native_theme_registration "build/unsigned/Payload/LINE.app/LineShopThemeRepository-Resources.bundle/Theme.momd/Theme 2.mom"
	./build/check_native_theme_install "build/manual-theme-downloads/34afc5b4-f330-40bc-a2ea-fae94207847a/328/EB2496FE-6830-4471-AB91-042275B519DB.linetheme"

build/check_native_theme_validation: src/themes/NativeThemeValidation.m src/themes/NativeThemeValidation.h
	mkdir -p build
	xcrun --sdk macosx clang -DRUIN_NATIVE_THEME_VALIDATION_HOST_CHECK=1 -fobjc-arc -fblocks -Wall -Wextra -Werror $(CPPFLAGS) src/themes/NativeThemeValidation.m -framework Foundation -framework CoreData -o $@

build/check_native_font: src/interface/NativeFontCustomization.m src/interface/NativeFontCustomization.h src/core/Features.h
	mkdir -p build
	xcrun --sdk macosx clang -DRUIN_NATIVE_FONT_HOST_CHECK=1 -fobjc-arc -fblocks -Wall -Wextra -Werror $(CPPFLAGS) src/interface/NativeFontCustomization.m -framework Foundation -o $@

build/check_legacy_messaging_configuration: src/messaging/LegacyMessagingConfiguration.m src/messaging/LegacyMessagingConfiguration.h
	mkdir -p build
	xcrun --sdk macosx clang -DRUIN_LEGACY_MESSAGING_CONFIGURATION_HOST_CHECK=1 -fobjc-arc -fblocks -Wall -Wextra -Werror $(CPPFLAGS) src/messaging/LegacyMessagingConfiguration.m -framework Foundation -o $@

build/check_local_appearance: src/interface/LocalAppearance.m src/interface/LocalAppearance.h
	mkdir -p build
	xcrun --sdk macosx clang -DRUIN_LOCAL_APPEARANCE_HOST_CHECK=1 -fobjc-arc -fblocks -Wall -Wextra -Werror $(CPPFLAGS) src/interface/LocalAppearance.m -framework Foundation -o $@

build/check_client_version_advertisement: src/platform/ClientVersionAdvertisement.m src/platform/ClientVersionAdvertisement.h src/core/Features.h
	mkdir -p build
	xcrun --sdk macosx clang -DRUIN_CLIENT_VERSION_ADVERTISEMENT_HOST_CHECK=1 -fobjc-arc -fblocks -Wall -Wextra -Werror $(CPPFLAGS) src/platform/ClientVersionAdvertisement.m -framework Foundation -o $@

build/check_local_notifications: src/platform/LocalNotifications.m src/platform/LocalNotifications.h tests/check_local_notifications.m
	mkdir -p build
	xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror $(CPPFLAGS) tests/check_local_notifications.m -framework Foundation -o $@

build/check_native_read_positions: src/messaging/NativeReadPositions.m src/messaging/NativeReadPositions.h tests/check_native_read_positions.m
	mkdir -p build
	xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror $(CPPFLAGS) src/messaging/NativeReadPositions.m tests/check_native_read_positions.m -framework Foundation -o $@

build/check_readers_sheet: src/messaging/ReadersSheet.m src/messaging/ReadersSheet.h
	mkdir -p build
	xcrun --sdk macosx clang -DRUIN_READERS_SHEET_HOST_CHECK=1 -fobjc-arc -fblocks -std=gnu11 -Wall -Wextra -Werror $(CPPFLAGS) src/messaging/ReadersSheet.m -framework Foundation -framework CoreData -o $@

build/check_theme_shop: src/themes/ThemeShop.m src/themes/ThemeShop.h
	mkdir -p build
	xcrun --sdk macosx clang -DRUIN_THEMESHOP_HOST_CHECK=1 -fobjc-arc -fblocks -Wall -Wextra -Werror $(CPPFLAGS) src/themes/ThemeShop.m -framework Foundation -o $@

build/check_marker_ui: src/core/Features.m src/core/Features.h src/messaging/MessageHistory.m src/messaging/MessageHistory.h src/messaging/UnsendMarkerUI.m src/messaging/UnsendMarkerUI.h src/messaging/NativeReadPositions.m src/messaging/NativeReadPositions.h
	mkdir -p build
	xcrun --sdk macosx clang -DRUIN_UNSEND_MARKER_UI_HOST_CHECK=1 -fobjc-arc -fblocks -std=gnu11 -Wall -Wextra -Werror $(CPPFLAGS) src/core/Features.m src/messaging/MessageHistory.m src/messaging/NativeReadPositions.m src/messaging/UnsendMarkerUI.m -framework Foundation -framework CoreData -framework CoreGraphics -lsqlite3 -o $@

build/check_reply: src/core/Features.m src/core/Features.h src/messaging/ReadOnReply.m src/messaging/ReadOnReply.h src/messaging/AutomaticReadGate.h tests/check_reply.m
	mkdir -p build
	xcrun --sdk macosx clang -fobjc-arc -fblocks -std=gnu11 -Wall -Wextra -Werror $(CPPFLAGS) src/core/Features.m src/messaging/ReadOnReply.m tests/check_reply.m -framework Foundation -framework CoreData -o $@

build/check_mid: src/interface/MIDLookup.m src/interface/MIDLookup.h
	mkdir -p build
	xcrun --sdk macosx clang -DRUIN_MIDLOOKUP_HOST_CHECK=1 -fobjc-arc -fblocks -Wall -Wextra -Werror $(CPPFLAGS) src/interface/MIDLookup.m -framework Foundation -o $@

build/check_unsend_operation: src/core/Features.m src/core/Features.h src/messaging/MessageHistory.m src/messaging/MessageHistory.h src/messaging/UnsendOperation.m src/messaging/UnsendOperation.h tests/check_unsend_operation.m src/messaging/NativeReadPositions.m src/messaging/NativeReadPositions.h
	mkdir -p build
	xcrun --sdk macosx clang -fobjc-arc -fblocks -std=gnu11 -Wall -Wextra -Werror $(CPPFLAGS) src/core/Features.m src/messaging/MessageHistory.m src/messaging/NativeReadPositions.m tests/check_unsend_operation.m -framework Foundation -framework CoreData -lsqlite3 -o $@

build/check_read_users: src/core/Features.m src/core/Features.h src/messaging/MessageHistory.m src/messaging/MessageHistory.h src/messaging/ReadUsersEvents.m src/messaging/ReadUsersEvents.h src/messaging/NativeReadPositions.m src/messaging/NativeReadPositions.h
	mkdir -p build
	xcrun --sdk macosx clang -DRUIN_READ_USERS_EVENTS_HOST_CHECK=1 -fobjc-arc -fblocks -std=gnu11 -Wall -Wextra -Werror $(CPPFLAGS) src/core/Features.m src/messaging/MessageHistory.m src/messaging/NativeReadPositions.m src/messaging/ReadUsersEvents.m -framework Foundation -framework CoreData -lsqlite3 -o $@

build/check_unsend: src/core/Features.m src/core/Features.h src/messaging/MessageHistory.m src/messaging/MessageHistory.h src/messaging/UnsendRetention.m src/messaging/UnsendRetention.h src/messaging/NativeReadPositions.m src/messaging/NativeReadPositions.h
	mkdir -p build
	xcrun --sdk macosx clang -DRUIN_UNSEND_HOST_CHECK=1 -fobjc-arc -fblocks -std=gnu11 -Wall -Wextra -Werror $(CPPFLAGS) src/core/Features.m src/messaging/MessageHistory.m src/messaging/NativeReadPositions.m src/messaging/UnsendRetention.m -framework Foundation -framework CoreData -lsqlite3 -o $@

build/check_features: src/core/Features.m src/core/Features.h tests/check_features.m
	mkdir -p build
	xcrun --sdk macosx clang -fobjc-arc -std=gnu11 -Wall -Wextra -Werror $(CPPFLAGS) -framework Foundation src/core/Features.m tests/check_features.m -o $@

build/check_history: src/core/Features.m src/core/Features.h src/messaging/MessageHistory.m src/messaging/MessageHistory.h tests/check_history.m src/messaging/NativeReadPositions.m src/messaging/NativeReadPositions.h
	mkdir -p build
	xcrun --sdk macosx clang -DRUIN_MESSAGE_HISTORY_HOST_CHECK=1 -fobjc-arc -fblocks -std=gnu11 -Wall -Wextra -Werror $(CPPFLAGS) src/core/Features.m src/messaging/MessageHistory.m src/messaging/NativeReadPositions.m tests/check_history.m -framework Foundation -framework CoreData -lsqlite3 -o $@

build/check_swift_fields: src/core/SwiftFields.swift
	mkdir -p build
	xcrun swiftc -parse-as-library -D RUIN_SWIFTFIELDS_TEST src/core/SwiftFields.swift -o $@

build/check_boundary: src/core/Features.m src/core/Features.h src/messaging/ReadBoundary.m src/messaging/ReadBoundary.h tests/check_boundary.m
	mkdir -p build
	xcrun --sdk macosx clang -DRUIN_BOUNDARY_HOST_CHECK=1 -fobjc-arc -fblocks -std=gnu11 -Wall -Wextra -Werror $(CPPFLAGS) src/core/Features.m src/messaging/ReadBoundary.m tests/check_boundary.m -framework Foundation -framework CoreData -o $@

build/%.o: %.m $(wildcard src/*/*.h) vendor/fishhook/fishhook.h
	mkdir -p $(@D)
	$(CC) $(CFLAGS) $(CPPFLAGS) -c $< -o $@

build/fishhook.o: vendor/fishhook/fishhook.c vendor/fishhook/fishhook.h
	mkdir -p build
	$(CC) -arch arm64 -isysroot $(SDK) -miphoneos-version-min=18.0 -O2 -c $< -o $@

build/SwiftFields.o: src/core/SwiftFields.swift src/core/SwiftFields.h
	mkdir -p build
	xcrun --sdk iphoneos swiftc -sdk $(SDK) -target arm64-apple-ios18.0 -parse-as-library -O -module-name RUINRuntime -emit-object $< -o $@

build/RUIN.dylib: $(OBJECTS)
	xcrun --sdk iphoneos swiftc -sdk $(SDK) -target arm64-apple-ios18.0 -emit-library $(OBJECTS) -framework Foundation -framework UIKit -framework WebKit -framework CoreGraphics -framework Security -framework CoreData -framework ImageIO -framework UniformTypeIdentifiers -framework UserNotifications -lsqlite3 -lz -Xlinker -install_name -Xlinker @rpath/RUIN.dylib -o $@

# Upstream: https://github.com/Tyilo/insert_dylib, pinned for reproducible builds.
build/insert_dylib.c:
	mkdir -p build
	curl -fL --retry 2 https://raw.githubusercontent.com/Tyilo/insert_dylib/eb7278162af8fcc372e7f2946a2dee6a386b17d8/insert_dylib/main.c -o $@

build/insert_dylib: build/insert_dylib.c
	xcrun clang -O2 $< -o $@
	codesign --force --sign - $@

clean:
	rm -rf build dist

build/check_native_title: src/interface/NativeChatControls.m
	mkdir -p build
	xcrun --sdk macosx clang -DRUIN_NATIVE_TITLE_HOST_CHECK=1 -fobjc-arc -fblocks -Wall -Wextra -Werror src/interface/NativeChatControls.m -framework Foundation -o $@

build/check_gif: src/messaging/GIFEncoder.m src/messaging/GIFEncoder.h tests/check_gif.m
	mkdir -p build
	xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror $(CPPFLAGS) src/messaging/GIFEncoder.m tests/check_gif.m -framework Foundation -framework ImageIO -framework CoreGraphics -o $@

build/check_theme_store_download: src/themes/ThemeStoreDownload.m src/themes/ThemeStoreDownload.h tests/check_theme_store_download.m
	mkdir -p build
	xcrun --sdk macosx clang -fobjc-arc -fblocks -std=gnu11 -Wall -Wextra -Werror -DRUIN_THEME_STORE_DOWNLOAD_HOST_CHECK $(CPPFLAGS) src/themes/ThemeStoreDownload.m tests/check_theme_store_download.m -framework Foundation -o $@

build/check_theme_version: src/themes/ThemeVersion.m src/themes/ThemeVersion.h tests/check_theme_version.m
	mkdir -p build
	xcrun --sdk macosx clang -fobjc-arc -Wall -Wextra -Werror $(CPPFLAGS) src/themes/ThemeVersion.m tests/check_theme_version.m -framework Foundation -o $@

build/check_theme_store_resolver: src/themes/ThemeStoreResolver.m src/themes/ThemeStoreResolver.h src/themes/ThemeVersion.m src/themes/ThemeVersion.h tests/check_theme_store_resolver.m
	mkdir -p build
	xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror $(CPPFLAGS) src/themes/ThemeVersion.m src/themes/ThemeStoreResolver.m tests/check_theme_store_resolver.m -framework Foundation -o $@

build/emit_theme_store_images: src/themes/ThemeStoreImages.m src/themes/ThemeStoreImages.h tests/emit_theme_store_images.m
	mkdir -p build
	xcrun --sdk macosx clang -fobjc-arc -Wall -Wextra -Werror -DRUIN_THEME_IMAGES_HOST_CHECK $(CPPFLAGS) src/themes/ThemeStoreImages.m tests/emit_theme_store_images.m -framework Foundation -o $@

build/check_native_theme_images: src/themes/NativeThemeImages.m src/themes/NativeThemeImages.h tests/check_native_theme_images.m
	mkdir -p build
	xcrun --sdk macosx clang -fobjc-arc -fblocks -std=gnu11 -Wall -Wextra -Werror -DRUIN_NATIVE_THEME_IMAGES_HOST_CHECK $(CPPFLAGS) src/themes/NativeThemeImages.m tests/check_native_theme_images.m -framework Foundation -o $@

build/check_theme_apply_event: src/themes/ThemeApplyEvent.m src/themes/ThemeApplyEvent.h tests/check_theme_apply_event.m
	mkdir -p build
	xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror $(CPPFLAGS) src/themes/ThemeApplyEvent.m tests/check_theme_apply_event.m -framework Foundation -o $@


build/check_native_theme_registration: src/themes/NativeThemeRegistration.m src/themes/NativeThemeRegistration.h src/themes/NativeThemeLocalPolicy.m src/themes/NativeThemeLocalPolicy.h src/themes/NativeThemeReceipt.m src/themes/NativeThemeReceipt.h tests/check_native_theme_registration.m
	mkdir -p build
	xcrun --sdk macosx clang -DRUIN_NATIVE_THEME_REGISTRATION_HOST_CHECK=1 -fobjc-arc -fblocks -Wall -Wextra -Werror $(CPPFLAGS) src/themes/NativeThemeRegistration.m src/themes/NativeThemeLocalPolicy.m src/themes/NativeThemeReceipt.m tests/check_native_theme_registration.m -framework Foundation -framework CoreData -o $@


build/check_native_theme_install: src/themes/NativeThemeInstall.m src/themes/NativeThemeInstall.h src/themes/NativeThemeRegistration.m src/themes/NativeThemeRegistration.h src/themes/NativeThemeLocalPolicy.m src/themes/NativeThemeLocalPolicy.h src/themes/ThemeArchive.m src/themes/ThemeArchive.h src/themes/ThemeVersion.m tests/check_native_theme_install.m
	mkdir -p build
	xcrun --sdk macosx clang -DRUIN_NATIVE_THEME_REGISTRATION_HOST_CHECK=1 -fobjc-arc -fblocks -Wall -Wextra -Werror $(CPPFLAGS) src/themes/NativeThemeInstall.m src/themes/NativeThemeRegistration.m src/themes/NativeThemeLocalPolicy.m src/themes/NativeThemeReceipt.m src/themes/ThemeArchive.m src/themes/ThemeVersion.m tests/check_native_theme_install.m -framework Foundation -framework CoreData -lz -o $@


build/check_native_theme_local_projection: src/themes/NativeThemeLocalPolicy.m src/themes/NativeThemeLocalPolicy.h src/themes/NativeThemeReceipt.m src/themes/NativeThemeReceipt.h tests/check_native_theme_local_projection.m
	mkdir -p build
	xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror $(CPPFLAGS) src/themes/NativeThemeLocalPolicy.m src/themes/NativeThemeReceipt.m tests/check_native_theme_local_projection.m -framework Foundation -framework CoreData -o $@


build/check_native_theme_local_policy: src/themes/NativeThemeLocalPolicy.m src/themes/NativeThemeLocalPolicy.h src/themes/NativeThemeReceipt.m src/themes/NativeThemeReceipt.h tests/check_native_theme_local_policy.m
	mkdir -p build
	xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror $(CPPFLAGS) src/themes/NativeThemeLocalPolicy.m src/themes/NativeThemeReceipt.m tests/check_native_theme_local_policy.m -framework Foundation -framework CoreData -o $@


build/check_native_theme_receipt: src/themes/NativeThemeReceipt.m src/themes/NativeThemeReceipt.h tests/check_native_theme_receipt.m
	mkdir -p build
	xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror $(CPPFLAGS) src/themes/NativeThemeReceipt.m tests/check_native_theme_receipt.m -framework Foundation -o $@

build/check_native_range_queue: src/messaging/NativeReadRangeSync.m src/messaging/NativeReadRangeSync.h
	mkdir -p build
	xcrun --sdk macosx clang -DRUIN_NATIVE_READ_RANGE_SYNC_HOST_CHECK -fobjc-arc -fblocks -Wall -Wextra -Werror $(CPPFLAGS) src/messaging/NativeReadRangeSync.m -framework Foundation -o $@

build/check_read_range_codec: src/messaging/ReadRangeCodec.m src/messaging/ReadRangeCodec.h tests/check_read_range_codec.m
	mkdir -p build
	xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror $(CPPFLAGS) src/messaging/ReadRangeCodec.m tests/check_read_range_codec.m -framework Foundation -o $@

build/check_native_tab_availability: src/interface/NativeTabAvailability.m src/interface/NativeTabAvailability.h
	mkdir -p build
	xcrun --sdk macosx clang -DRUIN_NATIVE_TAB_AVAILABILITY_HOST_CHECK -fobjc-arc -fblocks -Wall -Wextra -Werror $(CPPFLAGS) src/interface/NativeTabAvailability.m -framework Foundation -o $@
