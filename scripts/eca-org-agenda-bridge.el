;;; eca-org-agenda-bridge.el --- Org agenda bridge for ECA -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'subr-x)
(require 'org)
(require 'org-agenda)
(require 'org-id)

(defgroup eca-org-agenda nil
  "Org agenda helpers for agentic control via emacsclient."
  :group 'org)

(defcustom eca-org-agenda-fallback-files
  '("todo.org")
  "Fallback Org files used when `org-agenda-files' yields nothing.
Entries may be absolute paths or relative to `org-directory'."
  :type '(repeat string))

(defcustom eca-org-agenda-add-id t
  "When non-nil, ensure new entries created by this bridge have an :ID: property."
  :type 'boolean)

(defun eca-org-agenda--plain-string (s)
  "Return S without text properties, or nil when S is nil."
  (when (stringp s)
    (substring-no-properties s)))

(defun eca-org-agenda--plain-strings (strings)
  "Return STRINGS with text properties removed from each element."
  (when strings
    (mapcar #'eca-org-agenda--plain-string strings)))

(defun eca-org-agenda--current-entry-path ()
  "Return the current heading's outline path, including the heading itself."
  (eca-org-agenda--plain-strings (org-get-outline-path t nil)))

(defun eca-org-agenda--current-entry-plist (&rest extra)
  "Return metadata plist for the current Org heading, extended by EXTRA.
If point is inside the heading body, normalize back to the heading first."
  (save-excursion
    (org-back-to-heading t)
    (append
     (list
      :id (eca-org-agenda--plain-string (org-entry-get nil "ID"))
      :file (buffer-file-name)
      :pos (point)
      :line (line-number-at-pos)
      :level (org-outline-level)
      :path (eca-org-agenda--current-entry-path)
      :todo (eca-org-agenda--plain-string (org-get-todo-state))
      :title (eca-org-agenda--plain-string (org-get-heading t t t t)))
     extra)))

(defun eca-org-agenda--current-entry-detail-plist (&rest extra)
  "Return detailed metadata plist for the current Org heading, extended by EXTRA."
  (append
   (eca-org-agenda--current-entry-plist)
   (list
    :tags (eca-org-agenda--plain-strings (org-get-tags nil t))
    :scheduled (eca-org-agenda--plain-string (org-entry-get nil "SCHEDULED"))
    :deadline (eca-org-agenda--plain-string (org-entry-get nil "DEADLINE")))
   extra))

(defun eca-org-agenda--require-non-empty-string (value name)
  "Return VALUE trimmed, or signal a `user-error' mentioning NAME."
  (let ((trimmed (string-trim (or value ""))))
    (when (string-empty-p trimmed)
      (user-error "eca-org-agenda: %s must be a non-empty string" name))
    trimmed))

(defun eca-org-agenda--ensure-org-file (path)
  "Create PATH as a minimal Org file if it does not exist.
Create parent directories as needed."
  (let ((dir (file-name-directory path)))
    (unless (file-directory-p dir)
      (make-directory dir t)))
  (unless (file-exists-p path)
    (with-temp-buffer
      (insert "#+title: " (file-name-base path) "\n\n")
      (write-file path))))
(defun eca-org-agenda--normalize-planning-input (s)
  "Normalize S for `org-schedule' or `org-deadline'.
Active timestamps are returned as-is; inactive timestamps are converted
into active timestamps; plain date strings are returned trimmed."
  (when (and s (not (string-empty-p (string-trim s))))
    (let ((s (string-trim s)))
      (cond
       ((string-match-p "\\`<.*>\\'" s) s)
       ((string-match-p "\\`\\[.*\\]\\'" s)
        (concat "<" (substring s 1 -1) ">"))
       (t s)))))

(defun eca-org-agenda--normalize-tags-list (tags)
  "Normalize TAGS into a deduplicated list of local Org tag strings."
  (let ((parts
         (cond
          ((null tags) nil)
          ((stringp tags)
           (let* ((s (string-trim tags))
                  (s (replace-regexp-in-string "\\`:+\\|:+\\'" "" s)))
             (unless (string-empty-p s)
               (split-string s "[: ,]+" t))))
          ((listp tags)
           (cl-loop for tag in tags
                    if (stringp tag)
                    for trimmed = (string-trim tag)
                    unless (string-empty-p trimmed)
                    collect trimmed))
          (t
           (user-error "eca-org-agenda: tags must be nil, a string, or a list of strings")))))
    (when parts
      (delete-dups (copy-sequence parts)))))

(defun eca-org-agenda--require-tags-list (tags name)
  "Return TAGS normalized as a non-empty list, or signal a `user-error'."
  (let ((normalized (eca-org-agenda--normalize-tags-list tags)))
    (unless normalized
      (user-error "eca-org-agenda: %s must contain at least one tag" name))
    normalized))

(defun eca-org-agenda--tags-union (current extra)
  "Return CURRENT tags with EXTRA appended when missing, preserving order."
  (let ((result (copy-sequence (or current '()))))
    (dolist (tag extra)
      (unless (member tag result)
        (setq result (append result (list tag)))))
    result))

(defun eca-org-agenda--tags-difference (current remove)
  "Return CURRENT tags with all REMOVE tags filtered out."
  (cl-loop for tag in (or current '())
           unless (member tag remove)
           collect tag))

(defun eca-org-agenda--timestamp-day (timestamp)
  "Return the absolute day number for Org TIMESTAMP, or nil when absent."
  (when (and (stringp timestamp)
             (string-match "\\([0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\)" timestamp))
    (let ((date (match-string 1 timestamp)))
      (time-to-days (org-read-date nil t date)))))

(defun eca-org-agenda--entry-reference-day (item)
  "Return the earliest planning day for ITEM, or nil when it has none."
  (let ((days (delq nil (mapcar #'eca-org-agenda--timestamp-day
                                (list (plist-get item :deadline)
                                      (plist-get item :scheduled))))))
    (when days
      (apply #'min days))))

(defun eca-org-agenda--item-key (item)
  "Return a stable key string for ITEM."
  (or (plist-get item :id)
      (format "%s:%s"
              (or (plist-get item :file) "")
              (or (plist-get item :pos) 0))))

(defun eca-org-agenda--dedupe-items (items)
  "Return ITEMS with duplicate entries removed, preserving first-seen order."
  (let ((seen (make-hash-table :test #'equal))
        result)
    (dolist (item items (nreverse result))
      (let ((key (eca-org-agenda--item-key item)))
        (unless (gethash key seen)
          (puthash key t seen)
          (push item result))))))

(defun eca-org-agenda--normalize-heading-path (path)
  "Normalize PATH into a non-empty list of exact heading titles.
PATH may be a list of strings or a slash-separated string."
  (let ((parts
         (cond
          ((stringp path)
           (let* ((s (string-trim path))
                  (s (replace-regexp-in-string "\\`/+\\|/+\\'" "" s)))
             (unless (string-empty-p s)
               (mapcar #'string-trim (split-string s "/" t)))))
          ((listp path)
           (cl-loop for part in path
                    do (unless (stringp part)
                         (user-error
                          "eca-org-agenda: heading path list must contain only strings"))
                    for trimmed = (string-trim part)
                    unless (string-empty-p trimmed)
                    collect trimmed))
          (t
           (user-error
            "eca-org-agenda: heading path must be a string or list of strings")))))
    (unless parts
      (user-error "eca-org-agenda: heading path must not be empty"))
    parts))

(defun eca-org-agenda--heading-search-files (&optional file)
  "Return existing Org files to search for headings.
When FILE is non-nil, search only that file. Otherwise search agenda files."
  (if file
      (let ((path (eca-org-agenda--resolve-file file)))
        (unless (file-exists-p path)
          (user-error "eca-org-agenda: file does not exist: %s" path))
        (list path))
    (eca-org-agenda--agenda-files)))

(defun eca-org-agenda--format-heading-match (item)
  "Return a human-readable description string for heading ITEM."
  (format "%s in %s"
          (string-join (or (plist-get item :path)
                           (list (or (plist-get item :title) "<untitled>")))
                       " / ")
          (abbreviate-file-name (or (plist-get item :file) ""))))

(defun eca-org-agenda--collect-heading-matches (files predicate)
  "Return headings in FILES for which PREDICATE returns non-nil.
PREDICATE is called with point at each heading in turn."
  (let (matches)
    (dolist (path files (nreverse matches))
      (with-current-buffer (find-file-noselect path)
        (unless (derived-mode-p 'org-mode) (org-mode))
        (save-restriction
          (widen)
          (goto-char (point-min))
          (while (re-search-forward org-heading-regexp nil t)
            (goto-char (match-beginning 0))
            (org-back-to-heading t)
            (when (funcall predicate)
              (push (eca-org-agenda--current-entry-detail-plist) matches))
            (forward-line 1)))))))

(defun eca-org-agenda--single-heading-match (matches description)
  "Return the unique element in MATCHES, or signal a `user-error'."
  (pcase matches
    ('()
     (user-error "eca-org-agenda: no heading found for %s" description))
    (`(,match)
     match)
    (_
     (let* ((preview-count (min 3 (length matches)))
            (preview (mapconcat #'eca-org-agenda--format-heading-match
                                (cl-subseq matches 0 preview-count)
                                "; ")))
       (user-error
        "eca-org-agenda: %d headings found for %s; use a more specific path or file: %s"
        (length matches)
        description
        preview)))))

(defun eca-org-agenda--ensure-id-for-item (item)
  "Ensure ITEM has an :ID: property and return refreshed metadata."
  (eca-org-agenda--with-entry-at
   (plist-get item :file)
   (plist-get item :pos)
   (lambda ()
     (or (org-entry-get nil "ID")
         (org-id-get-create))
     (eca-org-agenda--current-entry-detail-plist))))

(defun eca-org-agenda--find-id-marker (id)
  "Return a fresh marker for entry ID, updating known ID locations if needed."
  (let* ((id (eca-org-agenda--require-non-empty-string id "id"))
         (marker (or (org-id-find id 'marker)
                     (progn
                       (org-id-update-id-locations (eca-org-agenda--agenda-files) t)
                       (org-id-find id 'marker)))))
    (or marker
        (user-error "eca-org-agenda: no entry found for id %s" id))))

(defun eca-org-agenda--with-entry-id (id fn)
  "Visit the entry identified by ID, call FN there, then save its buffer."
  (let ((marker (eca-org-agenda--find-id-marker id)))
    (unwind-protect
        (with-current-buffer (marker-buffer marker)
          (unless (derived-mode-p 'org-mode) (org-mode))
          (save-restriction
            (widen)
            (goto-char (marker-position marker))
            (org-back-to-heading t)
            (prog1 (funcall fn)
              (save-buffer))))
      (set-marker marker nil))))

(defun eca-org-agenda--current-subtree-text ()
  "Return the current subtree as plain text, including its heading line."
  (let* ((start (point))
         (end (save-excursion
                (org-end-of-subtree t t)
                (point)))
         (tree (buffer-substring-no-properties start end)))
    (if (string-suffix-p "\n" tree)
        tree
      (concat tree "\n"))))

(defun eca-org-agenda--insert-subtree-at-end-of-file (file tree)
  "Insert TREE as a top-level entry at the end of FILE.
Return a detailed metadata plist for the inserted entry."
  (let ((path (eca-org-agenda--resolve-file file)))
    (eca-org-agenda--ensure-org-file path)
    (with-current-buffer (find-file-noselect path)
      (unless (derived-mode-p 'org-mode) (org-mode))
      (save-restriction
        (widen)
        (goto-char (point-max))
        (unless (bolp) (insert "\n"))
        (let ((insert-pos (point)))
          (org-paste-subtree 1 tree)
          (goto-char insert-pos)
          (org-back-to-heading t)
          (save-buffer)
          (eca-org-agenda--current-entry-detail-plist))))))

(defun eca-org-agenda--insert-subtree-under-marker (marker tree)
  "Insert TREE as the last child of MARKER's entry.
Return a detailed metadata plist for the inserted entry."
  (with-current-buffer (marker-buffer marker)
    (unless (derived-mode-p 'org-mode) (org-mode))
    (save-restriction
      (widen)
      (goto-char (marker-position marker))
      (org-back-to-heading t)
      (let ((target-level (org-outline-level)))
        (org-end-of-subtree t t)
        (unless (bolp) (insert "\n"))
        (let ((insert-pos (point)))
          (org-paste-subtree (1+ target-level) tree)
          (goto-char insert-pos)
          (org-back-to-heading t)
          (save-buffer)
          (eca-org-agenda--current-entry-detail-plist))))))

(defun eca-org-agenda--resolve-file (file)
  "Resolve FILE to an absolute path.
If FILE is relative, resolve relative to `org-directory' when set,
otherwise relative to `default-directory'."
  (let ((base (or (bound-and-true-p org-directory) default-directory)))
    (expand-file-name file base)))

(defun eca-org-agenda--agenda-files ()
  "Return existing agenda files, or signal a `user-error' if none are available.
Prefer `org-agenda-files' if it yields anything; otherwise fall back to
`eca-org-agenda-fallback-files' resolved against `org-directory'."
  (let* ((files (ignore-errors (org-agenda-files t)))
         (files (if (and (listp files) files)
                    files
                  (mapcar #'eca-org-agenda--resolve-file eca-org-agenda-fallback-files)))
         (existing-files (cl-remove-if-not #'file-exists-p files)))
    (or existing-files
        (user-error
         "eca-org-agenda: no agenda files found; set `org-agenda-files' or create one of %s"
         (mapconcat #'abbreviate-file-name
                    (mapcar #'eca-org-agenda--resolve-file eca-org-agenda-fallback-files)
                    ", ")))))

(defun eca-org-agenda--normalize-active-date (s)
  "Normalize S into an active Org timestamp string like <YYYY-MM-DD Day>.
If S is already active (<...>) return it as-is. If S is inactive ([...]),
convert it to an active timestamp. Otherwise parse S with `org-read-date'
(FROM-STRING) and return <...>."
  (when (and s (not (string-empty-p (string-trim s))))
    (let ((s (string-trim s)))
      (cond
       ((string-match-p "\\`<.*>\\'" s) s)
       ((string-match-p "\\`\\[.*\\]\\'" s)
        (concat "<" (substring s 1 -1) ">"))
       (t
        (let* ((time (org-read-date nil t s))
               (ts (format-time-string "<%Y-%m-%d %a>" time)))
          ts))))))

(defun eca-org-agenda--normalize-body (body)
  "Turn BODY into a string suitable for insertion.
Allows BODY to contain literal \\n sequences."
  (when (and body (not (string-empty-p (string-trim body))))
    (replace-regexp-in-string "\\\\n" "\n" body t t)))

(defun eca-org-agenda--format-tags (tags)
  "Format TAGS for an Org heading, returning a string like \":a:b:\" or \"\".
TAGS may be nil, a string, or a list of strings."
  (cond
   ((null tags) "")
   ((stringp tags)
    (let ((t0 (string-trim tags)))
      (cond
       ((string-empty-p t0) "")
       ;; Keep an already-formed :tag:tag: block.
       ((string-match-p "\\`:[^ ]+:\\'" t0) (concat " " t0))
       (t
        (let* ((parts (split-string t0 "[ ,]+" t))
               (parts (cl-remove-if #'string-empty-p parts)))
          (if parts (concat " :" (string-join parts ":") ":") ""))))))
   ((listp tags)
    (let ((parts (cl-remove-if (lambda (x) (or (null x) (string-empty-p (string-trim x))))
                               (mapcar (lambda (x) (if (stringp x) (string-trim x) "")) tags))))
      (if parts (concat " :" (string-join parts ":") ":") "")))
   (t "")))

(defun eca-org-agenda--insert-entry (file heading &optional todo-state scheduled deadline body tags)
  "Insert a top-level entry into FILE and return a detailed plist describing it.
HEADING is the headline text (without TODO keyword).
TODO-STATE when non-nil is inserted before heading (e.g. \"TODO\").
SCHEDULED/DEADLINE may be Org timestamps or anything `org-read-date' can parse.
BODY is inserted as plain text under the entry; literal \\n is supported."
  (let* ((path (eca-org-agenda--resolve-file file))
         (heading (eca-org-agenda--require-non-empty-string heading "heading")))
    (eca-org-agenda--ensure-org-file path)
    (with-current-buffer (find-file-noselect path)
      (unless (derived-mode-p 'org-mode) (org-mode))
      (save-restriction
        (widen)
        (goto-char (point-max))
        (unless (bolp) (insert "\n"))
        (let ((entry-start (point)))
          (insert "* ")
          (when (and todo-state (not (string-empty-p (string-trim todo-state))))
            (insert (string-trim todo-state) " "))
          (insert heading)
          (insert (eca-org-agenda--format-tags tags))
          (insert "\n")
          (let ((sched (eca-org-agenda--normalize-active-date scheduled))
                (dead (eca-org-agenda--normalize-active-date deadline)))
            (when sched (insert "SCHEDULED: " sched "\n"))
            (when dead (insert "DEADLINE: " dead "\n")))
          (let ((body (eca-org-agenda--normalize-body body)))
            (when body
              (insert (string-trim-right body) "\n")))
          (goto-char entry-start)
          (org-back-to-heading t)
          (when eca-org-agenda-add-id
            (org-id-get-create))
          (save-buffer)
          (eca-org-agenda--current-entry-detail-plist))))))

(defun eca-org-agenda--insert-child-heading (title &optional todo-state scheduled deadline body tags force-id)
  "Insert a new child heading under the current Org heading.
Returns a detailed metadata plist for the created child. When FORCE-ID is
non-nil, create an :ID: property even if `eca-org-agenda-add-id' is nil."
  (let* ((title (eca-org-agenda--require-non-empty-string title "title"))
         (child-level (1+ (org-outline-level)))
         (stars (make-string child-level ?*)))
    (org-end-of-subtree t t)
    (unless (bolp) (insert "\n"))
    (let ((entry-start (point)))
      (insert stars " ")
      (when (and todo-state (not (string-empty-p (string-trim todo-state))))
        (insert (string-trim todo-state) " "))
      (insert title)
      (insert (eca-org-agenda--format-tags tags))
      (insert "\n")
      (let ((sched (eca-org-agenda--normalize-active-date scheduled))
            (dead (eca-org-agenda--normalize-active-date deadline)))
        (when sched (insert "SCHEDULED: " sched "\n"))
        (when dead (insert "DEADLINE: " dead "\n")))
      (let ((body (eca-org-agenda--normalize-body body)))
        (when body
          (insert (string-trim-right body) "\n")))
      (goto-char entry-start)
      (org-back-to-heading t)
      (when (or force-id eca-org-agenda-add-id)
        (org-id-get-create))
      (eca-org-agenda--current-entry-detail-plist))))

(defun eca-org-agenda--collect-direct-child-matches (title)
  "Return direct child headings named TITLE under the current heading."
  (let* ((title (eca-org-agenda--require-non-empty-string title "title"))
         (parent (eca-org-agenda--current-entry-detail-plist))
         (parent-level (plist-get parent :level))
         (subtree-end (save-excursion
                        (org-end-of-subtree t t)
                        (point)))
         matches)
    (save-excursion
      (while (and (outline-next-heading)
                  (< (point) subtree-end))
        (let ((level (org-outline-level)))
          (cond
           ((<= level parent-level)
            (goto-char subtree-end))
           ((= level (1+ parent-level))
            (when (string= (or (eca-org-agenda--plain-string
                                (org-get-heading t t t t))
                               "")
                           title)
              (push (eca-org-agenda--current-entry-detail-plist) matches)))))))
    (nreverse matches)))

(cl-defun eca-org-agenda--resolve-direct-child-heading (title &key ensure-id insert-missing todo-state tags body scheduled deadline)
  "Return or create a direct child heading named TITLE under the current heading.
When ENSURE-ID is non-nil, ensure the resolved child has an :ID: property.
When INSERT-MISSING is non-nil, insert a fresh child if no exact direct child
exists. TODO-STATE, TAGS, BODY, SCHEDULED, and DEADLINE are used only when a
missing child must be inserted."
  (let* ((parent (eca-org-agenda--current-entry-detail-plist))
         (matches (eca-org-agenda--collect-direct-child-matches title))
         (description (format "child title %S under %s"
                              title
                              (eca-org-agenda--format-heading-match parent))))
    (cond
     ((null matches)
      (if insert-missing
          (eca-org-agenda--insert-child-heading
           title todo-state scheduled deadline body tags ensure-id)
        (user-error "eca-org-agenda: no heading found for %s" description)))
     (t
      (let ((match (eca-org-agenda--single-heading-match matches description)))
        (if ensure-id
            (eca-org-agenda--ensure-id-for-item match)
          match))))))

(defun eca-org-agenda--current-body-region ()
  "Return the editable body region of the current heading as (START . END).
This excludes the headline, planning lines, and drawers, and stops before the
first child heading if one exists."
  (save-excursion
    (org-back-to-heading t)
    (let* ((level (org-outline-level))
           (subtree-end (save-excursion
                          (org-end-of-subtree t t)
                          (point)))
           (body-start (save-excursion
                         (org-end-of-meta-data t)
                         (point)))
           (body-end (save-excursion
                       (goto-char body-start)
                       (cond
                        ((and (looking-at org-heading-regexp)
                              (> (org-outline-level) level))
                         (point))
                        ((and (outline-next-heading)
                              (< (point) subtree-end)
                              (> (org-outline-level) level))
                         (line-beginning-position))
                        (t
                         subtree-end)))))
      (cons body-start body-end))))

(defun eca-org-agenda--current-body-string ()
  "Return the current heading body as a plain string, or nil when empty."
  (pcase-let ((`(,start . ,end) (eca-org-agenda--current-body-region)))
    (let ((body (buffer-substring-no-properties start end)))
      (unless (string-empty-p (string-trim-right body))
        (string-trim-right body)))))

(defun eca-org-agenda--current-entry-with-body-plist (&rest extra)
  "Return current heading metadata including `:body', extended by EXTRA."
  (append (eca-org-agenda--current-entry-detail-plist
           :body (eca-org-agenda--current-body-string))
          extra))

(defun eca-org-agenda--replace-current-body (body)
  "Replace the current heading body with BODY and return refreshed metadata.
BODY may be nil or empty to clear the current body. Literal \\n is supported."
  (let ((entry-pos (save-excursion
                     (org-back-to-heading t)
                     (point))))
    (pcase-let ((`(,start . ,end) (eca-org-agenda--current-body-region)))
      (let ((body (eca-org-agenda--normalize-body body)))
        (delete-region start end)
        (goto-char start)
        (when body
          (insert (string-trim-right body))
          (unless (bolp) (insert "\n")))
        (goto-char entry-pos)
        (eca-org-agenda--current-entry-with-body-plist)))))

(defun eca-org-agenda--append-current-body (body)
  "Append BODY to the current heading body and return refreshed metadata.
BODY must be non-empty. Literal \\n is supported."
  (let ((body (eca-org-agenda--normalize-body body))
        (entry-pos (save-excursion
                     (org-back-to-heading t)
                     (point))))
    (unless body
      (user-error "eca-org-agenda: body must be a non-empty string"))
    (pcase-let ((`(,start . ,end) (eca-org-agenda--current-body-region)))
      (goto-char end)
      (when (and (> end start)
                 (> (point) (point-min))
                 (not (eq (char-before) ?\n)))
        (insert "\n"))
      (insert (string-trim-right body))
      (unless (bolp) (insert "\n"))
      (goto-char entry-pos)
      (eca-org-agenda--current-entry-with-body-plist))))

(defun eca-org-agenda-capture-task (title &optional scheduled deadline body file)
  "Capture a TODO task to todo.org (or FILE), optionally with SCHEDULED/DEADLINE."
  (eca-org-agenda--insert-entry (or file "todo.org") title "TODO" scheduled deadline body nil))

(defun eca-org-agenda--collect-view-items (key &optional span start ensure-id)
  "Run org-agenda with KEY and collect headline-backed items from the agenda buffer.
KEY is an agenda dispatcher key string (e.g. \"a\" or \"t\").
SPAN is number of days (agenda views). START is an org date string.
If ENSURE-ID is non-nil, create IDs for items missing them."
  (let* ((org-agenda-files (eca-org-agenda--agenda-files))
         (org-agenda-span (or span org-agenda-span))
         (org-agenda-start-day (when start (org-read-date nil nil start)))
         (bufname org-agenda-buffer-name)
         (items '()))
    (save-window-excursion
      (org-agenda nil key)
      (with-current-buffer bufname
        (save-excursion
          (goto-char (point-min))
          (while (not (eobp))
            (let ((m (or (get-text-property (point) 'org-hd-marker)
                         (get-text-property (point) 'org-marker))))
              (when (markerp m)
                (let ((agenda-line (string-trim
                                    (buffer-substring-no-properties
                                     (line-beginning-position)
                                     (line-end-position)))))
                  (with-current-buffer (marker-buffer m)
                    (save-excursion
                      (goto-char (marker-position m))
                      (org-back-to-heading t)
                      (when (and ensure-id (not (org-entry-get nil "ID")))
                        (org-id-get-create)
                        (save-buffer))
                      (push (eca-org-agenda--current-entry-detail-plist
                             :agenda-line agenda-line)
                            items))))))
            (forward-line 1)))))
    (nreverse items)))

(defun eca-org-agenda-agenda-items (&optional span start ensure-id)
  "Return agenda items (dispatcher key \"a\") as a list of plists."
  (eca-org-agenda--collect-view-items "a" span start ensure-id))

(defun eca-org-agenda-todo-items (&optional ensure-id)
  "Return TODO list items (dispatcher key \"t\") as a list of plists."
  (eca-org-agenda--collect-view-items "t" nil nil ensure-id))

(defun eca-org-agenda-summary (&optional span start ensure-id)
  "Return a simple grouped summary of agenda and TODO items.
Buckets are relative to START, which defaults to today. The returned plist
contains `:counts', `:overdue', `:today', `:upcoming', and `:unscheduled'."
  (let* ((reference-time (org-read-date nil t (or start "today")))
         (reference-day (time-to-days reference-time))
         (agenda-items (eca-org-agenda--dedupe-items
                        (eca-org-agenda-agenda-items span start ensure-id)))
         (todo-items (eca-org-agenda--dedupe-items
                      (eca-org-agenda-todo-items ensure-id)))
         overdue today upcoming unscheduled)
    (dolist (item agenda-items)
      (let ((day (eca-org-agenda--entry-reference-day item)))
        (cond
         ((and day (< day reference-day))
          (push item overdue))
         ((and day (= day reference-day))
          (push item today))
         ((and day (> day reference-day))
          (push item upcoming)))))
    (dolist (item todo-items)
      (unless (or (plist-get item :scheduled)
                  (plist-get item :deadline))
        (push item unscheduled)))
    (setq overdue (nreverse overdue)
          today (nreverse today)
          upcoming (nreverse upcoming)
          unscheduled (nreverse unscheduled))
    (list
     :generated-at (format-time-string "%Y-%m-%d %H:%M")
     :reference-day (format-time-string "%Y-%m-%d" reference-time)
     :span (or span org-agenda-span)
     :counts (list
              :overdue (length overdue)
              :today (length today)
              :upcoming (length upcoming)
              :unscheduled (length unscheduled))
     :overdue overdue
     :today today
     :upcoming upcoming
     :unscheduled unscheduled)))

(defun eca-org-agenda-find-heading-in-file (file title &optional ensure-id)
  "Return a detailed plist for exact heading TITLE in FILE.
This works for any Org heading, not just agenda or TODO entries.
When ENSURE-ID is non-nil, create an :ID: property on the matched heading if
needed. The search requires exactly one exact title match in FILE."
  (let* ((title (eca-org-agenda--require-non-empty-string title "title"))
         (path (car (eca-org-agenda--heading-search-files file)))
         (match (eca-org-agenda--single-heading-match
                 (eca-org-agenda--collect-heading-matches
                  (list path)
                  (lambda ()
                    (string= (or (eca-org-agenda--plain-string
                                  (org-get-heading t t t t))
                                 "")
                             title)))
                 (format "title %S in %s"
                         title
                         (abbreviate-file-name path)))))
    (if ensure-id
        (eca-org-agenda--ensure-id-for-item match)
      match)))

(defun eca-org-agenda-find-heading-by-path (path &optional file ensure-id)
  "Return a detailed plist for exact outline PATH.
PATH may be a list of heading titles or a slash-separated string.
When FILE is nil, search agenda files and require a unique exact path match.
When ENSURE-ID is non-nil, create an :ID: property on the matched heading if
needed."
  (let* ((normalized-path (eca-org-agenda--normalize-heading-path path))
         (files (eca-org-agenda--heading-search-files file))
         (match (eca-org-agenda--single-heading-match
                 (eca-org-agenda--collect-heading-matches
                  files
                  (lambda ()
                    (equal (eca-org-agenda--current-entry-path)
                           normalized-path)))
                 (format "path %S%s"
                         normalized-path
                         (if file
                             (format " in %s"
                                     (abbreviate-file-name (car files)))
                           "")))))
    (if ensure-id
        (eca-org-agenda--ensure-id-for-item match)
      match)))

(defun eca-org-agenda--with-heading-by-path (path file ensure-id fn)
  "Resolve exact PATH, visit that heading, and call FN there."
  (let ((entry (eca-org-agenda-find-heading-by-path path file ensure-id)))
    (eca-org-agenda--with-entry-at
     (plist-get entry :file)
     (plist-get entry :pos)
     fn)))

(cl-defun eca-org-agenda-insert-child-heading-id (parent-id title &key todo-state tags body scheduled deadline ensure-id)
  "Insert a new child heading under PARENT-ID and return its metadata.
This always inserts a fresh child as the last child of the parent subtree.
Use TODO-STATE to create a TODO heading, leave it nil for a plain heading.
TAGS may be nil, a string, or a list of strings. BODY supports literal \\n.
SCHEDULED and DEADLINE accept Org timestamps or anything `org-read-date' can
parse. When ENSURE-ID is non-nil, force an :ID: property on the new child even
if `eca-org-agenda-add-id' is nil."
  (eca-org-agenda--with-entry-id
   parent-id
   (lambda ()
     (eca-org-agenda--insert-child-heading
      title todo-state scheduled deadline body tags ensure-id))))

(cl-defun eca-org-agenda-insert-child-heading-by-path (path title &key file ensure-parent-id todo-state tags body scheduled deadline ensure-id)
  "Insert a new child heading under exact parent PATH and return its metadata.
PATH may be a list of heading titles or a slash-separated string. FILE, when
non-nil, restricts the parent search to that file. When ENSURE-PARENT-ID is
non-nil, create an :ID: property on the matched parent heading if needed before
inserting the child. The child is always inserted as the last child.
Use TODO-STATE to create a TODO heading, leave it nil for a plain heading.
When ENSURE-ID is non-nil, force an :ID: property on the new child even if
`eca-org-agenda-add-id' is nil."
  (eca-org-agenda--with-heading-by-path
   path file ensure-parent-id
   (lambda ()
     (eca-org-agenda--insert-child-heading
      title todo-state scheduled deadline body tags ensure-id))))

(defun eca-org-agenda-find-child-heading-id (parent-id title &optional ensure-id)
  "Return the exact direct child heading TITLE under PARENT-ID.
When ENSURE-ID is non-nil, create an :ID: property on the matched child if
needed. The child match must be unique among direct children of the parent."
  (eca-org-agenda--with-entry-id
   parent-id
   (lambda ()
     (eca-org-agenda--resolve-direct-child-heading title :ensure-id ensure-id))))

(cl-defun eca-org-agenda-find-child-heading-by-path (path title &key file ensure-parent-id ensure-id)
  "Return the exact direct child heading TITLE under exact parent PATH.
PATH may be a list of heading titles or a slash-separated string. FILE, when
non-nil, restricts the parent search to that file. When ENSURE-PARENT-ID is
non-nil, create an :ID: property on the matched parent heading if needed before
resolving the child. When ENSURE-ID is non-nil, create an :ID: property on the
matched child if needed."
  (eca-org-agenda--with-heading-by-path
   path file ensure-parent-id
   (lambda ()
     (eca-org-agenda--resolve-direct-child-heading title :ensure-id ensure-id))))

(cl-defun eca-org-agenda-ensure-child-heading-id (parent-id title &key todo-state tags body scheduled deadline ensure-id)
  "Return or create direct child heading TITLE under PARENT-ID.
If an exact direct child already exists, return it. Otherwise insert a fresh
child as the last child of the parent subtree using TODO-STATE, TAGS, BODY,
SCHEDULED, and DEADLINE. When ENSURE-ID is non-nil, ensure the resolved child
has an :ID: property."
  (eca-org-agenda--with-entry-id
   parent-id
   (lambda ()
     (eca-org-agenda--resolve-direct-child-heading
      title
      :ensure-id ensure-id
      :insert-missing t
      :todo-state todo-state
      :tags tags
      :body body
      :scheduled scheduled
      :deadline deadline))))

(cl-defun eca-org-agenda-ensure-child-heading-by-path (path title &key file ensure-parent-id todo-state tags body scheduled deadline ensure-id)
  "Return or create direct child heading TITLE under exact parent PATH.
PATH may be a list of heading titles or a slash-separated string. FILE, when
non-nil, restricts the parent search to that file. When ENSURE-PARENT-ID is
non-nil, create an :ID: property on the matched parent heading if needed before
resolving the child. If the child is missing, insert it as the last child using
TODO-STATE, TAGS, BODY, SCHEDULED, and DEADLINE. When ENSURE-ID is non-nil,
ensure the resolved child has an :ID: property."
  (eca-org-agenda--with-heading-by-path
   path file ensure-parent-id
   (lambda ()
     (eca-org-agenda--resolve-direct-child-heading
      title
      :ensure-id ensure-id
      :insert-missing t
      :todo-state todo-state
      :tags tags
      :body body
      :scheduled scheduled
      :deadline deadline))))

(defun eca-org-agenda-get-body-id (id)
  "Return heading metadata plus `:body' for the entry identified by ID."
  (eca-org-agenda--with-entry-id
   id
   (lambda ()
     (eca-org-agenda--current-entry-with-body-plist))))

(cl-defun eca-org-agenda-get-body-by-path (path &key file ensure-id)
  "Return heading metadata plus `:body' for exact heading PATH.
PATH may be a list of heading titles or a slash-separated string. FILE, when
non-nil, restricts the search to that file. When ENSURE-ID is non-nil, create
an :ID: property on the matched heading if needed before returning."
  (eca-org-agenda--with-heading-by-path
   path file ensure-id
   (lambda ()
     (eca-org-agenda--current-entry-with-body-plist))))

(defun eca-org-agenda-replace-body-id (id body)
  "Replace the body under entry ID with BODY and return refreshed metadata.
Pass nil or an empty string to clear the body. BODY supports literal \\n."
  (eca-org-agenda--with-entry-id
   id
   (lambda ()
     (eca-org-agenda--replace-current-body body))))

(cl-defun eca-org-agenda-replace-body-by-path (path body &key file ensure-id)
  "Replace the body under exact heading PATH with BODY and return metadata.
PATH may be a list of heading titles or a slash-separated string. FILE, when
non-nil, restricts the search to that file. When ENSURE-ID is non-nil, create
an :ID: property on the matched heading if needed before editing. Pass nil or
an empty string to clear the body. BODY supports literal \\n."
  (eca-org-agenda--with-heading-by-path
   path file ensure-id
   (lambda ()
     (eca-org-agenda--replace-current-body body))))

(defun eca-org-agenda-append-body-id (id body)
  "Append BODY under entry ID and return refreshed metadata.
BODY must be non-empty and supports literal \\n."
  (eca-org-agenda--with-entry-id
   id
   (lambda ()
     (eca-org-agenda--append-current-body body))))

(cl-defun eca-org-agenda-append-body-by-path (path body &key file ensure-id)
  "Append BODY under exact heading PATH and return refreshed metadata.
PATH may be a list of heading titles or a slash-separated string. FILE, when
non-nil, restricts the search to that file. When ENSURE-ID is non-nil, create
an :ID: property on the matched heading if needed before editing. BODY must be
non-empty and supports literal \\n."
  (eca-org-agenda--with-heading-by-path
   path file ensure-id
   (lambda ()
     (eca-org-agenda--append-current-body body))))

(defun eca-org-agenda-find-id (id)
  "Return a detailed metadata plist for the Org entry identified by ID."
  (eca-org-agenda--with-entry-id
   id
   (lambda ()
     (eca-org-agenda--current-entry-detail-plist))))

(defun eca-org-agenda-open-id (id &optional indirect)
  "Open the Org entry identified by ID.
If INDIRECT is non-nil, open the subtree in an indirect buffer."
  (let ((marker (eca-org-agenda--find-id-marker id)))
    (unwind-protect
        (eca-org-agenda-open-at
         (buffer-file-name (marker-buffer marker))
         (marker-position marker)
         indirect)
      (set-marker marker nil))))

(defun eca-org-agenda-open-at (file pos &optional indirect)
  "Open FILE at POS. If INDIRECT is non-nil, open subtree in an indirect buffer.
Returns a plist describing the entry."
  (let* ((path (eca-org-agenda--resolve-file file)))
    (unless (file-exists-p path)
      (error "eca-org-agenda: file does not exist: %s" path))
    (find-file path)
    (unless (derived-mode-p 'org-mode) (org-mode))
    (save-restriction
      (widen)
      (goto-char pos)
      (org-back-to-heading t)
      (org-show-context)
      (let ((result (eca-org-agenda--current-entry-detail-plist)))
        (when indirect
          (org-tree-to-indirect-buffer))
        result))))

(defun eca-org-agenda--with-entry-at (file pos fn)
  "Visit FILE, go to POS heading, call FN, then save buffer."
  (let ((path (eca-org-agenda--resolve-file file)))
    (unless (file-exists-p path)
      (error "eca-org-agenda: file does not exist: %s" path))
    (with-current-buffer (find-file-noselect path)
      (unless (derived-mode-p 'org-mode) (org-mode))
      (save-restriction
        (widen)
        (goto-char pos)
        (org-back-to-heading t)
        (prog1 (funcall fn)
          (save-buffer))))))

(defun eca-org-agenda-set-todo-at (file pos new-state)
  "Set TODO state at FILE/POS to NEW-STATE, then save."
  (eca-org-agenda--with-entry-at
   file pos
   (lambda ()
     (let ((state (eca-org-agenda--require-non-empty-string new-state "new-state")))
       (org-todo state)
       (eca-org-agenda--current-entry-detail-plist)))))

(defun eca-org-agenda-set-todo-id (id new-state)
  "Set Org entry ID to NEW-STATE, then save."
  (eca-org-agenda--with-entry-id
   id
   (lambda ()
     (let ((state (eca-org-agenda--require-non-empty-string new-state "new-state")))
       (org-todo state)
       (eca-org-agenda--current-entry-detail-plist)))))

(defun eca-org-agenda-schedule-at (file pos &optional when)
  "Set or clear SCHEDULED for FILE/POS.
When WHEN is nil or empty, clear the schedule. Otherwise pass WHEN through to
`org-schedule' after normalizing inactive timestamps."
  (eca-org-agenda--with-entry-at
   file pos
   (lambda ()
     (let ((time (eca-org-agenda--normalize-planning-input when)))
       (if time
           (org-schedule nil time)
         (org-schedule '(4)))
       (eca-org-agenda--current-entry-detail-plist)))))

(defun eca-org-agenda-schedule-id (id &optional when)
  "Set or clear SCHEDULED for entry ID.
When WHEN is nil or empty, clear the schedule. Otherwise pass WHEN through to
`org-schedule' after normalizing inactive timestamps."
  (eca-org-agenda--with-entry-id
   id
   (lambda ()
     (let ((time (eca-org-agenda--normalize-planning-input when)))
       (if time
           (org-schedule nil time)
         (org-schedule '(4)))
       (eca-org-agenda--current-entry-detail-plist)))))

(defun eca-org-agenda-deadline-at (file pos &optional when)
  "Set or clear DEADLINE for FILE/POS.
When WHEN is nil or empty, clear the deadline. Otherwise pass WHEN through to
`org-deadline' after normalizing inactive timestamps."
  (eca-org-agenda--with-entry-at
   file pos
   (lambda ()
     (let ((time (eca-org-agenda--normalize-planning-input when)))
       (if time
           (org-deadline nil time)
         (org-deadline '(4)))
       (eca-org-agenda--current-entry-detail-plist)))))

(defun eca-org-agenda-deadline-id (id &optional when)
  "Set or clear DEADLINE for entry ID.
When WHEN is nil or empty, clear the deadline. Otherwise pass WHEN through to
`org-deadline' after normalizing inactive timestamps."
  (eca-org-agenda--with-entry-id
   id
   (lambda ()
     (let ((time (eca-org-agenda--normalize-planning-input when)))
       (if time
           (org-deadline nil time)
         (org-deadline '(4)))
       (eca-org-agenda--current-entry-detail-plist)))))

(defun eca-org-agenda-set-tags-at (file pos tags)
  "Replace local TAGS for FILE/POS.
TAGS may be nil, a string, or a list of strings. Nil or empty clears tags."
  (eca-org-agenda--with-entry-at
   file pos
   (lambda ()
     (org-set-tags (eca-org-agenda--normalize-tags-list tags))
     (eca-org-agenda--current-entry-detail-plist))))

(defun eca-org-agenda-set-tags-id (id tags)
  "Replace local TAGS for entry ID.
TAGS may be nil, a string, or a list of strings. Nil or empty clears tags."
  (eca-org-agenda--with-entry-id
   id
   (lambda ()
     (org-set-tags (eca-org-agenda--normalize-tags-list tags))
     (eca-org-agenda--current-entry-detail-plist))))

(defun eca-org-agenda-add-tags-at (file pos tags)
  "Add local TAGS to FILE/POS, preserving existing order when possible."
  (eca-org-agenda--with-entry-at
   file pos
   (lambda ()
     (let* ((extra (eca-org-agenda--require-tags-list tags "tags"))
            (current (eca-org-agenda--plain-strings (org-get-tags nil t))))
       (org-set-tags (eca-org-agenda--tags-union current extra))
       (eca-org-agenda--current-entry-detail-plist)))))

(defun eca-org-agenda-add-tags-id (id tags)
  "Add local TAGS to entry ID, preserving existing order when possible."
  (eca-org-agenda--with-entry-id
   id
   (lambda ()
     (let* ((extra (eca-org-agenda--require-tags-list tags "tags"))
            (current (eca-org-agenda--plain-strings (org-get-tags nil t))))
       (org-set-tags (eca-org-agenda--tags-union current extra))
       (eca-org-agenda--current-entry-detail-plist)))))

(defun eca-org-agenda-remove-tags-at (file pos tags)
  "Remove local TAGS from FILE/POS."
  (eca-org-agenda--with-entry-at
   file pos
   (lambda ()
     (let* ((remove (eca-org-agenda--require-tags-list tags "tags"))
            (current (eca-org-agenda--plain-strings (org-get-tags nil t))))
       (org-set-tags (eca-org-agenda--tags-difference current remove))
       (eca-org-agenda--current-entry-detail-plist)))))

(defun eca-org-agenda-remove-tags-id (id tags)
  "Remove local TAGS from entry ID."
  (eca-org-agenda--with-entry-id
   id
   (lambda ()
     (let* ((remove (eca-org-agenda--require-tags-list tags "tags"))
            (current (eca-org-agenda--plain-strings (org-get-tags nil t))))
       (org-set-tags (eca-org-agenda--tags-difference current remove))
       (eca-org-agenda--current-entry-detail-plist)))))

(defun eca-org-agenda-archive-at (file pos)
  "Archive the subtree at FILE/POS using `org-archive-subtree', then save."
  (eca-org-agenda--with-entry-at
   file pos
   (lambda ()
     (let ((title (eca-org-agenda--plain-string (org-get-heading t t t t)))
           (todo (eca-org-agenda--plain-string (org-get-todo-state)))
           (id (or (eca-org-agenda--plain-string (org-entry-get nil "ID"))
                   (when eca-org-agenda-add-id (org-id-get-create)))))
       (let ((org-archive-subtree-save-file-p t))
         (org-archive-subtree))
       (list :archived t :id id :todo todo :title title :file (buffer-file-name))))))

(defun eca-org-agenda-archive-id (id)
  "Archive the subtree identified by ID using `org-archive-subtree', then save."
  (eca-org-agenda--with-entry-id
   id
   (lambda ()
     (let ((title (eca-org-agenda--plain-string (org-get-heading t t t t)))
           (todo (eca-org-agenda--plain-string (org-get-todo-state)))
           (entry-id (or (eca-org-agenda--plain-string (org-entry-get nil "ID"))
                         (when eca-org-agenda-add-id (org-id-get-create)))))
       (let ((org-archive-subtree-save-file-p t))
         (org-archive-subtree))
       (list :archived t :id entry-id :todo todo :title title :file (buffer-file-name))))))

(defun eca-org-agenda-refile-id-to-file (id target-file)
  "Move subtree ID to TARGET-FILE as a top-level entry.
Returns a detailed plist for the moved entry at its new location."
  (let ((marker (eca-org-agenda--find-id-marker id)))
    (unwind-protect
        (with-current-buffer (marker-buffer marker)
          (unless (derived-mode-p 'org-mode) (org-mode))
          (save-restriction
            (widen)
            (goto-char (marker-position marker))
            (org-back-to-heading t)
            (let* ((source-file (buffer-file-name))
                   (source-start (point))
                   (source-end (save-excursion
                                 (org-end-of-subtree t t)
                                 (point)))
                   (tree (eca-org-agenda--current-subtree-text))
                   (target-path (eca-org-agenda--resolve-file target-file)))
              (delete-region source-start source-end)
              (save-buffer)
              (let ((result (eca-org-agenda--insert-subtree-at-end-of-file target-path tree)))
                (org-id-update-id-locations (delete-dups (list source-file target-path)) t)
                (append result (list :refiled t :source-file source-file))))))
      (set-marker marker nil))))

(defun eca-org-agenda-refile-id-to-id (id target-id)
  "Move subtree ID to become the last child of TARGET-ID.
Returns a detailed plist for the moved entry at its new location."
  (let ((source-marker (eca-org-agenda--find-id-marker id))
        (target-marker (eca-org-agenda--find-id-marker target-id)))
    (unwind-protect
        (with-current-buffer (marker-buffer source-marker)
          (unless (derived-mode-p 'org-mode) (org-mode))
          (save-restriction
            (widen)
            (goto-char (marker-position source-marker))
            (org-back-to-heading t)
            (let* ((source-file (buffer-file-name))
                   (source-start (point))
                   (source-end (save-excursion
                                 (org-end-of-subtree t t)
                                 (point)))
                   (tree (eca-org-agenda--current-subtree-text))
                   (target-file (buffer-file-name (marker-buffer target-marker)))
                   (target-pos (marker-position target-marker)))
              (when (equal (eca-org-agenda--plain-string (org-entry-get nil "ID"))
                           (eca-org-agenda--require-non-empty-string target-id "target-id"))
                (user-error "eca-org-agenda: cannot refile an entry under itself"))
              (when (and (eq (marker-buffer source-marker) (marker-buffer target-marker))
                         (>= target-pos source-start)
                         (< target-pos source-end))
                (user-error "eca-org-agenda: cannot refile an entry into its own subtree"))
              (delete-region source-start source-end)
              (save-buffer)
              (let ((result (eca-org-agenda--insert-subtree-under-marker target-marker tree)))
                (org-id-update-id-locations (delete-dups (list source-file target-file)) t)
                (append result (list :refiled t :source-file source-file :target-id target-id))))))
      (set-marker source-marker nil)
      (set-marker target-marker nil))))
(provide 'eca-org-agenda-bridge)
;;; eca-org-agenda-bridge.el ends here
