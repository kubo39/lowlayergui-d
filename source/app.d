import wayland.client;
import wayland.native.util : wl_array;
import xdg_shell;
import vulkan_setup  : VulkanSetup, RectInstance, GlyphInstance;
import font.freetype : FontLibrary, FontFace, GlyphBitmap;
import font.atlas    : GlyphAtlas, GlyphInfo;
import text.shaper   : TextShaper, ShapedGlyph;

import std.algorithm : min;
import std.exception : enforce;
import std.stdio : stderr;

enum DEFAULT_WIDTH  = 800;
enum DEFAULT_HEIGHT = 600;

class App
{
    WlDisplay    display;
    WlCompositor compositor;
    WlSeat       seat;
    XdgWmBase    xdgWmBase;

    WlSurface   surface;
    XdgSurface  xdgSurface;
    XdgToplevel toplevel;

    VulkanSetup vulkan;

    FontLibrary ftLib;
    FontFace    ftFace;
    GlyphAtlas  atlas;
    TextShaper  shaper;

    bool running    = true;
    bool configured = false; // 最初の xdg_surface configure 完了後に Vulkan 初期化
    uint pendingW   = DEFAULT_WIDTH;
    uint pendingH   = DEFAULT_HEIGHT;

    this()
    {
        display = enforce(WlDisplay.connect(), "Failed to connect to Wayland display");

        auto reg = display.getRegistry();
        reg.onGlobal = (WlRegistry reg, uint name, string iface, uint ver)
        {
            if (iface == WlCompositor.iface.name)
                compositor = cast(WlCompositor) reg.bind(name, WlCompositor.iface, min(ver, 4));
            else if (iface == XdgWmBase.iface.name)
            {
                xdgWmBase = cast(XdgWmBase) reg.bind(name, XdgWmBase.iface, min(ver, 2));
                xdgWmBase.onPing = (XdgWmBase wm, uint serial) { wm.pong(serial); };
            }
            else if (iface == WlSeat.iface.name)
                seat = cast(WlSeat) reg.bind(name, WlSeat.iface, min(ver, 7));
        };
        display.roundtrip();
        reg.destroy();

        enforce(compositor, "wl_compositor not available");
        enforce(xdgWmBase,  "xdg_wm_base not available");
    }

    void createWindow()
    {
        surface    = enforce(compositor.createSurface());
        xdgSurface = enforce(xdgWmBase.getXdgSurface(surface));
        toplevel   = enforce(xdgSurface.getToplevel());

        toplevel.onConfigure = (XdgToplevel, int w, int h, wl_array*)
        {
            if (w > 0) pendingW = cast(uint) w;
            if (h > 0) pendingH = cast(uint) h;
        };

        toplevel.onClose = (XdgToplevel) { running = false; };

        xdgSurface.onConfigure = (XdgSurface surf, uint serial)
        {
            surf.ackConfigure(serial);
            if (!configured)
            {
                // 初回 configure でサイズが確定してから Vulkan を初期化
                vulkan = new VulkanSetup(display, surface, pendingW, pendingH);
                setupDemoRects();
                setupFont(pendingW, pendingH);
                configured = true;
            }
            else if (vulkan)
            {
                vulkan.resize(pendingW, pendingH);
            }
            surface.commit();
        };

        toplevel.setTitle("lowlayergui");
        surface.commit();
    }

    // 32×32 = 1024個の矩形を格子状に配置
    private void setupDemoRects()
    {
        enum cols  = 32, rows = 32;
        enum float cellW = 2.0f / cols;
        enum float cellH = 2.0f / rows;
        enum float gap   = 0.003f;

        RectInstance[] rs;
        rs.reserve(cols * rows);
        foreach (row; 0 .. rows)
        {
            foreach (col; 0 .. cols)
            {
                float x = -1.0f + col * cellW + gap;
                float y = -1.0f + row * cellH + gap;
                float w = cellW - gap * 2;
                float h = cellH - gap * 2;

                float r = cast(float) col / cols;
                float g = cast(float) row / rows;
                float b = 1.0f - (r + g) * 0.5f;

                float cr = gap * 0.5f;  // 角丸半径 (NDC単位)

                rs ~= RectInstance([x, y, w, h], [r, g, b, 1.0f], cr, [0f, 0f, 0f]);
            }
        }
        vulkan.rects = rs;
    }

