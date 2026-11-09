# AGENTS.md - RUIN 保守・開発ガイドライン

本書は、RUINリポジトリの保守・改修を行う開発エージェント向けの行動規範、アーキテクチャ規約、および品質管理ガイドラインです。合意されたアーキテクチャ仕様に基づいて定義されています。

---

## 1. 基本行動規範

- **ユーザー指示の優先**: 常にユーザーの指示を最優先してください。
- **既存作業の保護**: 作業開始前に未コミットの変更差分がないか確認し、既存の変更を破棄または破壊しないこと。
- **推測による変更の禁止**: 根拠のないアドレス推測や当てずっぽうなバイナリパッチを行わないこと。
- **AIモデルの役割分担**:
  - **コード生成の制約**: Geminiにアプリ実装コードを書かせることは禁止します。ただし、Codexなど他の外部コードモデルによる実装や、ユーザーが明示的に許可したコード担当サブエージェントによるコード生成は禁止されません。
  - **文章・ローカライズの作成/レビュー**: ドキュメント (README等) や多言語ローカライズ文言の執筆・レビューは、Gemini 3.8 Flash Highが担当します。コードは実装担当者が扱います。
- **確認手順の適正化**: 依存取得、ファイル読み取り、通常の修正作業などを行う度に確認を求めないこと。既存のユーザー許可を引き継ぎ、自己承認ではなくメッセージ送信等に必要な許可が既にある時は毎回再質問しないこと。別チャットへのメッセージ送信、通話発信、データ削除などの破壊的操作については具体的な許可範囲内で行い、許可が得られていない行為についてのみ事前にユーザーへ確認する（ネットワーク通信全般を一律に許可制としない）。
- **環境情報の秘匿**: 作業端末固有のマシン名、絶対パス、ユーザー名、端末UDID、プロファイル名、パスワード、秘密鍵、個人データをドキュメントやコード内に記載・ハードコードしないこと。

---

## 2. リポジトリ構成

```text
RUIN/
├── src/
│   ├── core/         # Tweak.x (起動・Logos入口)、基盤ロジック、SwiftFields、バイナリ完全性・型ゲート検証
│   ├── known/        # KnownMappings.{h,m} (共有API・中央レジストリ)、VersionMapping.h、BinaryVerifier.{h,m}、versions/LINE*.m (バージョン別定義)
│   ├── interface/    # UIフック、RUINSettings.m (設定画面・標準Page Sheet/Push遷移)、長押しシート、ローカルフォント等
│   ├── messaging/    # メッセージ送受信制御、既読管理、送信取消保持、ミュート送信・送信取消制御
│   ├── platform/     # AppGroupStorage.{h,m} (保存先ポリシー)、Sideload.x + Keychain.m (署名・保存互換)、fishhook等
│   └── themes/       # ネイティブ着せかえ制御
├── resources/        # RUINResources.bundle (Tablerアイコン、Localizable.strings XML plist)
├── tools/            # パッケージング・署名準備スクリプト (package.py)、原IPA整合性検証 (macho_integrity.py)
├── tests/            # ホストテスト、パッケージ検査、ポータブル検査、フィクスチャ検証
└── docs/             # 仕様書、リファレンス、スクリーンショット (docs/screenshots/)
```

---

## 3. バージョン追従とフック実装方針

