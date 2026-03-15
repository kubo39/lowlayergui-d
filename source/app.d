import wayland.client;
import wayland.native.util : wl_array;
import xdg_shell;
import vulkan_setup : VulkanSetup, RectInstance;

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