    private void setupFont(uint screenW, uint screenH)
    {
        import std.file : exists;
        import std.stdio : writeln;

        // 一般的なフォントパスを順に試す (日本語対応フォントを優先)
        static immutable string[] candidates = [
            "/usr/share/fonts/truetype/noto/NotoSansCJK-Regular.ttc",
            "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
            "/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc",
            "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
            "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
            "/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf",
            "/usr/share/fonts/TTF/DejaVuSans.ttf",
        ];

        string fontPath;
        foreach (p; candidates)
            if (p.exists) { fontPath = p; break; }

        if (fontPath.length == 0)
        {
            stderr.writeln("Warning: no system font found, skipping text rendering");
            return;
        }
        writeln("Font: ", fontPath);

        ftLib  = new FontLibrary();
        ftFace = ftLib.loadFace(fontPath);
        ftFace.setPixelSize(0, 32); // 32px

        shaper = new TextShaper(ftFace);
        atlas.initialize();

        // デモ文字列をシェーピングしてグリフ ID を取得
        // 日本語を含めることでシェーピング (グリフID変換) が正しく動くか確認できる
        enum string demoText = "こんにちは World";
        auto shaped = shaper.shape(demoText);

        // シェーピング結果のグリフ ID をアトラスに登録
        foreach (ref sg; shaped)
        {
            if (sg.glyphId in atlas.glyphs) continue;
            auto bmp = ftFace.renderGlyphById(sg.glyphId);
            atlas.addGlyph(sg.glyphId, bmp);
        }

        vulkan.uploadAtlas(atlas);

        vulkan.glyphs = buildGlyphInstances(
            atlas, shaped,
            50.0f, cast(float)(screenH) * 0.6f,  // 左寄り・画面中央やや下
            [1.0f, 1.0f, 1.0f, 1.0f],            // 白
            screenW, screenH
        );
    }

    void run()
    {
        import core.sys.posix.poll : pollfd, poll, POLLIN;
        import core.time : MonoTime, dur;
        import std.stdio : writefln;

        ulong frameCount;
        auto fpsTimer = MonoTime.currTime;

        while (running)
        {
            display.flush();

            if (configured)
            {
                vulkan.renderFrame();
                frameCount++;

                auto now = MonoTime.currTime;
                auto elapsed = now - fpsTimer;
                if (elapsed >= dur!"seconds"(1))
                {
                    double fps = frameCount / (elapsed.total!"msecs" / 1000.0);
                    writefln("FPS: %.1f", fps);
                    frameCount = 0;
                    fpsTimer = now;
                }
            }

            // Wayland ソケットをノンブロッキングで読み取り
            if (display.prepareRead() == 0)
            {
                pollfd pfd = { fd: display.getFd(), events: POLLIN };
                if (poll(&pfd, 1, 0) > 0)
                    display.readEvents();
                else
                    display.cancelRead();
            }

            if (display.dispatchPending() < 0)
            {
                stderr.writeln("Wayland dispatch error");
                break;
            }
        }
    }

    void cleanup()
    {
        if (vulkan)     vulkan.cleanup();
        if (toplevel)   toplevel.destroy();
        if (xdgSurface) xdgSurface.destroy();
        if (surface)    surface.destroy();
        if (xdgWmBase)  xdgWmBase.destroy();
        if (seat)       seat.destroy();
        if (compositor) compositor.destroy();
        display.disconnect();
    }
}

/// シェーピング済みグリフ列を画面座標 (ピクセル) で配置した GlyphInstance 配列を返す。
/// startX, startY はベースラインの左端 (ピクセル座標、Y は画面上端が 0)。
GlyphInstance[] buildGlyphInstances(
    const ref GlyphAtlas atlas, const ShapedGlyph[] shaped,
    float startX, float startY,
    float[4] color,
    uint screenW, uint screenH)
{
    GlyphInstance[] result;
    float penX = startX;

    foreach (ref sg; shaped)
    {
        auto gp = sg.glyphId in atlas.glyphs;
        if (gp is null) { penX += 8; continue; } // 未登録: 幅 8px でスキップ

        // 空グリフ (スペース等) はインスタンス追加しないが advance は進める
        if (gp.width == 0 || gp.height == 0)
        {
            penX += sg.xAdvance;
            continue;
        }

        // ピクセル座標 → NDC 変換
        // NDC: x=[-1,1] 左→右、y=[-1,1] 上→下 (Vulkan 規約)
        float px = penX + gp.bearingX + sg.xOffset;
        float py = startY - gp.bearingY - sg.yOffset;  // Y: 上端 (ピクセル)
        float pw = cast(float) gp.width;
        float ph = cast(float) gp.height;

        float ndcX = 2.0f * px / screenW - 1.0f;
        float ndcY = 2.0f * py / screenH - 1.0f;
        float ndcW = 2.0f * pw / screenW;
        float ndcH = 2.0f * ph / screenH;

        GlyphInstance gi;
        gi.posRect = [ndcX, ndcY, ndcW, ndcH];
        gi.uvRect  = [gp.u0, gp.v0, gp.u1, gp.v1];
        gi.color   = color;
        result ~= gi;

        penX += sg.xAdvance;
    }
    return result;
}

void main()
{
    import std.stdio : writeln;
    version (WlDynamic) wlClientDynLib.load();

    try
    {
        auto app = new App;
        app.createWindow();
        app.run();
        app.cleanup();
    }
    catch (Exception e)
    {
        stderr.writeln("Exception: ", e.msg);
        stderr.writeln(e.info);
    }
}
