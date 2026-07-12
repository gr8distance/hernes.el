;;; hernes-test.el --- ERT tests for hernes -*- lexical-binding: t; -*-

;;; Commentary:

;; Network-free unit tests for hernes's pure logic: the deny-list, the
;; project-root guard, the mode->tool filter, the consecutive-error stop
;; condition, glob translation, conversation assembly, and tool-schema
;; generation.  Run with:
;;
;;   emacs -Q --batch -L . -L <gptel> -L <compat> -L <transient> \
;;     -l hernes-test.el -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'hernes)
(require 'hernes-ui)

;;;; Deny-list

(ert-deftest hernes-test-deny-list-blocks-destructive ()
  "Destructive commands are matched by the deny-list."
  (should (hernes--command-denied-p "rm -rf /"))
  (should (hernes--command-denied-p "rm -fr node_modules"))
  (should (hernes--command-denied-p "rm    -r   -f  foo"))
  (should (hernes--command-denied-p "sudo make install"))
  (should (hernes--command-denied-p "git push origin main"))
  (should (hernes--command-denied-p "git push --force"))
  (should (hernes--command-denied-p "some --force flag")))

(ert-deftest hernes-test-deny-list-allows-safe ()
  "Ordinary commands are not blocked."
  (should-not (hernes--command-denied-p "ls -la"))
  (should-not (hernes--command-denied-p "npm test"))
  (should-not (hernes--command-denied-p "git status"))
  (should-not (hernes--command-denied-p "git commit -m 'fix'"))
  (should-not (hernes--command-denied-p "make build"))
  (should-not (hernes--command-denied-p "rm foo.txt"))) ;plain rm without -r/-f

;;;; Project-root guard

(ert-deftest hernes-test-path-guard-inside ()
  "Paths inside the root resolve to an absolute path.
Uses a real temporary directory because the guard relies on
`file-in-directory-p', which requires the root directory to exist."
  (let ((root (file-name-as-directory (file-truename (make-temp-file "hernes-test" t)))))
    (unwind-protect
        (progn
          (should (equal (hernes--path-safe-p root "a.txt")
                         (expand-file-name "a.txt" root)))
          (should (equal (hernes--path-safe-p root "src/b.el")
                         (expand-file-name "src/b.el" root)))
          (should (equal (hernes--path-safe-p root "./a.txt")
                         (expand-file-name "a.txt" root))))
      (delete-directory root t))))

(ert-deftest hernes-test-path-guard-rejects-escape ()
  "Paths escaping the root are rejected."
  (let ((root (file-name-as-directory (file-truename (make-temp-file "hernes-test" t)))))
    (unwind-protect
        (progn
          (should-not (hernes--path-safe-p root "../secret"))
          (should-not (hernes--path-safe-p root "src/../../secret"))
          (should-not (hernes--path-safe-p root "/etc/passwd"))
          (should-not (hernes--path-safe-p root nil)))
      (delete-directory root t))))

;;;; Mode -> tool filter

(ert-deftest hernes-test-mode-filter-chat-hides-side-effects ()
  "`chat' mode exposes only read-only tools."
  (let* ((tools (hernes--all-tools))
         (chat (hernes--tools-for-mode 'chat tools))
         (names (mapcar (lambda (tl) (plist-get tl :name)) chat)))
    (should (member "read_file" names))
    (should (member "grep" names))
    (should (member "list_files" names))
    (should (member "git_diff" names))
    (should-not (member "write_file" names))
    (should-not (member "run_command" names))
    (should-not (member "git_checkpoint" names))
    ;; No exposed tool has a side effect.
    (should-not (cl-some (lambda (tl) (plist-get tl :side-effect)) chat))))

(ert-deftest hernes-test-mode-filter-auto-keeps-all ()
  "`auto' mode exposes every tool."
  (let* ((tools (hernes--all-tools))
         (auto (hernes--tools-for-mode 'auto tools)))
    (should (= (length auto) (length tools)))))

;;;; Consecutive-error stop condition

(ert-deftest hernes-test-error-streak-increments-same-tool ()
  "Repeated errors from the same tool accumulate."
  (let* ((r (lambda (name err) (list :name name :error err)))
         (s nil))
    (setq s (hernes--update-error-streak s (list (funcall r "run_command" t))))
    (should (equal s '("run_command" . 1)))
    (setq s (hernes--update-error-streak s (list (funcall r "run_command" t))))
    (should (equal s '("run_command" . 2)))
    (setq s (hernes--update-error-streak s (list (funcall r "run_command" t))))
    (should (equal s '("run_command" . 3)))))

(ert-deftest hernes-test-error-streak-resets-on-success ()
  "A clean batch resets the streak; a different tool restarts the count."
  (let ((r (lambda (name err) (list :name name :error err))))
    (should (null (hernes--update-error-streak '("run_command" . 2)
                                               (list (funcall r "read_file" nil)))))
    (should (equal (hernes--update-error-streak '("run_command" . 2)
                                                (list (funcall r "grep" t)))
                   '("grep" . 1)))))

;;;; Glob translation

(ert-deftest hernes-test-glob-to-regexp ()
  "Globs translate to anchored regexps that match at any depth."
  (should (string-match-p (hernes--glob-to-regexp "*.el") "src/foo.el"))
  (should (string-match-p (hernes--glob-to-regexp "*.el") "foo.el"))
  (should-not (string-match-p (hernes--glob-to-regexp "*.el") "foo.txt"))
  (should (string-match-p (hernes--glob-to-regexp "src/*.js") "src/app.js"))
  (should (string-match-p (hernes--glob-to-regexp "a?c") "abc"))
  (should-not (string-match-p (hernes--glob-to-regexp "a?c") "ac")))

;;;; Conversation assembly

(ert-deftest hernes-test-message-assembly-order-and-shape ()
  "Messages accumulate in order in gptel's advanced prompt-list shape."
  (let ((session (hernes--make-session :messages nil)))
    (hernes--push-message session (cons 'prompt "do the thing"))
    (hernes--push-message session (cons 'response "on it"))
    (hernes--push-message session (list 'tool :name "read_file"
                                        :args '(:path "a.el") :result "contents"))
    (let ((msgs (hernes-session-messages session)))
      (should (equal (nth 0 msgs) '(prompt . "do the thing")))
      (should (equal (nth 1 msgs) '(response . "on it")))
      ;; Every element is a cons whose car is a role gptel understands.
      (should (cl-every (lambda (m) (memq (car m) '(prompt response tool))) msgs))
      (let ((tool (nth 2 msgs)))
        (should (eq (car tool) 'tool))
        (should (equal (plist-get (cdr tool) :name) "read_file"))
        (should (equal (plist-get (cdr tool) :result) "contents"))))))

;;;; Tool-schema generation

(ert-deftest hernes-test-tool-schema-generation ()
  "Each hernes tool converts to a gptel-tool preserving name and args."
  (dolist (tool (hernes--all-tools))
    (let ((gt (hernes--tool->gptel tool)))
      (should (gptel-tool-p gt))
      (should (equal (gptel-tool-name gt) (plist-get tool :name)))
      (should (stringp (gptel-tool-description gt)))
      (should (= (length (gptel-tool-args gt))
                 (length (plist-get tool :args)))))))

(ert-deftest hernes-test-tool-schema-required-vs-optional ()
  "list_files exposes its glob argument as optional in the JSON schema."
  (let* ((tools (hernes--gptel-tools
                 (hernes--make-session :tools (hernes--all-tools))))
         (spec (gptel--parse-tools nil tools))
         (list-files (cl-find-if
                      (lambda (s) (equal (plist-get (plist-get s :function) :name)
                                         "list_files"))
                      (append spec nil)))
         (params (plist-get (plist-get list-files :function) :parameters)))
    ;; glob is optional -> not in the :required vector.
    (should (equal (append (plist-get params :required) nil) nil))))

;;;; Headless operation (no buffer, no minibuffer)

(ert-deftest hernes-test-headless-loop-runs-without-buffer ()
  "hernes-loop drives a run to completion with BUFFER nil, via callbacks only.
`hernes--send-request' is stubbed so no network is touched."
  (let ((done nil))
    (cl-letf (((symbol-function 'hernes--send-request)
               (lambda (session)
                 ;; Simulate a text-only final model response.
                 (setf (hernes-session-pending-text session) "all done")
                 (hernes--finalize-done session "all done"))))
      (let ((session (hernes-loop :task "do x"
                                  :root default-directory
                                  :buffer nil
                                  :on-done (lambda (r) (setq done r)))))
        (should (hernes-session-p session))
        (should (eq (plist-get done :status) 'done))
        (should (equal (plist-get done :result) "all done"))
        ;; The conversation was recorded without any buffer at all.
        (should (equal (car (hernes-session-messages session)) '(prompt . "do x")))
        (should (member '(response . "all done") (hernes-session-messages session)))))))

(ert-deftest hernes-test-headless-installs-no-default-callbacks ()
  "With no buffer and no callbacks, the loop installs neither default renderer."
  (cl-letf (((symbol-function 'hernes--send-request) #'ignore))
    (let ((session (hernes-loop :task "x" :root default-directory :buffer nil)))
      (should (null (hernes-session-on-turn session)))
      (should (null (hernes-session-on-done session))))))

(ert-deftest hernes-test-batch-mode-is-active ()
  "Sanity: these tests run under `noninteractive' (emacs --batch)."
  (should noninteractive))

(ert-deftest hernes-test-send-request-headless-no-crash ()
  "The real `hernes--send-request' runs with BUFFER nil without error and never
hands gptel-request a nil :buffer.  Only `gptel-request' is stubbed."
  (let ((captured nil)
        (done nil))
    (cl-letf (((symbol-function 'gptel-request)
               (lambda (_prompt &rest args)
                 (setq captured args)
                 ;; Drive a text-only completion through the real callback.
                 (let ((cb (plist-get args :callback))
                       (session (plist-get args :context)))
                   (funcall cb "ok" nil)
                   (hernes--finalize-done session "ok"))
                 nil)))
      (hernes-loop :task "x" :root default-directory :buffer nil
                   :on-done (lambda (r) (setq done r)))
      ;; send-request reached gptel-request (did not crash on the nil buffer)...
      (should captured)
      ;; ...and passed a live buffer, never nil.
      (should (bufferp (plist-get captured :buffer)))
      (should (buffer-live-p (plist-get captured :buffer)))
      (should (eq (plist-get done :status) 'done)))))

(ert-deftest hernes-test-loop-respects-explicit-id ()
  "An explicit :id is used as the session id (to match the git branch name)."
  (cl-letf (((symbol-function 'hernes--send-request) #'ignore))
    (let ((session (hernes-loop :task "x" :root default-directory
                                :buffer nil :id "20260712-custom")))
      (should (equal (hernes-session-id session) "20260712-custom")))
    ;; Without :id, an id is still generated.
    (let ((session (hernes-loop :task "x" :root default-directory :buffer nil)))
      (should (stringp (hernes-session-id session)))
      (should-not (string-empty-p (hernes-session-id session))))))

(ert-deftest hernes-test-run-command-uses-posix-shell ()
  "run_command invokes `hernes-shell-file-name' with -c, not the login shell."
  (let ((captured nil)
        (hernes-shell-file-name "/bin/sh"))
    (cl-letf (((symbol-function 'hernes--run-process)
               (lambda (_s _n _d command _timeout done &optional _codes)
                 (setq captured command)
                 (funcall done "" nil))))
      (hernes--tool-run-command (hernes--make-session :root default-directory)
                                '(:command "export FOO=bar")
                                (lambda (_r _e) nil)))
    (should (equal captured (list "/bin/sh" "-c" "export FOO=bar")))))

(ert-deftest hernes-test-grep-error-vs-no-match ()
  "grep reports a real ripgrep error as error-p t, but no-match as benign."
  ;; Real error (rg exit 2 surfaces as err-p t from `hernes--run-process').
  (let (res)
    (cl-letf (((symbol-function 'hernes--run-process)
               (lambda (_s _n _d _c _timeout done &optional _codes)
                 (funcall done "regex parse error: unclosed class" t))))
      (hernes--tool-grep (hernes--make-session :root default-directory)
                         '(:pattern "[")
                         (lambda (r e) (setq res (list r e)))))
    (should (nth 1 res)))
  ;; No matches (err-p nil): benign, not an error.
  (let (res)
    (cl-letf (((symbol-function 'hernes--run-process)
               (lambda (_s _n _d _c _timeout done &optional _codes)
                 (funcall done "" nil))))
      (hernes--tool-grep (hernes--make-session :root default-directory)
                         '(:pattern "zzz")
                         (lambda (r e) (setq res (list r e)))))
    (should-not (nth 1 res))
    (should (equal (nth 0 res) "(no matches)"))))

;;;; hernes-resume (continued conversation)

(ert-deftest hernes-test-resume-clears-finished-and-resets-turn ()
  "`hernes-resume' pushes a prompt, clears finished/aborted/error-streak, and
resets the turn counter to 0 before restarting the loop."
  (cl-letf (((symbol-function 'hernes--send-request) #'ignore))
    (let ((session (hernes--make-session
                     :root default-directory
                     :max-turns 30
                     :turn 5
                     :finished t
                     :aborted t
                     :error-streak '("run_command" . 2)
                     :messages (list (cons 'prompt "first")
                                     (cons 'response "done")))))
      (hernes-resume session "and then?")
      (should (equal (car (last (hernes-session-messages session)))
                     '(prompt . "and then?")))
      (should-not (hernes-session-finished session))
      (should-not (hernes-session-aborted session))
      (should (null (hernes-session-error-streak session)))
      ;; `hernes--run-turn' increments turn from the reset 0 to 1 before sending.
      (should (= (hernes-session-turn session) 1)))))

(ert-deftest hernes-test-resume-running-session-errors ()
  "`hernes-resume' refuses a session that is not finished."
  (let ((session (hernes--make-session :root default-directory :finished nil)))
    (should-error (hernes-resume session "hello") :type 'user-error)))

(ert-deftest hernes-test-resume-runs-loop-to-completion ()
  "After `hernes-resume', the turn loop runs and ON-DONE fires again, headless
(no buffer)."
  (let ((done nil))
    (cl-letf (((symbol-function 'hernes--send-request)
               (lambda (session)
                 (setf (hernes-session-pending-text session) "second answer")
                 (hernes--finalize-done session "second answer"))))
      (let ((session (hernes-loop :task "first" :root default-directory :buffer nil
                                  :on-done (lambda (r) (setq done r)))))
        (should (eq (plist-get done :status) 'done))
        (setq done nil)
        (hernes-resume session "continue please")
        (should (eq (plist-get done :status) 'done))
        (should (equal (plist-get done :result) "second answer"))
        (should (member '(prompt . "continue please") (hernes-session-messages session)))))))

;;;; plan mode (read-only tool filter + mode setter)

(ert-deftest hernes-test-mode-filter-plan-hides-side-effects ()
  "`plan' mode, like `chat', exposes only read-only tools."
  (let* ((tools (hernes--all-tools))
         (plan (hernes--tools-for-mode 'plan tools))
         (names (mapcar (lambda (tl) (plist-get tl :name)) plan)))
    (should (member "read_file" names))
    (should (member "grep" names))
    (should (member "list_files" names))
    (should (member "git_diff" names))
    (should-not (member "write_file" names))
    (should-not (member "run_command" names))
    (should-not (member "git_checkpoint" names))
    ;; No exposed tool has a side effect.
    (should-not (cl-some (lambda (tl) (plist-get tl :side-effect)) plan))))

(ert-deftest hernes-test-set-mode-validates ()
  "`hernes-set-mode' accepts chat/plan/auto and rejects anything else."
  (let ((s (hernes--make-session :mode 'chat)))
    (hernes-set-mode s 'auto)
    (should (eq (hernes-session-mode s) 'auto))
    (hernes-set-mode s 'plan)
    (should (eq (hernes-session-mode s) 'plan))
    (hernes-set-mode s 'chat)
    (should (eq (hernes-session-mode s) 'chat))
    ;; Invalid modes error and do not mutate the session.
    (should-error (hernes-set-mode s 'wild) :type 'error)
    (should-error (hernes-set-mode s nil) :type 'error)
    (should (eq (hernes-session-mode s) 'chat))))

;;;; Send-time tool filter (mode change re-filters the next request)

(ert-deftest hernes-test-send-request-refilters-tools-per-mode ()
  "Changing a session's mode changes the tool set of the NEXT send.
`gptel-request' is stubbed to read the dynamically-bound `gptel-tools' that
`hernes--send-request' computes, so we observe the filter at send time."
  (let ((captured nil))
    (cl-letf (((symbol-function 'gptel-request)
               (lambda (_prompt &rest _args)
                 (push (mapcar #'gptel-tool-name gptel-tools) captured)
                 nil)))
      (let ((session (hernes--make-session
                      :root default-directory
                      :mode 'auto
                      :backend hernes-backend
                      :system "sys"
                      :tools (hernes--all-tools)
                      :messages (list (cons 'prompt "x")))))
        ;; auto -> every tool, including side-effecting ones.
        (hernes--send-request session)
        ;; chat -> side-effect tools filtered out on the same session.
        (hernes-set-mode session 'chat)
        (hernes--send-request session)))
    (let ((chat-names (nth 0 captured))     ;most recent send first
          (auto-names (nth 1 captured)))
      (should (member "write_file" auto-names))
      (should (member "run_command" auto-names))
      (should (member "read_file" chat-names))
      (should-not (member "write_file" chat-names))
      (should-not (member "run_command" chat-names)))))

(ert-deftest hernes-test-effective-system-plan-appends-prompt ()
  "`plan' mode appends `hernes-plan-prompt'; other modes send the base prompt."
  (let ((session (hernes--make-session :system "BASE" :mode 'chat)))
    (should (equal (hernes--effective-system session) "BASE"))
    (hernes-set-mode session 'auto)
    (should (equal (hernes--effective-system session) "BASE"))
    (hernes-set-mode session 'plan)
    (should (equal (hernes--effective-system session)
                   (concat "BASE\n\n" hernes-plan-prompt)))))

;;;; Lazy git safety net (hernes--ensure-git)

(ert-deftest hernes-test-ensure-git-only-touches-git-for-auto ()
  "`hernes--ensure-git' runs the branch setup only for auto mode not yet ready.
The git process is stubbed, so we assert whether it was reached rather than
running git."
  (let ((called nil))
    (cl-letf (((symbol-function 'hernes--git-start)
               (lambda (_id _root done) (setq called t) (funcall done t nil))))
      ;; chat: immediate ok, git untouched.
      (let (res)
        (hernes--ensure-git (hernes--make-session :mode 'chat)
                            (lambda (ok reason) (setq res (list ok reason))))
        (should (equal res '(t nil)))
        (should-not called))
      ;; plan: immediate ok, git untouched.
      (setq called nil)
      (let (res)
        (hernes--ensure-git (hernes--make-session :mode 'plan)
                            (lambda (ok reason) (setq res (list ok reason))))
        (should (equal res '(t nil)))
        (should-not called))
      ;; auto but already prepared: immediate ok, git untouched.
      (setq called nil)
      (let (res)
        (hernes--ensure-git (hernes--make-session :mode 'auto :git-ready t)
                            (lambda (ok reason) (setq res (list ok reason))))
        (should (equal res '(t nil)))
        (should-not called))
      ;; auto and not prepared: runs setup, marks git-ready.
      (setq called nil)
      (let ((s (hernes--make-session :mode 'auto)) res)
        (hernes--ensure-git s (lambda (ok reason) (setq res (list ok reason))))
        (should called)
        (should (equal res '(t nil)))
        (should (hernes-session-git-ready s))))))

(ert-deftest hernes-test-ensure-git-propagates-failure ()
  "A failed branch setup is reported as (nil REASON) and leaves git not ready."
  (cl-letf (((symbol-function 'hernes--git-start)
             (lambda (_id _root done)
               (funcall done nil "working tree is dirty; commit or stash first"))))
    (let ((s (hernes--make-session :mode 'auto)) res)
      (hernes--ensure-git s (lambda (ok reason) (setq res (list ok reason))))
      (should (equal res '(nil "working tree is dirty; commit or stash first")))
      (should-not (hernes-session-git-ready s)))))

;;;; UI input extraction (pure buffer read)

(ert-deftest hernes-test-ui-input-string-extraction ()
  "`hernes-ui--input-string' returns exactly the editable region, and transcript
output inserted before the prompt does not disturb it."
  (with-temp-buffer
    (hernes-ui-mode)
    (let ((inhibit-read-only t))
      (hernes-ui--insert-ro "transcript line\n" nil)
      (let ((prefix-start (point)))
        (hernes-ui--insert-ro hernes-ui-prompt nil)
        (setq hernes-ui--input-marker (copy-marker (point) nil))
        (setq hernes-ui--prompt-marker (copy-marker prefix-start t))))
    ;; Empty input area reads as the empty string.
    (should (equal (hernes-ui--input-string) ""))
    ;; Typed input, including multiple lines, is returned verbatim.
    (goto-char (point-max))
    (insert "hello world")
    (should (equal (hernes-ui--input-string) "hello world"))
    (insert "\nsecond line")
    (should (equal (hernes-ui--input-string) "hello world\nsecond line"))
    ;; Rendering transcript output lands before the prompt and leaves input intact.
    (hernes-ui--render (current-buffer) "model says hi\n" nil)
    (should (equal (hernes-ui--input-string) "hello world\nsecond line"))
    (should (string-match-p "model says hi"
                            (buffer-substring-no-properties
                             (point-min) hernes-ui--input-marker)))))

(ert-deftest hernes-test-ui-transcript-is-read-only ()
  "Transcript and prompt text carry a `read-only' property; input does not."
  (with-temp-buffer
    (hernes-ui-mode)
    (let ((inhibit-read-only t))
      (hernes-ui--insert-ro "transcript line\n" nil)
      (let ((prefix-start (point)))
        (hernes-ui--insert-ro hernes-ui-prompt nil)
        (setq hernes-ui--input-marker (copy-marker (point) nil))
        (setq hernes-ui--prompt-marker (copy-marker prefix-start t))))
    (goto-char (point-max))
    (insert "typed input")
    ;; Editing the transcript is blocked by the read-only text property...
    (should-error (progn (goto-char (point-min)) (delete-char 1))
                  :type 'text-read-only)
    ;; ...while the typed input remains freely editable.
    (goto-char (point-max))
    (delete-char -1)
    (should (equal (hernes-ui--input-string) "typed inpu"))))

;;;; !command and @mention input constructs (hernes-ui.el)

(defun hernes-ui-test--make-input-buffer (root input)
  "Return a fresh `hernes-ui-mode' buffer rooted at ROOT with INPUT typed in.
Mirrors the marker setup the real UI does in `hernes-ui--new-buffer', minus the
banner text, so `hernes-ui-send' and friends operate on it exactly as they
would on a live session buffer."
  (let ((buf (generate-new-buffer " *hernes-ui-test*")))
    (with-current-buffer buf
      (hernes-ui-mode)
      (setq hernes-ui--root root)
      (let ((inhibit-read-only t))
        (let ((prefix-start (point)))
          (hernes-ui--insert-ro hernes-ui-prompt nil)
          (setq hernes-ui--input-marker (copy-marker (point) nil))
          (setq hernes-ui--prompt-marker (copy-marker prefix-start t))))
      (goto-char (point-max))
      (insert input))
    buf))

(defun hernes-ui-test--count-substr (needle haystack)
  "Return the number of non-overlapping occurrences of NEEDLE in HAYSTACK."
  (let ((count 0) (start 0))
    (while (string-match (regexp-quote needle) haystack start)
      (setq count (1+ count) start (match-end 0)))
    count))

;;;;; (a) !command detection and non-interference

(ert-deftest hernes-test-ui-bang-dispatch ()
  "`hernes-ui-send' routes `!...' input to `hernes-ui--send-bang' only."
  (let ((bang-arg nil) (first-called nil))
    (cl-letf (((symbol-function 'hernes-ui--send-bang)
               (lambda (input) (setq bang-arg input)))
              ((symbol-function 'hernes-ui--send-first)
               (lambda (_input) (setq first-called t))))
      (let ((buf (hernes-ui-test--make-input-buffer default-directory "!echo hi")))
        (unwind-protect
            (with-current-buffer buf
              (hernes-ui-send)
              (should (equal bang-arg "!echo hi"))
              (should-not first-called))
          (kill-buffer buf))))))

(ert-deftest hernes-test-ui-non-bang-input-does-not-dispatch-bang ()
  "Ordinary input never reaches `hernes-ui--send-bang' and flows to the normal
send path unchanged (no pending context, no mentions to expand)."
  (let ((bang-called nil) (first-arg nil))
    (cl-letf (((symbol-function 'hernes-ui--send-bang)
               (lambda (_input) (setq bang-called t)))
              ((symbol-function 'hernes-ui--send-first)
               (lambda (input) (setq first-arg input))))
      (let ((buf (hernes-ui-test--make-input-buffer default-directory "hello there")))
        (unwind-protect
            (with-current-buffer buf
              (hernes-ui-send)
              (should-not bang-called)
              (should (equal first-arg "hello there")))
          (kill-buffer buf))))))

;;;;; (b) @path expansion (pure function)

(ert-deftest hernes-test-expand-mentions-existing-file ()
  "An existing `@path' mention gets an appended <context> block; the literal
mention stays untouched in the returned text."
  (let ((root (file-name-as-directory (file-truename (make-temp-file "hernes-test" t)))))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "a.txt" root) (insert "hello world"))
          (let ((out (hernes-ui--expand-mentions "look at @a.txt please" root)))
            (should (string-match-p "look at @a.txt please" out))
            (should (string-match-p "<context file=\"a\\.txt\">" out))
            (should (string-match-p "hello world" out))
            (should (string-match-p "</context>" out))))
      (delete-directory root t))))

(ert-deftest hernes-test-expand-mentions-nonexistent-file-untouched ()
  "A mention that does not resolve to a real file under ROOT is left as-is."
  (let ((root (file-name-as-directory (file-truename (make-temp-file "hernes-test" t)))))
    (unwind-protect
        (let ((out (hernes-ui--expand-mentions "see @missing.txt" root)))
          (should (equal out "see @missing.txt"))
          (should-not (string-match-p "<context" out)))
      (delete-directory root t))))

(ert-deftest hernes-test-expand-mentions-escaping-path-untouched ()
  "A mention escaping ROOT via `..' is left as-is (guarded by `hernes--path-safe-p')."
  (let ((root (file-name-as-directory (file-truename (make-temp-file "hernes-test" t)))))
    (unwind-protect
        (let ((out (hernes-ui--expand-mentions "see @../secret" root)))
          (should (equal out "see @../secret"))
          (should-not (string-match-p "<context" out)))
      (delete-directory root t))))

(ert-deftest hernes-test-expand-mentions-truncates ()
  "Expanded content is truncated via `hernes--truncate-output'."
  (let ((root (file-name-as-directory (file-truename (make-temp-file "hernes-test" t))))
        (hernes-max-tool-output 10))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "big.txt" root)
            (insert (make-string 100 ?x)))
          (let ((out (hernes-ui--expand-mentions "@big.txt" root)))
            (should (string-match-p "\\[hernes\\] \\.\\.\\.output truncated at 10 chars\\]" out))))
      (delete-directory root t))))

(ert-deftest hernes-test-expand-mentions-dedups-repeated-mentions ()
  "The same path mentioned twice only produces one <context> block."
  (let ((root (file-name-as-directory (file-truename (make-temp-file "hernes-test" t)))))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "a.txt" root) (insert "x"))
          (let ((out (hernes-ui--expand-mentions "@a.txt and again @a.txt" root)))
            (should (= 1 (hernes-ui-test--count-substr "<context file=\"a.txt\">" out)))))
      (delete-directory root t))))

;;;;; (c) @path completion-at-point

(ert-deftest hernes-test-ui-capf-boundary-and-candidates ()
  "`hernes-ui--capf' returns the boundary right after `@' and project files."
  (let ((root (file-name-as-directory (file-truename (make-temp-file "hernes-test" t)))))
    (unwind-protect
        (progn
          (let ((default-directory root))
            (call-process "git" nil nil nil "init" "-q"))
          (with-temp-file (expand-file-name "foo.el" root) (insert ";; foo"))
          (with-temp-file (expand-file-name "bar.txt" root) (insert "bar"))
          (let ((buf (hernes-ui-test--make-input-buffer root "look at @fo")))
            (unwind-protect
                (with-current-buffer buf
                  (goto-char (point-max))
                  (let* ((res (hernes-ui--capf))
                         (start (nth 0 res))
                         (end (nth 1 res))
                         (candidates (nth 2 res)))
                    (should (equal (buffer-substring-no-properties start end) "fo"))
                    (should (member "foo.el" candidates))
                    (should (member "bar.txt" candidates))))
              (kill-buffer buf))))
      (delete-directory root t))))

(ert-deftest hernes-test-ui-capf-nil-outside-mention ()
  "`hernes-ui--capf' returns nil when point is not inside an `@' token."
  (let ((buf (hernes-ui-test--make-input-buffer default-directory "just plain text")))
    (unwind-protect
        (with-current-buffer buf
          (goto-char (point-max))
          (should (null (hernes-ui--capf))))
      (kill-buffer buf))))

(ert-deftest hernes-test-ui-capf-nil-before-input-marker ()
  "`hernes-ui--capf' never fires on the read-only transcript/prompt above the
input area, even if it happens to contain an `@'."
  (let ((buf (hernes-ui-test--make-input-buffer default-directory "@mention")))
    (unwind-protect
        (with-current-buffer buf
          (goto-char (point-min))
          (should (null (hernes-ui--capf))))
      (kill-buffer buf))))

;;;;; (d) pending !-context queue merges into the next send

(ert-deftest hernes-test-ui-pending-shell-context-merges-into-first-send ()
  "A `!' result queued before any session exists is prepended to the first send
and the queue is flushed afterward."
  (let ((buf (hernes-ui-test--make-input-buffer default-directory "implement the feature")))
    (unwind-protect
        (with-current-buffer buf
          (hernes-ui--queue-shell-context "ls" "file1\nfile2")
          (should hernes-ui--pending-shell-context)
          (let (captured)
            (cl-letf (((symbol-function 'hernes-ui--send-first)
                       (lambda (input) (setq captured input))))
              (hernes-ui-send))
            (should (string-match-p "I ran `ls` myself" captured))
            (should (string-match-p "file1\nfile2" captured))
            (should (string-match-p "implement the feature" captured))
            (should (null hernes-ui--pending-shell-context))))
      (kill-buffer buf))))

(ert-deftest hernes-test-ui-shell-context-pushed-directly-when-session-finished ()
  "A `!' result folds straight into a finished session via `hernes--push-message',
never touching the pending queue."
  (let ((buf (hernes-ui-test--make-input-buffer default-directory "")))
    (unwind-protect
        (with-current-buffer buf
          (setq hernes-ui--session
                (hernes--make-session :root default-directory :finished t :messages nil))
          (hernes-ui--queue-shell-context "pwd" "/tmp")
          (should (null hernes-ui--pending-shell-context))
          (should (equal (car (hernes-session-messages hernes-ui--session))
                         (cons 'prompt "I ran `pwd` myself. Output:\n/tmp"))))
      (kill-buffer buf))))

(ert-deftest hernes-test-ui-shell-context-queued-while-session-running ()
  "A `!' result queues (not pushes) while the session is still running."
  (let ((buf (hernes-ui-test--make-input-buffer default-directory "")))
    (unwind-protect
        (with-current-buffer buf
          (setq hernes-ui--session
                (hernes--make-session :root default-directory :finished nil :messages nil))
          (hernes-ui--queue-shell-context "pwd" "/tmp")
          (should hernes-ui--pending-shell-context)
          (should (null (hernes-session-messages hernes-ui--session))))
      (kill-buffer buf))))

;;;; Streaming + thinking (reasoning) display

;;;;; (a) assistant text chunks concatenate into pending-text

(ert-deftest hernes-test-stream-callback-concatenates-chunks ()
  "`hernes--turn-callback' accumulates streamed string chunks (does not replace).
The turn starts with an empty pending-text, and two chunks arriving in sequence
leave their concatenation."
  (let ((session (hernes--make-session :root default-directory :pending-text "")))
    (hernes--turn-callback session "Hello, " nil)
    (hernes--turn-callback session "world" nil)
    (should (equal (hernes-session-pending-text session) "Hello, world"))))

;;;;; (b) reasoning never enters the conversation context

(ert-deftest hernes-test-stream-reasoning-not-in-messages ()
  "Reasoning chunks are display-only: they touch neither the message list nor
pending-text, so they cannot re-enter the context on later turns."
  (let ((session (hernes--make-session :root default-directory
                                       :pending-text "" :messages nil)))
    (hernes--turn-callback session '(reasoning . "let me think ") nil)
    (hernes--turn-callback session '(reasoning . "about it") nil)
    (hernes--turn-callback session '(reasoning . t) nil)
    (should (null (hernes-session-messages session)))
    (should (equal (hernes-session-pending-text session) ""))))

;;;;; (c) send-request routes chunks to on-stream / reasoning to on-thinking

(ert-deftest hernes-test-send-request-routes-stream-and-reasoning ()
  "With `gptel-request' stubbed to emit a streamed turn, `hernes--send-request'
routes text chunks to on-stream and reasoning conses to on-thinking, concatenates
the text into pending-text, and keeps reasoning out of the messages."
  (let ((streamed nil) (thought nil))
    (cl-letf (((symbol-function 'gptel-request)
               (lambda (_prompt &rest args)
                 (let ((cb (plist-get args :callback)))
                   ;; thinking phase, then the answer, then stream success.
                   (funcall cb '(reasoning . "hmm ") nil)
                   (funcall cb '(reasoning . t) nil)
                   (funcall cb "the " nil)
                   (funcall cb "answer" nil)
                   (funcall cb t nil))
                 nil)))
      (let ((session (hernes--make-session
                      :root default-directory
                      :mode 'chat
                      :backend hernes-backend
                      :system "sys"
                      :tools (hernes--all-tools)
                      :pending-text ""
                      :messages (list (cons 'prompt "x"))
                      :on-stream (lambda (c) (push c streamed))
                      :on-thinking (lambda (c) (push c thought)))))
        (hernes--send-request session)
        (should (equal (nreverse streamed) '("the " "answer")))
        (should (equal (nreverse thought) '("hmm " t)))
        (should (equal (hernes-session-pending-text session) "the answer"))
        ;; No reasoning (or streamed text) leaked into the conversation.
        (should-not (cl-find 'reasoning (hernes-session-messages session)
                             :key #'car-safe))
        (should (equal (hernes-session-messages session)
                       (list (cons 'prompt "x"))))))))

;;;;; (d) headless: no callbacks, chunks are silently ignored

(ert-deftest hernes-test-stream-headless-ignores-chunks ()
  "With no on-stream/on-thinking (the headless default), streamed text and
reasoning chunks are accepted without error: text still accumulates, reasoning
is dropped, and nothing is pushed as a message."
  (let ((session (hernes--make-session :root default-directory
                                       :pending-text "" :messages nil)))
    (hernes--turn-callback session "chunk" nil)
    (hernes--turn-callback session '(reasoning . "think") nil)
    (hernes--turn-callback session '(reasoning . t) nil)
    (should (equal (hernes-session-pending-text session) "chunk"))
    (should (null (hernes-session-messages session)))))

;;;;; UI: header spinner + no double render of streamed text

(ert-deftest hernes-test-ui-header-shows-running-spinner ()
  "The header line shows a spinner glyph and an elapsed-seconds counter while
running, and `idle' otherwise."
  (with-temp-buffer
    (hernes-ui-mode)
    (setq hernes-ui--running t
          hernes-ui--spinner-start (current-time)
          hernes-ui--spinner-index 3)
    (let ((h (hernes-ui--header-string)))
      (should (string-match-p "running" h))
      (should (string-match-p "[0-9]+s" h))
      (should (string-match-p (regexp-quote
                               (aref hernes-ui--spinner-glyphs 3))
                              h)))
    (setq hernes-ui--running nil)
    (should (string-match-p "idle" (hernes-ui--header-string)))))

(ert-deftest hernes-test-ui-stream-not-double-rendered ()
  "Assistant text shown live by the on-stream callback is not rendered a second
time by the on-turn callback (the double-render guard via `stream-active')."
  (let ((buf (hernes-ui-test--make-input-buffer default-directory "")))
    (unwind-protect
        (with-current-buffer buf
          (let ((on-stream (hernes-ui--on-stream-fn buf))
                (on-turn (hernes-ui--on-turn-fn buf)))
            (funcall on-stream "Hello ")
            (funcall on-stream "there")
            (funcall on-turn (list :turn 1 :text "Hello there" :results nil)))
          (let ((transcript (buffer-substring-no-properties
                             (point-min) hernes-ui--input-marker)))
            (should (= 1 (hernes-ui-test--count-substr "Hello there" transcript)))))
      (kill-buffer buf))))

(ert-deftest hernes-test-ui-stream-disabled-renders-once ()
  "When streaming does not engage (no on-stream fired), the on-turn callback
still renders the assistant text exactly once (the fallback path)."
  (let ((buf (hernes-ui-test--make-input-buffer default-directory "")))
    (unwind-protect
        (with-current-buffer buf
          (funcall (hernes-ui--on-turn-fn buf)
                   (list :turn 1 :text "plain answer" :results nil))
          (let ((transcript (buffer-substring-no-properties
                             (point-min) hernes-ui--input-marker)))
            (should (= 1 (hernes-ui-test--count-substr "plain answer" transcript)))))
      (kill-buffer buf))))

;;;; Collapsible thinking blocks (hernes-ui.el)

(defun hernes-ui-test--make-thinking-buffer ()
  "Return a fresh `hernes-ui-mode' buffer with prompt/input markers set up, for
thinking-block tests.  Mirrors `hernes-ui-test--make-input-buffer' minus a
root and typed input, since these tests drive `hernes-ui--on-thinking-fn'
directly and never call `hernes-ui-send'."
  (let ((buf (generate-new-buffer " *hernes-ui-thinking-test*")))
    (with-current-buffer buf
      (hernes-ui-mode)
      (let ((inhibit-read-only t))
        (let ((prefix-start (point)))
          (hernes-ui--insert-ro hernes-ui-prompt nil)
          (setq hernes-ui--input-marker (copy-marker (point) nil))
          (setq hernes-ui--prompt-marker (copy-marker prefix-start t))))
      (goto-char (point-max)))
    buf))

;;;;; (a) closing a block wraps its body in a togglable-invisible overlay

(ert-deftest hernes-test-ui-thinking-block-overlay-toggles-invisible ()
  "After a reasoning block closes (`(reasoning . t)'), its body sits under an
overlay whose `invisible' property can be toggled directly."
  (let ((buf (hernes-ui-test--make-thinking-buffer)))
    (unwind-protect
        (let ((on-thinking (hernes-ui--on-thinking-fn buf))
              block)
          (funcall on-thinking "hmm, let me ")
          (funcall on-thinking "think about it")
          (with-current-buffer buf (setq block hernes-ui--thinking-open-block))
          (funcall on-thinking t)
          (should (overlayp (hernes-ui--thinking-block-overlay block)))
          (let ((ov (hernes-ui--thinking-block-overlay block)))
            (overlay-put ov 'invisible nil)
            (should-not (overlay-get ov 'invisible))
            (overlay-put ov 'invisible t)
            (should (overlay-get ov 'invisible))))
      (kill-buffer buf))))

;;;;; (b) `hernes-ui-thinking-collapse-on-done' governs the initial closed state

(ert-deftest hernes-test-ui-thinking-collapse-on-done-controls-initial-state ()
  "With the default t, a closed block starts collapsed (overlay invisible,
`open' nil); with nil it starts still expanded (overlay visible, `open' t)."
  (let ((buf (hernes-ui-test--make-thinking-buffer)))
    (unwind-protect
        (let ((hernes-ui-thinking-collapse-on-done t)
              (on-thinking (hernes-ui--on-thinking-fn buf))
              block)
          (funcall on-thinking "reasoning...")
          (with-current-buffer buf (setq block hernes-ui--thinking-open-block))
          (funcall on-thinking t)
          (should-not (hernes-ui--thinking-block-open block))
          (should (overlay-get (hernes-ui--thinking-block-overlay block) 'invisible)))
      (kill-buffer buf)))
  (let ((buf (hernes-ui-test--make-thinking-buffer)))
    (unwind-protect
        (let ((hernes-ui-thinking-collapse-on-done nil)
              (on-thinking (hernes-ui--on-thinking-fn buf))
              block)
          (funcall on-thinking "reasoning...")
          (with-current-buffer buf (setq block hernes-ui--thinking-open-block))
          (funcall on-thinking t)
          (should (hernes-ui--thinking-block-open block))
          (should-not (overlay-get (hernes-ui--thinking-block-overlay block) 'invisible)))
      (kill-buffer buf))))

;;;;; (c) the toggle command flips the ▾/▸ glyph and the closed-state summary

(ert-deftest hernes-test-ui-thinking-toggle-updates-glyph-and-summary ()
  "`hernes-ui-thinking-toggle', run with point on the header line, flips the
▾/▸ glyph and shows the elapsed-time/char-count summary only while collapsed."
  (let ((buf (hernes-ui-test--make-thinking-buffer)))
    (unwind-protect
        (let ((hernes-ui-thinking-collapse-on-done t)
              (on-thinking (hernes-ui--on-thinking-fn buf))
              block)
          (funcall on-thinking "some reasoning text")
          (with-current-buffer buf (setq block hernes-ui--thinking-open-block))
          (funcall on-thinking t)
          (with-current-buffer buf
            (should (string-match-p
                     "▸ thinking ("
                     (buffer-substring-no-properties
                      (hernes-ui--thinking-block-header-start block)
                      (hernes-ui--thinking-block-header-end block))))
            (goto-char (hernes-ui--thinking-block-header-start block))
            (hernes-ui-thinking-toggle)
            (should (hernes-ui--thinking-block-open block))
            (should (string-match-p
                     "▾ thinking"
                     (buffer-substring-no-properties
                      (hernes-ui--thinking-block-header-start block)
                      (hernes-ui--thinking-block-header-end block))))
            (hernes-ui-thinking-toggle)
            (should-not (hernes-ui--thinking-block-open block))))
      (kill-buffer buf))))

;;;;; (d) multiple blocks toggle independently

(ert-deftest hernes-test-ui-thinking-multiple-blocks-toggle-independently ()
  "Two thinking blocks in the same buffer toggle independently: expanding one
leaves the other's collapsed state untouched."
  (let ((buf (hernes-ui-test--make-thinking-buffer)))
    (unwind-protect
        (let ((hernes-ui-thinking-collapse-on-done t)
              (on-thinking (hernes-ui--on-thinking-fn buf))
              block1 block2)
          (funcall on-thinking "first block reasoning")
          (with-current-buffer buf (setq block1 hernes-ui--thinking-open-block))
          (funcall on-thinking t)
          (funcall on-thinking "second block reasoning")
          (with-current-buffer buf (setq block2 hernes-ui--thinking-open-block))
          (funcall on-thinking t)
          (should (overlay-get (hernes-ui--thinking-block-overlay block1) 'invisible))
          (should (overlay-get (hernes-ui--thinking-block-overlay block2) 'invisible))
          (with-current-buffer buf
            (goto-char (hernes-ui--thinking-block-header-start block1))
            (hernes-ui-thinking-toggle))
          (should-not (overlay-get (hernes-ui--thinking-block-overlay block1) 'invisible))
          (should (overlay-get (hernes-ui--thinking-block-overlay block2) 'invisible)))
      (kill-buffer buf))))

(provide 'hernes-test)
;;; hernes-test.el ends here