### 対象バージョン・環境要件
- **LINE**: `KnownHosts.def` および配列インデックス（`RUINKnownHosts`）による管理は廃止され、不変の `const RUINVersionMapping` 構造体が単一の (バージョン、ビルド番号、Mach-O UUID) の同一性を保持します。異なるビルド/UUIDバリアントは独立したレコードとして扱われ、同一バージョン文字列のバリアントも同一の `src/known/versions/LINE*.m` 内で個別のレジストリエントリとして共存可能です。バイナリマッピング値は `src/known/versions/LINE*.m` が所有し、`KnownMappings.h/m` が共有APIおよび中央レジストリを提供します。
  - 対象バージョン: LINE 26.16.0 (Build: `2026.1006.1718`、UUID: `292883E8-E011-3583-ADF5-F02241E3277B`) および 26.17.0 (Build: `2026.1103.1841`、UUID: `614CED59-07E5-372D-94B2-D4901870C7A0`)。
  - 26.17.0のホスト全体は `Unverified` とし、部分対応警告を維持します。起動・ログイン維持・Keychain・タブ非表示、およびiPhone（LINE 26.17.0）でのネイティブ着せかえダウンロード・プレビュー・適用・再ダウンロード復元フローは実機確認済みです。また、Rootless iPad（サブ端末）でもRUINからのThemeShop/StickerShop表示、ダウンロード、マイ着せかえ登録・適用、再起動後保持を確認済みです（ログイン・履歴は未変更、再ダウンロード復元の実機QAはiPhoneのみ）。一方、RUIN設定のPage Sheet展開や未検証の直接ルートが残り、全体ステータスは留保として全テーマ・全環境の検証完了とはしません。
  - 26.17.0の機能status: RUINThemeShopEligibilityMappingの総括shopEligibilityは未検証直接ルートを留保するため `Unsupported`、nativeReadAdapterStatusは22アンカー検証済みの `Verified`（StylesheetManager保存補正および所有固定URL判定）、所有権未証明ルート（shopSchemeScopeStatus）は `Unverified`（無効化）です。unsend lookup（6 frame/16 anchor、実機で本文保持・取消表示・再起動後保持を確認）および通常トークmanualReadのABI statusは `Verified` です。旧getter投影のreadBoundaryは `Unsupported`（旧アンカー不保持、送信前pending filterは構造的に独立維持、26.16.0送信前投影は維持）とし、`RUINMappingStatus` は版別mapping featureに適用します。
- **アーキテクチャ**: `arm64` および `arm64e`。アーキテクチャ別のオブジェクトディレクトリで個別ビルドし、双方のスライスのSwiftコンパイル・リンク対象をiOS 18.0として `lipo -create` で単一のFatバイナリを生成します。なお、両スライスの内包は実機での完全動作を保証するものではなく、既知の原バイナリおよび実機QA対象のLINE本体実行ファイルはarm64であり、実行時のLINE本体メインプロセスでもARM64が観測され、試行ごとのRUIN自身のarm64/arm64eスライス読み込みは確認済みですが、arm64eメインプロセスの機能QAは未検証です。
- **下限OS**: iOS 18.0 以降 (※ビルド下限値であり、全機種・全環境での動作を保証するものではありません)
- **ビルド依存**: macOSホスト、フルXcode (iOS SDK含む)、`make`、`perl` (Logos internal用)、`python3`、`node` (ホスト検査・JS構文検査用)。`Makefile` の `SOURCES` および `HOST_COMMON` に `src/known/versions/*.m` が含まれます。
- **ランタイム依存**: Apple系のシステムライブラリ・フレームワーク、同梱リソースのみ。脱獄版DEBにおける注入ローダー（mobilesubstrate仮想パッケージ）への依存は許容しますが、バイナリ自体が外部の Cydia Substrate、libhooker、pip パッケージ等へ動的リンクすることは禁止。

