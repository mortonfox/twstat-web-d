import vibe.d;
import std.conv : text;
import std.csv : csvReader;
import std.datetime : PosixTimeZone;
import std.file : read;
import std.zip : ZipArchive;
import tweetstats : TweetStats, TweetRecord;

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

struct DashParams {
    string status;
    bool cancel;
    string message;
    string errormsg;

    bool refresh;

    string[] tznames;
    string selected_tz;
}

void render_dash(Session sess, DashParams dashparams, HTTPServerResponse res) {
    dashparams.tznames = PosixTimeZone.getInstalledTZNames();
    dashparams.selected_tz = sess.get("tz", "US/Eastern");

    dashparams.status = sess.get("status", "ready");
    dashparams.message = sess.get("message", "");

    dashparams.refresh = dashparams.status == "waiting" || dashparams.status == "busy";

    dashparams.cancel = sess.get("cancel", false) == true;

    if (dashparams.status == "error") {
        // Background task completed with error. Show error message and reset status.
        dashparams.errormsg = sess.get("message", "");
        sess.set("status", "ready");
    }

    render!("dashboard.dt", dashparams)(res);
}

void dashboard(HTTPServerRequest req, HTTPServerResponse res) {
    if (!req.session) req.session = res.startSession();

    DashParams dashparams;
    render_dash(req.session, dashparams, res);
}

bool process_zipfile(Session sess, Path infile) {
    // CSV file for tweets within the ZIP file.
    const tweets_file = "tweets.csv";

    auto tweetstats = new TweetStats;

    try {
        auto zip = new ZipArchive(readFile(infile));
        auto zipdir = zip.directory;

        if (tweets_file !in zipdir)
            throw new Exception(text(tweets_file, " was not found in ZIP file ", infile));

        auto text = cast(char[]) zip.expand(zipdir[tweets_file]);
        auto records = csvReader!TweetRecord(text, ["timestamp", "source", "text"]);

        foreach (record; records)
            tweetstats.process_record(record);

        sess.set("status", "ready");
    }
    catch (Exception e) {
        sess.set("status", "error");
        sess.set("message", text("Error processing ZIP file: ", e.msg));
    }

    return true;
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

    req.session.set("status", "waiting");

    async(&process_zipfile, req.session, req.files["tweetdata"].tempPath);

    res.redirect("/");
}

void errorHandler(HTTPServerRequest req, HTTPServerResponse res, HTTPServerErrorInfo error) {
    if (!req.session) req.session = res.startSession();

    DashParams dashparams;
    dashparams.errormsg = text("Error ", error.code, ": ", error.message);

    render_dash(req.session, dashparams, res);
}
