import wayland.client;
import wayland.native.util : wl_array;
import xdg_shell;
import vulkan_setup;

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

    void run()
    {
        import core.sys.posix.poll : pollfd, poll, POLLIN;

        while (running)
        {
            display.flush();

            if (configured)
                vulkan.renderFrame();

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