### フック実装規約
- **Logos構文とジェネレータ**: Objective-Cフックは Logos (`.x`, `%hook`, `%orig`, `%new(typeencoding)`, `%group`, `%init`) を使用し、リポジトリ同梱の internal generator を通じて生成します。
- **外部依存の排除 (MSHookIvar禁止)**: 外部のSubstrateやlibhooker依存を追加しないでください。特に `MSHookIvar` を安易に追加して外部依存を増やすことは禁止します。Substrate非依存環境での手動ivarアクセス代替は最小限にとどめます。
- **C/Swift連携とSwiftFieldsガード**: C関数のimport rebindにはfishhookを使用し、Swift witness tableやdata-pointerアダプターは型安全性を検証した上で保持します。`isEnabled` の書き込みは完全一致クラス、Mirror Bool、実ivar metadata offset、インスタンス境界、格納バイトとの一致を実行時に検証して行います。ホストfixtureでは異なるivar offsetのroot classも検証します。
- **バージョンマッピングと共通API**:
  - テーマ、メッセージング、ネイティブタブの各マッピング値はバージョン別定義ファイル（`src/known/versions/LINE*.m`）内に保持されます。
  - `RUINMappingForInfo(info)` はLINEのバンドル識別子およびバージョン/ビルド番号のみから選択を行い、メタデータに曖昧さがある場合は `NULL` を返し、実行バイナリの真正性認証は行いません（明示的なフィクスチャやテストで使用）。
  - ランタイムの数値呼び出し元は共通API `RUINCurrentMapping()` を使用します。現在のメタデータとメインMach-O UUIDを照合して一意に解決し、未知・不一致時はフォールバックやミスのキャッシュを行わず `NULL` を返します。
  - ThemeShopアダプターは、26.16.0で全ステータスが `Verified` で有効な一方、26.17.0では22アンカー検証済みのadapter（Nv追加、数値直接パッチなし）が `Verified` であり、既存のStylesheetManager保存補正とRUIN所有固定URL判定の両方を支えます。所有権未証明の汎用ルート（genericScheme/generic unowned）は `Unverified`（無効化）を維持し、未検証の直接ルートを残すため全体ステータスは留保とします。ショップやMyThemesの固定URLをRUINから開く際のみSwift TaskLocal種別（Theme/Sticker/MyThemes）と単調増加IDを引き継ぎ、最新requestID一致・12秒以内・最大32回読み取りの厳密な版別native呼び出しチェーン/キー/typed読み取りで補正します（保存アカウント種別は不変、TaskLocal単体ではURL所有権根拠としない）。`RUINThemeShopReturnChain`（`accountChainAlternatives` / `accountChainAlternativeCount`）等の型付き代替リターンチェーンは版別定義が値を保持し、共通ロジックが消費します。
  - `readUntilABIStatus` は版別mappingが所有し、共通manualRead helperにversion literalを置きません。`AnyCancelableTask` はSwiftObject rootのためNSObject継承を仮定せず、native-root hostfixtureで検証します。
  - `BinaryVerifier` の `RUINResolveMainExecutableImage` はcanonical実行pathに一致する一意の64bit `MH_EXECUTE` からheader/slide/index/CPU/UUIDを一組として解決し、成功結果のみをprocess lifetime cacheしてmissは保存しません。全runtime numeric/caller consumerはこの一組を使用し、image0はraw diagnostic専用にとどめます。新resolver導入後もARM64制約、UUID、およびcode fingerprintsは `RUINVerifyHostImage` や `RUINReadImageBytes` で維持し、検証ゲートを弱めないでください。
  - `NativeFunctionPointer.h` のsign(`key_function_pointer`, discriminator 0)およびstripは既知のplain ARM64 consumerとClang C callableに限定し、Swift asyncやarm64e witness、GOT全般へ一般化しないでください。ReadUntil callbackの私有fixture（arm64e producer→ARM64 Swift consumer）合格は実iPad上のnil/error/ownership境界を確認したものであり、実際のネイティブ `ChatService` やreader機能のQAとは明確に区別します。新resolver統合の実機検証は進行中であり、私有fixtureの成功をもってfull verifiedやwhole-host statusへ昇格させないでください。
- **コンパイル済みマニフェスト検証**: `tools/export_version_mappings.m` はコンパイル済みレジストリ値から `tests/fixtures/version-mappings.json` を出力し、`make check-mapping-manifest` によってマニフェストの整合性を検証します。Python/Linuxツール群はこのマニフェストを消費する一方、Mach-Oのバイト列、制御フロー、UUID、SHAによる独立した検証・証明も維持されます。
- **段階的フェイルセーフと独立機能の保護**:
  - 一般的なObjective-Cフックは、LINEプロセスの識別およびクラス・セレクタ・型・スキーマの実検証を経て安全に有効化し、未知のバージョン番号のみを理由にアプリ全体のフックを一律停止しないこと。未検証ビルド起動時はユーザーへ1度だけ警告を表示し、確認できた機能のみを有効化する。
  - ビルド固有のSwift呼び出し位置、命令列、データ表へのフックは、該当ビルド・UUID・アドレス範囲・fingerprint検証が完全に一致する定義が存在する場合にのみ適用する。
  - 特定のフックが無効化された場合でも、安全性が確認されている他の独立機能の動作を巻き込んで停止させないこと。
