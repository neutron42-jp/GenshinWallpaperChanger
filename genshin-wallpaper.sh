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
APPLY_ONLY=""

# 引数解析
for arg in "$@"; do
    case "$arg" in
        -f|--force)
            FORCE="1"
            ;;
        --upscale-only)
            UPSCALE_ONLY="1"
            ;;
        --apply-only)
            APPLY_ONLY="1"
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

# 超解像に使う Vulkan デバイス番号 (0: NVIDIA dGPU / 1: AMD iGPU / 2: llvmpipe)
# dGPU では Xid 109 (CTX SWITCH TIMEOUT) で全タイルが失敗し、
# 全透明の WebP が出力される事故が起きたため、既定は iGPU。
REALESRGAN_GPU="${REALESRGAN_GPU:-1}"

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

# --- 画像チェック ---
# Real-ESRGAN は Vulkan の処理に失敗しても終了コード 0 で
# 全透明 (ほぼ空) の WebP を書き出すことがある。
# それを壁紙に設定すると GNOME は背景色だけを表示してしまうので、ここで弾く。
image_ok() {
    local img="$1" src="${2:-}"

    [[ -f "$img" && -s "$img" ]] || return 1

    # 正常な 2x 超解像なら元画像より十分大きくなる
    if [[ -n "$src" && -f "$src" ]]; then
        local src_size dst_size
        src_size=$(stat -c%s "$src")
        dst_size=$(stat -c%s "$img")
        (( dst_size * 2 > src_size )) || return 1
    fi

    # 画像が真っ平ら (全透明・単色) なら失敗とみなす
    if command -v identify &>/dev/null; then
        local sd
        sd=$(identify -format '%[fx:standard_deviation]' "$img" 2>/dev/null || true)
        if [[ -n "$sd" ]] && ! awk -v v="$sd" 'BEGIN { exit !(v > 0.001) }'; then
            return 1
        fi
    fi

    return 0
}

# --- AI超解像 ---
# 失敗したときは出力ファイルを残さない
run_upscale() {
    local src="$1" dst="$2"

    [[ -f "$REALESRGAN_BIN" ]] || return 1
    rm -f "$dst"
    if ! "$REALESRGAN_BIN" -i "$src" -o "$dst" -n realesr-animevideov3-x2 -s 2 -f webp \
        -g "$REALESRGAN_GPU" >/dev/null 2>&1; then
        rm -f "$dst"
        return 1
    fi
    if ! image_ok "$dst" "$src"; then
        rm -f "$dst"
        return 1
    fi
    return 0
}

# --- 壁紙を適用 (GNOME + Hyprland/Ambxst) ---
# GNOME: gsettings / Hyprland: Ambxst (起動しているときのみ)
apply_wallpaper() {
    local img="$1"
    if [[ ! -f "$img" || ! -s "$img" ]]; then
        echo "壁紙ファイルが存在しません: $img" >&2
        return 1
    fi

    # GNOME (light / dark 両方)
    if command -v gsettings &>/dev/null; then
        gsettings set org.gnome.desktop.background picture-uri "file://${img}"
        gsettings set org.gnome.desktop.background picture-uri-dark "file://${img}"
    fi

    # Hyprland (Ambxst)
    # Ambxst の壁紙ディレクトリに安定した名前で置いてから適用する。
    # (ディレクトリ外のファイルは cli_<timestamp>_... として取り込まれるため)
    local amx
    amx=$(command -v ambxst 2>/dev/null || true)
    [[ -z "$amx" && -x /usr/local/bin/ambxst ]] && amx=/usr/local/bin/ambxst
    if [[ -n "$amx" ]]; then
        local wp_dir dst IMG_FOR_AMX
        IMG_FOR_AMX=""
        wp_dir=$(jq -r '.wallPath // empty' "${HOME}/.cache/ambxst/wallpapers.json" 2>/dev/null || true)
        if [[ -n "$wp_dir" && -d "$wp_dir" ]]; then
            dst="${wp_dir}/genshin-wallpaper.webp"
            cmp -s "$img" "$dst" || cp -f "$img" "$dst"
            IMG_FOR_AMX="$dst"
            # 過去に取り込まれた ad-hoc コピーを掃除
            find "$wp_dir" -maxdepth 1 \( -name 'cli_*_current_upscaled.webp' -o -name 'cli_*_current.webp' \) -delete 2>/dev/null || true
        else
            IMG_FOR_AMX="$img"
        fi
        if timeout 30 "$amx" wallpaper "$IMG_FOR_AMX" >/dev/null 2>&1; then
            echo "Hyprland (Ambxst): 壁紙を適用しました (${IMG_FOR_AMX})"
        else
            echo "Hyprland (Ambxst): 適用をスキップ (Ambxst 未起動など)" >&2
        fi
    fi
}

# --- 適用のみ (Hyprland ログイン時の再適用などに使用) ---
if [[ -n "$APPLY_ONLY" ]]; then
    TARGET="$CURRENT_UPSCALED"
    [[ -f "$TARGET" ]] || TARGET="$CURRENT_IMG"
    if [[ ! -f "$TARGET" ]]; then
        echo "適用できる壁紙がありません。通常実行してください。" >&2
        exit 1
    fi
    apply_wallpaper "$TARGET"
    exit $?
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
    if run_upscale "$CURRENT_IMG" "$TEMP_UPSCALED"; then
        mv "$TEMP_UPSCALED" "$CURRENT_UPSCALED"
        sync
        sleep 2
        apply_wallpaper "$CURRENT_UPSCALED"
        echo "超解像完了。壁紙を更新しました。"
        exit 0
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
            # 適用中の超解像画像が壊れていたら作り直す
            # (Real-ESRGAN が全透明画像を書き出したまま、壁紙が背景色になる事故の復旧)
            if [[ -f "$CURRENT_UPSCALED" ]] && ! image_ok "$CURRENT_UPSCALED" "$CURRENT_IMG"; then
                echo "適用中の超解像画像が壊れています。再生成します..." >&2
                rm -f "$CURRENT_UPSCALED"
                if run_upscale "$CURRENT_IMG" "$TEMP_UPSCALED"; then
                    mv "$TEMP_UPSCALED" "$CURRENT_UPSCALED"
                    apply_wallpaper "$CURRENT_UPSCALED" || true
                else
                    apply_wallpaper "$CURRENT_IMG" || true
                fi
            fi
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
    # tempだけ消す。current_upscaledは処理中も残しておく
    if run_upscale "$CURRENT_IMG" "$TEMP_UPSCALED"; then
        mv "$TEMP_UPSCALED" "$CURRENT_UPSCALED"
        USE_UPSCALED="1"
        echo "AI超解像完了"
    else
        echo "AI超解像に失敗しました。通常の画像を使用します。" >&2
    fi
fi

if [[ -n "$USE_UPSCALED" ]]; then
    WALLPAPER_TARGET="$CURRENT_UPSCALED"
else
    rm -f "$CURRENT_UPSCALED"
    WALLPAPER_TARGET="$CURRENT_IMG"
fi

# --- 壁紙を適用 (GNOME + Hyprland/Ambxst) ---
sync
sleep 2
apply_wallpaper "$WALLPAPER_TARGET" || exit 1

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
