module text.harfbuzz;

// ────────────────────────────────────────────────────────────
// 不透明型
// ────────────────────────────────────────────────────────────

alias hb_buffer_t = void;
alias hb_font_t   = void;

// ────────────────────────────────────────────────────────────
// 定数
// ────────────────────────────────────────────────────────────

alias hb_direction_t = int;
enum : hb_direction_t
{
    HB_DIRECTION_INVALID = 0,
    HB_DIRECTION_LTR     = 4,
    HB_DIRECTION_RTL     = 5,
    HB_DIRECTION_TTB     = 6,
    HB_DIRECTION_BTT     = 7,
}

// ────────────────────────────────────────────────────────────
// 構造体
// ────────────────────────────────────────────────────────────

// hb_glyph_info_t: 5 × uint32 = 20 bytes
struct hb_glyph_info_t
{
    uint codepoint;  // シェーピング後はグリフ ID
    uint mask;       // ABI 互換のため保持
    uint cluster;    // 入力テキスト上の位置
    uint _var1;      // private
    uint _var2;      // private
}
static assert(hb_glyph_info_t.sizeof == 20);

// hb_glyph_position_t: 4 × int32 + 1 × uint32 = 20 bytes
struct hb_glyph_position_t
{
    int  x_advance;  // 26.6 固定小数点 (1/64 ピクセル)
    int  y_advance;
    int  x_offset;
    int  y_offset;
    uint _var;       // private
}
static assert(hb_glyph_position_t.sizeof == 20);

struct hb_feature_t
{
    uint tag;
    uint value;
    uint start;
    uint end;
}

// ────────────────────────────────────────────────────────────
// extern(C) 宣言 (HarfBuzz シンボルは非バージョン付き)
// ────────────────────────────────────────────────────────────

extern(C) @nogc nothrow
{
    hb_buffer_t* hb_buffer_create();
    void         hb_buffer_destroy(hb_buffer_t*);
    void         hb_buffer_reset(hb_buffer_t*);
    void         hb_buffer_add_utf8(hb_buffer_t*, const(char)* text,
                                    int text_length,
                                    uint item_offset, int item_length);
    void         hb_buffer_set_direction(hb_buffer_t*, hb_direction_t);
    void         hb_buffer_guess_segment_properties(hb_buffer_t*);
    void         hb_shape(hb_font_t*, hb_buffer_t*,
                          const hb_feature_t*, uint num_features);
    hb_glyph_info_t*     hb_buffer_get_glyph_infos(hb_buffer_t*, uint* length);
    hb_glyph_position_t* hb_buffer_get_glyph_positions(hb_buffer_t*, uint* length);

    // FreeType バックエンド (FT_Face を void* として渡す)
    hb_font_t* hb_ft_font_create_referenced(void* ft_face);
    void       hb_font_destroy(hb_font_t*);
}