- **Mach-O完全性とコード署名**: IPA内のMach-O命令コードや定数テーブルへの直接バイナリパッチは禁止です。署名用の `LC_LOAD_DYLIB` 追加と署名メタデータのみを許可し、元バイナリの全既存セクションおよびロードコマンドの整合性を `tools/macho_integrity.py` 等で厳格に確認してください。汎用注入ツールへの無条件の全対応は前提としません。
- **dylibコード署名と検査**: `make all` の出力dylibはApple codesignによりadhoc署名を行い、パッケージング（`distribute.py`）およびCI検証において `arm64`/`arm64e` の正確な2スライス構成、スライスごとの依存関係（外部フック依存の追加禁止）、および `codesign --verify --strict` による厳格検査を行います（未署名やスライス欠落・不正依存は拒否、有効なadhoc署名を受理。証明書は不要ですが、Jailed環境でのIPA組み込み時は環境に応じた再署名が必要）。
- **UI設計原則**:
  - UIKit標準コンポーネントおよびLINE本来のネイティブタブ生成・インデックスを尊重し、自前UIへの差し替えや配列インデックス改変、Mach-O直接パッチは行わないこと。
  - タブ非表示はメニュー生成および標準のタブ更新処理の確認済み呼び出しスコープに限定してフィルタリングを行い、内部ファクトリ等の他呼び出し元へは元の値を返します。旧実装の制約（one-service制約）は解除され、ショッピングとアプリの同時非表示に対応（再起動後に反映。実機ではウォレット単体の非表示がネイティブ設定往復後も維持されることを確認済み。トラブルシューティング用として `RUIN_DISABLE_TAB_HIDING=1` で一時解除可能）。
  - iPadの設定画面表示はサブ端末モードフラグに依存せず、可視の親コントローラからNavigation Pushで展開する動作を実機確認済みです。Rootless iPad（LINE 26.17.0サブ端末）ではRUIN 0.5.2インストール、厳格署名検証、dylib SHA一致、RUIN入口および設定UI表示、再起動後の通常起動復帰に加え、RUINからのThemeShop/StickerShop表示、ダウンロード、マイ着せかえ登録・適用（再起動後保持を確認、ログイン・履歴は未変更）を確認済みです。一方、未検証の直接ルートやRUIN設定のPage Sheet展開が未試験のため最新iPadの全機能完了とは断言しません（再ダウンロード復元の実機QAはiPhoneのみ）。

---

## 4. データ整合性と設定補正のスコープ

- **読み取り補正の最小化**: フックによる設定読み取り補正 (インターセプト) は必要最小限の対象に限定し、永続化された実ストレージ値やサーバー側の契約状態・メンバーシップ情報を不正に改変しないこと。
- **サンドボックスとキーチェーンの整合性・データ保護**:
  - OS許可済みのネイティブGroup、明示的な署名マッピング、または永続purpose markerのみを新規ログイン前の安全な保存先として認め、未確認時はauthorized nativeを推測選択しないこと。
  - 保存領域競合、権限不明、または共有Keychain名前空間が未準備のフォールバック状態では、既存セッションの通信を維持しつつ新規ログインやQR開始を準備未了として安全に抑止すること。
  - 暗号鍵やメッセージの移植、強制復号、削除、結合は一切行わないこと。
  - キーチェーンはOSが許可した実アクセスグループを検出し、自前の非機密メタデータのみを共有グループに保持してBundle ID変更後も継続参照します。既存の暗号鍵や認証情報のコピー・改変・消去は絶対に行わないこと。
  - これらはRUIN側の保存領域切り替え事故によるデータ喪失を防ぐ安全策であり、Appleの署名制限を超えるアクセス権限の付与やOS端末移行全経路の動作を保証するものではありません。
  - キーチェーン補正では、マッピング辞書が空かつ旧アプリ・旧共有グループ双方の実権限プローブでAllowedが確認された場合のみ、全アーキテクチャでCインポート書き換えを行わずにNativePassthrough（Ready）として扱います。一方、arm64e環境で空でないグループマッピングが必要な場合はインポート書き換え前に停止してUnsupportedAuthenticatedImports（準備未了）とし、既存のarm64向けC互換動作は維持します。
  - Bundle ID補正では、元のCFBundle情報が既にjp.naver.lineを示す場合はNativePassthroughを適用します。リネームされたバンドルのarm64e環境でもObjective-C層の識別子補正を維持し、CF関数のCインポート書き換えのみをUnsupportedAuthenticatedImportsとして停止させ、既存のarm64向けC投影は保持します。
