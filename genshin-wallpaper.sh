#!/bin/bash
# Genshin Impact Launcher Art Wallpaper Updater for Fedora 44 + GNOME
# 文字なし版（pure）+ AI超解像（Real-ESRGAN）
# ログイン時・定期実行用
#
# 使い方:
#   ~/.local/bin/genshin-wallpaper.sh        # 通常実行（変更があれば更新）
#   ~/.local/bin/genshin-wallpaper.sh -f     # 強制実行（ハッシュ無視・超解像も再実行）
#   ~/.local/bin/genshin-wallpaper.sh --upscale-only  # 既存画像を超解像のみ実行

set -euo pipefail

FORCE=""
UPSCALE_ONLY=""

# 引数解析
for arg in "$@"; do
    case "$arg" in
        -f|--force)
            FORCE="1"
            ;;
        --upscale-only)
            UPSCALE_ONLY="1"
            ;;
    esac
done

WALLPAPER_DIR="${HOME}/.local/share/genshin-wallpaper"
mkdir -p "$WALLPAPER_DIR"

CURRENT_IMG="${WALLPAPER_DIR}/current.webp"
CURRENT_UPSCALED="${WALLPAPER_DIR}/current_upscaled.webp"
HASH_FILE="${WALLPAPER_DIR}/current.hash"
TEMP_IMG="${WALLPAPER_DIR}/temp.webp"
TEMP_UPSCALED="${WALLPAPER_DIR}/temp_upscaled.webp"

# Real-ESRGAN 設定
REALESRGAN_DIR="${WALLPAPER_DIR}/realesrgan"
REALESRGAN_BIN="${REALESRGAN_DIR}/realesrgan-ncnn-vulkan"
REALESRGAN_URL="https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesrgan-ncnn-vulkan-20220424-ubuntu.zip"

# HoYoPlay API: getGames → 文字なし（pure）背景画像
API_URL="https://sg-hyp-api.hoyoverse.com/hyp/hyp-connect/api/getGames?launcher_id=VYTpXlbWo8&language=ja-jp"

# jqが無い場合はエラーで終了
if ! command -v jq &>/dev/null; then
    echo "jqがインストールされていません: sudo dnf install jq" >&2
    exit 0
fi

# curlが無い場合はエラーで終了（API取得・画像DLに必須）
if ! command -v curl &>/dev/null; then
    echo "curlがインストールされていません: sudo dnf install curl" >&2
    exit 0
fi

