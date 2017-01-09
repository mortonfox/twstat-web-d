import vibe.d;
import std.datetime : PosixTimeZone;

shared static this()
{
    auto router = new URLRouter;
    router.get("/", &dashboard);
    router.get("*", serveStaticFiles("public/"));

    auto settings = new HTTPServerSettings;
    settings.port = 8080;
    settings.bindAddresses = ["::1", "127.0.0.1"];
    listenHTTP(settings, router);

    logInfo("Please open http://127.0.0.1:8080/ in your browser.");
}

void dashboard(HTTPServerRequest req, HTTPServerResponse res) {
    auto tznames = PosixTimeZone.getInstalledTZNames();
    auto selected_tz = "US/Eastern";
    render!("dashboard.dt", tznames, selected_tz)(res);
}