- **マイグレーションの保護**: 既存のLINEアカウント設定、トーク履歴データベース、ログインセッションのデータ移行処理を削除・破壊しないこと。Bundle ID、App Group、キーチェーン共有の整合性を常に意識してください。
- **着せかえストレージのルート分離と名前空間検証**: ネイティブ着せかえ登録では、Application Supportツリー配下の所有テーマSQLite DB（OwnedDB）と、明示的にマッピングされたApp Groupツリー配下のテーマパッケージディレクトリ（Packages）が別個の検証済みルートを持ちます。両者が同一ルートを共有すると仮定しないこと。PrimaryおよびSecondaryの名前空間は、いずれも `ThemeAccountNamespace.h` の厳格な共通バリデータによって検証してください。

---

## 5. ローカライズ (Localizable.strings) 規約

- **リソース形式**: UIローカライズリソースは `resources/RUINResources.bundle/<locale>.lproj/Localizable.strings` (XML Property List形式) で管理します。
- **バンドル参照**: 文字列取得に `NSLocalizedString` (main bundle参照) を使用せず、必ず `RUINLocalizedString` 関数/ヘルパーを使用して `RUINResources.bundle` を参照してください。
- **ネイティブ文字列照合**: LINEネイティブUIやシステムとの文字列照合・比較を行う際は、直接の翻訳文字列ではなく、LINEバンドル内の公式ローカライズキーを参照して照合すること。
- **翻訳除外対象**: 内部プロトコルキー、LINE内部の文字列比較用定数、SQLクエリ、ユーザーの入力・表示コンテンツは翻訳対象外です。
- **5言語の同期更新**: 新規UI文字列を追加する場合は、以下の全5言語および英語フォールバックを同時に更新してください。
  - `ja` (日本語)
  - `en` (英語 - フォールバック基準)
  - `ko` (韓国語)
  - `zh-Hans` (簡体字中国語)
  - `zh-Hant` (繁体字中国語)
- **プレースホルダー検査**: `%@`, `%ld`, `%lu`, 改行文字 (`\n`) などのフォーマット指定子を厳密に一致させてください。

---

## 6. テスト・実機検証および安全管理

- **変更内容に応じたテスト実施**: 文書や軽微なテキストのみの変更で毎回フルiOSビルドやバイナリ解析を要求しないこと。変更内容に応じた適切な検証を実行する。
  - **コード修正時**: `make -j4 all`、`make -j4 check-host`
  - **パッケージング・配布関連の修正時**: `make check-packaging`、`make dist`
  - **多言語ローカライズ・翻訳修正時**: カタログ検証およびフォールバックfixtureによる整合性検証
  - **プライベートフック・ランタイム修正時**: 実機検証またはフィクスチャ検証 (`make check-fixtures`)、ABI/UUID検証
  - **ポータブル整合性・バージョン確認**: `make check-portable`、`make version`
  - **LINE新バージョン対応時**: 対象バイナリのバージョン、ビルド番号、UUID、型定義、対象ファイル、関数ABI情報、ネイティブUI制約を確認し、実機検証が完了していないバージョンは作業中として扱うこと
