# RUIN - iOS LINE Extension

RUINは、iOS版LINE向けの機能拡張（Tweaks）パッケージです。公式UIの操作感を維持しながら、既読回避・送信取消メッセージ保持・ミュート送信・フォント変更などの機能を提供します。

> [!NOTE]
> 本プロジェクトは非公式の拡張機能であり、LINEヤフー株式会社およびその関連会社とは一切関係がありません。

---

## スクリーンショット

| ホーム画面 | LINE設定内のRUIN入口 |
| :---: | :---: |
| <img src="docs/screenshots/home.png" width="320" alt="Home Screen" /> | <img src="docs/screenshots/settings-entry.png" width="320" alt="Settings Entry" /> |

| RUIN詳細設定 | ローカルカスタムフォント |
| :---: | :---: |
| <img src="docs/screenshots/ruin-settings.png" width="320" alt="RUIN Settings" /> | <img src="docs/screenshots/local-font.png" width="320" alt="Local Font" /> |

| メッセージ長押しメニュー | ミュート送信 |
| :---: | :---: |
| <img src="docs/screenshots/chat-menu.png" width="320" alt="Chat Menu" /> | <img src="docs/screenshots/mute-send.png" width="320" alt="Mute Send" /> |

---

## 主な機能

### メッセージング & プライバシー
- **既読回避**: 既読を付けずにメッセージを閲覧できます。トーク画面ヘッダーのアイコンから個別切り替えが可能です。
- **返信時自動既読**: 返信成功後に既読を付けます。送信失敗や古い境界では抑止し、成功後の次の新着は未読のままです。
- **このメッセージまで既読**: 26.17.0の通常トークとグループトークで、選択したメッセージまでの既読送信を実機確認済みです。後続メッセージは未読のままで、既読隠しの全体設定や例外は変わりません。iPad最新版は未検証です。メニューにはTabler checksアイコン付きで、狭いグリッドでも2行程度に自然に表示されます。
- **既読者一覧シート**: 既読者の表示名と日時を確認できます。再取得しても記録済みイベント日時は変わりません。
- **送信取消メッセージ保持**: 相手が取り消したメッセージを端末内に保持し、「取消済」マーク付きで表示します。26.17.0の通常トークでは取消後の受信本文保持、取消済表示、再起動後の保持を実機確認済みで、グループトークでも送信側の取消後に受信本文保持と取消済表示を実機確認済みです。
- **送信取消の延長**: 送信後24時間以内のメッセージについて、端末側での送信取消を可能にします。
- **ミュート送信**: 送信ボタンを約2秒長押しすることでネイティブの選択メニューが表示され、相手に通知を送らずに送信できます。
  - ※「24h送信取消・ミュートメッセージ」は、ローカルLYPとは独立した専用設定で管理されます。
- **トーク別既読管理・表示名変更**: 名前・アイコン・検索付きのトーク一覧から通常既読をつけるトークを選択できるほか、端末内限定の表示名変更（相手・サーバーには非反映、元に戻す機能付き）を設定できます。

### 表示管理 & ナビゲーション
- **不要要素の非表示**: 広告、おすすめコンテンツ、音声入力UI、Agent-i を個別に非表示化できます。
- **タブ管理**: LINE本来のタブ生成を尊重しながら、不要なネイティブタブ（ショッピングやアプリ等）を非表示にし、起動時の初期タブを指定できます。自前UIへの差し替えを行わず、メニュー生成および確認済みのタブ更新処理を安全に制御します（設定変更は再起動後に反映）。

### テーマ & カスタムフォント
- **ネイティブ着せかえ**: 公式着せかえショップやマイ着せかえのローカル適用・再取得に対応します。26.17.0ではショップ資格など一部機能が未対応で、テーマ機能全体の対応完了は確認されていません。
- **ローカルカスタムフォント**:
  - 「RUIN設定」→「カスタムフォント」から、フォントファイル（32MB以下）を取り込んでアプリ全体のフォントを変更できます。実機ではTTFのインポートとネイティブ本文への適用を確認済みです（OTFは拡張子受付のホスト検証のみ）。
  - 設定からいつでも標準フォントへ復帰可能です。

### 多言語ローカライズ
- 日本語 (`ja`)、英語 (`en`)、韓国語 (`ko`)、簡体字中国語 (`zh-Hans`)、繁体字中国語 (`zh-Hant`) の5言語に対応しています。

---

## 動作要件

| 項目 | 要件 |
| :--- | :--- |
| **対象アプリ** | LINE iOS 26.16.0 (Build `2026.1006.1718`)、26.17.0 (Build `2026.1103.1841`、部分対応・一部機能検証中) |
| **アーキテクチャ** | `arm64` |
| **対象OS** | iOS 18.0 以降 |
| **動作環境** | Jailed環境、Rootful/Rootless脱獄環境 |