# --- Real-ESRGAN ダウンロード（初回のみ） ---
download_realesrgan() {
    echo "Real-ESRGANをダウンロードしています..."
    mkdir -p "$REALESRGAN_DIR"

    local DL_OK=""
    local TMP_ZIP
    TMP_ZIP=$(mktemp --suffix=.zip)

    # 方法1: curl + User-Agent + redirect追従
    if command -v curl &>/dev/null && [[ -z "$DL_OK" ]]; then
        echo "curlでダウンロード試行中..."
        if curl -fsSL -A "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36"             --max-time 300 "$REALESRGAN_URL" -o "$TMP_ZIP" 2>/dev/null; then
            local SIZE
            SIZE=$(stat -c%s "$TMP_ZIP" 2>/dev/null || echo 0)
            if [[ $SIZE -gt 1000000 ]]; then
                DL_OK="1"
                echo "curlでダウンロード成功 ($SIZE bytes)"
            else
                echo "curl: ファイルサイズが小さすぎます ($SIZE bytes)"
            fi
        fi
    fi

    # 方法2: wget
    if command -v wget &>/dev/null && [[ -z "$DL_OK" ]]; then
        echo "wgetでダウンロード試行中..."
        if wget -q --timeout=300 --user-agent="Mozilla/5.0"             -O "$TMP_ZIP" "$REALESRGAN_URL" 2>/dev/null; then
            local SIZE
            SIZE=$(stat -c%s "$TMP_ZIP" 2>/dev/null || echo 0)
            if [[ $SIZE -gt 1000000 ]]; then
                DL_OK="1"
                echo "wgetでダウンロード成功 ($SIZE bytes)"
            else
                echo "wget: ファイルサイズが小さすぎます ($SIZE bytes)"
            fi
        fi
    fi

    # 展開
    if [[ -n "$DL_OK" ]] && command -v unzip &>/dev/null; then
        echo "展開中..."
        if unzip -o "$TMP_ZIP" -d "$REALESRGAN_DIR" 2>/dev/null; then
            local FOUND
            FOUND=$(find "$REALESRGAN_DIR" -name "realesrgan-ncnn-vulkan" -type f 2>/dev/null | head -n1)
            if [[ -n "$FOUND" ]]; then
                REALESRGAN_BIN="$FOUND"
                chmod +x "$REALESRGAN_BIN"
                echo "Real-ESRGANインストール完了: $REALESRGAN_BIN"
            else
                echo "Real-ESRGANバイナリが見つかりません" >&2
            fi
        else
            echo "展開に失敗しました" >&2
        fi
    else
        echo "Real-ESRGANのダウンロードに失敗しました。通常の画像を使用します。" >&2
        echo "手動インストール方法:" >&2
        echo "  1. ブラウザで以下を開いてダウンロード:" >&2
        echo "     https://github.com/xinntao/Real-ESRGAN/releases/tag/v0.2.5.0" >&2
        echo "  2. realesrgan-ncnn-vulkan-20220424-ubuntu.zip をダウンロード" >&2
        echo "  3. unzip -o realesrgan-ncnn-vulkan-20220424-ubuntu.zip -d $REALESRGAN_DIR" >&2
        echo "  4. chmod +x $REALESRGAN_DIR/realesrgan-ncnn-vulkan" >&2
    fi

    rm -f "$TMP_ZIP"
}

if [[ ! -f "$REALESRGAN_BIN" ]]; then
    download_realesrgan
fi

# --- 超解像のみ実行モード ---
if [[ -n "$UPSCALE_ONLY" ]]; then
    if [[ ! -f "$CURRENT_IMG" ]]; then
        echo "元画像が見つかりません。通常実行してください。" >&2
        exit 1
    fi
    if [[ ! -f "$REALESRGAN_BIN" ]]; then
        echo "Real-ESRGANがインストールされていません。" >&2
        exit 1
    fi
    echo "既存画像の超解像を実行します..."
    rm -f "$TEMP_UPSCALED"
    if "$REALESRGAN_BIN" -i "$CURRENT_IMG" -o "$TEMP_UPSCALED" -n realesr-animevideov3-x2 -s 2 -f webp >/dev/null 2>&1; then
        if [[ -f "$TEMP_UPSCALED" && -s "$TEMP_UPSCALED" ]]; then
            mv "$TEMP_UPSCALED" "$CURRENT_UPSCALED"
            sync
            sleep 2
            gsettings set org.gnome.desktop.background picture-uri "file://${CURRENT_UPSCALED}"
            gsettings set org.gnome.desktop.background picture-uri-dark "file://${CURRENT_UPSCALED}"
            echo "超解像完了。壁紙を更新しました。"
            exit 0
        fi
    fi
    echo "超解像に失敗しました。" >&2
    exit 1
fi

# --- APIから背景画像URLを取得 ---
BG_URL=$(curl -s --max-time 30 "$API_URL" | jq -r '.data.games[] | select(.id == "gopR6Cufr3") | .display.background.url')

if [[ -z "$BG_URL" || "$BG_URL" == "null" ]]; then
    echo "背景画像URLの取得に失敗しました。前の壁紙を維持します。" >&2
    exit 0
fi

