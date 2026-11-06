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
- **返信時自動既読**: メッセージを送信・返信した際に自動的に既読を付けます。
- **既読者一覧シート**: メッセージ長押しメニューから、既読者の表示名と日時を確認できます。
- **送信取消メッセージ保持**: 相手が取り消したメッセージを端末内に保持し、「取消済」マーク付きで表示します。
- **送信取消の延長**: 送信後24時間以内のメッセージについて、端末側での送信取消を可能にします。
- **ミュート送信**: 送信ボタンを約2秒長押しすることでネイティブの選択メニューが表示され、相手に通知を送らずに送信できます。
  - ※「送信取消延長・ミュート」は、ローカルLYPとは独立した専用設定で管理されます。
- **ローカル表示名**: 端末上でのみ友だちの表示名を変更します（相手やサーバーには反映されません）。

### 表示管理 & ナビゲーション
- **不要要素の非表示**: 広告、おすすめコンテンツ、音声入力UI、Agent-i を個別に非表示化できます。
- **タブ管理**: 不要なネイティブタブを非表示にし、起動時に表示する初期タブを指定できます。

### テーマ & カスタムフォント
- **ネイティブ着せかえ**: 公式着せかえショップやマイ着せかえのローカル適用・再取得に対応します。
- **ローカルカスタムフォント**:
  - 「RUIN設定」→「カスタムフォント」から、OTF/TTFファイル（32MB以下）をインポートしてアプリ全体のフォントを変更できます。
  - 設定からいつでも標準フォントへ復帰可能です。

### 多言語ローカライズ
- 日本語 (`ja`)、英語 (`en`)、韓国語 (`ko`)、簡体字中国語 (`zh-Hans`)、繁体字中国語 (`zh-Hant`) の5言語に対応しています。

---

## 動作要件

| 項目 | 要件 |
| :--- | :--- |
| **対象アプリ** | LINE iOS 26.16.0 (Build `2026.1006.1718`) |
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
  - 対象: LINE iOS 26.16.0 (Build `2026.1006.1718`) / `arm64`
  - ビルド下限: iOS 18.0（古いiOS環境での動作は保証しません）
  - フック実装: Logos internal / fishhook を使用し、動的リンクはApple系のシステムライブラリ・フレームワークのみ。脱獄版の `mobilesubstrate` 依存は環境側ローダーを示す仮想依存であり、Substrate/libhooker へのリンクや同梱はありません。
- **脱獄環境版 (`rootful` / `rootless`)**:
  - 公式Bundle ID（`jp.naver.line`）を受け付けるゲートおよびパッケージ仕様を整備していますが、脱獄環境での実機検証は未実施です。
  - rootless版のリソースは `dladdr` によりdylib隣接パスから解決され、固定パスに依存しません。App Store版LINE（`arm64`）を対象とし、`arm64e` システムプロセスへの対応は含みません。
- **非脱獄用ペイロード (`jailed`)**:
  - 非脱獄環境の dpkg で直接インストールするものではなく、復号済みIPAへの注入および独自署名用のリソース群を内包したパッケージです（他2種との共用不可）。

---

## アーキテクチャと安全性

- **外部依存の排除**: Cydia Substrate や libhooker を必要とせず、Apple系のシステムライブラリ・フレームワークと同梱リソースのみで動作します。脱獄版DEBは環境側の注入ローダー（mobilesubstrate仮想パッケージ）に依存しますが、バイナリ自体は外部フックライブラリにリンクしません。
- **データ破壊防止 (フェイルセーフ)**: 対象バイナリのバージョンや内部型定義・ABIの整合性を検証し、不一致を検知した場合は該当フックを安全に自動無効化します（トーク履歴やアカウントデータの保護）。
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
  - リリースタグプッシュ時はプレフィックス `v` を除いたバージョン名（例: `0.4.1`）で配布物が生成され、GitHub Releaseへ自動添付されます。

---

## 署名とインストール

非脱獄端末へのインストールには、ユーザー自身が用意した復号済みIPA、Apple Developer証明書、およびプロファイルが必要です。

### Jailed環境での利用
配布物の `RUIN-<version>-jailed.deb` は、非脱獄端末へ直接dpkgインストールすることはできません。ユーザー自身の署名・注入ツールを用いて復号済みIPAへ組み込み、再署名を行ってください。
その際、`RUIN.dylib` だけでなく `RUINResources.bundle` もアプリバンドル内へ取り込めるツールおよび設定が必要です（汎用注入ツールでの一律動作保証は行いません）。

### アプリ内部Bundle ID補正
非公式なBundle IDで署名された場合でもLINE本来の機能を損なわないよう、アプリ内部向けBundle ID補正機能を実装しています。
対象LINEバージョン（26.16.0）、ビルド番号（`2026.1006.1718`）、およびバイナリUUIDを検証後、メインバンドルの `bundleIdentifier`、`objectForInfoDictionaryKey:@"CFBundleIdentifier"`、`infoDictionary`、および必要に応じて公開C API（`CFBundleGetInfoDictionary`）経由の読み取り値をアプリ内部向けに `jp.naver.line` へ補正します。
- OS側のコード署名、プロファイル、Entitlementsの実IDは変更しません。
- LINE以外の `NSBundle` やAppleシステムフレームワークからの呼び出しには適用されません。

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
