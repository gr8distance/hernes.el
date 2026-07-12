;;; hernes.el --- Local-LLM coding agent harness on top of gptel -*- lexical-binding: t; -*-

;; Author: gr8distance
;; Version: 0.1.0-P-A
;; Package-Requires: ((emacs "29.1") (gptel "0.9"))
;; Keywords: tools, convenience, llm
;; URL: https://github.com/gr8distance/hernes.el

;;; Commentary:

;; hernes is an autonomous coding-agent harness that runs inside Emacs and
;; drives an OpenAI-compatible local LLM (LM Studio, llama-server, Ollama, ...)
;; through gptel.
;;
;; Design split (see DESIGN.md):
;;   gptel  = transport + tool-schema serialization + backend abstraction.
;;   hernes = the harness: it OWNS the conversation state and the turn loop,
;;            enforces the safety net, runs tools in parallel and stops on
;;            well-defined conditions, returning control to the human.
;;
;; This file implements phase P-A: `hernes-loop', the fs/exec/git tools, the
;; `chat'/`auto' modes, the control buffer, and the always-on safety net
;; (deny-list + project-root guard + git checkpoint branch).  See DESIGN.md
;; sections 2, 3, 5 and 8.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'project)
(require 'gptel)
(require 'gptel-openai)                 ;for `gptel-make-openai' (normally autoloaded)

;; gptel internals we build on.  Declared to keep the byte-compiler quiet even
;; if load order changes; they are provided by `gptel'.
(defvar gptel-request--handlers)
(defvar gptel-backend)
(defvar gptel-model)
(defvar gptel-use-tools)
(defvar gptel-tools)
(defvar gptel-confirm-tool-calls)

;;;; Customization

(defgroup hernes nil
  "Local-LLM coding agent harness."
  :group 'tools
  :prefix "hernes-")

(defcustom hernes-backend '(:endpoint "http://localhost:1234" :model "local-model")
  "Default LLM backend for hernes sessions.
A plist with :endpoint (base URL of an OpenAI-compatible server) and
:model (the model name to request).  Each session may override this."
  :type '(plist :key-type symbol :value-type string)
  :group 'hernes)

(defcustom hernes-max-turns 30
  "Maximum number of model turns before hernes stops and returns to the human.
A \"turn\" is one round-trip to the model, which may contain several tool
calls."
  :type 'integer
  :group 'hernes)

(defcustom hernes-command-timeout 60
  "Timeout in seconds for `run_command', `grep' and `git_diff' subprocesses."
  :type 'integer
  :group 'hernes)

(defcustom hernes-shell-file-name "/bin/sh"
  "Shell used to run `run_command'.
Deliberately NOT `shell-file-name': the model emits POSIX sh commands
\(e.g. `export FOO=bar'), which a login shell such as fish would mis-parse."
  :type 'string
  :group 'hernes)

(defcustom hernes-command-deny-list
  '("\\brm\\s-+\\(-[[:alnum:]]*[rf][[:alnum:]]*\\s-+\\)*-[[:alnum:]]*[rf]"
    "\\brm\\s-+-[[:alnum:]]*r[[:alnum:]]*f"
    "\\brm\\s-+-[[:alnum:]]*f[[:alnum:]]*r"
    "\\bsudo\\b"
    "\\bgit\\s-+push\\b"
    "--force\\b"
    "\\bmkfs\\b"
    "\\bshutdown\\b"
    "\\breboot\\b"
    ":(){"                              ;fork bomb
    ">\\s-*/dev/sd")
  "List of regexps for shell commands that must never be executed.
Any `run_command' request matching one of these is refused before it runs,
in every mode, and the refusal is reported back to the model."
  :type '(repeat regexp)
  :group 'hernes)

(defcustom hernes-grep-exclude-dirs '(".git" "node_modules" "tmp" "log" "public")
  "Directory names excluded from `grep' searches, mirroring consult-ripgrep."
  :type '(repeat string)
  :group 'hernes)

(defcustom hernes-max-tool-output 8000
  "Maximum number of characters of a tool's output fed back to the model.
Longer output is truncated with a marker.  Keeps context bounded."
  :type 'integer
  :group 'hernes)

(defcustom hernes-system-prompt
  "You are hernes, an autonomous coding agent operating inside the user's Emacs \
and working on a real software project.

You accomplish tasks by calling the provided tools. Work step by step: inspect \
the code with read_file, list_files and grep before changing anything; make \
focused edits with write_file; and verify your work by running the project's \
tests or build with run_command.

Guidelines:
- Prefer small, verifiable steps over large speculative changes.
- After a meaningful, self-contained unit of progress, call git_checkpoint with \
a concise message so the human can review and, if needed, roll back.
- File paths are relative to the project root. You cannot read or write outside it.
- Some commands are blocked for safety; if one is refused, find another way.
- When the task is complete, or if you are blocked, uncertain, or need a decision \
from the human, STOP and reply with a plain text message (no tool call) \
explaining the situation or asking your question. Do not guess when a wrong \
guess would be costly.
- Keep your natural-language replies brief and concrete."
  "System prompt sent to the model at the start of every hernes session."
  :type 'string
  :group 'hernes)

(defcustom hernes-plan-prompt
  "You are in PLAN mode. Investigate the code with the read-only tools \
\(read_file, list_files, grep, git_diff\), then present a concrete, numbered \
implementation plan in markdown. Do NOT implement anything, and do NOT claim to \
have made any changes -- you have no write access in this mode. End your reply \
by asking the human to review the plan before switching to auto mode to carry \
it out."
  "Extra system-prompt guidance appended in `plan' mode.
Appended to `hernes-system-prompt' (or the session's own system prompt) only
while the session mode is `plan', and recomputed on every send so that toggling
the mode changes the model's instructions on the very next turn."
  :type 'string
  :group 'hernes)

;;;; Session state

(cl-defstruct (hernes-session (:constructor hernes--make-session)
                              (:copier nil))
  "State for a single hernes run.  All mutable state lives here so that
`hernes-loop' is re-entrant and safe to nest (subagents)."
  id root mode task
  (messages nil)                        ;conversation, forward order (see below)
  (turn 0)
  max-turns
  tools                                 ;candidate hernes tool plists (UNFILTERED;
                                        ;the mode filter is applied per send)
  system backend
  buffer                                ;control buffer
  on-turn on-done
  on-stream on-thinking                 ;live streaming / reasoning display (UI only)
  (pending-text "")                     ;assistant text captured this turn
  (error-streak nil)                    ;(TOOL-NAME . COUNT) of consecutive errors
  (processes nil)                       ;live subprocesses, for abort
  (git-ready nil)                       ;t once the auto-mode safety branch exists
  (aborted nil)
  (finished nil))

;; A conversation message (an element of `hernes-session-messages') is one of:
;;   (prompt   . STRING)                    ; a user message
;;   (response . STRING)                    ; an assistant text message
;;   (tool . (:name NAME :args ARGS :result RESULT))  ; a tool call + its result
;; This is exactly gptel's "advanced" prompt-list format for OpenAI-compatible
;; backends (see `gptel--parse-list'), so the whole list can be handed to
;; `gptel-request' verbatim, one request per turn -- hernes stays the owner of
;; the conversation and of turn control.

;;;; Safety net (pure predicates -- unit tested)

(defun hernes--path-safe-p (root path)
  "Return the absolute path of PATH if it is inside ROOT, else nil.
PATH may be relative (resolved against ROOT) or absolute; `..' escapes and
absolute paths pointing outside ROOT are rejected."
  (and (stringp path)
       (let ((abs (expand-file-name path (file-name-as-directory root))))
         (and (file-in-directory-p abs root) abs))))

(defun hernes--command-denied-p (command)
  "Return the first `hernes-command-deny-list' regexp that COMMAND matches, or nil."
  (and (stringp command)
       (cl-find-if (lambda (re) (string-match-p re command))
                   hernes-command-deny-list)))

(defun hernes--tools-for-mode (mode tools)
  "Return the subset of TOOLS exposed to the model in MODE.
In `chat' and `plan' mode, tools with a non-nil :side-effect are removed (their
schema is never sent), so those modes are strictly read-only.  In `auto' (and,
later, `confirm') mode all tools are exposed; gating side-effect tools behind
confirmation is a separate concern, so this filter already has the shape confirm
will need."
  (if (memq mode '(chat plan))
      (cl-remove-if (lambda (tool) (plist-get tool :side-effect)) tools)
    tools))

(defun hernes--update-error-streak (streak results)
  "Return the updated error streak after a batch of tool RESULTS.
STREAK is nil or a cons (TOOL-NAME . COUNT).  RESULTS is a list of tool-result
plists (:name :error ...).  If any tool in the batch errored, the streak tracks
the first errored tool: the count increments when it is the same tool as
before, otherwise it resets to 1.  A batch with no errors resets the streak to
nil.  Callers stop the session when the count reaches 3."
  (let ((errored (cl-find-if (lambda (r) (plist-get r :error)) results)))
    (if (not errored)
        nil
      (let ((name (plist-get errored :name)))
        (if (and streak (equal (car streak) name))
            (cons name (1+ (cdr streak)))
          (cons name 1))))))

;;;; Tool registry

(defun hernes--all-tools ()
  "Return the full list of hernes tool definitions.
Each tool is a plist: :name :description :args (gptel arg specs) :side-effect
and :fn, an async executor called as (funcall FN SESSION ARGS DONE) where ARGS
is the model-supplied argument plist and DONE is called once with
\(RESULT-STRING &optional ERROR-P)."
  (list
   (list :name "read_file"
         :description
         "Read and return the full text contents of a file. The path is \
relative to the project root. Use this to inspect source before editing it."
         :args (list '(:name "path" :type string
                       :description "File path, relative to the project root."))
         :side-effect nil
         :fn #'hernes--tool-read-file)
   (list :name "write_file"
         :description
         "Create or overwrite a file with the given content. The path is \
relative to the project root; parent directories are created as needed. This \
replaces the entire file, so include the complete intended contents."
         :args (list '(:name "path" :type string
                       :description "File path, relative to the project root.")
                     '(:name "content" :type string
                       :description "The complete new contents of the file."))
         :side-effect t
         :fn #'hernes--tool-write-file)
   (list :name "list_files"
         :description
         "List project files tracked under the project root. Optionally filter \
by a glob pattern such as \"*.el\" or \"src/*.js\" (\"*\" matches any \
characters). Returns newline-separated paths relative to the project root."
         :args (list '(:name "glob" :type string :optional t
                       :description "Optional glob to filter file paths."))
         :side-effect nil
         :fn #'hernes--tool-list-files)
   (list :name "grep"
         :description
         "Search the project's text files for a regular expression using \
ripgrep. Returns matching lines prefixed with file path and line number. \
Common noise directories (.git, node_modules, tmp, log, public) are excluded. \
Optionally restrict the search to files matching a glob."
         :args (list '(:name "pattern" :type string
                       :description "The regular expression to search for.")
                     '(:name "glob" :type string :optional t
                       :description "Optional ripgrep glob to restrict files, e.g. \"*.el\"."))
         :side-effect nil
         :fn #'hernes--tool-grep)
   (list :name "run_command"
         :description
         "Run a shell command from the project root and return its combined \
standard output and error. Use this to run tests, builds, linters or other \
project tooling. The command runs with a timeout and cannot be interactive. \
Destructive commands are refused for safety."
         :args (list '(:name "command" :type string
                       :description "The shell command line to execute."))
         :side-effect t
         :fn #'hernes--tool-run-command)
   (list :name "git_checkpoint"
         :description
         "Stage all current changes and create a git commit on the session \
branch. Use this after completing a meaningful unit of work so the human can \
review the diff. Provide a short, descriptive commit message."
         :args (list '(:name "message" :type string
                       :description "The commit message describing this checkpoint."))
         :side-effect t
         :fn #'hernes--tool-git-checkpoint)
   (list :name "git_diff"
         :description
         "Return the current unstaged git diff for the project, so you can \
review what you have changed since the last checkpoint."
         :args nil
         :side-effect nil
         :fn #'hernes--tool-git-diff)))

;;;; Tool executors (all async: each calls DONE exactly once)

(defun hernes--truncate-output (text)
  "Truncate TEXT to `hernes-max-tool-output' characters with a marker."
  (if (<= (length text) hernes-max-tool-output)
      text
    (concat (substring text 0 hernes-max-tool-output)
            (format "\n[hernes] ...output truncated at %d chars]"
                    hernes-max-tool-output))))

(defun hernes--glob-to-regexp (glob)
  "Translate a simple GLOB (\"*\", \"?\") into an anchored regexp string."
  (concat "\\`"
          (thread-last (regexp-quote glob)
                       (replace-regexp-in-string "\\\\\\*" ".*")
                       (replace-regexp-in-string "\\\\\\?" "."))
          "\\'"))

(defun hernes--run-process (session name dir command timeout done &optional success-codes)
  "Run COMMAND (a list) in DIR asynchronously, then call DONE with output.
Registers the process on SESSION for abort.  DONE is called with the combined
output string and a boolean indicating failure.  Failure is a timeout or an
exit code not in SUCCESS-CODES (which defaults to (0)); pass e.g. (0 1) for
tools like ripgrep where a benign \"no match\" also returns non-zero."
  (condition-case err
      (let* ((buf (generate-new-buffer (format " *hernes-%s*" name)))
             (default-directory (file-name-as-directory (expand-file-name dir)))
             (timed-out nil)
             (timer nil)
             (proc nil))
        (setq proc
              (make-process
               :name (concat "hernes-" name)
               :buffer buf
               :command command
               :noquery t
               :connection-type 'pipe
               :sentinel
               (lambda (p _event)
                 (when (memq (process-status p) '(exit signal))
                   (when timer (cancel-timer timer))
                   (setf (hernes-session-processes session)
                         (delq p (hernes-session-processes session)))
                   (let ((out (if (buffer-live-p buf)
                                  (with-current-buffer buf (buffer-string))
                                ""))
                         (code (process-exit-status p)))
                     (when (buffer-live-p buf) (kill-buffer buf))
                     (funcall done
                              (if timed-out
                                  (concat out (format "\n[hernes] command timed out after %ds]"
                                                      timeout))
                                out)
                              (or timed-out
                                  (not (memq code (or success-codes '(0)))))))))))
        (push proc (hernes-session-processes session))
        (setq timer (run-at-time timeout nil
                                 (lambda ()
                                   (when (process-live-p proc)
                                     (setq timed-out t)
                                     (kill-process proc)))))
        proc)
    (error
     (funcall done (format "Error: could not run %s: %s"
                           (car command) (error-message-string err))
              t)
     nil)))

(defun hernes--tool-read-file (session args done)
  "Execute the read_file tool.  See `hernes--all-tools' for the calling contract."
  (let* ((root (hernes-session-root session))
         (path (plist-get args :path))
         (abs (hernes--path-safe-p root path)))
    (cond
     ((not (stringp path))
      (funcall done "Error: missing 'path' argument." t))
     ((null abs)
      (funcall done (format "Error: path %S is outside the project root." path) t))
     ((not (file-readable-p abs))
      (funcall done (format "Error: file %S does not exist or is not readable." path) t))
     ((file-directory-p abs)
      (funcall done (format "Error: %S is a directory, not a file." path) t))
     (t (funcall done
                 (with-temp-buffer
                   (insert-file-contents abs)
                   (buffer-string))
                 nil)))))

(defun hernes--tool-write-file (session args done)
  "Execute the write_file tool."
  (let* ((root (hernes-session-root session))
         (path (plist-get args :path))
         (content (or (plist-get args :content) ""))
         (abs (hernes--path-safe-p root path)))
    (cond
     ((not (stringp path))
      (funcall done "Error: missing 'path' argument." t))
     ((null abs)
      (funcall done (format "Error: refusing to write %S: outside the project root." path) t))
     (t (condition-case err
            (progn
              (make-directory (file-name-directory abs) t)
              (let ((coding-system-for-write 'utf-8))
                (with-temp-file abs (insert content)))
              (funcall done (format "Wrote %d bytes to %s." (string-bytes content) path) nil))
          (error (funcall done (format "Error writing %S: %s" path (error-message-string err)) t)))))))

(defun hernes--tool-list-files (session args done)
  "Execute the list_files tool."
  (let* ((root (hernes-session-root session))
         (glob (plist-get args :glob))
         (proj (project-current nil root))
         (files (if proj
                    (mapcar (lambda (f) (file-relative-name f root)) (project-files proj))
                  (mapcar (lambda (f) (file-relative-name f root))
                          (directory-files-recursively root ".*" nil
                                                       (lambda (d)
                                                         (not (member (file-name-nondirectory d)
                                                                      hernes-grep-exclude-dirs))))))))
    (when (and (stringp glob) (not (string-empty-p glob)))
      (let ((re (hernes--glob-to-regexp glob)))
        (setq files (cl-remove-if-not
                     (lambda (f) (or (string-match-p re f)
                                     (string-match-p re (file-name-nondirectory f))))
                     files))))
    (funcall done (if files (string-join (sort files #'string<) "\n") "(no files)") nil)))

(defun hernes--tool-grep (session args done)
  "Execute the grep tool via ripgrep."
  (let* ((root (hernes-session-root session))
         (pattern (plist-get args :pattern))
         (glob (plist-get args :glob))
         (excludes (cl-loop for d in hernes-grep-exclude-dirs
                            append (list "--glob" (concat "!" d))))
         (glob-arg (and (stringp glob) (not (string-empty-p glob))
                        (list "--glob" glob)))
         (cmd (append (list "rg" "--line-number" "--no-heading" "--color" "never"
                            "--max-columns" "500")
                      excludes glob-arg (list "--" pattern))))
    (if (not (stringp pattern))
        (funcall done "Error: missing 'pattern' argument." t)
      ;; ripgrep exit codes: 0 = matches, 1 = no matches (benign), 2 = real
      ;; error (bad regexp, unreadable path).  Only 2+ is a tool error.
      (hernes--run-process
       session "grep" root cmd hernes-command-timeout
       (lambda (out err-p)
         (funcall done
                  (cond
                   (err-p (if (string-empty-p (string-trim out))
                              "Error: ripgrep failed." (hernes--truncate-output out)))
                   ((string-empty-p (string-trim out)) "(no matches)")
                   (t (hernes--truncate-output out)))
                  err-p))
       '(0 1)))))

(defun hernes--tool-run-command (session args done)
  "Execute the run_command tool, honoring the deny-list."
  (let* ((root (hernes-session-root session))
         (command (plist-get args :command))
         (denied (hernes--command-denied-p command)))
    (cond
     ((not (stringp command))
      (funcall done "Error: missing 'command' argument." t))
     (denied
      (funcall done
               (format "Error: command refused by the hernes safety deny-list (matched %S). \
It was NOT executed. Choose a safe alternative." denied)
               t))
     (t (hernes--run-process
         session "command" root
         (list hernes-shell-file-name "-c" command)
         hernes-command-timeout
         (lambda (out err-p)
           (funcall done
                    (let ((o (hernes--truncate-output out)))
                      (if (string-empty-p (string-trim o))
                          (if err-p "(command failed, no output)" "(command produced no output)")
                        o))
                    err-p)))))))

(defun hernes--tool-git-checkpoint (session args done)
  "Execute the git_checkpoint tool: stage all changes, then commit."
  (let* ((root (hernes-session-root session))
         (message (let ((m (plist-get args :message)))
                    (if (and (stringp m) (not (string-empty-p (string-trim m))))
                        m "hernes checkpoint"))))
    (hernes--run-process
     session "git-add" root '("git" "add" "-A") 30
     (lambda (_out _err)
       (hernes--run-process
        session "git-commit" root (list "git" "commit" "-m" message) 30
        (lambda (out err-p)
          (funcall done
                   (if (string-empty-p (string-trim out))
                       (if err-p "git commit failed (nothing to commit?)" "Committed.")
                     out)
                   ;; "nothing to commit" is a benign non-zero exit.
                   (and err-p (not (string-match-p "nothing to commit" out))))))))))

(defun hernes--tool-git-diff (session _args done)
  "Execute the git_diff tool."
  (let ((root (hernes-session-root session)))
    (hernes--run-process
     session "git-diff" root '("git" "diff") hernes-command-timeout
     (lambda (out err-p)
       (funcall done
                (if (string-empty-p (string-trim out))
                    "(no changes)"
                  (hernes--truncate-output out))
                err-p)))))

;;;; Conversation assembly

(defun hernes--push-message (session message)
  "Append MESSAGE (a conversation cons) to SESSION's message list."
  (setf (hernes-session-messages session)
        (append (hernes-session-messages session) (list message))))

(defun hernes--tool->gptel (tool)
  "Build a `gptel-tool' from a hernes TOOL plist, for schema transmission only.
The :function is never invoked: every tool is built with :confirm t, so gptel's
tool-use handler always routes the call back to hernes's callback as
\(tool-call . PENDING) instead of executing it.  The confirm flag must live on
the tool struct itself: gptel evaluates it asynchronously when the response
arrives, long after any dynamic binding around `gptel-request' has exited."
  (gptel-make-tool
   :name (plist-get tool :name)
   :description (plist-get tool :description)
   :args (plist-get tool :args)
   :function #'ignore
   :category "hernes"
   :confirm t))

(defun hernes--active-tools (session)
  "Return SESSION's candidate tools filtered by its CURRENT mode.
Recomputed on demand (rather than frozen at session creation) so that a
mid-session mode change via `hernes-set-mode' takes effect on the very next
send and on the next tool dispatch."
  (hernes--tools-for-mode (hernes-session-mode session)
                          (hernes-session-tools session)))

(defun hernes--gptel-tools (session)
  "Return the gptel-tool structs for SESSION's mode-active tools."
  (mapcar #'hernes--tool->gptel (hernes--active-tools session)))

;;;; Backend

(defun hernes--make-backend (session)
  "Construct a gptel OpenAI-compatible backend from SESSION's backend plist."
  (let* ((backend (hernes-session-backend session))
         (endpoint (or (plist-get backend :endpoint) "http://localhost:1234"))
         (model (or (plist-get backend :model) "local-model"))
         (url (url-generic-parse-url endpoint))
         (protocol (or (url-type url) "http"))
         (host (concat (url-host url)
                       (when (and (url-portspec url) (> (url-portspec url) 0))
                         (format ":%d" (url-portspec url))))))
    (gptel-make-openai "hernes-local"
      :host host
      :protocol protocol
      :endpoint "/v1/chat/completions"
      ;; Streaming must be enabled on the backend struct itself: gptel gates
      ;; streaming on (gptel-backend-stream gptel-backend) in addition to the
      ;; per-request :stream flag, so `:stream nil' here would silently disable
      ;; the token/thinking stream even when the request asks for it.
      :stream t
      :key "no-key"
      :models (list (list (intern model) :capabilities '(tool))))))

;;;; Request / turn loop

(defun hernes--make-fsm ()
  "Return a fresh gptel FSM whose terminal states notify hernes.
hernes appends its own handler to the DONE, ERRS and ABRT states so it learns
when a request finished as plain text (no further tool calls), errored, or was
aborted -- the boundary at which the loop either completes or stops."
  (gptel-make-fsm
   :handlers (mapcar
              (lambda (entry)
                (if (memq (car entry) '(DONE ERRS ABRT))
                    (append entry (list #'hernes--fsm-terminal))
                  entry))
              gptel-request--handlers)))

(defun hernes--fsm-terminal (fsm)
  "Terminal-state handler: finish or stop the hernes session driving FSM."
  (let ((session (plist-get (gptel-fsm-info fsm) :context)))
    (when (and (hernes-session-p session)
               (not (hernes-session-finished session))
               (not (hernes-session-aborted session)))
      (if (plist-get (gptel-fsm-info fsm) :error)
          (hernes--stop session (format "Model request failed: %s"
                                        (or (plist-get (gptel-fsm-info fsm) :status)
                                            "unknown error")))
        (hernes--finalize-done session (hernes-session-pending-text session))))))

(defun hernes--effective-system (session)
  "Return the system prompt to send for SESSION given its CURRENT mode.
In `plan' mode `hernes-plan-prompt' is appended to the session's base system
prompt; in every other mode the base prompt is sent unchanged.  Computed per
send so a mode toggle changes the instructions on the next turn."
  (let ((base (hernes-session-system session)))
    (if (eq (hernes-session-mode session) 'plan)
        (concat base "\n\n" hernes-plan-prompt)
      base)))

(defun hernes--send-request (session)
  "Send SESSION's current conversation to the model as one turn.
The tool set and the system prompt are both derived from SESSION's CURRENT mode
here, at send time (see `hernes--active-tools' and `hernes--effective-system'),
so a mode change mid-session takes effect on this very request.

Works headless: when SESSION has no live control buffer, the request runs in
the current buffer instead (gptel never receives a nil :buffer)."
  (let* ((sbuf (hernes-session-buffer session))
         (buffer (if (buffer-live-p sbuf) sbuf (current-buffer))))
    (with-current-buffer buffer
      (let ((gptel-backend (hernes--make-backend session))
            (gptel-model (intern (or (plist-get (hernes-session-backend session) :model)
                                     "local-model")))
            (gptel-use-tools t)
            ;; Ask the backend to emit the model's reasoning/thinking as
            ;; (reasoning . CHUNK) callbacks so the UI can show it live.  Unlike
            ;; `gptel-confirm-tool-calls', this variable IS read synchronously
            ;; while `gptel-request' builds the payload, so the let binding
            ;; applies.  hernes never stores reasoning in the conversation (see
            ;; `hernes--turn-callback'), so it does not pollute later turns.
            (gptel-include-reasoning t)
            ;; Interception relies on each tool's :confirm slot (see
            ;; `hernes--tool->gptel'), NOT on binding `gptel-confirm-tool-calls'
            ;; here: gptel reads that variable asynchronously after this let
            ;; has exited, so a dynamic binding would silently not apply.
            (gptel-tools (hernes--gptel-tools session)))
        (gptel-request (hernes-session-messages session)
          :system (hernes--effective-system session)
          :buffer buffer
          ;; Stream so a reasoning model's long "thinking" phase produces visible
          ;; output instead of dead air.  Text chunks arrive incrementally and
          ;; are concatenated in `hernes--turn-callback'; if streaming does not
          ;; engage (e.g. no curl) gptel delivers one final string, which the
          ;; same concatenation handles as a single chunk.
          :stream t
          :context session
          :fsm (hernes--make-fsm)
          :callback (lambda (response info)
                      (hernes--turn-callback session response info)))))))

(defun hernes--turn-callback (session response _info)
  "gptel callback for SESSION.  RESPONSE is as in `gptel-request'.
Under streaming RESPONSE arrives in pieces: assistant text chunks (strings),
reasoning chunks (\\=(reasoning . CHUNK)) with a (reasoning . t) terminator, tool
calls (\\=(tool-call . PENDING)), and a final t on success.  Whether the turn
ends is still decided by the tool-call branch or the FSM terminal handler."
  (cond
   ((hernes-session-aborted session) nil)
   ((stringp response)
    ;; Assistant text.  CONCATENATE (streaming delivers fragments); a
    ;; non-streamed reply is simply a single fragment appended to the empty
    ;; pending-text that `hernes--run-turn' set at the start of the turn.
    (setf (hernes-session-pending-text session)
          (concat (hernes-session-pending-text session) response))
    (hernes--notify-stream session response))
   ((and (consp response) (eq (car response) 'reasoning))
    ;; Thinking: shown live only.  Deliberately NOT concatenated into
    ;; pending-text and NEVER pushed as a message, so it never re-enters the
    ;; context on later turns.  CHUNK is a string fragment, or t at block end.
    (hernes--notify-thinking session (cdr response)))
   ((and (consp response) (eq (car response) 'tool-call))
    (hernes--handle-tool-calls session (cdr response)))
   ;; final t (stream success), abort symbol, nil (pure tool call, no text):
   ;; nothing to do here.
   (t nil)))

(defun hernes--handle-tool-calls (session pending)
  "Run the PENDING tool calls of a turn in parallel, then advance SESSION.
PENDING is gptel's list of (TOOL-SPEC ARGS CB); the CBs are intentionally not
called -- hernes executes the tools itself and builds the next request."
  (let* ((text (hernes-session-pending-text session))
         (calls (mapcar (lambda (p)
                          (cons (gptel-tool-name (nth 0 p)) (nth 1 p)))
                        pending))
         (n (length calls))
         (results (make-vector n nil))
         (remaining n))
    (when (and (stringp text) (not (string-empty-p (string-trim text))))
      (hernes--push-message session (cons 'response text)))
    (cl-loop
     for i from 0
     for (name . args) in calls
     do (let ((idx i) (nm name) (ag args))
          (hernes--exec-tool
           session nm ag
           (lambda (result error-p)
             (aset results idx (list :name nm :args ag :result result :error error-p))
             (setq remaining (1- remaining))
             (when (zerop remaining)
               (hernes--tools-finished session (append results nil)))))))))

(defun hernes--exec-tool (session name args done)
  "Look up tool NAME in SESSION and execute it with ARGS, calling DONE.
If NAME is unknown or not exposed in the current mode, DONE receives an error
\(this is itself part of the safety net): the lookup is against the mode-active
tool set, so a side-effect tool refused for `chat'/`plan' cannot be dispatched
even if the model asks for it."
  (let ((tool (cl-find name (hernes--active-tools session)
                       :key (lambda (tl) (plist-get tl :name)) :test #'equal)))
    (if (null tool)
        (funcall done
                 (format "Error: tool %S is not available in %s mode."
                         name (hernes-session-mode session))
                 t)
      (condition-case err
          (funcall (plist-get tool :fn) session args done)
        (error (funcall done (format "Error running %s: %s" name (error-message-string err)) t))))))

(defun hernes--tools-finished (session results)
  "Record RESULTS of a turn's tool calls on SESSION and decide what happens next."
  (dolist (r results)
    (hernes--push-message session (list 'tool
                                        :name (plist-get r :name)
                                        :args (plist-get r :args)
                                        :result (plist-get r :result))))
  (setf (hernes-session-error-streak session)
        (hernes--update-error-streak (hernes-session-error-streak session) results))
  (hernes--notify-turn session results)
  (let ((streak (hernes-session-error-streak session)))
    (cond
     ((and streak (>= (cdr streak) 3))
      (hernes--stop session (format "Tool %S failed 3 times in a row." (car streak))))
     (t (hernes--run-turn session)))))

(defun hernes--run-turn (session)
  "Start the next model turn for SESSION, or stop if a limit is reached."
  (unless (or (hernes-session-aborted session) (hernes-session-finished session))
    (if (>= (hernes-session-turn session) (hernes-session-max-turns session))
        (hernes--stop session (format "Reached the maximum of %d turns."
                                      (hernes-session-max-turns session)))
      (cl-incf (hernes-session-turn session))
      (setf (hernes-session-pending-text session) "")
      (hernes--send-request session))))

;;;; Termination

(defun hernes--notify-turn (session results)
  "Call SESSION's on-turn hook, if any, with this turn's RESULTS."
  (when (functionp (hernes-session-on-turn session))
    (with-demoted-errors "hernes on-turn error: %S"
      (funcall (hernes-session-on-turn session)
               (list :turn (hernes-session-turn session)
                     :text (hernes-session-pending-text session)
                     :results results)))))

(defun hernes--notify-stream (session chunk)
  "Call SESSION's on-stream hook, if any, with an assistant text CHUNK.
Headless-safe: with no on-stream callback (the default, as under `emacs
--batch') this is a no-op."
  (when (functionp (hernes-session-on-stream session))
    (with-demoted-errors "hernes on-stream error: %S"
      (funcall (hernes-session-on-stream session) chunk))))

(defun hernes--notify-thinking (session chunk)
  "Call SESSION's on-thinking hook, if any, with a reasoning CHUNK.
CHUNK is a string fragment or t (end of the thinking block).  Headless-safe:
with no on-thinking callback this is a no-op, so reasoning is simply dropped."
  (when (functionp (hernes-session-on-thinking session))
    (with-demoted-errors "hernes on-thinking error: %S"
      (funcall (hernes-session-on-thinking session) chunk))))

(defun hernes--finish (session status reason)
  "Mark SESSION finished with STATUS and REASON and call on-done once.
The loop keeps no buffer of its own here; any user-visible output is the
responsibility of the ON-DONE callback (whose default renders to the control
buffer).  This is what lets the loop run headless."
  (unless (hernes-session-finished session)
    (setf (hernes-session-finished session) t)
    (hernes--kill-processes session)
    (when (functionp (hernes-session-on-done session))
      (with-demoted-errors "hernes on-done error: %S"
        (funcall (hernes-session-on-done session)
                 (list :status status
                       :reason reason
                       :result (hernes-session-pending-text session)
                       :turns (hernes-session-turn session)
                       :messages (hernes-session-messages session)))))))

(defun hernes--finalize-done (session text)
  "Finish SESSION normally: TEXT is the model's final plain-text reply."
  (when (and (stringp text) (not (string-empty-p (string-trim text))))
    ;; TEXT is authoritative for the final reply, so the on-done :result agrees.
    (setf (hernes-session-pending-text session) text)
    ;; Ensure the final answer is part of the recorded conversation.
    (let ((last (car (last (hernes-session-messages session)))))
      (unless (and (consp last) (eq (car last) 'response) (equal (cdr last) text))
        (hernes--push-message session (cons 'response text)))))
  (hernes--finish session 'done (if (string-empty-p (string-trim (or text "")))
                                    "completed with no final message"
                                  "completed")))

(defun hernes--stop (session reason)
  "Stop SESSION early (a limit or error), returning control to the human."
  (hernes--finish session 'stopped reason))

(defun hernes--kill-processes (session)
  "Kill any live subprocesses owned by SESSION."
  (dolist (p (hernes-session-processes session))
    (when (process-live-p p) (ignore-errors (kill-process p))))
  (setf (hernes-session-processes session) nil))

;;;; Core entry point: hernes-loop

;;;###autoload
(cl-defun hernes-loop (&key task system-prompt tools backend mode max-turns
                            on-turn on-done on-stream on-thinking buffer root id)
  "Run an autonomous agent loop and return its `hernes-session'.

This is the re-entrant core: all state lives in the returned session struct, so
it is safe to nest (a subagent is just another call to this function).  The
loop is asynchronous and never blocks Emacs.

The loop is fully headless: it drives progress only through the ON-TURN and
ON-DONE callbacks and never reads the minibuffer or assumes a visible buffer,
so it runs unchanged under `emacs --batch', a daemon, or a cron trigger.  The
control buffer is not special to the loop -- it is simply what the *default*
callbacks render into (see `hernes--render-turn' / `hernes--render-done'),
installed only when BUFFER is live and the caller passed no callback of its own.

Keyword arguments:
  TASK           the task description (the initial user message).  Required.
  ROOT           the project root directory.  Required.
  BUFFER         optional control buffer.  When live and the matching callback
                 is not supplied, the loop installs a default renderer for it.
                 Pass nil for headless operation.
  SYSTEM-PROMPT  system prompt (defaults to `hernes-system-prompt').
  TOOLS          candidate tool list (defaults to `hernes--all-tools'); it is
                 filtered by MODE before use.
  BACKEND        backend plist (:endpoint :model), defaults to `hernes-backend'.
  MODE           `chat' or `auto' (defaults to `auto').
  MAX-TURNS      turn cap (defaults to `hernes-max-turns').
  ID             session id string (defaults to a timestamp).  Pass this to keep
                 the session id aligned with an externally created git branch.
  ON-TURN        called after each turn that ran tools, with a status plist
                 (:turn :text :results).  Overrides the default buffer renderer.
  ON-DONE        called once at completion, with a result plist
                 (:status :reason :result :turns :messages).  Overrides the
                 default buffer renderer.
  ON-STREAM      called with each assistant text CHUNK (a string) as it streams
                 in.  Optional and UI-only: omit it (the default) for headless
                 runs, where streamed chunks are simply dropped.
  ON-THINKING    called with each reasoning CHUNK (a string), and with t at the
                 end of the thinking block.  Optional and UI-only in the same
                 way; reasoning is never added to the conversation."
  (let ((session (hernes--init-session
                  :task task :system-prompt system-prompt :tools tools
                  :backend backend :mode mode :max-turns max-turns
                  :on-turn on-turn :on-done on-done
                  :on-stream on-stream :on-thinking on-thinking
                  :buffer buffer :root root :id id)))
    (hernes--run-turn session)
    session))

(cl-defun hernes--init-session (&key task system-prompt tools backend mode max-turns
                                     on-turn on-done on-stream on-thinking buffer root id)
  "Build and return a fresh `hernes-session' WITHOUT starting its turn loop.
This is the constructor half of `hernes-loop': it validates nothing new, stores
the UNFILTERED candidate tools (the mode filter is applied per send), installs
the default buffer renderers only when BUFFER is live and no callback was
supplied, records the opening prompt, and returns.  Callers that need to gate
the first turn (e.g. the UI running `hernes--ensure-git' for `auto' mode) use
this plus `hernes--run-turn' instead of `hernes-loop'; see DESIGN.md section 1.

ON-STREAM and ON-THINKING (the live token/reasoning display) are stored as
given, with no default buffer renderer installed: they are a UI concern that
only hernes-ui.el wires up, and a nil callback keeps the core headless-safe (see
`hernes--notify-stream' / `hernes--notify-thinking')."
  (let* ((mode (or mode 'auto))
         (buffer-live (buffer-live-p buffer))
         ;; The default control-buffer chrome (banner + renderers) is only for
         ;; the legacy `hernes-mode' path: install it just when BUFFER is live
         ;; and the caller passed no callbacks of its own.
         (use-default-ui (and buffer-live (not on-turn) (not on-done)))
         (on-turn (or on-turn
                      (and buffer-live (hernes--buffer-renderer buffer #'hernes--render-turn))))
         (on-done (or on-done
                      (and buffer-live (hernes--buffer-renderer buffer #'hernes--render-done))))
         (session (hernes--make-session
                   :id (or id (format-time-string "%Y%m%d-%H%M%S"))
                   :root (expand-file-name root)
                   :mode mode
                   :task task
                   :max-turns (or max-turns hernes-max-turns)
                   :tools (or tools (hernes--all-tools))
                   :system (or system-prompt hernes-system-prompt)
                   :backend (or backend hernes-backend)
                   :buffer buffer
                   :on-turn on-turn
                   :on-done on-done
                   :on-stream on-stream
                   :on-thinking on-thinking)))
    ;; The only buffer touch in the core, and it is guarded: headless runs skip it.
    (when buffer-live
      (with-current-buffer buffer (setq-local hernes--session session)))
    (when use-default-ui
      (hernes--render-header buffer session))
    (hernes--push-message session (cons 'prompt task))
    session))

;;;###autoload
(defun hernes-set-mode (session mode)
  "Set the active MODE of SESSION to one of `chat', `plan' or `auto'.
Signals an error for any other value.  The tool set and system prompt are
recomputed from the mode on the next send, so this may be called at any time,
including while a run is in flight -- it takes effect on the following turn."
  (unless (memq mode '(chat plan auto))
    (error "hernes: invalid mode %S (expected chat, plan or auto)" mode))
  (setf (hernes-session-mode session) mode))

;;;###autoload
(defun hernes-resume (session text)
  "Continue a finished SESSION with a new human message TEXT.

SESSION must be finished (`hernes-session-finished' non-nil), whether it
completed normally or was aborted; a still-running session signals a
`user-error'.  TEXT is appended to the conversation as a new prompt, the
finished/aborted/error-streak state is cleared, the turn counter is reset
to 0 (a fresh human message resets the turn budget, the same semantics
Claude Code uses), and the turn loop restarts with `hernes--run-turn'.
SESSION's existing ON-TURN/ON-DONE callbacks are reused unchanged.

This is the headless counterpart to `hernes-reply': it never touches a
buffer or the minibuffer, so it works the same under `emacs --batch'."
  (unless (hernes-session-finished session)
    (user-error "hernes: session is still running"))
  (hernes--push-message session (cons 'prompt text))
  (setf (hernes-session-finished session) nil
        (hernes-session-aborted session) nil
        (hernes-session-error-streak session) nil
        (hernes-session-turn session) 0
        (hernes-session-pending-text session) "")
  (hernes--run-turn session)
  session)

;;;; Control buffer and UI

(defvar-local hernes--session nil
  "The `hernes-session' displayed in this control buffer.")

(defvar hernes-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-k") #'hernes-abort)
    (define-key map (kbd "r") #'hernes-reply)
    (define-key map (kbd "C-c C-c") #'hernes-reply)
    map)
  "Keymap for `hernes-mode'.")

(define-derived-mode hernes-mode special-mode "Hernes"
  "Major mode for the legacy hernes control buffer.
Superseded by `hernes-ui-mode' (hernes-ui.el), which `M-x hernes' now uses;
this mode backs only the default renderers and headless/programmatic callers."
  (setq-local truncate-lines nil))

(defun hernes--args-string (args)
  "Return a compact one-line rendering of tool ARGS plist."
  (string-trim (truncate-string-to-width (format "%S" args) 120 nil nil t)))

(defun hernes--summarize (text)
  "Return a ~200 char single-line summary of TEXT for the control buffer."
  (let ((s (replace-regexp-in-string "[ \t\n\r]+" " " (or text ""))))
    (truncate-string-to-width (string-trim s) 200 nil nil t)))

;; The control buffer is populated only through these default callbacks; the
;; loop core never calls them directly (see `hernes-loop').

(defun hernes--buffer-renderer (buffer render-fn)
  "Return a callback that applies RENDER-FN to BUFFER, but only while it is live.
Used to build the default ON-TURN/ON-DONE callbacks."
  (lambda (payload)
    (when (buffer-live-p buffer)
      (funcall render-fn buffer payload))))

(defun hernes--buffer-insert (buffer text)
  "Append TEXT to control BUFFER, keeping point at the end if it was there."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((inhibit-read-only t)
            (at-end (eobp)))
        (save-excursion
          (goto-char (point-max))
          (insert text))
        (when at-end (goto-char (point-max)))))))

(defun hernes--render-header (buffer session)
  "Render SESSION's opening banner and task into control BUFFER."
  (hernes--buffer-insert
   buffer
   (format "\n=== hernes session %s (mode=%s, max-turns=%d) ===\n[root] %s\n\n[user]\n%s\n"
           (hernes-session-id session)
           (hernes-session-mode session)
           (hernes-session-max-turns session)
           (hernes-session-root session)
           (hernes-session-task session))))

(defun hernes--render-turn (buffer payload)
  "Default ON-TURN renderer: write PAYLOAD (a turn) into control BUFFER.
Shows the assistant's full text and a summary of each tool call and result."
  (let ((turn (plist-get payload :turn))
        (text (plist-get payload :text))
        (results (plist-get payload :results)))
    (hernes--buffer-insert buffer (format "\n--- Turn %d ---\n" turn))
    (when (and (stringp text) (not (string-empty-p (string-trim text))))
      (hernes--buffer-insert buffer (format "[assistant]\n%s\n" text)))
    (dolist (r results)
      (hernes--buffer-insert
       buffer
       (format "  -> %s %s\n  <- %s%s\n"
               (plist-get r :name)
               (hernes--args-string (plist-get r :args))
               (if (plist-get r :error) "[error] " "")
               (hernes--summarize (plist-get r :result)))))))

(defun hernes--render-done (buffer payload)
  "Default ON-DONE renderer: write completion PAYLOAD into control BUFFER."
  (let ((status (plist-get payload :status))
        (result (plist-get payload :result)))
    (when (and (eq status 'done) (stringp result)
               (not (string-empty-p (string-trim result))))
      (hernes--buffer-insert buffer (format "\n[assistant]\n%s\n" result)))
    (hernes--buffer-insert
     buffer (format "\n=== %s: %s (turns: %s) ===\n"
                    status (plist-get payload :reason) (plist-get payload :turns)))
    (hernes--buffer-insert buffer "-- reply with r, abort with C-c C-k --\n")))

;;;; Git session setup

(defun hernes--git-start (session-id root done)
  "Prepare the git safety net for a new session in ROOT, then call DONE.
Refuses (DONE nil REASON) if the working tree is dirty; otherwise creates and
switches to branch hernes/SESSION-ID and calls (DONE t nil)."
  (let ((default-directory (file-name-as-directory (expand-file-name root))))
    (let ((status-buf (generate-new-buffer " *hernes-git-status*")))
      (make-process
       :name "hernes-git-status"
       :buffer status-buf
       :command '("git" "status" "--porcelain")
       :noquery t
       :sentinel
       (lambda (p _e)
         (when (memq (process-status p) '(exit signal))
           (let ((out (with-current-buffer status-buf (buffer-string)))
                 (code (process-exit-status p)))
             (kill-buffer status-buf)
             (cond
              ((not (eql code 0))
               (funcall done nil "not a git repository (or git unavailable)"))
              ((not (string-empty-p (string-trim out)))
               (funcall done nil "working tree is dirty; commit or stash first"))
              (t
               (let ((branch (concat "hernes/" session-id))
                     (sw-buf (generate-new-buffer " *hernes-git-switch*")))
                 (make-process
                  :name "hernes-git-switch"
                  :buffer sw-buf
                  :command (list "git" "switch" "-c" branch)
                  :noquery t
                  :sentinel
                  (lambda (p2 _e2)
                    (when (memq (process-status p2) '(exit signal))
                      (let ((o2 (with-current-buffer sw-buf (buffer-string)))
                            (c2 (process-exit-status p2)))
                        (kill-buffer sw-buf)
                        (if (eql c2 0)
                            (funcall done t nil)
                          (funcall done nil (format "could not create branch %s: %s"
                                                    branch (string-trim o2))))))))))))))))))

(defun hernes--ensure-git (session done)
  "Prepare SESSION's git safety net if needed, then call DONE.
The safety branch is created lazily, only for `auto' mode and only once: when
SESSION is in `auto' mode and not yet `git-ready', run `hernes--git-start' and,
on success, mark the session `git-ready' and call (DONE t nil); on failure (no
repo, or a dirty tree) call (DONE nil REASON) WITHOUT starting anything so the
caller can surface REASON.  In any other mode, or when the branch already
exists, call (DONE t nil) immediately -- `chat'/`plan' never touch git."
  (if (and (eq (hernes-session-mode session) 'auto)
           (not (hernes-session-git-ready session)))
      (hernes--git-start
       (hernes-session-id session)
       (hernes-session-root session)
       (lambda (ok reason)
         (if ok
             (progn (setf (hernes-session-git-ready session) t)
                    (funcall done t nil))
           (funcall done nil reason))))
    (funcall done t nil)))

;;;; Interactive entry points
;;
;; The session-buffer UI (`M-x hernes') lives in hernes-ui.el.  The legacy
;; control-buffer path below -- `hernes-mode', `hernes-abort' and `hernes-reply'
;; with their minibuffer reply flow -- is retained for the headless/default
;; renderer and for backward compatibility, but is no longer reached from
;; `M-x hernes'.

;;;###autoload
(defun hernes-abort ()
  "Abort the hernes session running in the current control buffer."
  (interactive)
  (let ((session hernes--session))
    (if (not (hernes-session-p session))
        (message "No hernes session in this buffer.")
      (setf (hernes-session-aborted session) t)
      (hernes--kill-processes session)
      (ignore-errors (gptel-abort (hernes-session-buffer session)))
      (hernes--finish session 'stopped "aborted by user"))))

;;;###autoload
(defun hernes-reply ()
  "Continue the hernes session in the current control buffer.
Reads additional text from the minibuffer, echoes it into the control
buffer as a `[user]' entry, and resumes the session via `hernes-resume'.
Does nothing but message if the buffer has no session or the session is
still running (use `hernes-abort' first if you want to interrupt it)."
  (interactive)
  (let ((session hernes--session))
    (cond
     ((not (hernes-session-p session))
      (message "No hernes session in this buffer."))
     ((not (hernes-session-finished session))
      (message "Session is still running."))
     (t
      (let ((text (read-string "hernes reply: ")))
        (hernes--buffer-insert (hernes-session-buffer session)
                               (format "\n[user]\n%s\n" text))
        (hernes-resume session text))))))

(provide 'hernes)
;;; hernes.el ends here
