module font.freetype;

import std.exception : enforce;
import std.string    : toStringz;
import std.conv      : to;

// ────────────────────────────────────────────────────────────
// 型エイリアス
// ────────────────────────────────────────────────────────────

alias FT_Library = void*;
alias FT_Error   = int;
alias FT_Long    = long;
alias FT_ULong   = ulong;
alias FT_Int     = int;
alias FT_Int32   = int;
alias FT_UInt    = uint;
alias FT_Short   = short;
alias FT_UShort  = ushort;
alias FT_Pos     = long;

// ────────────────────────────────────────────────────────────
// 構造体 (x86_64 Linux のレイアウトに合わせる)
// D は C と同様に自然アライメントを行うため、
// ポインタ直前の int フィールドには自動的に 4 バイトパディングが入る。
// ────────────────────────────────────────────────────────────

struct FT_Vector { FT_Pos x, y; }

// FT_Bitmap: rows(4) + width(4) + pitch(4) + [pad4] + buffer(8)
//          + num_grays(2) + pixel_mode(1) + palette_mode(1) + [pad4] + palette(8)
//          = 40 bytes
struct FT_Bitmap
{
    uint   rows;
    uint   width;
    int    pitch;
    ubyte* buffer;      // D が自動で 4 バイトパディング挿入 (8 バイトアライン)
    ushort num_grays;
    ubyte  pixel_mode;
    ubyte  palette_mode;
    void*  palette;     // D が自動で 4 バイトパディング挿入
}
static assert(FT_Bitmap.sizeof          == 40, "FT_Bitmap size mismatch");
static assert(FT_Bitmap.buffer.offsetof == 16, "FT_Bitmap.buffer offset mismatch");

struct FT_Glyph_Metrics
{
    FT_Pos width,  height;
    FT_Pos horiBearingX, horiBearingY, horiAdvance;
    FT_Pos vertBearingX, vertBearingY, vertAdvance;
}
static assert(FT_Glyph_Metrics.sizeof == 64);

// FT_GlyphSlotRec 先頭フィールドの最低限定義
// offset  0: library, face, next (各 ptr 8)
// offset 24: glyph_index (uint 4) → [pad4] → offset 32
// offset 32: generic (void*[2] = 16)
// offset 48: metrics (64)
// offset 112: linearHoriAdvance, linearVertAdvance (各 8)
// offset 128: advance (FT_Vector 16)
// offset 144: format (uint 4) → [pad4] → offset 152
// offset 152: bitmap (FT_Bitmap 40)
// offset 192: bitmap_left, bitmap_top (各 int 4)
struct FT_GlyphSlotRec
{
    void*            _library;
    void*            _face;
    void*            _next;
    FT_UInt          glyph_index;
    void*[2]         _generic;      // D が自動で 4 バイトパディング挿入
    FT_Glyph_Metrics metrics;
    FT_Long          linearHoriAdvance;
    FT_Long          linearVertAdvance;
    FT_Vector        advance;
    uint             format;
    FT_Bitmap        bitmap;        // D が自動で 4 バイトパディング挿入
    int              bitmap_left;
    int              bitmap_top;
}
static assert(FT_GlyphSlotRec.bitmap.offsetof     == 152, "bitmap offset mismatch");
static assert(FT_GlyphSlotRec.bitmap_left.offsetof == 192, "bitmap_left offset mismatch");

alias FT_GlyphSlot = FT_GlyphSlotRec*;

// FT_FaceRec 先頭フィールドの最低限定義
// offset   0: num_faces … num_glyphs (long × 5 = 40)
// offset  40: family_name, style_name (ptr × 2 = 16)
// offset  56: num_fixed_sizes (int 4) → [pad4] → offset 64
// offset  64: available_sizes (ptr 8)
// offset  72: num_charmaps (int 4) → [pad4] → offset 80
// offset  80: charmaps (ptr 8)
// offset  88: _generic (void*[2] = 16)
// offset 104: _bbox (FT_Pos[4] = 32)
// offset 136: units_per_EM … underline_thickness (short × 8 = 16)
// offset 152: glyph (ptr 8)
struct FT_FaceRec
{
    FT_Long   num_faces;
    FT_Long   face_index;
    FT_Long   face_flags;
    FT_Long   style_flags;
    FT_Long   num_glyphs;
    char*     family_name;
    char*     style_name;
    FT_Int    num_fixed_sizes;
    void*     available_sizes;  // D が自動で 4 バイトパディング挿入
    FT_Int    num_charmaps;
    void*     charmaps;         // D が自動で 4 バイトパディング挿入
    void*[2]  _generic;
    FT_Pos[4] _bbox;
    FT_UShort units_per_EM;
    FT_Short  ascender;
    FT_Short  descender;
    FT_Short  height;
    FT_Short  max_advance_width;
    FT_Short  max_advance_height;
    FT_Short  underline_position;
    FT_Short  underline_thickness;
    FT_GlyphSlot glyph;
}
static assert(FT_FaceRec.glyph.offsetof == 152, "FT_FaceRec.glyph offset mismatch");

