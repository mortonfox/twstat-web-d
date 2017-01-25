import vibe.d;
import std.conv : text;
import std.datetime : PosixTimeZone;

shared static this()
{
    auto router = new URLRouter;
    router.get("/", &dashboard);
    router.get("/upload", &dashboard);
    router.post("/upload", &upload);
    router.get("*", serveStaticFiles("public/"));

    auto settings = new HTTPServerSettings;
    settings.sessionStore = new MemorySessionStore;
    settings.port = 8080;
    settings.bindAddresses = ["::1", "127.0.0.1"];
    settings.maxRequestSize = 50_000_000;
    settings.errorPageHandler = toDelegate(&errorHandler);
    listenHTTP(settings, router);

    logInfo("Please open http://127.0.0.1:8080/ in your browser.");
}

void dashboard(HTTPServerRequest req, HTTPServerResponse res) {
    auto tznames = PosixTimeZone.getInstalledTZNames();

    if (!req.session) req.session = res.startSession();
    auto selected_tz = req.session.get("tz", "US/Eastern");
    auto errormsg = "";

    render!("dashboard.dt", tznames, selected_tz, errormsg)(res);
}

void upload(HTTPServerRequest req, HTTPServerResponse res) {
    if (!req.session) req.session = res.startSession();

    auto new_tz = req.form.get("timezone");

    try {
        // Error checking for user input. Don't change the session tz if
        // timezone string is invalid.
        PosixTimeZone.getTimeZone(new_tz);

        req.session.set("tz", new_tz);
    }
    catch (Exception e) {
    }

    res.redirect("/");
}

void errorHandler(HTTPServerRequest req, HTTPServerResponse res, HTTPServerErrorInfo error) {
    if (!req.session) req.session = res.startSession();

    auto errormsg = text("Error ", error.code, ": ", error.message);
    auto tznames = PosixTimeZone.getInstalledTZNames();
    auto selected_tz = req.session.get("tz", "US/Eastern");

    render!("dashboard.dt", tznames, selected_tz, errormsg)(res);
}