---

## 配布パッケージ構成

RUINの配布パッケージは以下のDEB形式3種およびハッシュ一覧のみで構成されます（単体dylib、ZIPアーカイブ、別出しライセンスtxtは廃止。ローカルの `build/RUIN.dylib` はビルド中間物です）。全DEBに同一の `arm64` バイナリ、Tablerアイコンおよび5言語を含む `RUINResources.bundle`、XMLフィルター、ライセンス通知（`/usr/share/doc/com.tqmane.ruin/RUIN-ThirdPartyNotices.txt`、rootlessは `/var/jb` 配下）を内包しています。

| パッケージ | 対象環境 | Architecture | 格納レイアウト / 依存 |
| :--- | :--- | :--- | :--- |
| `RUIN-<version>-rootful.deb` | Rootful脱獄 | `iphoneos-arm` | `/Library/MobileSubstrate/DynamicLibraries/`<br>依存: `firmware (>=18.0), mobilesubstrate` |
| `RUIN-<version>-rootless.deb` | Rootless脱獄 | `iphoneos-arm64` | `/var/jb/Library/MobileSubstrate/DynamicLibraries/`<br>依存: `firmware (>=18.0), mobilesubstrate` |
| `RUIN-<version>-jailed.deb` | 非脱獄（署名・注入用） | `iphoneos-arm64` | `/Library/MobileSubstrate/DynamicLibraries/`<br>ヘッダー: `X-RUIN-Variant: jailed` |
| `SHA256SUMS` | 配布物検証 | - | 上記3パッケージのSHA-256ハッシュ一覧 |

- **共通基盤**:
  - 対象: LINE iOS 26.16.0 (Build `2026.1006.1718`)、26.17.0 (Build `2026.1103.1841`、部分対応) / `arm64`
  - ビルド下限: iOS 18.0（古いiOS環境での動作は保証しません）
  - フック実装: Logos internal / fishhook を使用し、動的リンクはApple系のシステムライブラリ・フレームワークのみ。脱獄版の `mobilesubstrate` 依存は環境側ローダーを示す仮想依存であり、Substrate/libhooker へのリンクや同梱はありません。
  - dylib署名: 配布DEB内のdylibにはadhoc署名が付与されており、パッケージ生成時に厳格な署名検査を行っています（開発証明書不要。Jailed環境でのIPA注入時は通常どおり再署名が必要です）。
- **脱獄環境版 (`rootful` / `rootless`)**:
  - 公式Bundle ID（`jp.naver.line`）を受け付けるゲートおよびパッケージ仕様を整備していますが、脱獄環境での実機検証は未実施です。
  - rootless版のリソースは `dladdr` によりdylib隣接パスから解決され、固定パスに依存しません。App Store版LINE（`arm64`）を対象とし、`arm64e` システムプロセスへの対応は含みません。
- **非脱獄用ペイロード (`jailed`)**:
  - 非脱獄環境の dpkg で直接インストールするものではなく、復号済みIPAへの注入および独自署名用のリソース群を内包したパッケージです（他2種との共用不可）。

---

## アーキテクチャと安全性

- **外部依存の排除**: Cydia Substrate や libhooker を必要とせず、Apple系のシステムライブラリ・フレームワークと同梱リソースのみで動作します。脱獄版DEBは環境側の注入ローダー（mobilesubstrate仮想パッケージ）に依存しますが、バイナリ自体は外部フックライブラリにリンクしません。
- **不変の同一性マッピングと検証**: 各バージョン・ビルド・Mach-O UUIDごとに独立した不変の同一性マッピング（`RUINVersionMapping`）を定義し、実行時は共通API（`RUINCurrentMapping()`）によって実バイナリUUIDとメタデータを厳格に照合して曖昧さや推測フォールバックを排除します。また、コンパイル済みマニフェスト検証（`check-mapping-manifest`）により定義の整合性を自動検証します。
- **データ破壊防止 (フェイルセーフ)**: 一般的なObjective-Cフックはクラス・セレクタ・型の実検証により安全に有効化し、バージョン番号のみでアプリ全体を停止しません。未検証バージョンでは起動時に一度警告を表示した上で、動作が確認できた機能のみを有効化します。ビルド固有のSwift呼び出しやデータ表はビルド番号・UUID・指紋の完全一致時のみ適用され、不一致時は該当機能のみを無効化して他の独立機能の動作を継続します。
- **クリーンなバイナリ統合**: 実行コードの直接書き換え（バイナリパッチ）は行わず、動的リンクによって安全に機能をロードします。

---

## ビルド

### 必要環境
- macOS / フルXcode (iOS SDK 含む)
- `make`, `perl`, `python3`, `node`

