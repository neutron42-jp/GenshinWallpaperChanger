# GenshinWallpaperChanger

HoYoPlay API から『原神』ランチャーの**文字なし背景画像**を取得し、Real-ESRGAN で 2x 超解像して GNOME の壁紙に設定するスクリプトです。systemd user timer により、ログイン時と1時間ごとに自動実行されます。

## 動作の流れ

1. HoYoPlay API (`getGames`) から背景画像 URL を取得
2. 画像をダウンロード（前回と SHA256 が同じなら何もしない）
3. Real-ESRGAN (`realesr-animevideov3-x2`) で 2 倍に超解像
4. `gsettings` で GNOME の壁紙（light / dark 両方）に設定

## 動作環境

- Fedora 44 + GNOME
- `gsettings` が使えること（GNOME デスクトップ）
- Real-ESRGAN (`realesrgan-ncnn-vulkan`) 実行のため **Vulkan 対応 GPU** が必要
- x86_64 Linux（Real-ESRGAN バイナリは Ubuntu 版を自動ダウンロード）

## 必要なもの

| コマンド | 用途 | 必須 |
| --- | --- | --- |
| `jq` | API レスポンスの解析 | 必須 |
| `curl` | API 取得・画像ダウンロード | 必須 |
| `unzip` | Real-ESRGAN の自動展開 | 自動DLを使う場合 |
| `wget` | curl 失敗時のフォールバック | 任意 |

```bash
sudo dnf install jq curl unzip
```

Real-ESRGAN 本体は初回実行時に GitHub Releases から `~/.local/share/genshin-wallpaper/realesrgan/` へ自動ダウンロードされます。

## インストール

```bash
git clone https://github.com/neutron42-jp/GenshinWallpaperChanger.git
cd GenshinWallpaperChanger

install -Dm755 genshin-wallpaper.sh ~/.local/bin/genshin-wallpaper.sh
install -Dm644 systemd/genshin-wallpaper.service ~/.config/systemd/user/genshin-wallpaper.service
install -Dm644 systemd/genshin-wallpaper.timer   ~/.config/systemd/user/genshin-wallpaper.timer

systemctl --user daemon-reload
systemctl --user enable --now genshin-wallpaper.timer
```

## 使い方

```bash
genshin-wallpaper.sh               # 通常実行（変更があれば更新）
genshin-wallpaper.sh -f            # 強制実行（ハッシュ無視・超解像も再実行）
genshin-wallpaper.sh --upscale-only # 既存の元画像を超解像のみ実行
```

手動で即時実行する場合:

```bash
systemctl --user start genshin-wallpaper.service
```

ログの確認:

```bash
journalctl --user -u genshin-wallpaper.service -e
```

## ファイル構成

```
genshin-wallpaper.sh                  # 本体
systemd/genshin-wallpaper.service     # 実行 unit
systemd/genshin-wallpaper.timer       # 定期実行（ログイン30秒後 + 1時間ごと）
```

## 生成物

`~/.local/share/genshin-wallpaper/` 配下:

| ファイル | 内容 |
| --- | --- |
| `current.webp` | API から取得した元画像 |
| `current_upscaled.webp` | 超解像後の画像（壁紙に設定される） |
| `current.hash` | 元画像の SHA256 |
| `realesrgan/` | Real-ESRGAN 本体とモデル |

## 設定のカスタマイズ

- **API の言語**: `genshin-wallpaper.sh` の `API_URL` 内 `language=ja-jp` を変更
- **解像度・モデル**: `-n realesr-animevideov3-x2 -s 2` の部分を変更（他モデルは `realesrgan/models/` 参照）
- **実行間隔**: `systemd/genshin-wallpaper.timer` の `OnUnitActiveSec` を変更

## 注意

- GNOME 専用です。`gsettings` のキー (`org.gnome.desktop.background`) に依存します。
- 壁紙の設定先は `~/.local/bin` を前提としています。別の場所に置く場合は `genshin-wallpaper.service` の `ExecStart` を修正してください。
- API は非公式に利用しています。仕様変更により取得に失敗する可能性があります（その場合は前回の壁紙を維持します）。
