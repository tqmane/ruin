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
| **動作環境** | Jailed環境対応（Cydia Substrate / libhooker 等の外部フレームワーク不要） |

---

## アーキテクチャと安全性

- **外部依存の排除**: Cydia Substrate や libhooker を必要とせず、iOS標準フレームワークと同梱リソースのみで動作します。
- **データ破壊防止 (フェイルセーフ)**: 対象バイナリのバージョンや内部型定義・ABIの整合性を検証し、不一致を検知した場合は該当フックを安全に自動無効化します（トーク履歴やアカウントデータの保護）。
- **クリーンなバイナリ統合**: 実行コードの直接書き換え（バイナリパッチ）は行わず、動的リンクによって安全に機能をロードします。

---

## ビルド

### 必要環境
- macOS / フルXcode (iOS SDK 含む)
- `make`, `perl`, `python3`, `node`

### コマンド

```bash
# dylib およびツールのビルド
make -j4 all

# 配布用パッケージ (DEB / ZIP) の生成
make dist

# ホスト環境検査・ポータブル整合性検査
make -j4 check-host
make check-packaging
make check-portable

# バージョン確認
make version
```

ビルド成果物は `build/` および `dist/` に出力されます。

---

## 署名とインストール

非脱獄端末へのインストールには、ユーザー自身が用意した復号済みIPA、Apple Developer証明書、およびプロファイルが必要です。

同梱の `tools/package.py` を使用して署名とインジェクションを一括で準備できます。

```bash
python3 tools/package.py \
  --ipa <LINE.ipa> \
  --profile <profile.mobileprovision> \
  --p12 <certificate.p12> \
  --password-file <password.txt> \
  --udid <device-udid> \
  --bundle-id <profile-allowed-bundle-id> \
  --dylib <RUIN.dylib> \
  --resources <RUINResources.bundle>
```

> [!TIP]
> 既存のLINEのトーク履歴やログインデータを維持して更新する場合は、既存のBundle ID、App Group、およびキーチェーン共有設定を変更せずに署名してください。
