module text.shaper;

import text.harfbuzz;
import font.freetype : FontFace;

// ────────────────────────────────────────────────────────────
// シェーピング結果の 1 グリフ
// ────────────────────────────────────────────────────────────

struct ShapedGlyph
{
    uint glyphId;   // FreeType / HarfBuzz グリフ ID
    int  xAdvance;  // ピクセル単位 (26.6 変換済み)
    int  xOffset;   // ピクセル単位
    int  yOffset;   // ピクセル単位
}

// ────────────────────────────────────────────────────────────
// TextShaper: HarfBuzz でシェーピング (LTR のみ)
// ────────────────────────────────────────────────────────────

class TextShaper
{
    private hb_font_t*   _hbFont;
    private hb_buffer_t* _buf;

    this(FontFace face)
    {
        _hbFont = hb_ft_font_create_referenced(face.native);
        _buf    = hb_buffer_create();
    }

    /// UTF-8 文字列をシェーピングして ShapedGlyph[] を返す。
    ShapedGlyph[] shape(string text)
    {
        hb_buffer_reset(_buf);
        hb_buffer_add_utf8(_buf, text.ptr, cast(int) text.length, 0, -1);
        hb_buffer_set_direction(_buf, HB_DIRECTION_LTR);
        hb_buffer_guess_segment_properties(_buf);
        hb_shape(_hbFont, _buf, null, 0);

        uint glyphCount;
        hb_glyph_info_t*     infos = hb_buffer_get_glyph_infos(_buf, &glyphCount);
        hb_glyph_position_t* poses = hb_buffer_get_glyph_positions(_buf, &glyphCount);

        ShapedGlyph[] result;
        result.length = glyphCount;
        foreach (i; 0 .. glyphCount)
        {
            result[i].glyphId  = infos[i].codepoint;       // シェーピング後はグリフ ID
            result[i].xAdvance = poses[i].x_advance >> 6;  // 26.6 → ピクセル
            result[i].xOffset  = poses[i].x_offset  >> 6;
            result[i].yOffset  = poses[i].y_offset  >> 6;
        }
        return result;
    }

    ~this()
    {
        if (_buf)    { hb_buffer_destroy(_buf);  _buf    = null; }
        if (_hbFont) { hb_font_destroy(_hbFont); _hbFont = null; }
    }
}