# --- 画像ダウンロード ---
if ! curl -sL --max-time 60 "$BG_URL" -o "$TEMP_IMG"; then
    echo "画像のダウンロードに失敗しました。前の壁紙を維持します。" >&2
    rm -f "$TEMP_IMG"
    exit 0
fi

if [[ ! -s "$TEMP_IMG" ]]; then
    echo "ダウンロードした画像が空です。前の壁紙を維持します。" >&2
    rm -f "$TEMP_IMG"
    exit 0
fi

# --- SHA256ハッシュで前回と比較 ---
CURRENT_HASH=$(sha256sum "$TEMP_IMG" | awk '{print $1}')

NEED_UPSCALE=""
if [[ -n "$FORCE" ]]; then
    echo "強制実行モード: ハッシュチェックをスキップします"
    NEED_UPSCALE="1"
else
    if [[ -f "$HASH_FILE" ]]; then
        PREV_HASH=$(cat "$HASH_FILE")
        if [[ "$CURRENT_HASH" == "$PREV_HASH" ]]; then
            echo "画像に変更はありません"
            rm -f "$TEMP_IMG"
            exit 0
        fi
    fi
    NEED_UPSCALE="1"
fi

# --- ファイルを確定 ---
mv "$TEMP_IMG" "$CURRENT_IMG"
echo "$CURRENT_HASH" > "$HASH_FILE"

# --- AI超解像 ---
# 注意: 処理中に前回の壁紙を削除しないように、current_upscaled は消さない
USE_UPSCALED=""
if [[ -n "$NEED_UPSCALE" ]] && [[ -f "$REALESRGAN_BIN" ]]; then
    echo "AI超解像処理中...（数秒〜数十秒かかります）"
    rm -f "$TEMP_UPSCALED"  # tempだけ消す。current_upscaledは残しておく
    if "$REALESRGAN_BIN" -i "$CURRENT_IMG" -o "$TEMP_UPSCALED" -n realesr-animevideov3-x2 -s 2 -f webp >/dev/null 2>&1; then
        if [[ -f "$TEMP_UPSCALED" && -s "$TEMP_UPSCALED" ]]; then
            mv "$TEMP_UPSCALED" "$CURRENT_UPSCALED"
            USE_UPSCALED="1"
            echo "AI超解像完了"
        fi
    fi
    if [[ -z "$USE_UPSCALED" ]]; then
        echo "AI超解像に失敗しました。通常の画像を使用します。" >&2
        rm -f "$TEMP_UPSCALED"
    fi
fi

if [[ -n "$USE_UPSCALED" ]]; then
    WALLPAPER_TARGET="$CURRENT_UPSCALED"
else
    rm -f "$CURRENT_UPSCALED"
    WALLPAPER_TARGET="$CURRENT_IMG"
fi

# --- GNOME壁紙を設定 ---
if [[ -f "$WALLPAPER_TARGET" && -s "$WALLPAPER_TARGET" ]]; then
    sync
    sleep 2
    gsettings set org.gnome.desktop.background picture-uri "file://${WALLPAPER_TARGET}"
    gsettings set org.gnome.desktop.background picture-uri-dark "file://${WALLPAPER_TARGET}"
else
    echo "壁紙ファイルが存在しません。設定をスキップします。" >&2
    exit 1
fi

# ロック画面も設定したい場合は以下のコメントを外す
# gsettings set org.gnome.desktop.screensaver picture-uri "file://${WALLPAPER_TARGET}"

# ファイル情報を表示
SIZE=$(stat -c%s "$WALLPAPER_TARGET" 2>/dev/null || echo 0)
echo "壁紙を更新しました: $(date '+%Y-%m-%d %H:%M:%S')"
echo "  ファイル: $WALLPAPER_TARGET"
echo "  サイズ: ${SIZE} bytes ($(( SIZE / 1024 / 1024 )) MB)"
if command -v file &>/dev/null; then
    file "$WALLPAPER_TARGET" | sed 's/^/  /'
fi
