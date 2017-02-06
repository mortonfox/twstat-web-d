import vibe.d;
import std.conv : text;
import std.csv : csvReader;
import std.datetime : PosixTimeZone;
import std.file : read, tempDir;
import std.zip : ZipArchive;
import tweetstats : TweetStats, TweetRecord;

shared static this()
{
    auto router = new URLRouter;
    router.get("/", &dashboard);
    router.get("/upload", &dashboard);
    router.get("/report", &report);
    router.post("/upload", &upload);
    router.post("/cancel", &cancel);
    router.get("/about", &about);
    router.get("*", serveStaticFiles("public/"));

    auto settings = new HTTPServerSettings;
    settings.sessionStore = new MemorySessionStore;
    settings.port = 8080;
    settings.bindAddresses = ["::1", "127.0.0.1"];
    settings.maxRequestSize = 50_000_000;
    settings.errorPageHandler = toDelegate(&errorHandler);
    listenHTTP(settings, router);

    // setLogLevel(LogLevel.debug_);

    logInfo("Please open http://127.0.0.1:8080/ in your browser.");
}

struct DashParams {
    string status;
    bool cancel;
    string message;
    string errormsg;
    string last_generated;

    bool refresh;

    string[] tznames;
    string selected_tz;
}

const default_timezone = "US/Eastern";

void render_dash(Session sess, DashParams dashparams, HTTPServerResponse res) {
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

void dashboard(HTTPServerRequest req, HTTPServerResponse res) {
    if (!req.session) req.session = res.startSession();

    DashParams dashparams;
    render_dash(req.session, dashparams, res);
}

shared struct TaskState {
    string status;
    string message;
    bool cancel;
    string[string] report_vars;

    this(string status, string message = "") {
        this.status = status;
        this.message = message;
        this.cancel = false;
    }
}

synchronized class TaskStates {
    // Task states indexed by session ID.
    private TaskState[string] states;

    // Retrieve TaskState corresponding to session ID. Initialize a TaskState
    // and return it if it doesn't exist.
    private auto get_state(string sessid) {
        if (sessid !in states)
            states[sessid] = shared(TaskState)("ready");
        return &states[sessid];
    }

    string get_status(string sessid) {
        return get_state(sessid).status;
    }

    string get_message(string sessid) {
        return get_state(sessid).message;
    }

    void set_status(string sessid, string status, string message = "") {
        auto task_state = get_state(sessid);
        task_state.status = status;
        task_state.message = message;
    }

    bool get_cancel(string sessid) {
        return get_state(sessid).cancel;
    }

    void set_cancel(string sessid, bool cancel) {
        get_state(sessid).cancel = cancel;
    }

    auto get_report_vars(string sessid) {
        return get_state(sessid).report_vars;
    }

    void set_report_vars(string sessid, string[string] report) {
        auto task_state = get_state(sessid);
        task_state.report_vars.clear;

        // Copy it string by string because the incoming report is not a
        // shared variable.
        foreach (pair; report.byKeyValue)
            task_state.report_vars[pair.key] = pair.value;
    }
} // TaskStates

shared task_states = new TaskStates();

bool process_zipfile(string sessid, Path infile, string tz) {

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

        // Reset busy state when done.
        task_states.set_status(sessid, "ready");

        // Ensure cleanup.
        removeFile(infile);
    }

    auto tweetstats = new TweetStats(tz);

    try {
        logInfo("zipfile processor starting...");

        auto zip = new ZipArchive(readFile(infile));
        auto zipdir = zip.directory;

        if (tweets_file !in zipdir)
            throw new Exception(text(tweets_file, " was not found in ZIP file ", infile));

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

void cancel(HTTPServerRequest req, HTTPServerResponse res) {
    if (!req.session) req.session = res.startSession();

    auto sessid = req.session.id;

    auto status = task_states.get_status(sessid);

    // Can only cancel if task is running.
    if (status == "waiting" || status == "busy")
        task_states.set_cancel(sessid, true);

    res.redirect("/");
} // cancel

void report(HTTPServerRequest req, HTTPServerResponse res) {
    if (!req.session) req.session = res.startSession();
    auto sessid = req.session.id;
    auto report = task_states.get_report_vars(sessid);
    render!("report.dt", report)(res);
} // report

void about(HTTPServerRequest req, HTTPServerResponse res) {
    DashParams dashparams;
    render!("about.dt", dashparams)(res);
} // report

void errorHandler(HTTPServerRequest req, HTTPServerResponse res, HTTPServerErrorInfo error) {
    if (!req.session) req.session = res.startSession();

    DashParams dashparams;
    dashparams.errormsg = text("Error ", error.code, ": ", error.message);

    render_dash(req.session, dashparams, res);
}
