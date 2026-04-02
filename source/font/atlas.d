module font.atlas;

import font.freetype : GlyphBitmap;
import std.algorithm : max;

// アトラス内のグリフ情報
struct GlyphInfo
{
    float u0, v0, u1, v1;  // UV 座標 (正規化 0.0 〜 1.0)
    int   bearingX;        // ピクセル
    int   bearingY;
    uint  width;
    uint  height;
    int   advanceX;        // ピクセル
}

// グレースケールビットマップアトラス (CPU 側)
// テクスチャフォーマット: VK_FORMAT_R8_UNORM
struct GlyphAtlas
{
    enum SIZE    = 2048;  // アトラスの幅・高さ (ピクセル)
    enum PADDING = 1;     // グリフ間の隙間

    ubyte[]          pixels;   // R8, SIZE × SIZE バイト
    uint             cursorX = PADDING;
    uint             cursorY = PADDING;
    uint             rowH    = 0;
    GlyphInfo[uint] glyphs;  // キー: FreeType グリフ ID
    bool             dirty = false;

    void initialize()
    {
        pixels.length = SIZE * SIZE;
        pixels[]      = 0;
    }

    /// グリフをアトラスに追加する。
    /// すでに登録済みの場合はそのポインタを返す。
    /// アトラスが溢れた場合は null を返す。
    /// グリフ ID をキーにアトラスへ登録する。
    /// すでに登録済みの場合はそのポインタを返す。
    /// アトラスが溢れた場合は null を返す。
    GlyphInfo* addGlyph(uint glyphId, ref const GlyphBitmap bmp)
    {
        if (auto p = glyphId in glyphs) return p;

        GlyphInfo gi;
        gi.bearingX = bmp.bearingX;
        gi.bearingY = bmp.bearingY;
        gi.advanceX = bmp.advanceX;
        gi.width    = bmp.width;
        gi.height   = bmp.rows;

        // 空グリフ (スペース等): UV はゼロのまま、advance のみ有効
        if (bmp.width == 0 || bmp.rows == 0)
        {
            gi.u0 = gi.v0 = gi.u1 = gi.v1 = 0;
            glyphs[glyphId] = gi;
            return glyphId in glyphs;
        }

        uint w = bmp.width + PADDING;
        uint h = bmp.rows  + PADDING;

        // shelf-packing: 右端に収まらなければ次の行へ
        if (cursorX + w > SIZE)
        {
            cursorX  = PADDING;
            cursorY += rowH + PADDING;
            rowH     = 0;
        }
        if (cursorY + h > SIZE) return null; // アトラス溢れ

        // ピクセルコピー (行単位)
        foreach (row; 0 .. bmp.rows)
        {
            size_t dst = (cursorY + row) * SIZE + cursorX;
            size_t src = row * bmp.width;
            pixels[dst .. dst + bmp.width] = bmp.pixels[src .. src + bmp.width];
        }

        // UV 計算
        gi.u0 = cast(float)  cursorX            / SIZE;
        gi.v0 = cast(float)  cursorY            / SIZE;
        gi.u1 = cast(float)(cursorX + bmp.width) / SIZE;
        gi.v1 = cast(float)(cursorY + bmp.rows)  / SIZE;

        cursorX += w;
        rowH     = max(rowH, h);
        dirty    = true;

        glyphs[glyphId] = gi;
        return glyphId in glyphs;
    }
}