### コマンド

```bash
# dylib およびツールのビルド（build/RUIN.dylib はビルド中間物）
make -j4 all

# 配布用パッケージ (DEB 3種および SHA256SUMS) の生成
make dist

# ホスト環境検査・パッケージ構造検査・ポータブル整合性検査
make -j4 check-host
make check-packaging
make check-portable

# バージョン確認
make version
```

ビルド成果物は `build/`（中間物）および `dist/`（配布用パッケージ）に出力されます。

---

## CI / CD

GitHub Actions による自動検証および配布パッケージビルドが構成されています。

### ワークフロー概要

- **Validate RUIN** (`validate.yml`):
  - **トリガー**: `main` へのプッシュ、プルリクエスト、手動実行 (`workflow_dispatch`)
  - **検証内容**:
    - macOS環境: iOS SDKを用いたビルド検証、ホストテスト（Node.js構文検査含む）、合成フィクスチャ検証、パッケージ構造検証
    - Linux環境: `make check-portable` によるLogos前処理検証、Python単体テスト（※Linux上でのバイナリビルドは行いません）
  - **テストフィクスチャ**: 合成フィクスチャおよびホスト検証データのみを使用し、秘密の復号済み原IPA等は一切使用しません。
- **Build RUIN distribution** (`distribute.yml`):
  - **トリガー**: 手動実行 (`workflow_dispatch`)、リリースタグプッシュ (`v*`)
  - **成果物**:
    - `RUIN-<version>-rootful.deb`
    - `RUIN-<version>-rootless.deb`
    - `RUIN-<version>-jailed.deb`
    - `SHA256SUMS`（上記3パッケージのハッシュ一覧）
  - リリースタグプッシュ時はプレフィックス `v` を除いたバージョン名（例: `0.5.0`）で配布物が生成され、GitHub Releaseへ自動添付されます。

---

## 署名とインストール

非脱獄端末へのインストールには、ユーザー自身が用意した復号済みIPA、Apple Developer証明書、およびプロファイルが必要です。

### Jailed環境での利用
配布物の `RUIN-<version>-jailed.deb` は、非脱獄端末へ直接dpkgインストールすることはできません。ユーザー自身の署名・注入ツールを用いて復号済みIPAへ組み込み、再署名を行ってください。
その際、`RUIN.dylib` だけでなく `RUINResources.bundle` もアプリバンドル内へ取り込めるツールおよび設定が必要です（汎用注入ツールでの一律動作保証は行いません）。

### 署名環境・ストレージ補正
非公式な署名やEntitlementが制限された環境でもLINE本来の機能を損なわないよう、必要最小限の読み取り・ストレージ補正機能を実装しています。
- **Bundle ID補正**: 対象LINEバイナリの整合性を確認後、メインバンドルID参照値のみをアプリ内部向けに `jp.naver.line` へ補正します（OS側のコード署名やEntitlementsの実IDは保持）。
- **App Group / キーチェーン保護**: OS許可済みのグループ、有効な明示マッピング、または永続マーカーのみを安全な保存先として認識し、安定した共有保存先を確認できない新規インストールや共有Keychain未準備の状態では既存セッションを維持しつつ新規ログイン/QR開始を安全に抑止します。暗号鍵やメッセージの移植・強制復号・削除・結合は行わず、アプリ独自の保存領域切り替えによるデータ喪失事故を防ぎます（※Appleの署名制限を超える権限付与や端末移行全経路の保証を行うものではありません）。
- **タブ復旧オプション**: 設定変更は再起動後に反映されます。トラブルシューティング用として、環境変数 `RUIN_DISABLE_TAB_HIDING=1` を指定して起動することで一時的にタブ非表示を解除できます。
- **iPad対応**: iPad環境における設定画面の入口は可視の親コントローラからNavigation Pushで展開する動作を実機確認済みです（実装済みの標準Page Sheet展開は未試験であり、検証完了とはしていません）。

### 開発用パッケージングスクリプト
リポジトリ同梱の `tools/package.py` は、ローカルビルドの中間生成物を用いてテスト用IPAを生成する**開発者向けツール**です。

```bash
# ローカルビルド成果物を用いた署名・インジェクション例（開発用）
python3 tools/package.py \
  --ipa <LINE.ipa> \
  --profile <profile.mobileprovision> \
  --p12 <certificate.p12> \
  --password-file <password.txt> \
  --udid <device-udid> \
  --bundle-id <profile-allowed-bundle-id> \
  --dylib build/RUIN.dylib \
  --resources resources/RUINResources.bundle
```

> [!TIP]
> 既存のトーク履歴やログインセッションを維持してアップデートする場合は、既存のBundle ID、App Group、およびキーチェーン共有設定を維持したプロファイルで署名してください。