- **実機検証の安全管理**: 実機検証において、別チャットへのメッセージ送信、通話発信、データ削除等の破壊的操作を行う場合は、事前に合意された具体的な許可範囲内でのみ実行し、未許可の行為は事前にユーザーへ確認すること。既存の許可は引き継ぎ、自己承認ではなくメッセージ送信等に必要な許可が既にある時は毎回再質問しないこと。
- **機能ステータスの厳密化と設計規約**:
  - LINE 26.17における「ログイン」長押し対応は、既存のUIControl探索に加えSwiftUIアクセシビリティ要素（AX識別子login完全一致）の検出を実装し、通常ログイン・サブ端末ログイン・ABI不一致のホスト検証に合格していますが、実機での端末認証試験は行っておらず、実際のログインや実機でのモード切り替え動作は未検証です。
  - 既読者一覧シートの長押しアイコンはTabler `eye` を使用。
  - 既読者一覧の完全性をテストしないという規則は禁止です。既知のテストデータによる欠落検査やパース検証、および後日の取得時刻による記録済み実イベント日時の上書き防止検証は必ず実施してください（※未観測の正確な日時や常に完全な一覧の提供を保証する宣伝を行わないという意味であり、テストを怠るものではありません）。
  - **独立スイッチの維持**: ローカルLYP（アプリアイコン等のローカルUI表示）と、『24h送信取消・ミュートメッセージ』は独立した別スイッチとして管理し、後者をローカルLYPにネストさせないこと。ローカルLYPが無効な状態でも独立スイッチが有効であれば機能が動作する仕様として整理する。
  - **manualRead検証**: 26.17.0通常トークで未読I/Jを用意し、Iまでを選ぶと対向端末のレシートはIのみseen、peerReadUpToはI、後着Kは未読のまま、既読隠しの全体設定/例外は不変、受信端末のNative unread countは3から1へ変わることを確認します。グループトークでも未読A/BからAまでを選び、AのみreadCount 1、Bは0、カーソルはA、設定/例外は不変であることを実機確認済みです。iPad最新版は未検証です。メニューはTabler `checks` アイコンと「このメッセージまで既読」が狭いグリッドで2行程度に自然表示されることを確認します。
  - **返信時自動既読**: prior KVO gateで返信成功・失敗・古い境界を区別し、通常トークでF未読→G返信成功後にF既読→後続H未読を確認します。
  - **既読者一覧の複数ストア**: 26.17で複数の他者表示名と日時、および再取得時に記録済みイベント日時が上書きされないことを実機確認したのはPrimaryP_のみです。PrimaryP_/SecondaryS_双方の名前空間処理はホストfixtureで検証し、最新iPadでのSecondaryS_は未検証です。
  - **ローカルカスタムフォント**: 実機にてTTFおよびOTFサンプルの取り込み、フォント登録、トーク本文（nativeBody）への描画適用、および標準フォントへの復元を確認済み。
  - **ネイティブ着せかえの実機検証と復元**: iPhone（LINE 26.17.0）にて着せかえのダウンロード・プレビュー・適用、およびパッケージアセットと保存ZIP退避後の再ダウンロード復元（マイ着せかえのダウンロード矢印からの新規パッケージ生成・再適用）を確認済みです。また、rootless iPad（LINE 26.17.0サブ端末）でもRUINからのThemeShop/StickerShop表示、ダウンロード、マイ着せかえ登録・適用（配色・背景変化、再起動後保持、ログイン・履歴未変更）を確認済みです（再ダウンロード復元の実機QAはiPhoneのみ。未検証の直接ルートを残すため全体ステータスは留保）。なお、過去のiPhone検証後は元アーカイブ、「基本」を選び「適用する」操作による標準テーマ復元、標準フォントへの復帰、および一時ファイル消去による原状復帰を確認しています（iPad側は適用テーマの保持を維持）。
  - **着せかえリセット仕様の明確化**: マイ着せかえ画面のリセットボタン（didTapResetButton）は選択中テーマの編集・リセットを行うものであり、デフォルトテーマ適用ではない。スタンドアロンのRUINResetThemeは呼出元が存在せず単体動作は未確立である。標準テーマへの復元は「基本」を選び「適用する」操作により成功を確認済み。
  - **通知機能の制限事項**: 単体iPhone環境におけるバックグラウンド通知受信の復帰は未確立であり、APNs通知連携の動作は未確認（全端末環境に一般化せず、未保証として扱うこと）。
  - **送信取消の対応範囲**: 送信取消の対応範囲は24時間までとし、24時間超の研究や7日保証などの追加拡張を今後の課題として強制・仮定しないこと。
  - **ミュート送信の操作仕様**: 本文入力確定後、送信ボタンを約2秒長押しすることでLINEネイティブのメニュー（ミュート／通常）が表示される仕様とする。NativeLINEラボへの別移動を必須操作として案内しないこと。
