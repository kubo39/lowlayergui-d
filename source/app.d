import wayland.client;
import wayland.native.util : wl_array;
import xdg_shell;

import std.algorithm : min;
import std.exception : enforce;
import std.stdio : stderr;

class App
{
    WlDisplay    display;
    WlCompositor compositor;
    WlSeat       seat;
    XdgWmBase    xdgWmBase;

    WlSurface    surface;
    XdgSurface   xdgSurface;
    XdgToplevel  toplevel;

    bool running = true;

    this()
    {
        display = enforce(WlDisplay.connect(), "Failed to connect to Wayland display");

        auto reg = display.getRegistry();
        reg.onGlobal = (WlRegistry reg, uint name, string iface, uint ver)
        {
            if (iface == WlCompositor.iface.name)
            {
                compositor = cast(WlCompositor) reg.bind(name, WlCompositor.iface, min(ver, 4));
            }
            else if (iface == XdgWmBase.iface.name)
            {
                xdgWmBase = cast(XdgWmBase) reg.bind(name, XdgWmBase.iface, min(ver, 2));
                xdgWmBase.onPing = (XdgWmBase wm, uint serial) { wm.pong(serial); };
            }
            else if (iface == WlSeat.iface.name)
            {
                seat = cast(WlSeat) reg.bind(name, WlSeat.iface, min(ver, 7));
            }
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

        xdgSurface.onConfigure = (XdgSurface surf, uint serial)
        {
            surf.ackConfigure(serial);
            surface.commit();
        };

        toplevel.onConfigure = (XdgToplevel, int, int, wl_array*) {};
        toplevel.onClose     = (XdgToplevel) { running = false; };

        toplevel.setTitle("lowlayergui");
        surface.commit();
    }

    void run()
    {
        while (running)
        {
            if (display.dispatch() < 0)
            {
                stderr.writeln("Wayland dispatch error");
                break;
            }
        }
    }

    void cleanup()
    {
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
    version (WlDynamic) wlClientDynLib.load();

    auto app = new App;
    app.createWindow();
    app.run();
    app.cleanup();
}
