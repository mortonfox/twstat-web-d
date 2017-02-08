// TaskStates
// Global per-session task info and state. Shared and synchronized across threads.

private shared struct TaskState {
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
