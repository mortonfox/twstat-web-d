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

    setLogLevel(LogLevel.debug_);

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

    auto sessid = sess.id;

    dashparams.status = task_states.get_status(sessid);
    dashparams.message = task_states.get_message(sessid);
    /* dashparams.status = sess.get("status", "ready"); */
    /* dashparams.message = sess.get("message", ""); */

    logDebug("Dashboard status: %s, message: %s", dashparams.status, dashparams.message);

    dashparams.refresh = dashparams.status == "waiting" || dashparams.status == "busy";

    dashparams.cancel = sess.get("cancel", false) == true;

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

struct TaskState {
    string status;
    string message;

    this(string status, string message = "") {
        this.status = status;
        this.message = message;
    }
}

synchronized class TaskStates {
    private TaskState[string] states;

    private void ensure_state(string sessid) {
        if (sessid !in states)
            states[sessid] = TaskState("ready");
    }

    string get_status(string sessid) {
        ensure_state(sessid);
        return states[sessid].status;
    }

    string get_message(string sessid) {
        ensure_state(sessid);
        return states[sessid].message;
    }

    void set_status(string sessid, string status) {
        ensure_state(sessid);
        states[sessid].status = status;
    }

    void set_message(string sessid, string message) {
        ensure_state(sessid);
        states[sessid].message = message;
    }
}

shared task_states = new TaskStates();

bool process_zipfile(string sessid, Path infile) {

    void busy_message(string message) {
        task_states.set_status(sessid, "busy");
        task_states.set_message(sessid, message);
        /* sess.set("status", "busy"); */
        /* sess.set("message", message); */

        logDebug("Busy message: %s", message);
    }

    // CSV file for tweets within the ZIP file.
    const tweets_file = "tweets.csv";

    auto tweetstats = new TweetStats;

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

        foreach (record; records)
            tweetstats.process_record(record, &busy_message);

        task_states.set_status(sessid, "ready");
        /* sess.set("status", "ready"); */
    }
    catch (Exception e) {
        task_states.set_status(sessid, "error");
        task_states.set_message(sessid, text("Error processing ZIP file: ", e.msg));
        /* sess.set("status", "error"); */
        /* sess.set("message", text("Error processing ZIP file: ", e.msg)); */
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

    task_states.set_status(req.session.id, "waiting");
    runWorkerTask(&process_zipfile, req.session.id, req.files["tweetdata"].tempPath);

    res.redirect("/");
} // upload

void errorHandler(HTTPServerRequest req, HTTPServerResponse res, HTTPServerErrorInfo error) {
    if (!req.session) req.session = res.startSession();

    DashParams dashparams;
    dashparams.errormsg = text("Error ", error.code, ": ", error.message);

    render_dash(req.session, dashparams, res);
}