- **スクリーンショット管理**:
  - 公開用スクリーンショットは作業担当者が公開前に目視確認（プライバシー検査）を実施して選定・配置する運用とする（人間に丸投げする承認フローとしない）。
  - リポジトリに掲載されている5点 (`home.png`, `settings-entry.png`, `ruin-settings.png`, `local-font.png`, `chat-menu.png`) は代表例であり、上限や固定ルールではありません。新機能の追加時もプライバシー検査を経て画像を追加可能です。
  - ホーム画面画像 (`home.png`) は、友だちリストおよびグループリストを両方折りたたんだ状態で撮影することを必須要件とする。
  - 実機検証済みのミュート送信画面 (`mute-send.png`) を含む正常動作確認画像は、目視によるプライバシー検査を経て掲載可能とする（掲載を一律・恒久的に禁じる一時ルールを固定しない）。
  - スクリーンショットには第三者の個人情報（他者プロフィールや個人特定可能ID）を含めないこと（許可された自身のテストトーク画面は掲載可能）。
  - ログイン中のアカウント本人以外の表示名・プロフィール画像（サブアカウント含む）にモザイクを施し、ホーム画面の友だち・グループリストを折りたたんで撮影する（メッセージやUIアイコンはモザイク不要）。
- **秘匿情報の排除**: 復号済みIPA、P12証明書、プロファイル、パスワード、実機データベース、実機UDID、環境固有の絶対パスをGitリポジトリやCI設定に絶対に含めないこと。

---

## 7. バージョン更新とCI/CD・リリース手順

1. **バージョン定義**: 製品バージョンの基準はリポジトリ直下の `VERSION` ファイルです。手動上書きビルド時は以下のコマンドを個別に実行します。
   - `make RUIN_BUILD_VERSION=0.5.0 all`
   - `make RUIN_BUILD_VERSION=0.5.0 dist`
2. **整合性確認**: `make version` を実行し、パッケージメタデータとの不整合がないことを確認します。
3. **CI検証と保守運用**:
   - PR、`main` へのpush、および手動実行 (`workflow_dispatch`) により `Validate RUIN` ワークフローが実行されます。
     - macOS環境: iOS SDKを用いたFat 2スライスビルド検証、ホストテスト（Node.js構文検査含む）、合成フィクスチャ検証、実パッケージおよび合成パッケージ構造検証を実施。
     - Linux環境: `make check-portable` によるLogos前処理検証、Python unittestを実施（Linux上でのバイナリビルドは行わない）。
     - テストデータ: 秘密の原IPAや復号バイナリは使用せず、合成フィクスチャおよびホスト検証データのみを使用。
   - 保守エージェントは、特定の会話時点の状態に依存せず、実行結果を確認した上で成功報告を行う普遍的な運用手順を遵守してください。
4. **リリースタグ運用と配布物**:
   - リリース時は `vX.Y.Z` 形式のSemVerタグをpushします。`Build RUIN distribution` ワークフロー (`distribute.yml`) が起動し（手動実行 `workflow_dispatch` も可能）、プレフィックス `v` を除いたバージョン名で配布物が生成され、GitHub Releaseへ添付されます。
   - 配布物は以下の3つのDEBパッケージおよびチェックサムファイルのみに限定されます（単体dylib、`manual-injection.zip`、単体ライセンスtxtは全て廃止。ローカルの `build/RUIN.dylib` はビルド中間物です）。
     - `RUIN-<version>-rootful.deb` (Architecture: `iphoneos-arm`、`/Library/MobileSubstrate/DynamicLibraries/` 配下、Debian Depends: `firmware (>=18.0), mobilesubstrate`)
     - `RUIN-<version>-rootless.deb` (Architecture: `iphoneos-arm64`、`/var/jb/Library/MobileSubstrate/DynamicLibraries/` 配下、Debian Depends: `firmware (>=18.0), mobilesubstrate`、`dladdr` による隣接リソース解決)
     - `RUIN-<version>-jailed.deb` (Architecture: `iphoneos-arm64`、`X-RUIN-Variant: jailed`、`/Library/MobileSubstrate/DynamicLibraries/` レイアウト、復号IPAへの注入・独自署名用ペイロードであり直接のdpkgインストール用ではない)
     - `SHA256SUMS` (上記3DEBのSHA-256ハッシュ一覧)
   - 全DEBパッケージに同一の `arm64`+`arm64e` Fatバイナリ、5言語対応 `RUINResources.bundle`、LINE限定XMLフィルタ、ライセンス通知 (`usr/share/doc/com.tqmane.ruin/RUIN-ThirdPartyNotices.txt`、rootlessは `/var/jb` 配下) を内包します。
