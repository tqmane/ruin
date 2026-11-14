SDK = $(shell xcrun --sdk iphoneos --show-sdk-path)
CC := xcrun --sdk iphoneos clang
VERSION_MAPPING_SOURCES := $(wildcard src/known/versions/*.m)
HOST_COMMON := $(wildcard src/known/*.m) $(VERSION_MAPPING_SOURCES)
HOST_CC = xcrun --sdk macosx clang -DRUIN_HOST_CHECK=1 -fblocks $(HOST_COMMON)
export RUIN_TEST_RESOURCE_BUNDLE := $(CURDIR)/resources/RUINResources.bundle
HOST_WARNINGS := -Wall -Wextra -Werror
RUIN_BUILD_VERSION ?= $(shell cat VERSION)
HEADER_DIRS := $(sort $(dir $(wildcard src/*/*.h))) vendor/fishhook
CPPFLAGS := $(addprefix -I,$(HEADER_DIRS)) $(addprefix -Ibuild/logos/,$(filter src/%,$(HEADER_DIRS)))
PERL ?= perl
LOGOS := vendor/logos/bin/logos.pl
LOGOS_SOURCES := $(sort $(wildcard src/*/*.x))
LOGOS_GENERATED := $(LOGOS_SOURCES:%.x=build/logos/%.m)
LOGOS_DEPS := $(wildcard \
	vendor/logos/bin/*.pl \
	vendor/logos/bin/lib/*.pm \
	vendor/logos/bin/lib/Logos/*.pm \
	vendor/logos/bin/lib/Logos/Generator/*.pm \
	vendor/logos/bin/lib/Logos/Generator/*/*.pm \
	vendor/logos/bin/lib/Logos/Patch/Source/*.pm)
# Host fixtures compile the same generated hooks as the iOS dylib.
source = $(if $(filter $(1:.m=.x),$(LOGOS_SOURCES)),build/logos/$(1),$(1))
CFLAGS = -isysroot $(SDK) -miphoneos-version-min=18.0 -fobjc-arc -fblocks -Wall -Wextra -O2 \
	-DRUIN_BUILD_VERSION='@"$(RUIN_BUILD_VERSION)"'
SOURCES := $(sort $(wildcard src/*/*.m) $(VERSION_MAPPING_SOURCES))
SWIFT_SOURCES := $(sort $(wildcard src/*/*.swift))
RUIN_ARCHS := arm64 arm64e
arch_objects = $(patsubst %.m,build/$(1)/%.o,$(SOURCES)) $(patsubst %.x,build/$(1)/%.o,$(LOGOS_SOURCES)) build/$(1)/fishhook.o build/$(1)/SwiftFields.o

.PHONY: all check check-host check-portable check-packaging check-fixtures check-mapping-manifest logos clean dist version FORCE
all: build/RUIN.dylib build/insert_dylib
FORCE:
version:
	@printf '%s\n' "$(RUIN_BUILD_VERSION)"
dist: build/RUIN.dylib
	python3 tools/distribute.py --version "$(RUIN_BUILD_VERSION)"
logos: $(LOGOS_GENERATED)
check: check-fixtures check-packaging
check-portable: logos
	python3 -m unittest discover -s tests -p 'test_*.py' -v

check-packaging: build/insert_dylib build/RUIN.dylib
	python3 tests/check_packaging_tools.py

# These two integration checks require private, locally supplied fixtures.
LINE_APP ?= build/unsigned/Payload/LINE.app
THEME_ARCHIVE ?= build/manual-theme-downloads/34afc5b4-f330-40bc-a2ea-fae94207847a/328/EB2496FE-6830-4471-AB91-042275B519DB.linetheme
check-fixtures: check-host build/check_native_theme_registration build/check_native_theme_install
	@test -f "$(LINE_APP)/LineShopThemeRepository-Resources.bundle/Theme.momd/Theme 2.mom" || (echo 'Set LINE_APP to the extracted source app.'; exit 1)
	@test -f "$(THEME_ARCHIVE)" || (echo 'Set THEME_ARCHIVE to a locally obtained theme archive.'; exit 1)
	python3 tools/macho_integrity.py "$(LINE_APP)/LINE"
	python3 tests/check_theme_persistence.py "$(LINE_APP)/LINE"
	python3 tests/check_native_tabs.py "$(LINE_APP)/LINE"
	./build/check_native_theme_registration "$(LINE_APP)/LineShopThemeRepository-Resources.bundle/Theme.momd/Theme 2.mom"
	./build/check_native_theme_install "$(THEME_ARCHIVE)"

HOST_FIXTURES := \
	build/check_chat_catalog \
	build/check_chat_picker \
	build/check_bundle_identity \
	build/check_known_mappings \
	build/check_main_image_resolver \
	build/check_feature_image \
	build/check_keychain \
	build/check_sideload \
	build/check_app_group_storage \
	build/check_client_version_advertisement \
	build/check_local_appearance \
	build/check_localization \
	build/check_legacy_messaging_configuration \
	build/check_native_tab_availability \
	build/check_read_range_codec \
	build/check_native_range_queue \
	build/check_features \
	build/check_history \
	build/check_swift_fields \
	build/check_boundary \
	build/check_unsend \
	build/check_read_users \
	build/check_unsend_operation \
	build/check_mid \
	build/check_reply \
	build/check_read_until \
	build/check_marker_ui \
	build/check_theme_shop \
	build/check_readers_sheet \
	build/check_native_title \
	build/check_gif \
	build/check_theme_store_download \
	build/check_theme_version \
	build/check_theme_store_resolver \
	build/emit_theme_store_images \
	build/check_native_theme_images \
	build/check_theme_apply_event \
	build/check_native_theme_registration \
	build/check_native_theme_install \
	build/check_native_theme_local_projection \
	build/check_native_theme_local_policy \
	build/check_native_theme_receipt \
	build/check_native_theme_validation \
	build/check_native_read_positions \
	build/check_local_notifications \
	build/check_retained_media_store
$(HOST_FIXTURES): $(wildcard src/*/*.h) $(HOST_COMMON)

build/export_version_mappings: tools/export_version_mappings.m $(HOST_COMMON) $(wildcard src/*/*.h)
	mkdir -p build
	$(HOST_CC) -fobjc-arc -fblocks $(HOST_WARNINGS) $(CPPFLAGS) $< -framework Foundation -o $@

check-mapping-manifest: build/export_version_mappings tests/fixtures/version-mappings.json
	./build/export_version_mappings --check tests/fixtures/version-mappings.json

check-host: check-portable check-mapping-manifest $(HOST_FIXTURES)
	python3 tests/check_siri_compatibility.py
	python3 tests/check_theme_store_web_notifications.py
	python3 tests/check_theme_product_identity.py
	python3 tests/check_theme_ui_resolution.py
	node tests/check_theme_store_web.js
	python3 tests/check_messaging_review.py
	python3 tests/check_interface_review.py
	python3 tests/check_runtime_latency.py
	python3 tests/check_interface_hotpath.py
	python3 tests/check_menu_hotpath.py
	@set -e; for fixture in $(filter build/%,$^); do codesign --force --sign - "$$fixture"; done
	./build/check_native_tab_availability
	./build/check_bundle_identity
	./build/check_known_mappings
	./build/check_main_image_resolver
	./build/check_feature_image
	./build/check_keychain
	./build/check_sideload
	./build/check_app_group_storage
	./build/check_chat_picker
	./build/check_chat_catalog
	./build/check_read_range_codec
	./build/check_native_range_queue
	./build/check_features
	./build/check_history
	./build/check_retained_media_store
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
	./build/check_read_until
	./build/check_read_until native-owner
	./build/check_read_until chat-abi
	./build/check_read_until service-abi
	./build/check_read_until mid-abi
	./build/check_read_until swift-root
	./build/check_marker_ui
	python3 tests/check_marker_hotpath.py
	python3 tests/check_marker_archive.py
	python3 tests/check_retained_getter_hotpath.py
	./build/check_theme_shop
	./build/check_theme_shop mismatch
	tests/check_theme_route_scope.sh
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
	./build/check_localization "$(CURDIR)/resources/RUINResources.bundle"
	./build/check_legacy_messaging_configuration
	python3 tests/check_secondary_login.py
	python3 tests/check_local_font_scope.py
	python3 tests/check_native_mute_send.py
	python3 tests/check_confirmations.py
	python3 tests/check_retained_video_cache.py
	python3 tests/check_theme_archive.py

build/check_chat_catalog: $(call source,src/interface/ChatCatalog.m) src/interface/ChatCatalog.h
	mkdir -p build
	$(HOST_CC) -DRUIN_CHAT_CATALOG_HOST_CHECK=1 -fobjc-arc -fblocks $(HOST_WARNINGS) $(CPPFLAGS) \
		$(call source,src/interface/ChatCatalog.m) -framework Foundation -framework CoreData -o $@

build/check_chat_picker: src/interface/ChatPicker.m src/interface/ChatPicker.h
	mkdir -p build
	$(HOST_CC) -DRUIN_CHAT_PICKER_HOST_CHECK=1 -fobjc-arc -fblocks $(HOST_WARNINGS) $(CPPFLAGS) \
		src/interface/ChatPicker.m -framework Foundation -o $@

build/check_bundle_identity: $(call source,src/platform/BundleIdentity.m) src/platform/BundleIdentity.h
	mkdir -p build
	$(HOST_CC) -DRUIN_BUNDLE_IDENTITY_HOST_CHECK=1 -fobjc-arc -fblocks $(HOST_WARNINGS) $(CPPFLAGS) \
		$(call source,src/platform/BundleIdentity.m) -framework Foundation -o $@

build/check_keychain: tests/check_keychain.m src/platform/Keychain.m
	mkdir -p build
	$(HOST_CC) -fobjc-arc -fblocks $(HOST_WARNINGS) $(CPPFLAGS) \
		tests/check_keychain.m -framework Foundation -framework Security -o $@

build/check_known_mappings: tests/check_known_mappings.m
	mkdir -p build
	$(HOST_CC) -fobjc-arc -fblocks $(HOST_WARNINGS) $(CPPFLAGS) \
		tests/check_known_mappings.m -framework Foundation -o $@

build/check_main_image_resolver: tests/check_main_image_resolver.m
	mkdir -p build
	$(HOST_CC) -fobjc-arc -fblocks $(HOST_WARNINGS) $(CPPFLAGS) \
		tests/check_main_image_resolver.m -framework Foundation -o $@

build/check_sideload: $(call source,src/platform/Sideload.m)
	mkdir -p build
	$(HOST_CC) -DRUIN_SIDELOAD_HOST_CHECK=1 -fobjc-arc -fblocks $(HOST_WARNINGS) $(CPPFLAGS) \
		$(call source,src/platform/Sideload.m) -framework Foundation -o $@

build/check_app_group_storage: src/platform/AppGroupStorage.m tests/check_app_group_storage.m
	mkdir -p build
	$(HOST_CC) -fobjc-arc -fblocks $(HOST_WARNINGS) $(CPPFLAGS) \
		src/platform/AppGroupStorage.m tests/check_app_group_storage.m -framework Foundation -o $@

build/check_native_theme_validation: $(call source,src/themes/NativeThemeValidation.m) \
	src/themes/NativeThemeValidation.h
	mkdir -p build
	$(HOST_CC) -DRUIN_NATIVE_THEME_VALIDATION_HOST_CHECK=1 -fobjc-arc -fblocks $(HOST_WARNINGS) $(CPPFLAGS) \
		$(call source,src/themes/NativeThemeValidation.m) -framework Foundation -framework CoreData -o $@

build/check_legacy_messaging_configuration: $(call source,src/messaging/LegacyMessagingConfiguration.m) \
	src/messaging/LegacyMessagingConfiguration.h
	mkdir -p build
	$(HOST_CC) -DRUIN_LEGACY_MESSAGING_CONFIGURATION_HOST_CHECK=1 -fobjc-arc -fblocks $(HOST_WARNINGS) \
		$(CPPFLAGS) $(call source,src/messaging/LegacyMessagingConfiguration.m) -framework Foundation -o $@

build/check_local_appearance: $(call source,src/interface/LocalAppearance.m) src/interface/LocalAppearance.h
	mkdir -p build
	$(HOST_CC) -DRUIN_LOCAL_APPEARANCE_HOST_CHECK=1 -fobjc-arc -fblocks $(HOST_WARNINGS) $(CPPFLAGS) \
		$(call source,src/interface/LocalAppearance.m) -framework Foundation -o $@

build/check_localization: src/core/Localization.m src/core/Localization.h tests/check_localization.m
	mkdir -p build
	$(HOST_CC) -fobjc-arc -fblocks $(HOST_WARNINGS) $(CPPFLAGS) tests/check_localization.m \
		-framework Foundation -o $@

build/check_client_version_advertisement: $(call source,src/platform/ClientVersionAdvertisement.m) \
	src/platform/ClientVersionAdvertisement.h src/core/Features.h
	mkdir -p build
	$(HOST_CC) -DRUIN_CLIENT_VERSION_ADVERTISEMENT_HOST_CHECK=1 -fobjc-arc -fblocks $(HOST_WARNINGS) $(CPPFLAGS) \
		$(call source,src/platform/ClientVersionAdvertisement.m) -framework Foundation -o $@

build/check_local_notifications: $(call source,src/platform/LocalNotifications.m) \
	src/platform/LocalNotifications.h tests/check_local_notifications.m
	mkdir -p build
	$(HOST_CC) -fobjc-arc -fblocks $(HOST_WARNINGS) $(CPPFLAGS) tests/check_local_notifications.m \
		-framework Foundation -o $@

build/check_native_read_positions: $(call source,src/messaging/NativeReadPositions.m) \
	src/messaging/NativeReadPositions.h tests/check_native_read_positions.m
	mkdir -p build
	$(HOST_CC) -fobjc-arc -fblocks $(HOST_WARNINGS) $(CPPFLAGS) \
		$(call source,src/messaging/NativeReadPositions.m) tests/check_native_read_positions.m \
		-framework Foundation -o $@

build/check_readers_sheet: $(call source,src/messaging/ReadersSheet.m) src/messaging/ReadersSheet.h
	mkdir -p build
	$(HOST_CC) -DRUIN_READERS_SHEET_HOST_CHECK=1 -fobjc-arc -fblocks -std=gnu11 $(HOST_WARNINGS) $(CPPFLAGS) \
		$(call source,src/messaging/ReadersSheet.m) -framework Foundation -framework CoreData -o $@

build/check_theme_shop: $(call source,src/themes/ThemeShop.m) src/themes/ThemeShop.h
	mkdir -p build
	$(HOST_CC) -DRUIN_THEMESHOP_HOST_CHECK=1 -fobjc-arc -fblocks $(HOST_WARNINGS) $(CPPFLAGS) \
		$(call source,src/themes/ThemeShop.m) -framework Foundation -o $@

build/check_marker_ui: $(call source,src/core/Features.m) src/core/Features.h \
	$(call source,src/messaging/MessageHistory.m) src/messaging/MessageHistory.h \
	$(call source,src/messaging/UnsendMarkerUI.m) src/messaging/UnsendMarkerUI.h \
	$(call source,src/messaging/NativeReadPositions.m) src/messaging/NativeReadPositions.h \
	$(call source,src/messaging/UnsendOperation.m)
	mkdir -p build
	$(HOST_CC) -DRUIN_UNSEND_MARKER_UI_HOST_CHECK=1 -fobjc-arc -fblocks -std=gnu11 $(HOST_WARNINGS) $(CPPFLAGS) \
		$(call source,src/core/Features.m) $(call source,src/messaging/MessageHistory.m) \
		$(call source,src/messaging/NativeReadPositions.m) $(call source,src/messaging/UnsendMarkerUI.m) \
		-framework Foundation -framework CoreData -framework CoreGraphics -lsqlite3 -o $@

build/check_reply: $(call source,src/core/Features.m) src/core/Features.h \
	$(call source,src/messaging/ReadOnReply.m) src/messaging/ReadOnReply.h src/messaging/AutomaticReadGate.h \
	$(call source,src/messaging/AutomaticReadGate.m) \
	tests/check_reply.m
	mkdir -p build
	$(HOST_CC) -DRUIN_AUTOMATIC_READ_GATE_HOST_CHECK=1 -fobjc-arc -fblocks -std=gnu11 $(HOST_WARNINGS) $(CPPFLAGS) $(call source,src/core/Features.m) \
		$(call source,src/messaging/ReadOnReply.m) $(call source,src/messaging/AutomaticReadGate.m) \
		tests/check_reply.m -framework Foundation -framework CoreData \
		-o $@

build/check_read_until: src/messaging/ReadUntil.m src/messaging/ReadUntil.h tests/check_read_until.m
	mkdir -p build
	$(HOST_CC) -DRUIN_READ_UNTIL_HOST_CHECK=1 -fobjc-arc -fblocks $(HOST_WARNINGS) $(CPPFLAGS) \
		src/messaging/ReadUntil.m tests/check_read_until.m -framework Foundation -framework CoreData -o $@

build/check_mid: $(call source,src/interface/MIDLookup.m) src/interface/MIDLookup.h
	mkdir -p build
	$(HOST_CC) -DRUIN_MIDLOOKUP_HOST_CHECK=1 -fobjc-arc -fblocks $(HOST_WARNINGS) $(CPPFLAGS) \
		$(call source,src/interface/MIDLookup.m) -framework Foundation -o $@

build/check_unsend_operation: $(call source,src/core/Features.m) src/core/Features.h \
	$(call source,src/messaging/MessageHistory.m) src/messaging/MessageHistory.h \
	$(call source,src/messaging/UnsendOperation.m) src/messaging/UnsendOperation.h \
	tests/check_unsend_operation.m $(call source,src/messaging/NativeReadPositions.m) \
	src/messaging/NativeReadPositions.h
	mkdir -p build
	$(HOST_CC) -fobjc-arc -fblocks -std=gnu11 $(HOST_WARNINGS) $(CPPFLAGS) $(call source,src/core/Features.m) \
		$(call source,src/messaging/MessageHistory.m) $(call source,src/messaging/NativeReadPositions.m) \
		tests/check_unsend_operation.m -framework Foundation -framework CoreData -lsqlite3 -o $@

build/check_read_users: $(call source,src/core/Features.m) src/core/Features.h \
	$(call source,src/messaging/MessageHistory.m) src/messaging/MessageHistory.h \
	$(call source,src/messaging/ReadUsersEvents.m) src/messaging/ReadUsersEvents.h \
	$(call source,src/messaging/NativeReadPositions.m) src/messaging/NativeReadPositions.h
	mkdir -p build
	$(HOST_CC) -DRUIN_READ_USERS_EVENTS_HOST_CHECK=1 -fobjc-arc -fblocks -std=gnu11 $(HOST_WARNINGS) $(CPPFLAGS) \
		$(call source,src/core/Features.m) $(call source,src/messaging/MessageHistory.m) \
		$(call source,src/messaging/NativeReadPositions.m) $(call source,src/messaging/ReadUsersEvents.m) \
		-framework Foundation -framework CoreData -lsqlite3 -o $@

build/check_unsend: $(call source,src/core/Features.m) src/core/Features.h \
	$(call source,src/messaging/MessageHistory.m) src/messaging/MessageHistory.h \
	$(call source,src/messaging/UnsendRetention.m) src/messaging/UnsendRetention.h \
	$(call source,src/messaging/NativeReadPositions.m) src/messaging/NativeReadPositions.h
	mkdir -p build
	$(HOST_CC) -DRUIN_UNSEND_HOST_CHECK=1 -fobjc-arc -fblocks -std=gnu11 $(HOST_WARNINGS) $(CPPFLAGS) \
		$(call source,src/core/Features.m) $(call source,src/messaging/MessageHistory.m) \
		$(call source,src/messaging/NativeReadPositions.m) $(call source,src/messaging/UnsendRetention.m) \
		-framework Foundation -framework CoreData -lsqlite3 -o $@

build/check_features: $(call source,src/core/Features.m) src/core/Features.h tests/check_features.m
	mkdir -p build
	$(HOST_CC) -fobjc-arc -std=gnu11 $(HOST_WARNINGS) $(CPPFLAGS) -framework Foundation \
		$(call source,src/core/Features.m) tests/check_features.m -o $@

build/check_history: $(call source,src/core/Features.m) src/core/Features.h \
	$(call source,src/messaging/MessageHistory.m) src/messaging/MessageHistory.h tests/check_history.m \
	$(call source,src/messaging/NativeReadPositions.m) src/messaging/NativeReadPositions.h
	mkdir -p build
	$(HOST_CC) -DRUIN_MESSAGE_HISTORY_HOST_CHECK=1 -fobjc-arc -fblocks -std=gnu11 $(HOST_WARNINGS) $(CPPFLAGS) \
		$(call source,src/core/Features.m) $(call source,src/messaging/MessageHistory.m) \
		$(call source,src/messaging/NativeReadPositions.m) tests/check_history.m -framework Foundation \
		-framework CoreData -lsqlite3 -o $@

build/check_swift_fields: src/core/SwiftFields.swift
	mkdir -p build
	xcrun swiftc -parse-as-library -D RUIN_SWIFTFIELDS_TEST src/core/SwiftFields.swift -o $@

build/check_boundary: $(call source,src/core/Features.m) src/core/Features.h \
	$(call source,src/messaging/ReadBoundary.m) src/messaging/ReadBoundary.h tests/check_boundary.m
	mkdir -p build
	$(HOST_CC) -DRUIN_BOUNDARY_HOST_CHECK=1 -fobjc-arc -fblocks -std=gnu11 $(HOST_WARNINGS) $(CPPFLAGS) \
		$(call source,src/core/Features.m) $(call source,src/messaging/ReadBoundary.m) tests/check_boundary.m \
		-framework Foundation -framework CoreData -o $@

.SECONDARY: $(LOGOS_GENERATED)
build/logos/%.m: %.x $(LOGOS_DEPS)
	mkdir -p $(@D)
	$(PERL) $(LOGOS) -c generator=internal -c warnings=error $< > $@.tmp
	mv $@.tmp $@

define RUIN_ARCH_RULES
# Rebuild the version owner for command-line version overrides, for each slice.
build/$(1)/src/core/Tweak.o: FORCE

build/$(1)/%.o: build/logos/%.m $(wildcard src/*/*.h) vendor/fishhook/fishhook.h VERSION
	mkdir -p $$(@D)
	$$(CC) -arch $(1) $$(CFLAGS) $$(CPPFLAGS) -c $$< -o $$@

build/$(1)/%.o: %.m $(wildcard src/*/*.h) vendor/fishhook/fishhook.h VERSION
	mkdir -p $$(@D)
	$$(CC) -arch $(1) $$(CFLAGS) $$(CPPFLAGS) -c $$< -o $$@

build/$(1)/fishhook.o: vendor/fishhook/fishhook.c vendor/fishhook/fishhook.h
	mkdir -p $$(@D)
	$$(CC) -arch $(1) -isysroot $$(SDK) -miphoneos-version-min=18.0 -O2 -c $$< -o $$@

build/$(1)/SwiftFields.o: $$(SWIFT_SOURCES) src/core/SwiftFields.h
	mkdir -p $$(@D)
	xcrun --sdk iphoneos swiftc -sdk $$(SDK) -target $(1)-apple-ios18.0 -parse-as-library -whole-module-optimization -O -module-name RUINRuntime -emit-object $$(SWIFT_SOURCES) -o $$@

build/$(1)/RUIN.dylib: $(call arch_objects,$(1))
	xcrun --sdk iphoneos swiftc -sdk $$(SDK) -target $(1)-apple-ios18.0 -emit-library $$^ -framework Foundation -framework UIKit -framework AVFoundation -framework CoreText -framework WebKit -framework CoreGraphics -framework Security -framework CoreData -framework ImageIO -framework UniformTypeIdentifiers -framework UserNotifications -framework QuickLook -framework Intents -lsqlite3 -lz -Xlinker -install_name -Xlinker @rpath/RUIN.dylib -o $$@
endef

$(foreach arch,$(RUIN_ARCHS),$(eval $(call RUIN_ARCH_RULES,$(arch))))

build/RUIN.dylib: $(addprefix build/,$(addsuffix /RUIN.dylib,$(RUIN_ARCHS)))
	xcrun lipo -create $^ -output $@
	codesign --force --sign - --timestamp=none $@

# Upstream: https://github.com/Tyilo/insert_dylib, pinned for reproducible builds.
build/insert_dylib.c:
	mkdir -p build
	curl -fL --retry 2 https://raw.githubusercontent.com/Tyilo/insert_dylib/eb7278162af8fcc372e7f2946a2dee6a386b17d8/insert_dylib/main.c -o $@

build/insert_dylib: build/insert_dylib.c
	xcrun clang -O2 $< -o $@
	codesign --force --sign - $@

clean:
	rm -rf build dist

build/check_native_title: $(call source,src/interface/NativeChatControls.m)
	mkdir -p build
	$(HOST_CC) -DRUIN_NATIVE_TITLE_HOST_CHECK=1 -fobjc-arc -fblocks $(HOST_WARNINGS) $(CPPFLAGS) \
		$(call source,src/interface/NativeChatControls.m) -framework Foundation -o $@

build/check_gif: $(call source,src/messaging/GIFEncoder.m) src/messaging/GIFEncoder.h tests/check_gif.m
	mkdir -p build
	$(HOST_CC) -fobjc-arc -fblocks $(HOST_WARNINGS) $(CPPFLAGS) $(call source,src/messaging/GIFEncoder.m) \
		tests/check_gif.m -framework Foundation -framework ImageIO -framework CoreGraphics -o $@

build/check_theme_store_download: $(call source,src/themes/ThemeStoreDownload.m) src/themes/ThemeStoreDownload.h \
	tests/check_theme_store_download.m
	mkdir -p build
	$(HOST_CC) -fobjc-arc -fblocks -std=gnu11 $(HOST_WARNINGS) -DRUIN_THEME_STORE_DOWNLOAD_HOST_CHECK \
		$(CPPFLAGS) $(call source,src/themes/ThemeStoreDownload.m) tests/check_theme_store_download.m \
		-framework Foundation -o $@

build/check_theme_version: $(call source,src/themes/ThemeVersion.m) src/themes/ThemeVersion.h \
	tests/check_theme_version.m
	mkdir -p build
	$(HOST_CC) -fobjc-arc $(HOST_WARNINGS) $(CPPFLAGS) $(call source,src/themes/ThemeVersion.m) \
		tests/check_theme_version.m -framework Foundation -o $@

build/check_theme_store_resolver: $(call source,src/themes/ThemeStoreResolver.m) src/themes/ThemeStoreResolver.h \
	$(call source,src/themes/ThemeVersion.m) src/themes/ThemeVersion.h tests/check_theme_store_resolver.m
	mkdir -p build
	$(HOST_CC) -fobjc-arc -fblocks $(HOST_WARNINGS) $(CPPFLAGS) $(call source,src/themes/ThemeVersion.m) \
		$(call source,src/themes/ThemeStoreResolver.m) tests/check_theme_store_resolver.m -framework Foundation \
		-o $@

build/emit_theme_store_images: $(call source,src/themes/ThemeStoreImages.m) src/themes/ThemeStoreImages.h \
	tests/emit_theme_store_images.m
	mkdir -p build
	$(HOST_CC) -fobjc-arc $(HOST_WARNINGS) -DRUIN_THEME_IMAGES_HOST_CHECK $(CPPFLAGS) \
		$(call source,src/themes/ThemeStoreImages.m) tests/emit_theme_store_images.m -framework Foundation -o $@

build/check_native_theme_images: $(call source,src/themes/NativeThemeImages.m) src/themes/NativeThemeImages.h \
	tests/check_native_theme_images.m
	mkdir -p build
	$(HOST_CC) -fobjc-arc -fblocks -std=gnu11 $(HOST_WARNINGS) -DRUIN_NATIVE_THEME_IMAGES_HOST_CHECK $(CPPFLAGS) \
		$(call source,src/themes/NativeThemeImages.m) tests/check_native_theme_images.m -framework Foundation \
		-o $@

build/check_theme_apply_event: $(call source,src/themes/ThemeApplyEvent.m) src/themes/ThemeApplyEvent.h \
	tests/check_theme_apply_event.m
	mkdir -p build
	$(HOST_CC) -fobjc-arc -fblocks $(HOST_WARNINGS) $(CPPFLAGS) $(call source,src/themes/ThemeApplyEvent.m) \
		tests/check_theme_apply_event.m -framework Foundation -o $@


build/check_native_theme_registration: $(call source,src/themes/NativeThemeRegistration.m) \
	src/themes/NativeThemeRegistration.h $(call source,src/themes/NativeThemeLocalPolicy.m) \
	src/themes/NativeThemeLocalPolicy.h $(call source,src/themes/NativeThemeReceipt.m) \
	src/themes/NativeThemeReceipt.h tests/check_native_theme_registration.m
	mkdir -p build
	$(HOST_CC) -DRUIN_NATIVE_THEME_REGISTRATION_HOST_CHECK=1 -fobjc-arc -fblocks $(HOST_WARNINGS) $(CPPFLAGS) \
		$(call source,src/themes/NativeThemeRegistration.m) $(call source,src/themes/NativeThemeLocalPolicy.m) \
		$(call source,src/themes/NativeThemeReceipt.m) tests/check_native_theme_registration.m \
		-framework Foundation -framework CoreData -o $@


build/check_native_theme_install: $(call source,src/themes/NativeThemeInstall.m) src/themes/NativeThemeInstall.h \
	$(call source,src/themes/NativeThemeRegistration.m) src/themes/NativeThemeRegistration.h \
	$(call source,src/themes/NativeThemeLocalPolicy.m) src/themes/NativeThemeLocalPolicy.h \
	$(call source,src/themes/ThemeArchive.m) src/themes/ThemeArchive.h $(call source,src/themes/ThemeVersion.m) \
	tests/check_native_theme_install.m
	mkdir -p build
	$(HOST_CC) -DRUIN_NATIVE_THEME_REGISTRATION_HOST_CHECK=1 -fobjc-arc -fblocks $(HOST_WARNINGS) $(CPPFLAGS) \
		$(call source,src/themes/NativeThemeInstall.m) $(call source,src/themes/NativeThemeRegistration.m) \
		$(call source,src/themes/NativeThemeLocalPolicy.m) $(call source,src/themes/NativeThemeReceipt.m) \
		$(call source,src/themes/ThemeArchive.m) $(call source,src/themes/ThemeVersion.m) \
		tests/check_native_theme_install.m -framework Foundation -framework CoreData -lz -o $@


build/check_native_theme_local_projection: $(call source,src/themes/NativeThemeLocalPolicy.m) \
	src/themes/NativeThemeLocalPolicy.h $(call source,src/themes/NativeThemeReceipt.m) \
	src/themes/NativeThemeReceipt.h tests/check_native_theme_local_projection.m
	mkdir -p build
	$(HOST_CC) -fobjc-arc -fblocks $(HOST_WARNINGS) $(CPPFLAGS) \
		$(call source,src/themes/NativeThemeLocalPolicy.m) $(call source,src/themes/NativeThemeReceipt.m) \
		tests/check_native_theme_local_projection.m -framework Foundation -framework CoreData -o $@


build/check_native_theme_local_policy: $(call source,src/themes/NativeThemeLocalPolicy.m) \
	src/themes/NativeThemeLocalPolicy.h $(call source,src/themes/NativeThemeReceipt.m) \
	src/themes/NativeThemeReceipt.h tests/check_native_theme_local_policy.m
	mkdir -p build
	$(HOST_CC) -fobjc-arc -fblocks $(HOST_WARNINGS) $(CPPFLAGS) \
		$(call source,src/themes/NativeThemeLocalPolicy.m) $(call source,src/themes/NativeThemeReceipt.m) \
		tests/check_native_theme_local_policy.m -framework Foundation -framework CoreData -o $@


build/check_native_theme_receipt: $(call source,src/themes/NativeThemeReceipt.m) src/themes/NativeThemeReceipt.h \
	tests/check_native_theme_receipt.m
	mkdir -p build
	$(HOST_CC) -fobjc-arc -fblocks $(HOST_WARNINGS) $(CPPFLAGS) $(call source,src/themes/NativeThemeReceipt.m) \
		tests/check_native_theme_receipt.m -framework Foundation -o $@

build/check_native_range_queue: $(call source,src/messaging/NativeReadRangeSync.m) \
	src/messaging/NativeReadRangeSync.h
	mkdir -p build
	$(HOST_CC) -DRUIN_NATIVE_READ_RANGE_SYNC_HOST_CHECK -fobjc-arc -fblocks $(HOST_WARNINGS) $(CPPFLAGS) \
		$(call source,src/messaging/NativeReadRangeSync.m) -framework Foundation -o $@

build/check_read_range_codec: $(call source,src/messaging/ReadRangeCodec.m) src/messaging/ReadRangeCodec.h \
	tests/check_read_range_codec.m
	mkdir -p build
	$(HOST_CC) -fobjc-arc -fblocks $(HOST_WARNINGS) $(CPPFLAGS) $(call source,src/messaging/ReadRangeCodec.m) \
		tests/check_read_range_codec.m -framework Foundation -o $@

build/check_native_tab_availability: $(call source,src/interface/NativeTabAvailability.m) \
	src/interface/NativeTabAvailability.h src/core/NativeFunctionPointer.h
	mkdir -p build
	$(HOST_CC) -DRUIN_NATIVE_TAB_AVAILABILITY_HOST_CHECK -fobjc-arc -fblocks $(HOST_WARNINGS) $(CPPFLAGS) \
		$(call source,src/interface/NativeTabAvailability.m) -framework Foundation -o $@

# Uses the production file store, including unlink races and process-restart markers.
build/check_retained_media_store: tests/check_retained_media_store.m src/messaging/RetainedMediaStore.m
	mkdir -p build
	$(HOST_CC) -fobjc-arc -fblocks $(HOST_WARNINGS) $(CPPFLAGS) tests/check_retained_media_store.m src/messaging/RetainedMediaStore.m -framework Foundation -framework ImageIO -framework UniformTypeIdentifiers -o $@

build/check_feature_image: tests/check_feature_image.m
	mkdir -p build
	$(HOST_CC) -fobjc-arc -fblocks $(HOST_WARNINGS) $(CPPFLAGS) $< -framework Foundation -o $@
