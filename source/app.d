import vibe.d;
import std.conv : text;
import std.csv : csvReader;
import std.datetime : PosixTimeZone;
import std.file : read, tempDir;
import std.zip : ZipArchive;
import tweetstats : TweetStats, TweetRecord;
import taskstates : task_states;

shared static this()
{
    auto router = new URLRouter;
    router.get("/", &dashboard);
    router.get("/report", &report);
    router.post("/upload", &upload);
    router.post("/cancel", &cancel);
    router.get("/about", &about);
    router.get("*", serveStaticFiles("public/"));

    ushort port = 8080;
    readOption("port|p", &port, "Port number for web server");

    auto settings = new HTTPServerSettings;
    settings.sessionStore = new MemorySessionStore;
    settings.port = port;
    settings.bindAddresses = ["::1", "127.0.0.1"];
    settings.maxRequestSize = 50_000_000;
    settings.errorPageHandler = toDelegate(&errorHandler);
    listenHTTP(settings, router);

    // setLogLevel(LogLevel.debug_);

    logInfo(text("Please open http://127.0.0.1:", port, "/ in your browser."));
}

private struct DashParams {
    string status;
    bool cancel;
    string message;
    string errormsg;
    string last_generated;

    bool refresh;

    string[] tznames;
    string selected_tz;
}

private const default_timezone = "US/Eastern";

private void render_dash(Session sess, DashParams dashparams, HTTPServerResponse res) {
    dashparams.tznames = PosixTimeZone.getInstalledTZNames();
    dashparams.selected_tz = sess.get("tz", default_timezone);

    auto sessid = sess.id;

    dashparams.status = task_states.get_status(sessid);
    dashparams.message = task_states.get_message(sessid);

    logDebug("Dashboard status: %s, message: %s", dashparams.status, dashparams.message);

    dashparams.refresh = dashparams.status == "waiting" || dashparams.status == "busy";

    dashparams.cancel = task_states.get_cancel(sessid);

    auto report_vars = task_states.get_report_vars(sessid);
    logDebug("Report Vars:");
    foreach (pair; report_vars.byKeyValue)
        logDebug("  %s: %s", pair.key, pair.value);

    if (report_vars)
        dashparams.last_generated = report_vars["last_generated"];

    if (dashparams.status == "error") {
        // Background task completed with error. Show error message and reset status.
        dashparams.errormsg = dashparams.message;
        task_states.set_status(sessid, "ready");
    }

    render!("dashboard.dt", dashparams)(res);
} // render_dash

private void dashboard(HTTPServerRequest req, HTTPServerResponse res) {
    if (!req.session) req.session = res.startSession();

    DashParams dashparams;
    render_dash(req.session, dashparams, res);
}

private bool process_zipfile(string sessid, Path infile, string tz) {

    void busy_message(string message) {
        task_states.set_status(sessid, "busy", message);
        logDebug("Busy message: %s", message);
    }

    // CSV file for tweets within the ZIP file.
    const tweets_file = "tweets.csv";

    // Reset cancel flag, just in case.
    task_states.set_cancel(sessid, false);

    scope(exit) {
        // Make sure cancel flag gets reset when the worker task is done, just in case.
        task_states.set_cancel(sessid, false);

        if (task_states.get_status(sessid) == "busy") {
            // Reset busy state when done.
            // Don't change the state if state is "error" because we want the
            // error message to show in the dashboard.
            task_states.set_status(sessid, "ready");
        }

        // Ensure cleanup.
        removeFile(infile);
    }

    auto tweetstats = new TweetStats(tz);

    try {
        logInfo("zipfile processor starting...");

        auto zip = new ZipArchive(readFile(infile));
        auto zipdir = zip.directory;

        if (tweets_file !in zipdir)
            throw new Exception(text(tweets_file, " was not found in ZIP file"));

        logInfo("Extracting %s...", tweets_file);

        auto text = cast(char[]) zip.expand(zipdir[tweets_file]);
        auto records = csvReader!TweetRecord(text, ["timestamp", "source", "text"]);

        logInfo("Processing CSV tweet records...");

        foreach (record; records) {
            tweetstats.process_record(record, &busy_message);

            // Detect user cancel.
            if (task_states.get_cancel(sessid)) {
                logInfo("Task canceled!");
                return false;
            }
        }

        auto report_vars = tweetstats.report_vars;
        task_states.set_report_vars(sessid, report_vars);
    }
    catch (Exception e) {
        task_states.set_status(sessid, "error", text("Error processing ZIP file: ", e.msg));
    }

    return true;
} // process_zipfile

private void upload(HTTPServerRequest req, HTTPServerResponse res) {
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

    auto sessid = req.session.id;

    task_states.set_status(sessid, "waiting");

    // Make a copy of the tempfile in case it gets deleted before the worker
    // task has had a chance to read it.
    auto upload_file = req.files["tweetdata"];
    auto new_fname = Path(tempDir()) ~ ("dup_" ~ upload_file.tempPath.head.toString);

    try
        moveFile(upload_file.tempPath, new_fname);
    catch (Exception e)
        copyFile(upload_file.tempPath, new_fname);

    logDebug("copied upload file: %s", new_fname);

    runWorkerTask(&process_zipfile, sessid, new_fname, req.session.get("tz", default_timezone));

    res.redirect("/");
} // upload

private void cancel(HTTPServerRequest req, HTTPServerResponse res) {
    if (!req.session) req.session = res.startSession();
    auto sessid = req.session.id;
    auto status = task_states.get_status(sessid);

    // Can only cancel if task is running.
    if (status == "waiting" || status == "busy")
        task_states.set_cancel(sessid, true);

    res.redirect("/");
} // cancel

private void report(HTTPServerRequest req, HTTPServerResponse res) {
    if (!req.session) req.session = res.startSession();
    auto sessid = req.session.id;
    auto report = task_states.get_report_vars(sessid);
    if (report)
        render!("report.dt", report)(res);
    else
        res.redirect("/");
} // report

private void about(HTTPServerRequest req, HTTPServerResponse res) {
    DashParams dashparams;
    render!("about.dt", dashparams)(res);
} // report

private void errorHandler(HTTPServerRequest req, HTTPServerResponse res, HTTPServerErrorInfo error) {
    if (!req.session) req.session = res.startSession();

    DashParams dashparams;
    dashparams.errormsg = text("Error ", error.code, ": ", error.message);

    render_dash(req.session, dashparams, res);
} // errorHandler
