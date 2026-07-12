;;; hernes-ui.el --- Session-buffer UI for hernes -*- lexical-binding: t; -*-

;; Author: gr8distance
;; Version: 0.1.0-P-A
;; Package-Requires: ((emacs "29.1") (hernes "0.1.0"))
;; Keywords: tools, convenience, llm
;; URL: https://github.com/gr8distance/hernes.el

;;; Commentary:

;; A Claude-Code-style conversation buffer for hernes.  `M-x hernes' opens a
;; per-project session buffer `*hernes: <id>*' instead of driving the agent
;; through the minibuffer: the top of the buffer is a read-only transcript and
;; the bottom is a multi-line input area following the prompt marker `❯ '.
;;
;; This file is the UI layer only; the harness core (hernes.el) stays headless.
;; It reuses the headless API: `hernes--init-session' + `hernes--run-turn' for a
;; first send (so `hernes--ensure-git' can gate `auto' mode), and `hernes-resume'
;; to continue a finished session.
;;
;; Buffer layout and markers
;; --------------------------
;; The buffer always ends with the input prompt:
;;
;;   <transcript, read-only> ...
;;   ❯ <editable input, possibly multi-line>
;;
;; Two markers manage the boundary:
;;   `hernes-ui--prompt-marker'  points at the `❯' glyph, insertion-type t, so
;;      transcript text inserted at it lands BEFORE the prompt and the marker
;;      rides along to stay pinned to the prompt.
;;   `hernes-ui--input-marker'   points at the first editable character (just
;;      after `❯ '); it sits after the prompt marker, so any transcript
;;      insertion shifts it forward automatically.
;; The transcript and the `❯ ' prefix carry a `read-only' text property with
;; `rear-nonsticky' so that text the human types after the prefix is editable
;; while everything above stays immutable.  Input is the substring from
;; `hernes-ui--input-marker' to `point-max'.

;;; Code:

(require 'hernes)
(require 'cl-lib)
(require 'subr-x)
(require 'project)

;;;; Customization

(defgroup hernes-ui nil
  "Session-buffer UI for the hernes agent harness."
  :group 'hernes
  :prefix "hernes-ui-")

(defcustom hernes-ui-prompt "❯ "
  "Prompt string marking the start of the editable input area."
  :type 'string
  :group 'hernes-ui)

(defcustom hernes-ui-thinking-collapse-on-done t
  "Whether a thinking block auto-collapses once its reasoning finishes.
Non-nil (the default) hides the reasoning body as soon as `(reasoning . t)'
closes the block, leaving only the `▸ thinking (Ns, M chars)' summary header;
nil leaves it expanded until the human toggles it (TAB/RET/mouse-1 on the
header line). Either way the block is always shown expanded while it is still
streaming -- this only controls the state it lands in once done."
  :type 'boolean
  :group 'hernes-ui)

(defface hernes-ui-user-face
  '((t :inherit font-lock-keyword-face :weight bold))
  "Face for the human's messages echoed into the transcript."
  :group 'hernes-ui)

(defface hernes-ui-assistant-face
  '((t :inherit default))
  "Face for the model's natural-language replies."
  :group 'hernes-ui)

(defface hernes-ui-tool-face
  '((t :inherit shadow))
  "Face for tool-call log lines."
  :group 'hernes-ui)

(defface hernes-ui-error-face
  '((t :inherit error))
  "Face for refusals and error status lines."
  :group 'hernes-ui)

(defface hernes-ui-status-face
  '((t :inherit font-lock-comment-face))
  "Face for turn/completion status lines."
  :group 'hernes-ui)

(defface hernes-ui-thinking-face
  '((t :inherit shadow :slant italic))
  "Face for the model's live reasoning/thinking text.
Deliberately dim: thinking is shown to prove the model is working, not as part
of the answer, and it is never fed back into the conversation."
  :group 'hernes-ui)

(defconst hernes-ui--spinner-glyphs
  ["⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏"]
  "Braille spinner frames cycled in the header line while a turn is running.")

;;;; Buffer-local state

(defvar-local hernes-ui--session nil
  "The `hernes-session' driven from this buffer, or nil before the first send.")

(defvar-local hernes-ui--mode 'chat
  "Mode applied to this buffer's next send: `chat', `plan' or `auto'.
Kept in sync with the session's mode via `hernes-set-mode' once one exists.")

(defvar-local hernes-ui--root nil
  "Absolute project root for sessions started from this buffer.")

(defvar-local hernes-ui--id nil
  "Session id for this buffer (also the git branch suffix).")

(defvar-local hernes-ui--prompt-marker nil
  "Marker at the `❯' glyph; transcript output is inserted here.")

(defvar-local hernes-ui--input-marker nil
  "Marker at the first editable character of the input area.")

(defvar-local hernes-ui--running nil
  "Non-nil while a turn is in flight, for the header-line state.")

(defvar-local hernes-ui--stream-active nil
  "Non-nil while a live assistant text region is open in the transcript.
Set when the first stream chunk of a turn is rendered, cleared when the turn's
`on-turn'/`on-done' callback closes the region.  It tells those callbacks the
assistant text is already on screen so they do not render it a second time.")

(defvar-local hernes-ui--thinking-open-block nil
  "The `hernes-ui--thinking-block' currently streaming, or nil when none is open.
Set by `hernes-ui--open-thinking-block' on the first reasoning fragment of a
turn and cleared by `hernes-ui--close-thinking' once `(reasoning . t)' arrives;
see that section for the collapsible-header design.")

(defvar-local hernes-ui--spinner-timer nil
  "Repeating timer that refreshes the running header line, or nil when idle.")

(defvar-local hernes-ui--spinner-start nil
  "Time the current run started, for the header's elapsed-seconds counter.")

(defvar-local hernes-ui--spinner-index 0
  "Index into `hernes-ui--spinner-glyphs' for the current header frame.")

(defvar-local hernes-ui--bang-running nil
  "Non-nil while a `!command' (see `hernes-ui--send-bang') is executing.
Guards against overlapping human-run commands; the next `!' is refused until
this one's process sentinel clears the flag.")

(defvar-local hernes-ui--pending-shell-context nil
  "Queue of formatted `!command' results awaiting the next send.
Reverse-chronological (built with `push'); each element is a string of the
form documented in `hernes-ui--queue-shell-context'.  Flushed and cleared by
`hernes-ui--prepare-outgoing'.")

;;;; Read-only transcript rendering

(defconst hernes-ui--ro-props '(read-only t rear-nonsticky t front-sticky t)
  "Text properties that make a region immutable yet allow typing after it.")

(defun hernes-ui--insert-ro (text &optional face)
  "Insert TEXT at point as read-only transcript text, optionally in FACE.
Point must already be where the transcript should grow."
  (let ((start (point)))
    (insert (if face (propertize text 'face face) text))
    (add-text-properties start (point) hernes-ui--ro-props)))

(defun hernes-ui--render (buf text &optional face)
  "Append TEXT (optionally in FACE) to BUF's transcript, before the input area.
No-op if BUF is dead or not yet initialized.  The human's point and any typed
input are preserved."
  (when (and (buffer-live-p buf) text)
    (with-current-buffer buf
      (when (and hernes-ui--prompt-marker
                 (marker-position hernes-ui--prompt-marker))
        (let ((inhibit-read-only t))
          (save-excursion
            (goto-char hernes-ui--prompt-marker)
            (hernes-ui--insert-ro text face)))))))

;;;; Input area

(defun hernes-ui--input-string ()
  "Return the current text of the editable input area in the current buffer.
This is the substring from `hernes-ui--input-marker' to `point-max'; it is a
pure read of buffer state (no side effects), which is what the send command and
its tests exercise."
  (if (and hernes-ui--input-marker
           (marker-position hernes-ui--input-marker))
      (buffer-substring-no-properties hernes-ui--input-marker (point-max))
    ""))

(defun hernes-ui--clear-input ()
  "Delete the editable input area, leaving point at the (empty) prompt end."
  (let ((inhibit-read-only t))
    (delete-region hernes-ui--input-marker (point-max)))
  (goto-char (point-max)))

;;;; Header line

(defun hernes-ui--header-string ()
  "Return the header-line string: mode, model, turn count and idle/running.
While running the state field shows a cycling spinner glyph and the seconds
elapsed since the run started, so a long silent \"thinking\" phase still looks
alive."
  (let* ((session hernes-ui--session)
         (backend (if session (hernes-session-backend session) hernes-backend))
         (model (or (plist-get backend :model) "?"))
         (turns (if session (hernes-session-turn session) 0))
         (state (if hernes-ui--running
                    (let ((glyph (aref hernes-ui--spinner-glyphs
                                       (mod hernes-ui--spinner-index
                                            (length hernes-ui--spinner-glyphs))))
                          (elapsed (if hernes-ui--spinner-start
                                       (floor (float-time
                                               (time-subtract (current-time)
                                                              hernes-ui--spinner-start)))
                                     0)))
                      (format "%s running %ds" glyph elapsed))
                  "idle")))
    (format " [%s] %s  turns:%d  (%s)" hernes-ui--mode model turns state)))

(defun hernes-ui--update-header (buf)
  "Refresh BUF's header line from its current state."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (setq header-line-format (hernes-ui--header-string))
      (force-mode-line-update))))

(defun hernes-ui--start-spinner (buf)
  "Start (or restart) BUF's running-header spinner timer.
The timer captures BUF and cancels itself if BUF dies, so it cannot leak past
the buffer's lifetime even if `hernes-ui--stop-spinner' is somehow missed."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (hernes-ui--stop-spinner buf)
      (setq hernes-ui--spinner-start (current-time)
            hernes-ui--spinner-index 0)
      (let (timer)
        (setq timer
              (run-with-timer
               0.2 0.2
               (lambda ()
                 (if (buffer-live-p buf)
                     (with-current-buffer buf
                       (if hernes-ui--running
                           (progn (cl-incf hernes-ui--spinner-index)
                                  (hernes-ui--update-header buf))
                         (hernes-ui--stop-spinner buf)))
                   (cancel-timer timer)))))
        (setq hernes-ui--spinner-timer timer)))))

(defun hernes-ui--stop-spinner (buf)
  "Cancel BUF's spinner timer, if any."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (when (timerp hernes-ui--spinner-timer)
        (cancel-timer hernes-ui--spinner-timer))
      (setq hernes-ui--spinner-timer nil
            hernes-ui--spinner-start nil))))

(defun hernes-ui--cancel-spinner-on-kill ()
  "Cancel this buffer's spinner timer.  Installed on `kill-buffer-hook'."
  (when (timerp hernes-ui--spinner-timer)
    (cancel-timer hernes-ui--spinner-timer)
    (setq hernes-ui--spinner-timer nil)))

(defun hernes-ui--set-running (buf flag)
  "Set BUF's running FLAG, drive the spinner timer, and refresh its header."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (setq hernes-ui--running flag)
      (if flag
          (hernes-ui--start-spinner buf)
        (hernes-ui--stop-spinner buf))
      (hernes-ui--update-header buf))))

;;;; Thinking blocks (collapsible reasoning, DESIGN.md §7.2)
;;
;; Each reasoning burst from the model becomes one independently toggleable
;; block: a always-visible header line (`▾ thinking' while open, `▸ thinking
;; (Ns, M chars)' while collapsed) followed by a body of dim-face text.  The
;; header carries a `keymap' text property (TAB/RET/mouse-1 toggle) and a
;; `hernes-ui-thinking-block' text property pointing at the block's struct, so
;; the toggle commands below can find and mutate the right block regardless of
;; how many others exist in the buffer.  The body's visibility is controlled
;; by an overlay's `invisible' property -- the read-only text itself is never
;; touched, only hidden/shown.

(cl-defstruct (hernes-ui--thinking-block
               (:constructor hernes-ui--make-thinking-block)
               (:copier nil))
  "State for one collapsible reasoning block in a hernes-ui transcript.
Stored by reference as the `hernes-ui-thinking-block' text property on the
block's header line, so toggling mutates the same object the streaming code
created; each block's markers/overlay are independent of every other block's."
  header-start   ; marker at the header line's first character (the glyph)
  header-end     ; marker just past the header line's trailing newline
  body-start     ; marker at the first character of the body (set at open)
  overlay        ; invisibility overlay over the body, or nil until the block closes
  start-time     ; `current-time' when the block opened, for the elapsed-time summary
  elapsed        ; seconds spent reasoning, set by `hernes-ui--close-thinking'
  char-count     ; body length in characters, set by `hernes-ui--close-thinking'
  open)          ; non-nil while the body is visible

(defvar hernes-ui--thinking-header-keymap
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "TAB") #'hernes-ui-thinking-toggle)
    (define-key map (kbd "RET") #'hernes-ui-thinking-toggle)
    (define-key map [mouse-1] #'hernes-ui-thinking-toggle-mouse)
    map)
  "Keymap active, via the `keymap' text property, on a thinking-block header
line. TAB, RET and mouse-1 all toggle that block's body visibility. Being a
text-property keymap rather than part of `hernes-ui-mode-map', it only takes
effect with point on the header line and does not shadow those bindings
(e.g. RET-to-send) anywhere else in the buffer.")

(defun hernes-ui--thinking-header-glyph-text (block)
  "Return BLOCK's header line text (sans trailing newline) for its current state."
  (if (hernes-ui--thinking-block-open block)
      "▾ thinking"
    (format "▸ thinking (%ds, %d chars)"
            (or (hernes-ui--thinking-block-elapsed block) 0)
            (or (hernes-ui--thinking-block-char-count block) 0))))

(defun hernes-ui--insert-thinking-header (text block)
  "Insert TEXT (already newline-terminated) at point as BLOCK's header line.
Read-only like ordinary transcript text (see `hernes-ui--ro-props'), but also
carries `hernes-ui--thinking-header-keymap' and a `hernes-ui-thinking-block'
property pointing at BLOCK, so a toggle command run from anywhere on this line
finds the right block."
  (let ((start (point)))
    (insert (propertize text 'face 'hernes-ui-thinking-face))
    (add-text-properties start (point)
                          (append hernes-ui--ro-props
                                  (list 'keymap hernes-ui--thinking-header-keymap
                                        'hernes-ui-thinking-block block)))))

(defun hernes-ui--render-thinking-header (block)
  "Rewrite BLOCK's header line in place to match its current open/closed state.
Deletes the old header text between its `header-start'/`header-end' markers
and reinserts fresh text via `hernes-ui--insert-thinking-header', so the glyph
and (once closed) the elapsed-time/char-count summary stay in sync. Editing
this region shifts BLOCK's own `body-start' and any later block's markers
forward/backward automatically (they are markers), so nothing else needs
adjusting."
  (let ((inhibit-read-only t)
        (start (marker-position (hernes-ui--thinking-block-header-start block)))
        (end (marker-position (hernes-ui--thinking-block-header-end block))))
    (save-excursion
      (delete-region start end)
      (goto-char start)
      (hernes-ui--insert-thinking-header
       (concat (hernes-ui--thinking-header-glyph-text block) "\n") block)
      (set-marker (hernes-ui--thinking-block-header-end block) (point)))))

(defun hernes-ui--open-thinking-block (buf)
  "Open a new collapsible thinking block in BUF and return it.
Inserts a `▾ thinking' header at the transcript insertion point (see
`hernes-ui--render'), then records `hernes-ui--thinking-open-block' so
subsequent reasoning fragments (rendered the ordinary way, via
`hernes-ui--render') land in the block's body and `hernes-ui--close-thinking'
can finish it once `(reasoning . t)' arrives."
  (with-current-buffer buf
    (let ((inhibit-read-only t))
      (goto-char hernes-ui--prompt-marker)
      (let ((block (hernes-ui--make-thinking-block
                    :header-start (copy-marker (point) nil)
                    :start-time (current-time)
                    :open t)))
        (hernes-ui--insert-thinking-header "▾ thinking\n" block)
        (setf (hernes-ui--thinking-block-header-end block) (copy-marker (point) nil))
        (setf (hernes-ui--thinking-block-body-start block) (copy-marker (point) nil))
        (setq hernes-ui--thinking-open-block block)
        block))))

(defun hernes-ui--toggle-thinking-block (block)
  "Flip BLOCK's open/closed state and refresh its overlay and header.
A no-op (with a message) while BLOCK is still streaming: it has no overlay
yet (`hernes-ui--close-thinking' creates it), so there is nothing to hide
until the reasoning text is complete."
  (if (not (hernes-ui--thinking-block-overlay block))
      (message "hernes: this thinking block is still streaming.")
    (let ((open (not (hernes-ui--thinking-block-open block))))
      (setf (hernes-ui--thinking-block-open block) open)
      (overlay-put (hernes-ui--thinking-block-overlay block) 'invisible (not open))
      (hernes-ui--render-thinking-header block))))

(defun hernes-ui-thinking-toggle ()
  "Toggle the thinking block at point (bound to TAB/RET on its header line)."
  (interactive)
  (let ((block (get-text-property (point) 'hernes-ui-thinking-block)))
    (if block
        (hernes-ui--toggle-thinking-block block)
      (message "hernes: no thinking block at point."))))

(defun hernes-ui-thinking-toggle-mouse (event)
  "Toggle the thinking block clicked via mouse-1 EVENT.
Uses the click position rather than `point' since a mouse command may run
before point moves there."
  (interactive "e")
  (let* ((pos (posn-point (event-start event)))
         (block (and pos (get-text-property pos 'hernes-ui-thinking-block))))
    (if block
        (hernes-ui--toggle-thinking-block block)
      (message "hernes: no thinking block at point."))))

;;;; Session callbacks (render into the transcript)

(defun hernes-ui--on-stream-fn (buf)
  "Return an ON-STREAM callback appending each assistant CHUNK live into BUF.
The first chunk of a turn opens a live assistant region (via
`hernes-ui--stream-active'); subsequent chunks extend it.  The matching
`on-turn'/`on-done' callback closes the region and, seeing it was streamed,
skips re-rendering the same text (see `hernes-ui--close-stream')."
  (lambda (chunk)
    (when (and (buffer-live-p buf) (stringp chunk) (not (string-empty-p chunk)))
      (with-current-buffer buf
        (setq hernes-ui--stream-active t))
      (hernes-ui--render buf chunk 'hernes-ui-assistant-face))))

(defun hernes-ui--on-thinking-fn (buf)
  "Return an ON-THINKING callback rendering reasoning live into BUF.
A string PAYLOAD is a reasoning fragment streamed into the current thinking
block's body (opening a new collapsible block, see
`hernes-ui--open-thinking-block', on the first fragment of a turn); PAYLOAD t
closes the block via `hernes-ui--close-thinking'.  Reasoning is display-only
and is never part of the conversation the model sees on later turns."
  (lambda (payload)
    (when (buffer-live-p buf)
      (cond
       ((and (stringp payload) (not (string-empty-p payload)))
        (with-current-buffer buf
          (unless hernes-ui--thinking-open-block
            (hernes-ui--open-thinking-block buf)))
        (hernes-ui--render buf payload 'hernes-ui-thinking-face))
       ((eq payload t)
        (hernes-ui--close-thinking buf))))))

(defun hernes-ui--close-thinking (buf)
  "Close BUF's open thinking block, if any.
Measures elapsed time and body character count, wraps the body in an
invisibility overlay, applies the initial open/closed state from
`hernes-ui-thinking-collapse-on-done', and rewrites the header line (via
`hernes-ui--render-thinking-header') to show either the still-open glyph or
the collapsed summary."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (when hernes-ui--thinking-open-block
        (let* ((block hernes-ui--thinking-open-block)
               (body-start (marker-position (hernes-ui--thinking-block-body-start block)))
               (body-end (marker-position hernes-ui--prompt-marker))
               (elapsed (round (float-time
                                (time-subtract (current-time)
                                               (hernes-ui--thinking-block-start-time block)))))
               (char-count (max 0 (- body-end body-start)))
               (overlay (make-overlay body-start body-end)))
          (setf (hernes-ui--thinking-block-overlay block) overlay
                (hernes-ui--thinking-block-elapsed block) elapsed
                (hernes-ui--thinking-block-char-count block) char-count
                (hernes-ui--thinking-block-open block) (not hernes-ui-thinking-collapse-on-done))
          (overlay-put overlay 'invisible (not (hernes-ui--thinking-block-open block)))
          (overlay-put overlay 'hernes-ui-thinking-body block)
          (hernes-ui--render-thinking-header block)
          (setq hernes-ui--thinking-open-block nil)
          (hernes-ui--render buf "\n\n" 'hernes-ui-thinking-face))))))

(defun hernes-ui--close-stream (buf)
  "Close BUF's live assistant stream region, returning non-nil if one was open.
When a region was open the streamed text is already on screen, so the caller
must NOT render the turn/final text again -- it just terminates the region with
a blank line."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (when hernes-ui--stream-active
        (setq hernes-ui--stream-active nil)
        (hernes-ui--render buf "\n\n" 'hernes-ui-assistant-face)
        t))))

(defun hernes-ui--on-turn-fn (buf)
  "Return an ON-TURN callback that renders a turn's output into BUF."
  (lambda (payload)
    (when (buffer-live-p buf)
      (let ((text (plist-get payload :text))
            (results (plist-get payload :results)))
        (hernes-ui--close-thinking buf)
        ;; If the assistant text streamed in live, close that region instead of
        ;; drawing it again; otherwise (streaming disabled) render it once here.
        (unless (hernes-ui--close-stream buf)
          (when (and (stringp text) (not (string-empty-p (string-trim text))))
            (hernes-ui--render buf (format "%s\n\n" (string-trim text))
                               'hernes-ui-assistant-face)))
        (dolist (r results)
          (hernes-ui--render
           buf
           (format "  %s %s\n    %s%s\n"
                   (plist-get r :name)
                   (hernes--args-string (plist-get r :args))
                   (if (plist-get r :error) "[error] " "")
                   (hernes--summarize (plist-get r :result)))
           'hernes-ui-tool-face)))
      (hernes-ui--update-header buf))))

(defun hernes-ui--on-done-fn (buf)
  "Return an ON-DONE callback that renders completion into BUF and goes idle."
  (lambda (payload)
    (when (buffer-live-p buf)
      (let ((status (plist-get payload :status))
            (result (plist-get payload :result)))
        (hernes-ui--close-thinking buf)
        ;; Same double-render guard as on-turn: a text-only final turn streams
        ;; its answer with no on-turn call, so the region is still open here.
        (unless (hernes-ui--close-stream buf)
          (when (and (eq status 'done) (stringp result)
                     (not (string-empty-p (string-trim result))))
            (hernes-ui--render buf (format "%s\n\n" (string-trim result))
                               'hernes-ui-assistant-face)))
        (hernes-ui--render buf
                           (format "── %s: %s (turns: %s) ──\n\n"
                                   status
                                   (or (plist-get payload :reason) "")
                                   (plist-get payload :turns))
                           (if (eq status 'done)
                               'hernes-ui-status-face
                             'hernes-ui-error-face)))
      (hernes-ui--set-running buf nil))))

;;;; Sending

(defun hernes-ui-send ()
  "Send the input area as the next human message.
Semantics by session state: with no session yet, the input starts a new
`hernes-loop' (its text becomes the task); a finished session is continued with
`hernes-resume'; a running session is refused.  In `auto' mode the git safety
branch is ensured first, and a failure (e.g. a dirty tree) is shown in the
transcript instead of sending.

Two input constructs are special-cased ahead of the ordinary LLM-message path
(Claude-Code-style, see DESIGN.md §7):
  `!command'  is never sent to the model; it runs immediately as the human
              (see `hernes-ui--send-bang') and works even while a session is
              running, since it bypasses the loop entirely.
  `@path'     mentions inside an ordinary message are expanded into appended
              <context> blocks for the OUTGOING message only -- the transcript
              still echoes the human's literal input (see
              `hernes-ui--expand-mentions')."
  (interactive)
  (let* ((input (string-trim (hernes-ui--input-string)))
         (session hernes-ui--session))
    (cond
     ((string-empty-p input)
      (message "hernes: nothing to send."))
     ((string-prefix-p "!" input)
      (hernes-ui--send-bang input))
     ((and session (not (hernes-session-finished session)))
      (message "Session is still running."))
     (t
      (hernes-ui--clear-input)
      (hernes-ui--render (current-buffer) (format "%s\n\n" input)
                         'hernes-ui-user-face)
      (let ((outgoing (hernes-ui--prepare-outgoing input)))
        (if session
            (hernes-ui--send-resume session outgoing)
          (hernes-ui--send-first outgoing)))))))

(defun hernes-ui--send-first (input)
  "Start a new session in the current buffer with INPUT as the task."
  (let* ((buf (current-buffer))
         (session (hernes--init-session
                   :task input
                   :mode hernes-ui--mode
                   :root hernes-ui--root
                   :id hernes-ui--id
                   :buffer buf
                   :on-turn (hernes-ui--on-turn-fn buf)
                   :on-done (hernes-ui--on-done-fn buf)
                   :on-stream (hernes-ui--on-stream-fn buf)
                   :on-thinking (hernes-ui--on-thinking-fn buf))))
    (setq hernes-ui--session session)
    (hernes-ui--set-running buf t)
    (hernes--ensure-git
     session
     (lambda (ok reason)
       (when (buffer-live-p buf)
         (with-current-buffer buf
           (if ok
               (hernes--run-turn session)
             ;; Discard the ungated session so the next RET is a fresh start.
             (setq hernes-ui--session nil
                   hernes--session nil)
             (hernes-ui--set-running buf nil)
             (hernes-ui--render buf (format "Refusing to start: %s\n\n" reason)
                                'hernes-ui-error-face))))))))

(defun hernes-ui--send-resume (session input)
  "Continue a finished SESSION with INPUT from the current buffer."
  (let ((buf (current-buffer)))
    (hernes-ui--set-running buf t)
    (hernes--ensure-git
     session
     (lambda (ok reason)
       (when (buffer-live-p buf)
         (with-current-buffer buf
           (if ok
               (hernes-resume session input)
             ;; SESSION stays finished; the human can fix git and resend.
             (hernes-ui--set-running buf nil)
             (hernes-ui--render buf (format "Refusing to continue: %s\n\n" reason)
                                'hernes-ui-error-face))))))))

;;;; Special input constructs: !command and @mentions

(defun hernes-ui--flush-pending-shell-context ()
  "Return `hernes-ui--pending-shell-context' joined into one string, and clear it.
Returns nil when the queue is empty, so callers can tell \"nothing queued\"
apart from \"queued but empty\"."
  (when hernes-ui--pending-shell-context
    (prog1 (string-join (nreverse hernes-ui--pending-shell-context) "\n\n")
      (setq hernes-ui--pending-shell-context nil))))

(defun hernes-ui--prepare-outgoing (input)
  "Build the text actually sent to the model for the human's INPUT.
Any `!command' results queued while no session existed, or while one was
running (see `hernes-ui--queue-shell-context'), are flushed and prepended;
`@path' mentions in INPUT are then expanded into <context> blocks via
`hernes-ui--expand-mentions'.  The transcript echo of INPUT (done by the
caller, `hernes-ui-send') is unaffected -- only the text handed to
`hernes-ui--send-first' / `hernes-ui--send-resume' changes."
  (let ((pending (hernes-ui--flush-pending-shell-context))
        (expanded (hernes-ui--expand-mentions input hernes-ui--root)))
    (if pending (concat pending "\n\n" expanded) expanded)))

(defun hernes-ui--queue-shell-context (command output)
  "Fold a finished `!' COMMAND's OUTPUT into the conversation context.
If this buffer's session exists and is finished, the message is pushed onto it
directly via `hernes--push-message' -- this does NOT start a model turn, it
just makes the fact available to the next one.  Otherwise (no session yet, or
one still running) the message is queued in `hernes-ui--pending-shell-context'
and merged into the next outgoing send by `hernes-ui--prepare-outgoing'."
  (let ((text (format "I ran `%s` myself. Output:\n%s" command output))
        (session hernes-ui--session))
    (if (and session (hernes-session-finished session))
        (hernes--push-message session (cons 'prompt text))
      (push text hernes-ui--pending-shell-context))))

(defun hernes-ui--send-bang (input)
  "Handle a `!command' INPUT line: run the command as the human, not the model.
INPUT is the trimmed input area text starting with `!'; the part after `!' is
the shell command, run asynchronously in the project root via
`hernes--run-process' (shell `hernes-shell-file-name', timeout
`hernes-command-timeout').

Deliberately does NOT consult `hernes-command-deny-list': the deny-list bounds
what the MODEL may run unsupervised; a human typing `!rm -rf build' at their
own keyboard is exercising the same authority as running the command in a
shell directly (or `M-!' in Emacs), so gating it here would just be friction,
not safety.

Refuses to start a second `!' while one is already running
\(`hernes-ui--bang-running'); completion re-enables it.  The command line is
echoed to the transcript immediately, and the (truncated) output is appended
once the process exits and also queued into the conversation context via
`hernes-ui--queue-shell-context'."
  (if hernes-ui--bang-running
      (message "hernes: a `!' command is still running; wait for it to finish.")
    (let ((command (string-trim (substring input 1))))
      (if (string-empty-p command)
          (message "hernes: nothing to run after `!'.")
        (hernes-ui--clear-input)
        (hernes-ui--render (current-buffer) (format "! %s\n" command)
                           'hernes-ui-tool-face)
        (setq hernes-ui--bang-running t)
        (let ((buf (current-buffer))
              (root hernes-ui--root)
              ;; Reuse the live session for process/abort bookkeeping when one
              ;; exists; otherwise `hernes--run-process' only needs a session
              ;; shape to register the process on, so a throwaway one is fine.
              (proc-session (or hernes-ui--session (hernes--make-session :root hernes-ui--root))))
          (hernes--run-process
           proc-session "ui-bang" root
           (list hernes-shell-file-name "-c" command)
           hernes-command-timeout
           (lambda (out _err-p)
             (let ((output (hernes--truncate-output out)))
               (when (buffer-live-p buf)
                 (with-current-buffer buf
                   (setq hernes-ui--bang-running nil)
                   (hernes-ui--render buf (format "%s\n\n" output) 'hernes-ui-tool-face)
                   (hernes-ui--queue-shell-context command output)))))))))))

(defun hernes-ui--expand-mentions (text root)
  "Expand `@path' mentions in TEXT into appended <context> blocks.
Pure: no buffer or process state, safe to unit-test directly.  TEXT itself is
returned with its literal `@path/to/file' tokens intact -- only APPENDED
<context file=\"...\"> blocks carry the file content, one per distinct
existing path, in first-mention order, each truncated to
`hernes-max-tool-output' via `hernes--truncate-output'.

Mentions are found by simple whitespace splitting (Claude-Code-style `@'
tokens, not a general path grammar).  A token counts as a mention when it
resolves, via `hernes--path-safe-p' against ROOT, to an existing readable
regular file; anything else (a typo, a directory, a path escaping ROOT, or no
ROOT at all) is left as ordinary text in TEXT with no block appended, so the
model still sees the literal `@path' the human typed."
  (if (not (and (stringp root) (stringp text)))
      text
    (let ((seen nil)
          (blocks nil))
      (dolist (token (split-string text "[ \t\n\r]+" t))
        (when (and (> (length token) 1) (string-prefix-p "@" token))
          (let* ((path (substring token 1))
                 (abs (hernes--path-safe-p root path)))
            (when (and abs (not (member path seen))
                       (file-regular-p abs) (file-readable-p abs))
              (push path seen)
              (push (format "<context file=\"%s\">\n%s\n</context>"
                            path
                            (hernes--truncate-output
                             (with-temp-buffer
                               (insert-file-contents abs)
                               (buffer-string))))
                    blocks)))))
      (if blocks
          (concat text "\n\n" (string-join (nreverse blocks) "\n\n"))
        text))))

;;;; @path completion-at-point

(defun hernes-ui--project-file-candidates ()
  "Return project-relative file paths under `hernes-ui--root', or nil.
Backed by `project-files' via `project-current' rooted there; when no project
can be determined, no candidates are offered (rather than falling back to some
other directory)."
  (when hernes-ui--root
    (let ((proj (project-current nil hernes-ui--root)))
      (when proj
        (mapcar (lambda (f) (file-relative-name f hernes-ui--root))
                (project-files proj))))))

(defun hernes-ui--capf ()
  "`completion-at-point-functions' entry completing `@path' mentions.
Active only in the editable input area (at or after `hernes-ui--input-marker').
Finds the current whitespace-delimited token; if it starts with `@', the
completion boundary is right after the `@' (so candidates are plain project
paths, matching the convention that `@' itself is not part of what gets
completed) through point.  Returns nil outside such a token, so it defers to
other capfs via the standard `:exclusive' protocol."
  (when (and hernes-ui--input-marker
             (>= (point) (marker-position hernes-ui--input-marker)))
    (let* ((end (point))
           (bound (marker-position hernes-ui--input-marker))
           (token-start (save-excursion
                          (skip-chars-backward "^ \t\n" bound)
                          (point))))
      (when (and (< token-start end)
                 (eq (char-after token-start) ?@))
        (list (1+ token-start) end
              (hernes-ui--project-file-candidates)
              :exclusive 'no)))))

;;;; Commands

(defun hernes-ui-newline ()
  "Insert a newline in the input area (bound to S-RET and C-j)."
  (interactive)
  (when (and hernes-ui--input-marker
             (< (point) hernes-ui--input-marker))
    (goto-char (point-max)))
  (insert "\n"))

(defun hernes-ui-cycle-mode ()
  "Cycle this buffer's mode chat -> plan -> auto -> chat (bound to S-TAB).
Also updates the live session, if any, via `hernes-set-mode', so the change
takes effect from the next send even mid-run."
  (interactive)
  (let ((next (pcase hernes-ui--mode
                ('chat 'plan)
                ('plan 'auto)
                ('auto 'chat)
                (_ 'chat))))
    (setq hernes-ui--mode next)
    (when (hernes-session-p hernes-ui--session)
      (hernes-set-mode hernes-ui--session next))
    (hernes-ui--update-header (current-buffer))
    (message "hernes mode: %s" next)))

(defun hernes-ui-abort ()
  "Abort the running session in this buffer (bound to C-c C-k)."
  (interactive)
  (let ((session hernes-ui--session))
    (if (not (hernes-session-p session))
        (message "No hernes session in this buffer.")
      (setf (hernes-session-aborted session) t)
      (hernes--kill-processes session)
      (ignore-errors (gptel-abort (hernes-session-buffer session)))
      ;; `hernes--finish' fires ON-DONE, which renders the stop and goes idle.
      (hernes--finish session 'stopped "aborted by user"))))

;;;; Major mode

(defvar hernes-ui-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'hernes-ui-send)
    (define-key map (kbd "<return>") #'hernes-ui-send)
    (define-key map (kbd "S-<return>") #'hernes-ui-newline)
    (define-key map (kbd "C-j") #'hernes-ui-newline)
    (define-key map (kbd "<backtab>") #'hernes-ui-cycle-mode) ;S-TAB
    (define-key map (kbd "C-c C-k") #'hernes-ui-abort)
    map)
  "Keymap for `hernes-ui-mode'.")

(define-derived-mode hernes-ui-mode text-mode "Hernes"
  "Major mode for a hernes conversation buffer.
Derives from `text-mode' (not `special-mode') because the buffer's bottom is an
editable input area.  RET sends, S-RET/C-j insert a newline, S-TAB cycles the
mode and \\[hernes-ui-abort] aborts.  `@path' mentions in the input area are
completed via `hernes-ui--capf' (a standard capf, so Corfu/Orderless pick it
up with no extra wiring)."
  (setq-local truncate-lines nil)
  (visual-line-mode 1)
  (add-hook 'completion-at-point-functions #'hernes-ui--capf nil t)
  ;; Guarantee the running-header timer never outlives the buffer.
  (add-hook 'kill-buffer-hook #'hernes-ui--cancel-spinner-on-kill nil t))

;;;; Buffer setup / entry point

(defun hernes-ui--new-buffer (root)
  "Create, initialize and return a fresh hernes UI buffer for ROOT."
  (let* ((id (format-time-string "%Y%m%d-%H%M%S"))
         (buf (generate-new-buffer (format "*hernes: %s*" id))))
    (with-current-buffer buf
      (hernes-ui-mode)
      (setq hernes-ui--root (expand-file-name root)
            hernes-ui--id id
            hernes-ui--mode 'chat
            hernes-ui--session nil
            hernes-ui--running nil)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (hernes-ui--insert-ro
         (format "hernes session %s\nType a task below, RET to send. \
S-TAB cycles mode (chat/plan/auto), C-c C-k aborts.\n\n" id)
         'hernes-ui-status-face)
        ;; Prompt prefix: read-only, followed by the editable input area.
        (let ((prefix-start (point)))
          (hernes-ui--insert-ro hernes-ui-prompt 'hernes-ui-user-face)
          (setq hernes-ui--input-marker (copy-marker (point) nil))
          ;; insertion-type t: transcript inserted here rides forward, staying
          ;; pinned just before the prompt glyph.
          (setq hernes-ui--prompt-marker (copy-marker prefix-start t))))
      (hernes-ui--update-header buf)
      (goto-char (point-max)))
    buf))

(defun hernes-ui--find-buffer (root)
  "Return an existing hernes UI buffer for ROOT, or nil."
  (let ((expanded (expand-file-name root)))
    (cl-find-if (lambda (b)
                  (with-current-buffer b
                    (and (derived-mode-p 'hernes-ui-mode)
                         (equal hernes-ui--root expanded))))
                (buffer-list))))

;;;###autoload
(defun hernes (&optional new)
  "Open a hernes conversation buffer for the current project and focus its input.
Type the task in the input area and press RET; the default mode is `chat', and
S-TAB cycles chat/plan/auto.  Reuses an existing buffer for the project unless
prefix arg NEW is given, which always creates a fresh session buffer.

This replaces the old minibuffer-driven entry point; the headless API
\(`hernes-loop' / `hernes-resume') is unchanged and still usable directly."
  (interactive "P")
  (let* ((proj (project-current t))
         (root (project-root proj))
         (buf (or (and (not new) (hernes-ui--find-buffer root))
                  (hernes-ui--new-buffer root))))
    (pop-to-buffer buf)
    (goto-char (point-max))))

(provide 'hernes-ui)
;;; hernes-ui.el ends here