alias FT_Face = FT_FaceRec*;

// ────────────────────────────────────────────────────────────
// ロードフラグ
// ────────────────────────────────────────────────────────────

enum FT_LOAD_RENDER = 0x4;

// ────────────────────────────────────────────────────────────
// extern(C) 宣言
// ────────────────────────────────────────────────────────────

extern(C) @nogc nothrow
{
    FT_Error FT_Init_FreeType(FT_Library* alibrary);
    FT_Error FT_Done_FreeType(FT_Library library);
    FT_Error FT_New_Face(FT_Library library, const(char)* filepathname,
                         FT_Long face_index, FT_Face* aface);
    FT_Error FT_Done_Face(FT_Face face);
    FT_Error FT_Set_Pixel_Sizes(FT_Face face, FT_UInt pixel_width, FT_UInt pixel_height);
    FT_Error FT_Load_Char(FT_Face face, FT_ULong char_code, FT_Int32 load_flags);
}

// ────────────────────────────────────────────────────────────
// グリフビットマップ (コピー保持)
// ────────────────────────────────────────────────────────────

struct GlyphBitmap
{
    ubyte[] pixels;   // R8, width × rows (pitch 正規化済み)
    uint    width;
    uint    rows;
    int     bearingX; // ピクセル単位
    int     bearingY;
    int     advanceX; // ピクセル単位 (26.6 固定小数点 → 整数)
}

// ────────────────────────────────────────────────────────────
// FontFace ラッパー
// ────────────────────────────────────────────────────────────

class FontFace
{
    private FT_Face _face;

    @property FT_Face native()      { return _face; }
    @property int     unitsPerEM()  { return _face.units_per_EM; }
    @property int     ascender()    { return _face.ascender; }
    @property int     descender()   { return _face.descender; }

    this(FT_Library lib, string path, long faceIndex = 0)
    {
        auto err = FT_New_Face(lib, path.toStringz, faceIndex, &_face);
        enforce(err == 0, "FT_New_Face failed (" ~ path ~ "): " ~ err.to!string);
    }

    void setPixelSize(uint width, uint height)
    {
        auto err = FT_Set_Pixel_Sizes(_face, width, height);
        enforce(err == 0, "FT_Set_Pixel_Sizes failed: " ~ err.to!string);
    }

    /// グリフをラスタライズして GlyphBitmap を返す。
    /// スペース等の空グリフは pixels が空で advanceX のみ有効。
    GlyphBitmap renderGlyph(dchar ch)
    {
        auto err = FT_Load_Char(_face, cast(FT_ULong) ch, FT_LOAD_RENDER);
        if (err != 0) return GlyphBitmap.init;

        FT_GlyphSlot slot = _face.glyph;
        FT_Bitmap*   bmp  = &slot.bitmap;

        GlyphBitmap gb;
        gb.width    = bmp.width;
        gb.rows     = bmp.rows;
        gb.bearingX = slot.bitmap_left;
        gb.bearingY = slot.bitmap_top;
        gb.advanceX = cast(int)(slot.advance.x >> 6); // 26.6 → 整数ピクセル

        if (gb.width > 0 && gb.rows > 0)
        {
            import core.stdc.string : memcpy;
            int absPitch = bmp.pitch < 0 ? -bmp.pitch : bmp.pitch;
            gb.pixels.length = gb.width * gb.rows;
            foreach (row; 0 .. gb.rows)
                memcpy(gb.pixels.ptr + row * gb.width,
                       bmp.buffer   + row * absPitch,
                       gb.width);
        }
        return gb;
    }

    ~this() { if (_face) { FT_Done_Face(_face); _face = null; } }
}

// ────────────────────────────────────────────────────────────
// FontLibrary ラッパー
// ────────────────────────────────────────────────────────────

class FontLibrary
{
    private FT_Library _lib;

    this()
    {
        auto err = FT_Init_FreeType(&_lib);
        enforce(err == 0, "FT_Init_FreeType failed");
    }

    FontFace loadFace(string path, long faceIndex = 0)
    {
        return new FontFace(_lib, path, faceIndex);
    }

    ~this() { if (_lib) { FT_Done_FreeType(_lib); _lib = null; } }
}
