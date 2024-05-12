;;; bufferlo.el --- Manage frame/tab-local buffer lists -*- lexical-binding: t -*-

;; Copyright (C) 2021-2024 Free Software Foundation, Inc.

;; Author: Florian Rommel <mail@florommel.de>
;; Maintainer: Florian Rommel <mail@florommel.de>
;; Url: https://github.com/florommel/bufferlo
;; Created: 2021-09-15
;; Version: 0.7
;; Package-Requires: ((emacs "27.1"))
;; Keywords: buffer frame tabs local

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; This gives you separate buffer lists per frame and per (tab-bar) tab.

;; Bufferlo is a lightweight wrapper around Emacs's buffer-list frame
;; parameter.  In contrast to similar solutions, it integrates
;; seamlessly with the standard frame and tab management facilities,
;; including undeletion of frame and tabs, tab duplication and moving,
;; frame cloning, and persisting sessions (via desktop.el).

;; With bufferlo, every frame or tab (if you use tab-bar tabs) has an
;; additional manageable local buffer list.  A buffer is added to the
;; local buffer list when displayed in the frame/tab (e.g., by opening
;; a new file in the tab or by switching to the buffer from the global
;; buffer list).  Bufferlo provides extensive management functions for
;; the local list and frame/tab-local variants of the switch-buffer
;; function, buffer menu, and Ibuffer.  In addition, you can configure
;; any command that selects a buffer to use the local buffer list
;; (bufferlo anyhwere).  Bufferlo also allows you to bookmark and
;; persist the state of individual frames or tabs.

;;; Code:

(require 'seq)
(require 'tab-bar)
(require 'desktop)
(require 'bookmark)

(defgroup bufferlo nil
  "Manage frame/tab-local buffer lists."
  :group 'convenience)

(defcustom bufferlo-prefer-local-buffers t
  "Use a frame predicate to prefer local buffers over global ones.
This means that a local buffer will be preferred to be displayed
when the current buffer disappears (buried or killed).
This is also required to make `next-buffer' and `previous-buffer'
work as expected.
Changes to this variable must be made before enabling
`bufferlo-mode' in order to take effect."
  :type 'boolean)

(defcustom bufferlo-include-buried-buffers t
  "Include buried buffers in the local list (`bufferlo-buffer-list').
Use `bufferlo-bury' to remove and bury a buffer if this is set to t."
  :type 'boolean)

(defcustom bufferlo-include-buffer-filters nil
  "Buffers that should always get included in a new tab or frame.
This is a list of regular expressions that match buffer names.
This is applied on frame and tab creation.  Included buffers can be
explicitly removed later.
This overrides buffers excluded by `bufferlo-exclude-buffer-filters.'"
  :type '(repeat string))

(defcustom bufferlo-exclude-buffer-filters '(".*")
  "Buffers that should always get excluded in a new tab or frame.
This is a list of regular expressions that match buffer names.
This is applied on frame and tab creation.  Excluded buffers can be
added explicitly later.  Use `bufferlo-hidden-buffers' to permanently
hide buffers from the local list.
Buffers included by `bufferlo-include-buffer-filters' take precedence."
  :type '(repeat string))

(defcustom bufferlo-hidden-buffers nil
  "List of regexps matching names of buffers to hide in the local buffer lists.
Matching buffers are hidden even if displayed in the current frame or tab."
  :type '(repeat string))

(defcustom bufferlo-kill-buffers-exclude-filters
  '("\\` " "\\`\\*Messages\\*\\'" "\\`\\*scratch\\*\\'")
  "Buffers that should not be killed by `bufferlo-kill-buffers'.
This is a list of regular expressions that match buffer names."
  :type '(repeat string))

(defcustom bufferlo-ibuffer-bind-local-buffer-filter t
  "If non-nil, bind the local buffer filter and the orphan filter in ibuffer.
The local buffer filter is bound to \"/ l\" and the orphan filter to \"/ L\"."
  :type 'boolean)

(defcustom bufferlo-local-scratch-buffer-name "*local scratch*"
  "Base name of the local scratch buffer.
Multiple frame/tabs will use `generate-new-buffer-name' (which
appends \"<N>\" to the name) in order to get a unique buffer.

Local scratch buffers are optional and not used by default.
Use the following functions to create and work with them:
`bufferlo-create-local-scratch-buffer',
`bufferlo-get-local-scratch-buffer',
`bufferlo-switch-to-local-scratch-buffer',
and `bufferlo-toggle-local-scratch-buffer'.
For example, create a dedicated local scratch buffer for all tabs and frames:
  (setq \\='tab-bar-new-tab-choice #\\='bufferlo-create-local-scratch-buffer)
  (add-hook \\='after-make-frame-functions
             #\\='bufferlo-switch-to-local-scratch-buffer)

You can set this to \"*scratch*\"."
  :type 'string)

(defcustom bufferlo-local-scratch-buffer-initial-major-mode nil
  "The initial major mode for local scratch buffers.
If nil, the local scratch buffers' major mode is set to `initial-major-mode'."
  :type 'function)

(defcustom bufferlo-anywhere-filter '(switch-to-buffer
                                      bufferlo-switch-to-buffer
                                      bufferlo-find-buffer
                                      bufferlo-find-buffer-switch)
  "The functions that use the local buffer list in `bufferlo-anywhere-mode'.
If `bufferlo-anywhere-filter-type' is set to `exclude', this is an exclude
filter (i.e., determines the functions that do not use the local buffer list).
If `bufferlo-anywhere-filter-type' is set to `include' (or any other value),
this is an include filter.
The value can either be a list of functions, or t (for all functions),
or a custom filter function that takes a function symbol as its argument and
returns whether the probed function should be filtered (non-nil) or
not-filtered (nil)."
  :type '(choice (repeat   :tag "Filter specific functions" function)
                 (const    :tag "All functions" t)
                 (function :tag "Custom filter function")))

(defcustom bufferlo-anywhere-filter-type 'exclude
  "Determines whether `bufferlo-anywhere-filter' is an include or exclude filter.
Set this to `include' or `exclude'."
  :type '(radio (const :tag "Include filter" include)
                (const :tag "Exclude filter" exclude)))

(defcustom bufferlo-bookmark-map-functions nil
  "Functions to call for every local buffer when making a tab bookmark.
Each function takes a bookmark record as its argument.  The corresponding
buffer is set as current buffer.  Every function should return a valid
bookmark record or nil.  The first function gets the buffer's default
bookmark record or nil if it is not bookmarkable.  Subsequent functions
receive the bookmark record that the previous function returned as their
argument.  The bookmark record of the last function is used as the
effective record.  If the last function returns nil, no record for the
respective buffer is included in the frame or tab bookmark.

These functions are also called when creating a frame bookmark, since a
frame bookmark is a collection of tab bookmarks."
  :type 'hook)

(defvar bufferlo--desktop-advice-active nil)
(defvar bufferlo--desktop-advice-active-force nil)

(defvar bufferlo--clear-buffer-lists-active nil)

;;;###autoload
(define-minor-mode bufferlo-mode
  "Manage frame/tab-local buffers."
  :global t
  :require 'bufferlo
  :init-value nil
  :lighter nil
  :keymap nil
  (if bufferlo-mode
      (progn
        ;; Prefer local buffers
        (when bufferlo-prefer-local-buffers
          (dolist (frame (frame-list))
            (bufferlo--set-buffer-predicate frame))
          (add-hook 'after-make-frame-functions #'bufferlo--set-buffer-predicate))
        ;; Include/exclude buffers
        (add-hook 'after-make-frame-functions #'bufferlo--include-exclude-buffers)
        (add-hook 'tab-bar-tab-post-open-functions #'bufferlo--tab-include-exclude-buffers)
        ;; Save/restore local buffer list
        (advice-add #'window-state-get :around #'bufferlo--window-state-get)
        (advice-add #'window-state-put :after #'bufferlo--window-state-put)
        ;; Desktop support
        (advice-add #'frameset--restore-frame :around #'bufferlo--activate)
        ;; Duplicate/move tabs
        (advice-add #'tab-bar-select-tab :around #'bufferlo--activate-force)
        ;; Clone & undelete frame
        (when (>= emacs-major-version 28)
          (advice-add #'clone-frame :around #'bufferlo--activate-force))
        (when (>= emacs-major-version 29)
          (advice-add #'undelete-frame :around #'bufferlo--activate-force))
        ;; Switch-tab workaround
        (advice-add #'tab-bar-select-tab :around #'bufferlo--clear-buffer-lists-activate)
        (advice-add #'tab-bar--tab :after #'bufferlo--clear-buffer-lists))
    ;; Prefer local buffers
    (dolist (frame (frame-list))
      (bufferlo--reset-buffer-predicate frame))
    (remove-hook 'after-make-frame-functions #'bufferlo--set-buffer-predicate)
    ;; Include/exclude buffers
    (remove-hook 'after-make-frame-functions #'bufferlo--include-exclude-buffers)
    (remove-hook 'tab-bar-tab-post-open-functions #'bufferlo--tab-include-exclude-buffers)
    ;; Save/restore local buffer list
    (advice-remove #'window-state-get #'bufferlo--window-state-get)
    (advice-remove #'window-state-put #'bufferlo--window-state-put)
    ;; Desktop support
    (advice-remove #'frameset--restore-frame #'bufferlo--activate)
    ;; Duplicate/move tabs
    (advice-remove #'tab-bar-select-tab #'bufferlo--activate-force)
    ;; Clone & undelete frame
    (when (>= emacs-major-version 28)
      (advice-remove #'clone-frame #'bufferlo--activate-force))
    (when (>= emacs-major-version 29)
      (advice-remove #'undelete-frame #'bufferlo--activate-force))
    ;; Switch-tab workaround
    (advice-remove #'tab-bar-select-tab #'bufferlo--clear-buffer-lists-activate)
    (advice-remove #'tab-bar--tab #'bufferlo--clear-buffer-lists)))

(defun bufferlo-local-buffer-p (buffer &optional frame tabnum include-hidden)
  "Return non-nil if BUFFER is in the list of local buffers.
A non-nil value of FRAME selects a specific frame instead of the current one.
If TABNUM is nil, the current tab is used.  If it is non-nil, it specifies
a tab index in the given frame.  If INCLUDE-HIDDEN is set, include hidden
buffers, see `bufferlo-hidden-buffers'."
  (memq buffer (bufferlo-buffer-list frame tabnum include-hidden)))

(defun bufferlo-non-local-buffer-p (buffer &optional frame tabnum include-hidden)
  "Return non-nil if BUFFER is not in the list of local buffers.
A non-nil value of FRAME selects a specific frame instead of the current one.
If TABNUM is nil, the current tab is used.  If it is non-nil, it specifies
a tab index in the given frame.  If INCLUDE-HIDDEN is set, include hidden
buffers, see `bufferlo-hidden-buffers'."
  (not (bufferlo-local-buffer-p buffer frame tabnum include-hidden)))

(defun bufferlo--clear-buffer-lists (&optional frame)
  "This is a workaround advice function to fix tab-bar's tab switching behavior.
On `tab-bar-select-tab', when `wc-bl' or `wc-bbl' is nil, the function does not
set the correspoinding `buffer-list' / `buried-buffer-list' frame parameters.
As a result the previous tab's values remain active.

To mitigate this, this functions clears `buffer-list' and `buried-buffer-list'.
It should be set up as an advice after `tab-bar--tab' and takes its FRAME
parameter.  In addition, `bufferlo--clear-buffer-lists-activate' must be
set up as a advice around `tab-bar-select-tab' to activate this function
when `tab-bar--tab' is called from `tab-bar-select-tab."
  (when bufferlo--clear-buffer-lists-active
    (set-frame-parameter frame 'buffer-list nil)
    (set-frame-parameter frame 'buried-buffer-list nil)))

(defun bufferlo--clear-buffer-lists-activate (oldfn &rest args)
  "This should be set up as a advice around `tab-bar-select-tab'.
It actiavtes clearing the buffer lists for `tab-bar--tab'
before calling OLDFN with ARGS.  See `bufferlo--clear-buffer-lists'."
  (let* ((bufferlo--clear-buffer-lists-active t)
         (result (apply oldfn args)))

    ;; Occasionally it happens that a non-local buffer is shown in the tab,
    ;; after switching frames, primarily with empty tabs.
    ;; This workaround selects a buffer that is in the local list in such a case.
    (unless (bufferlo-local-buffer-p (current-buffer) nil nil t)
      (let ((buffer (or
                     (seq-find (lambda (b) (not (minibufferp b)))
                               (frame-parameter nil 'buffer-list))
                     (seq-find (lambda (b) (not (minibufferp b)))
                               (frame-parameter nil 'buried-buffer-list)))))
        (switch-to-buffer buffer t t)))

    result))

(defun bufferlo--buffer-predicate (buffer)
  "Return whether BUFFER is local to the current fram/tab.
Includes hidden buffers."
  (bufferlo-local-buffer-p buffer nil nil t))

(defun bufferlo--set-buffer-predicate (frame)
  "Set the buffer predicate of FRAME to `bufferlo--buffer-predicate'."
  (set-frame-parameter frame 'buffer-predicate #'bufferlo--buffer-predicate))

(defun bufferlo--reset-buffer-predicate (frame)
  "Reset the buffer predicate of FRAME if it is `bufferlo--buffer-predicate'."
  (when (eq (frame-parameter frame 'buffer-predicate) #'bufferlo--buffer-predicate)
    (set-frame-parameter frame 'buffer-predicate nil)))

(defun bufferlo--merge-regexp-list (regexp-list)
  "Merge a list of regular expressions REGEXP-LIST."
  (mapconcat (lambda (x)
               (concat "\\(?:" x "\\)"))
             regexp-list "\\|"))

(defun bufferlo--include-exclude-buffers (frame)
  "Include and exclude buffers from the local buffer list of FRAME."
  (let* ((include (bufferlo--merge-regexp-list
                   (append '("a^") bufferlo-include-buffer-filters)))
         (exclude (bufferlo--merge-regexp-list
                   (append '("a^") bufferlo-exclude-buffer-filters)))
         (buffers (bufferlo--current-buffers frame))
         (buffers (seq-filter (lambda (b)
                                (not (string-match-p exclude (buffer-name b))))
                              buffers))
         (incl-buffers (seq-filter (lambda (b)
                                     (string-match-p include (buffer-name b)))
                                   (buffer-list frame)))
         (buffers (delete-dups (append buffers incl-buffers))))
    ;; FIXME: Currently all the included buffers are put into the 'buffer-list,
    ;;        even if they were in the 'buried-buffer-list before.
    (set-frame-parameter frame 'buffer-list
                         ;; The current buffer must be always on the list,
                         ;; otherwise the buffer list gets replaced later.
                         (push (if frame
                                   (with-selected-frame frame (current-buffer))
                                 (current-buffer))
                               buffers))
    (set-frame-parameter frame 'buried-buffer-list nil)))

(defun bufferlo--tab-include-exclude-buffers (ignore)
  "Include and exclude buffers from the buffer list of the current tab's frame.
Argument IGNORE is for compatibility with `tab-bar-tab-post-open-functions'."
  (ignore ignore)
  ;; Reset the local buffer list unless we clone the tab (tab-duplicate).
  (unless (or (eq tab-bar-new-tab-choice 'clone)
              (and (< emacs-major-version 29)
                   (not tab-bar-new-tab-choice)))
    (bufferlo--include-exclude-buffers nil)))

(defun bufferlo--current-buffers (frame)
  "Get the buffers of the current tab in FRAME."
  (if bufferlo-include-buried-buffers
      (append
       (frame-parameter frame 'buffer-list)
       (frame-parameter frame 'buried-buffer-list))
    (frame-parameter frame 'buffer-list)))

(defun bufferlo--get-tab-buffers (tab)
  "Extract buffers from the given TAB structure."
  (or
   (if bufferlo-include-buried-buffers
       (append
        (cdr (assq 'wc-bl tab))
        (cdr (assq 'wc-bbl tab)))
     (cdr (assq 'wc-bl tab)))
   ;; fallback to bufferlo-buffer-list, managed by bufferlo--window-state-*
   (mapcar 'get-buffer
           (car (cdr (assq 'bufferlo-buffer-list (assq 'ws tab)))))))

(defun bufferlo-buffer-list (&optional frame tabnum include-hidden)
  "Return a list of all live buffers associated with the current frame and tab.
A non-nil value of FRAME selects a specific frame instead of the current one.
If TABNUM is nil, the current tab is used.  If it is non-nil, it specifies
a tab index in the given frame.  If INCLUDE-HIDDEN is set, include hidden
buffers, see `bufferlo-hidden-buffers'."
  (let ((list
         (if tabnum
             (let ((tab (nth tabnum (frame-parameter frame 'tabs))))
               (if (eq 'current-tab (car tab))
                   (bufferlo--current-buffers frame)
                 (bufferlo--get-tab-buffers tab)))
           (bufferlo--current-buffers frame))))
    (if include-hidden
        (seq-filter #'buffer-live-p list)
      (seq-filter (lambda (buffer)
                    (let ((hidden (bufferlo--merge-regexp-list
                                   (append '("a^") bufferlo-hidden-buffers))))
                      (and
                       (buffer-live-p buffer)
                       (not (string-match-p hidden (buffer-name buffer))))))
                  list))))

(defun bufferlo--window-state-get (oldfn &optional window writable)
  "Save the frame's buffer list to the window state.
Used as advice around `window-state-get'.  OLDFN is the original
function.  WINDOW and WRITABLE are passed to the function."
  (let ((ws (apply oldfn (list window writable))))
    (let* ((buffers (bufferlo--current-buffers (window-frame window)))
           (names (mapcar #'buffer-name buffers)))
      (if names (append ws (list (list 'bufferlo-buffer-list names))) ws))))

(defun bufferlo--window-state-put (state &optional window ignore)
  "Restore the frame's buffer list from the window state.
Used as advice after `window-state-put'.  STATE is the window state.
WINDOW is the window in question.  IGNORE is not used and exists for
compatibility with the adviced function."
  (ignore ignore)
  ;; We have to make sure that the window is live at this point.
  ;; `frameset-restore' may pass a window with a non-existing buffer
  ;; to `window-state-put', which in turn will delete that window
  ;; before the advice calls us.
  ;; This is not the case when we are called from `tab-bar-select-tab'.
  (when (or bufferlo--desktop-advice-active-force
            (and bufferlo--desktop-advice-active (window-live-p window)))
    ;; FIXME: Currently there is no distinction between buffers and
    ;;        buried buffers for dektop.el.
    (let ((bl (car (cdr (assq 'bufferlo-buffer-list state)))))
      (set-frame-parameter (window-frame window) 'buffer-list
                           ;; The current buffer must be always on the list,
                           ;; otherwise the buffer list gets replaced later.
                           (cons (window-buffer window)
                                 (mapcar #'get-buffer bl)))
      (set-frame-parameter (window-frame window) 'buried-buffer-list
                           (list (window-buffer window))))))

(defun bufferlo--activate (oldfn &rest args)
  "Activate the advice for `bufferlo--window-state-{get,put}'.
OLDFN is the original function.  ARGS is for compatibility with
the adviced functions."
  (let ((bufferlo--desktop-advice-active t))
    (apply oldfn args)))

(defun bufferlo--activate-force (oldfn &rest args)
  "Activate the advice for `bufferlo--window-state-{get,put}'.
OLDFN is the original function.  ARGS is for compatibility with
the adviced functions."
  (let ((bufferlo--desktop-advice-active t)
        (bufferlo--desktop-advice-active-force t))
    (apply oldfn args)))

(defsubst bufferlo--warn ()
  "Warn if `bufferlo-mode' is not enabled."
  (defvar bufferlo--warn-current-command nil)
  (when (and (not bufferlo-mode)
             (not (eq this-command bufferlo--warn-current-command)))
    (setq bufferlo--warn-current-command this-command)
    (message (format "%s: bufferlo-mode should be enabled"
                     this-command))))

(defun bufferlo-clear (&optional frame)
  "Clear the frame/tab's buffer list, except for the current buffer.
If FRAME is nil, use the current frame."
  (interactive)
  (bufferlo--warn)
  (set-frame-parameter frame 'buffer-list
                       (list (if frame
                                 (with-selected-frame frame
                                   (current-buffer))
                               (current-buffer))))
  (set-frame-parameter frame 'buried-buffer-list nil))

(defun bufferlo-remove (buffer)
  "Remove BUFFER from the frame/tab's buffer list."
  (interactive
   (list
    (let ((lbs (mapcar (lambda (b) (buffer-name b))
                       (bufferlo-buffer-list))))
      (read-buffer "Remove buffer: " nil t
                   (lambda (b) (member (car b) lbs))))))
  (bufferlo--warn)
  (let ((bl (frame-parameter nil 'buffer-list))
        (bbl (frame-parameter nil 'buried-buffer-list))
        (buffer (get-buffer buffer)))
    (set-frame-parameter nil 'buffer-list (delq buffer bl))
    (set-frame-parameter nil 'buried-buffer-list (delq buffer bbl))
    ;; Adapted from bury-buffer:
    (cond
     ((or (not (eq buffer (window-buffer)))
          ;; Don't try to delete the minibuffer window, undedicate it
          ;; or switch to a previous buffer in it.
          (window-minibuffer-p)))
     ((window--delete nil t))
     (t
      ;; Switch to another buffer in window.
      (set-window-dedicated-p nil nil)
      (switch-to-prev-buffer nil 'bury)))
    nil))

(defun bufferlo-remove-non-exclusive-buffers ()
  "Remove all buffers from the local buffer list that are not exclusive to it."
  (interactive)
  (bufferlo--warn)
  (dolist (buffer (bufferlo--get-exclusive-buffers nil t))
    (bufferlo-remove buffer)))

(defun bufferlo-bury (&optional buffer-or-name)
  "Bury and remove the buffer specified by BUFFER-OR-NAME from the local list.
If `bufferlo-include-buried-buffers' is set to nil then this has the same
effect as a simple `bury-buffer'."
  (interactive)
  (bufferlo--warn)
  (let ((buffer (window-normalize-buffer buffer-or-name)))
    (bury-buffer-internal buffer)
    (bufferlo-remove buffer)))

(defun bufferlo--get-captured-buffers (&optional exclude-frame)
  "Get all buffers that are in a local list of at least one frame or tab.
If EXCLUDE-FRAME is a frame, exclude the local buffer list of this frame."
  (let* ((flatten (lambda (list)
                    (apply #'append (append list '(nil)))))
         (get-inactive-tabs-buffers (lambda (f)
                                      (funcall flatten
                                               (mapcar
                                                #'bufferlo--get-tab-buffers
                                                (frame-parameter f 'tabs)))))
         (get-frames-buffers (lambda ()
                               (funcall flatten
                                        (mapcar
                                         (lambda (f)
                                           (unless (eq f exclude-frame)
                                             (bufferlo--current-buffers f)))
                                         (frame-list))))))
    (seq-uniq
     (funcall flatten
              (list
               (funcall flatten (mapcar get-inactive-tabs-buffers (frame-list)))
               (funcall get-frames-buffers))))))

(defun bufferlo--get-orphan-buffers ()
  "Get all buffers that are not in any local list of a frame or tab."
  (seq-filter (lambda (b)
                (not (memq b (bufferlo--get-captured-buffers))))
              (buffer-list)))

(defun bufferlo--get-exclusive-buffers (&optional frame invert)
  "Get all buffers that are exclusive to this frame and tab.
If FRAME is nil, use the current frame.
If INVERT is non-nil, return the non-exclusive buffers instead."
  (let ((other-bufs (bufferlo--get-captured-buffers (or frame (selected-frame))))
        (this-bufs (bufferlo--current-buffers frame)))
    (seq-filter (if invert
                    (lambda (b) (memq b other-bufs))
                  (lambda (b) (not (memq b other-bufs))))
                this-bufs)))

(defun bufferlo-kill-buffers (&optional killall frame)
  "Kill the buffers of the frame/tab-local buffer list.
By default, this will only kill buffers that are exclusive to the frame/tab.
If KILLALL (prefix argument) is given then buffers that are also present in the
local lists of other frames and tabs are killed too.
Buffers matching `bufferlo-kill-buffers-exclude-filters' are never killed.
If FRAME is nil, use the current frame."
  (interactive "P")
  (bufferlo--warn)
  (let ((exclude (bufferlo--merge-regexp-list
                  (append '("a^") bufferlo-kill-buffers-exclude-filters)))
        (kill-list (if killall
                       (bufferlo--current-buffers frame)
                     (bufferlo--get-exclusive-buffers frame))))
    (dolist (buffer kill-list)
      (unless (string-match-p exclude (buffer-name buffer))
        (kill-buffer buffer)))))

(defun bufferlo-kill-orphan-buffers ()
  "Kill all buffers that are not in any local list of a frame or tab.
Buffers matching `bufferlo-kill-buffers-exclude-filters' are never killed."
  (interactive)
  (bufferlo--warn)
  (let ((exclude (bufferlo--merge-regexp-list
                  (append '("a^") bufferlo-kill-buffers-exclude-filters))))
    (dolist (buffer (bufferlo--get-orphan-buffers))
      (unless (string-match-p exclude (buffer-name buffer))
        (kill-buffer buffer)))))

(defun bufferlo-delete-frame-kill-buffers (&optional frame)
  "Delete a frame and kill the local buffers.
If FRAME is nil, kill the current frame."
  (interactive)
  (bufferlo--warn)
  (bufferlo-kill-buffers frame)
  (delete-frame))

(defun bufferlo-tab-close-kill-buffers (&optional killall)
  "Close the current tab and kill the local buffers.
The optional parameter KILLALL is passed to `bufferlo-kill-buffers'"
  (interactive "P")
  (bufferlo--warn)
  (bufferlo-kill-buffers killall)
  (tab-bar-close-tab))

(defun bufferlo-isolate-project (&optional file-buffers-only)
  "Isolate a project in the frame or tab.
Remove all buffers that do not belong to the current project from
the local buffer list.  When FILE-BUFFERS-ONLY is non-nil or the
prefix argument is given, remove only buffers that visit a file.
Buffers matching `bufferlo-include-buffer-filters' are not removed."
  (interactive "P")
  (bufferlo--warn)
  (let ((curr-project (project-current))
        (include (bufferlo--merge-regexp-list
                  (append '("a^") bufferlo-include-buffer-filters))))
    (if curr-project
        (dolist (buffer (bufferlo-buffer-list))
          (when (and (not (string-match-p include (buffer-name buffer)))
                     (not (equal curr-project
                                 (with-current-buffer buffer (project-current))))
                     (or (not file-buffers-only) (buffer-file-name buffer)))
            (bufferlo-remove buffer)))
      (message "Current buffer is not part of a project"))))

(defun bufferlo-find-buffer (buffer-or-name)
  "Switch to the frame/tab containing BUFFER-OR-NAME in its local list.
If multiple frame or tabs contain the buffer, interactively prompt
for the to-be-selected frame and tab.
This does not select the buffer -- just the containing frame and tab."
  (interactive "b")
  (bufferlo--warn)
  (let* ((buffer (get-buffer buffer-or-name))
         (flatten (lambda (list)
                    (apply #'append (append list '()))))
         (search-tabs (lambda (f)
                        (let ((i 0))
                          (mapcar
                           (lambda (tab)
                             (setq i (1+ i))
                             (when (bufferlo-local-buffer-p buffer f (1- i) t)
                               (list f (frame-parameter f 'name)
                                     (eq f (selected-frame))
                                     i (cdr (assq 'name tab)))))
                           (frame-parameter f 'tabs)))))
         (search-frames (lambda (f)
                          (unless (frame-parameter f 'no-accept-focus)
                            (if (frame-parameter f 'tabs)
                                ;; has tabs
                                (funcall search-tabs f)
                              ;; has no tabs
                              (when (bufferlo-local-buffer-p buffer f nil t)
                                (list (list f (frame-parameter f 'name)
                                            (eq f (selected-frame))
                                            nil nil)))))))
         (candidates (seq-filter 'identity
                                 (funcall flatten
                                          (mapcar
                                           (lambda (f)
                                             (funcall search-frames f))
                                           (frame-list)))))
         (candidates (mapcar
                      (lambda (c)
                        (let ((sel (if (nth 2 c) " [this]" ""))
                              (frame-name (nth 1 c))
                              (frame-obj  (nth 0 c))
                              (tab-index  (nth 3 c))
                              (tab-name   (nth 4 c)))
                          (if tab-index
                              (cons (format "Frame: %s (%s)%s  Tab %s: %s"
                                            frame-name frame-obj sel
                                            tab-index tab-name)
                                    c)
                            (cons (format "Frame: %s (%s)%s"
                                          frame-name frame-obj sel)
                                  c))))
                      candidates))
         (selected (if (cdr candidates)
                       (completing-read
                        "Select frame/tab: "
                        candidates
                        nil t)
                     (caar candidates)))
         (selected (assoc selected candidates)))
    (if (not selected)
        (message "Orphan: No frame/tab contains buffer '%s'" (buffer-name buffer))
      (let ((frame (nth 1 selected))
            (tab-index (nth 4 selected)))
        (select-frame-set-input-focus frame)
        (when tab-index
          (tab-bar-select-tab tab-index))
        frame))))

(defun bufferlo-find-buffer-switch (buffer-or-name)
  "Switch to the frame/tab containig BUFFER-OR-NAME and select the buffer.
This is like `bufferlo-find-buffer' but additionally selects the buffer."
  (interactive "b")
  (bufferlo--warn)
  (when (bufferlo-find-buffer buffer-or-name)
    (switch-to-buffer buffer-or-name)))

(defun bufferlo-get-local-scratch-buffer ()
  "Get the local scratch buffer or create it if not already existent and return it."
  (let ((buffer (seq-find (lambda (b)
                            (string-match-p
                             (concat
                              "^"
                              (regexp-quote bufferlo-local-scratch-buffer-name)
                              "\\(<[0-9]*>\\)?$")
                             (buffer-name b)))
                          (bufferlo-buffer-list nil nil t))))
    (unless buffer
      (setq buffer (get-buffer-create
                    (generate-new-buffer-name bufferlo-local-scratch-buffer-name)))
      (with-current-buffer buffer
        (when (eq major-mode 'fundamental-mode)
	  (funcall (or bufferlo-local-scratch-buffer-initial-major-mode
                       initial-major-mode
                       #'ignore)))))
    buffer))

(defun bufferlo-create-local-scratch-buffer ()
  "Create a local scratch buffer and return it."
  (get-buffer-create (generate-new-buffer-name bufferlo-local-scratch-buffer-name)))

(defun bufferlo-switch-to-scratch-buffer (&optional frame)
  "Switch to the scratch buffer.
When FRAME is non-nil, switch to the scratch buffer in the specified frame
instead of the current one."
  (interactive)
  (if frame
      (with-selected-frame frame
        (switch-to-buffer "*scratch*"))
    (switch-to-buffer "*scratch*")))

(defun bufferlo-switch-to-local-scratch-buffer (&optional frame)
  "Switch to the local scratch buffer.
When FRAME is non-nil, switch to the local scratch buffer in the specified frame
instead of the current one."
  (interactive)
  (if frame
      (with-selected-frame frame
        (switch-to-buffer (bufferlo-get-local-scratch-buffer)))
    (switch-to-buffer (bufferlo-get-local-scratch-buffer))))

(defun bufferlo-toggle-local-scratch-buffer ()
  "Switch to the local scratch buffer or bury it if it is already selected.
Creates a new local scratch buffer if none exists for this frame/tab."
  (interactive)
  (let ((buffer (bufferlo-get-local-scratch-buffer)))
    (if (eq buffer (current-buffer))
        (bury-buffer)
      (switch-to-buffer buffer))))

(defun bufferlo-switch-to-buffer (buffer &optional norecord force-same-window)
  "Display the BUFFER in the selected window.
Completion includes only local buffers.
This is the frame/tab-local equivilant to `switch-to-buffer'.
The arguments NORECORD and FORCE-SAME-WINDOW are passed to `switch-to-buffer'.
If the prefix arument is given, include all buffers."
  (interactive
   (list
    (if current-prefix-arg
        (read-buffer "Switch to buffer: " (other-buffer (current-buffer)) nil)
      (let ((lbs (mapcar #'buffer-name (bufferlo-buffer-list))))
        (read-buffer
         "Switch to local buffer: " (other-buffer (current-buffer)) nil
         (lambda (b) (member (if (stringp b) b (car b)) lbs)))))))
  (bufferlo--warn)
  (switch-to-buffer buffer norecord force-same-window))

(defvar-local bufferlo--buffer-menu-this-frame nil)

(defun bufferlo--local-buffer-list-this-frame ()
  "Return the local buffer list of the buffer's frame."
  (bufferlo-buffer-list bufferlo--buffer-menu-this-frame))

(defun bufferlo-list-buffers ()
  "Display a list of local buffers."
  (interactive)
  (bufferlo--warn)
  (display-buffer
   (let* ((old-buffer (current-buffer))
          (name (or
                 (seq-find (lambda (b)
                             (string-match-p
                              "\\`\\*Local Buffer List\\*\\(<[0-9]*>\\)?\\'"
                              (buffer-name b)))
                           (bufferlo-buffer-list))
                 (generate-new-buffer-name "*Local Buffer List*")))
	  (buffer (get-buffer-create name)))
     (with-current-buffer buffer
       (Buffer-menu-mode)
       (setq bufferlo--buffer-menu-this-frame (selected-frame))
       (setq Buffer-menu-files-only nil)
       (setq Buffer-menu-buffer-list #'bufferlo--local-buffer-list-this-frame)
       (setq Buffer-menu-filter-predicate nil)
       (list-buffers--refresh #'bufferlo--local-buffer-list-this-frame old-buffer)
       (tabulated-list-print)
       (revert-buffer))
     buffer)))

(defun bufferlo-list-orphan-buffers ()
  "Display a list of orphan buffers."
  (interactive)
  (bufferlo--warn)
  (display-buffer
   (let* ((old-buffer (current-buffer))
          (name "*Orphan Buffer List*")
	  (buffer (get-buffer-create name)))
     (with-current-buffer buffer
       (Buffer-menu-mode)
       (setq bufferlo--buffer-menu-this-frame (selected-frame))
       (setq Buffer-menu-files-only nil)
       (setq Buffer-menu-buffer-list #'bufferlo--get-orphan-buffers)
       (setq Buffer-menu-filter-predicate nil)
       (list-buffers--refresh #'bufferlo--get-orphan-buffers old-buffer)
       (tabulated-list-print)
       (revert-buffer))
     buffer)))

(with-eval-after-load 'ibuf-ext
  (define-ibuffer-filter bufferlo-local-buffers
      "Limit current view to local buffers."
    (:description "local buffers" :reader nil)
    (bufferlo-local-buffer-p buf))
  (define-ibuffer-filter bufferlo-orphan-buffers
      "Limit current view to orphan buffers."
    (:description "orphan buffers" :reader nil)
    (not (memq buf (bufferlo--get-captured-buffers)))))

(with-eval-after-load 'ibuffer
  (when bufferlo-ibuffer-bind-local-buffer-filter
    (require 'ibuf-ext)
    (define-key ibuffer--filter-map (kbd "l")
                #'ibuffer-filter-by-bufferlo-local-buffers)
    (define-key ibuffer--filter-map (kbd "L")
                #'ibuffer-filter-by-bufferlo-orphan-buffers)))

(defun bufferlo-ibuffer (&optional other-window-p noselect shrink)
  "Invoke `ibuffer' filtered for local buffers.
Every frame/tab gets its own local bufferlo ibuffer buffer.
The parameters OTHER-WINDOW-P NOSELECT SHRINK are passed to `ibuffer'."
  (interactive)
  (bufferlo--warn)
  (let ((name (or
               (seq-find (lambda (b)
                           (string-match-p
                            "\\`\\*Bufferlo Ibuffer\\*\\(<[0-9]*>\\)?\\'"
                            (buffer-name b)))
                         (bufferlo-buffer-list))
               (generate-new-buffer-name "*Bufferlo Ibuffer*"))))
    (ibuffer other-window-p name '((bufferlo-local-buffers . nil))
             noselect shrink)))

(defun bufferlo-ibuffer-orphans (&optional other-window-p noselect shrink)
  "Invoke `ibuffer' filtered for orphan buffers.
The parameters OTHER-WINDOW-P NOSELECT SHRINK are passed to `ibuffer'."
  (interactive)
  (bufferlo--warn)
  (let ((name "*Bufferlo Orphans Ibuffer*"))
    (ibuffer other-window-p name '((bufferlo-orphan-buffers . nil))
             noselect shrink)))

(define-minor-mode bufferlo-anywhere-mode
  "Frame/tab-local buffer lists anywhere you like.
Enables bufferlo's local buffer list for any function that interactively prompts
for buffers via `read-buffer'.  By default this enables the local buffer list
for (almost) all functions.  Customize `bufferlo-anywhere-filter' and
`bufferlo-anywhere-filter-type' to adapt the behavior.
This minor mode requires `bufferlo-mode' to be enabled.
You can use `bufferlo-anywhere-disable' to disable the local buffer list for
the next command, when the mode is enabled."
  :global t
  :require 'bufferlo
  :init-value nil
  :lighter nil
  :keymap nil
  (if bufferlo-anywhere-mode
      (progn
        (bufferlo--warn)
        (advice-add #'call-interactively
                    :around #'bufferlo--interactive-advice))
    (advice-remove #'call-interactively #'bufferlo--interactive-advice)))

(defvar bufferlo--anywhere-tmp-enabled nil)
(defvar bufferlo--anywhere-tmp-disabled nil)
(defvar bufferlo--anywhere-old-read-buffer-function nil)
(defvar bufferlo--anywhere-nested nil)

(defun bufferlo--interactive-advice (oldfn function &optional record-flags keys)
  "Advice function for `call-interactively' for `bufferlo-anywhere-mode'.
Temporarily overrides the `read-buffer-function' to filter the
available buffers to bufferlo's local buffer list.
OLDFN is the original function.
FUNCTION is the interactively called functions.
RECORD-FLAGS and KEYS are passed to `call-interactively'."
  (if (or bufferlo--anywhere-tmp-enabled
          (and (not bufferlo--anywhere-tmp-disabled)
               (xor (eq bufferlo-anywhere-filter-type 'exclude)
                    (cond
                     ((eq bufferlo-anywhere-filter t) t)
                     ((listp bufferlo-anywhere-filter)
                      (memq function bufferlo-anywhere-filter))
                     ((functionp bufferlo-anywhere-filter)
                      (funcall bufferlo-anywhere-filter function))))))
      (let* ((bufferlo--anywhere-old-read-buffer-function
              ;; Preserve the original `read-buffer-function' but not for
              ;; nested calls; otherwise we would save our own function.
              (if bufferlo--anywhere-nested
                  bufferlo--anywhere-old-read-buffer-function
                read-buffer-function))
             (bufferlo--anywhere-nested t)
             (read-buffer-function
              (lambda (prompt &optional def require-match predicate)
                (let ((read-buffer-function
                       bufferlo--anywhere-old-read-buffer-function))
                  (read-buffer prompt def require-match
                               (lambda (b)
                                 (and (bufferlo-local-buffer-p
                                       (get-buffer
                                        (if (stringp b) b (car b))))
                                      (or (not predicate)
                                          (funcall predicate b)))))))))
        (apply oldfn (list function record-flags keys)))
    ;; `call-interactively' can be nested, e.g., on M-x invocations.
    ;; Therefore, we restore the original value of the `read-buffer-function'
    ;; if we do not use bufferlo's local buffer list for this call.
    (let ((read-buffer-function
           (if bufferlo--anywhere-nested
               bufferlo--anywhere-old-read-buffer-function
             read-buffer-function)))
      (apply oldfn (list function record-flags keys)))))

(defun bufferlo-anywhere-disable-prefix ()
  "Disable `bufferlo-anywhere-mode' only for the next command.
Has no effect if `bufferlo-anywhere-mode' is not enabled.
Has no effect if the next command does not query for a buffer."
  (interactive)
  (let* ((command this-command)
         (minibuffer-depth (minibuffer-depth))
         (postfun (make-symbol "bufferlo--anywhere-reenable-next-command")))
    (fset postfun
          (lambda ()
            (unless (or
                     ;; from window.el:display-buffer-override-next-command
		     (> (minibuffer-depth) minibuffer-depth)
		     (eq this-command command))
              (setq bufferlo--anywhere-tmp-disabled nil)
              (remove-hook 'post-command-hook postfun))))
    (setq bufferlo--anywhere-tmp-disabled t)
    (add-hook 'post-command-hook postfun)))

(defun bufferlo-anywhere-enable-prefix ()
  "Use bufferlo's local buffer list for the next command.
Has a similar effect as `bufferlo-anywhere-mode' but only for the next command.
Has no effect if the next command does not query for a buffer.
Can be used with or without `bufferlo-anywhere-mode' enabled.
In contrast to `bufferlo-anywhere-mode', this does not adhere to
`bufferlo-anywhere-filter'.  Therefore, you can use it in conjunction with
`bufferlo-anywhere-mode' to temporarily disable the configured filters."
  (interactive)
  (let* ((command this-command)
         (minibuffer-depth (minibuffer-depth))
         (postfun (make-symbol "bufferlo--anywhere-disable-next-command")))
    (fset postfun
          (lambda ()
            (unless (or
                     ;; from window.el:display-buffer-override-next-command
		     (> (minibuffer-depth) minibuffer-depth)
		     (eq this-command command))
              (setq bufferlo--anywhere-tmp-enabled nil)
              (unless bufferlo-anywhere-mode
                (advice-remove #'call-interactively
                               #'bufferlo--interactive-advice))
              (remove-hook 'post-command-hook postfun))))
    (setq bufferlo--anywhere-tmp-enabled t)
    (unless bufferlo-anywhere-mode
      (advice-add #'call-interactively :around #'bufferlo--interactive-advice))
    (add-hook 'post-command-hook postfun)))

(defun bufferlo--bookmark-get-for-buffer (buffer)
  "Get `buffer-name' and bookmark for BUFFER."
  (with-current-buffer buffer
    (let ((record (when (or (and (eq bookmark-make-record-function
                                     #'bookmark-make-record-default)
                                 (ignore-errors (bookmark-buffer-file-name)))
                            (not (eq bookmark-make-record-function
                                     #'bookmark-make-record-default)))
                    (bookmark-make-record))))
      (dolist (fn bufferlo-bookmark-map-functions)
        (setq record (funcall fn record)))
      (list (buffer-name buffer) record))))

(defun bufferlo--bookmark-get-for-buffers-in-tab (frame)
  "Get bookmarks for all buffers of the tab TABNUM in FRAME."
  (with-selected-frame (or frame (selected-frame))
    (seq-filter #'identity
                (mapcar #'bufferlo--bookmark-get-for-buffer
                        (bufferlo-buffer-list frame nil t)))))

(defun bufferlo--bookmark-tab-get (&optional name frame)
  "Get the bufferlo tab bookmark for the current tab in FRAME.
Optional argument NAME provides a name for the bookmarks.
FRAME specifies the frame; the default value of nil selects the current frame."
  `((buffer-bookmarks . ,(bufferlo--bookmark-get-for-buffers-in-tab frame))
    (buffer-list . ,(mapcar #'buffer-name (bufferlo-buffer-list frame nil t)))
    (window . ,(window-state-get (frame-root-window frame) 'writable))
    (name . ,name)
    (handler . ,#'bufferlo--bookmark-tab-handler)))

(defun bufferlo--ws-replace-buffer-names (ws replace-alist)
  "Replace buffer names according to REPLACE-ALIST in the window state WS."
  (dolist (el ws)
    (when-let (type (and (listp el) (car el)))
      (cond ((memq type '(vc hc))
             (bufferlo--ws-replace-buffer-names (cdr el) replace-alist))
            ((eq type 'leaf)
             (let ((bc (assq 'buffer (cdr el))))
               (when-let (replace (assoc (cadr bc) replace-alist))
                 (setf (cadr bc) (cdr replace)))))))))

(defun bufferlo--bookmark-tab-handler (bookmark &optional no-message)
  "Handle bufferlo tab bookmark.
The argument BOOKMARK is the to-be restored tab bookmark created via
`bufferlo--bookmark-tab-get'.  The optional argument NO-MESSAGE inhibits
the message after successfully restoring the bookmark."
  (let* ((ws (copy-tree (alist-get 'window bookmark)))
         (dummy (generate-new-buffer " *bufferlo dummy buffer*"))
         (renamed
          (mapcar
           (lambda (bm)
             (let ((org-name (car bm))
                   (record (cadr bm)))
               (set-buffer dummy)
               (condition-case err
                   (progn (funcall (or (bookmark-get-handler record)
                                       'bookmark-default-handler)
                                   record)
                          (run-hooks 'bookmark-after-jump-hook))
                 (error
                  (ignore err)
                  (message "Bufferlo tab: Could not restore %s" org-name)))
               (unless (eq (current-buffer) dummy)
                 (unless (string-equal org-name (buffer-name))
                   (cons org-name (buffer-name))))))
           (alist-get 'buffer-bookmarks bookmark)))
         (bl (mapcar (lambda (b)
                       (if-let (replace (assoc b renamed))
                           (cdr replace)
                         b))
                     (alist-get 'buffer-list bookmark)))
         (bl (seq-filter #'get-buffer bl))
         (bl (mapcar #'get-buffer bl)))
    (kill-buffer dummy)
    (bufferlo--ws-replace-buffer-names ws renamed)
    (window-state-put ws (frame-root-window))
    (set-frame-parameter nil 'buffer-list bl)
    (set-frame-parameter nil 'buried-buffer-list nil))
  (unless no-message
    (message "Restored bufferlo tab bookmark%s"
             (if-let (name (alist-get 'name bookmark))
                 (format ": %s" name) ""))))

(defun bufferlo--bookmark-frame-get (&optional name frame)
  "Get the bufferlo frame bookmark.
Optional argument NAME provides a name for the bookmarks.
FRAME specifies the frame; the default value of nil selects the current frame."
  (let ((org-tab (1+ (tab-bar--current-tab-index nil frame)))
        (tabs nil))
    (dotimes (i (length (funcall tab-bar-tabs-function)))
      (tab-bar-select-tab (1+ i))
      (let* ((curr (alist-get 'current-tab (funcall tab-bar-tabs-function)))
             (name (alist-get 'name curr))
             (explicit-name (alist-get 'explicit-name curr))
             (tbm (bufferlo--bookmark-tab-get nil frame)))
        (if explicit-name
            (push (cons 'tab-name name) tbm)
          (push (cons 'tab-name nil) tbm))
        (push tbm tabs)))
    (tab-bar-select-tab org-tab)
    `((tabs . ,(reverse tabs))
      (current . ,org-tab)
      (name . ,name)
      (handler . ,#'bufferlo--bookmark-frame-handler))))

(defun bufferlo--bookmark-frame-handler (bookmark &optional no-message)
  "Handle bufferlo frame bookmark.
The argument BOOKMARK is the to-be restored frame bookmark created via
`bufferlo--bookmark-frame-get'.  The optional argument NO-MESSAGE inhibits
the message after successfully restoring the bookmark."
  (if (>= emacs-major-version 28)
      (tab-bar-tabs-set nil)
    (set-frame-parameter nil 'tabs nil))
  (let ((first t))
    (mapc
     (lambda (tbm)
       (if first
           (setq first nil)
         (tab-bar-new-tab-to))
       (bufferlo--bookmark-tab-handler tbm t)
       (when-let (tab-name (alist-get 'tab-name tbm))
         (tab-bar-rename-tab tab-name)))
     (alist-get 'tabs bookmark)))
  (tab-bar-select-tab (alist-get 'current bookmark))
  (unless no-message
    (message "Restored bufferlo frame bookmark%s"
             (if-let (name (alist-get 'name bookmark))
                 (format ": %s" name) ""))))

(defun bufferlo--bookmark-get-names (&rest handlers)
  "Get the names of all existing bookmarks for HANDLERS."
  (bookmark-maybe-load-default-file)
  (mapcar
   #'car
   (seq-filter
    (lambda (bm)
      (memq (alist-get 'handler (cdr bm)) handlers))
    bookmark-alist)))

(defun bufferlo--current-tab ()
  "Get the current tab record."
  (if (>= emacs-major-version 28)
      (tab-bar--current-tab-find)
    (assq 'current-tab (funcall tab-bar-tabs-function nil))))

(defun bufferlo-bookmark-tab-save (name &optional no-overwrite)
  "Save the current tab as a bookmark.
NAME is the bookmark's name.  If NO-OVERWRITE is non-nil,
record the new bookmark without throwing away the old one.

This function persists the current tab's state:
The resulting bookmark stores the window configuration and the local
buffer list of the current tab.  In addition, it saves the bookmark
state (not the contents) of the bookmarkable buffers in the tab's local
buffer list."
  (interactive
   (list (completing-read
          "Save bufferlo tab bookmark: "
          (bufferlo--bookmark-get-names #'bufferlo--bookmark-tab-handler)
          nil nil nil 'bufferlo-bookmark-tab-history)))
  (bufferlo--warn)
  (bookmark-store name (bufferlo--bookmark-tab-get name) no-overwrite)
  (setf (alist-get 'bufferlo-bookmark-tab-name
                   (cdr (bufferlo--current-tab)))
        name)
  (message "saved bufferlo tab bookmark: %s" name))

(defun bufferlo-bookmark-tab-load (name)
  "Load a tab bookmark; replace the current tab's state.
NAME is the bookmark's name."
  (interactive
   (list (completing-read
          "Load bufferlo tab bookmark: "
          (bufferlo--bookmark-get-names #'bufferlo--bookmark-tab-handler)
          nil nil nil 'bufferlo-bookmark-tab-history)))
  (bufferlo--warn)
  (let ((bookmark-fringe-mark nil))
    (bookmark-jump name #'ignore))
  (setf (alist-get 'bufferlo-bookmark-tab-name
                   (cdr (bufferlo--current-tab)))
        name))

(defun bufferlo-bookmark-tab-save-current ()
  "Save the current tab to its associated bookmark.
The associated bookmark is determined by the name of the bookmark to
which the tab was last saved or (if not yet saved) from which it was
initially loaded.  Performs an interactive bookmark selection if no
associated bookmark exists."
  (interactive)
  (bufferlo--warn)
  (if-let (bm (alist-get 'bufferlo-bookmark-tab-name
                         (cdr (bufferlo--current-tab))))
      (bufferlo-bookmark-tab-save bm)
    (call-interactively #'bufferlo-bookmark-tab-save)))

(defun bufferlo-bookmark-tab-load-current ()
  "Load the current tab's associated bookmark.
The associated bookmark is determined by the name of the bookmark to
which the tab was last saved or (if not yet saved) from which it was
initially loaded.  Performs an interactive bookmark selection if no
associated bookmark exists."
  (interactive)
  (bufferlo--warn)
  (if-let (bm (alist-get 'bufferlo-bookmark-tab-name
                         (cdr (bufferlo--current-tab))))
      (bufferlo-bookmark-tab-load bm)
    (call-interactively #'bufferlo-bookmark-tab-load)))

(defun bufferlo-bookmark-frame-save (name &optional no-overwrite)
  "Save the current frame as a bookmark.
NAME is the bookmark's name.  If NO-OVERWRITE is non-nil,
record the new bookmark without throwing away the old one.

This function persists the current frame's state (the \"session\"):
The resulting bookmark stores the window configurations and the local
buffer lists of all tabs in the frame.  In addition, it saves the bookmark
state (not the contents) of the bookmarkable buffers for each tab."
  (interactive
   (list (completing-read
          "Save bufferlo frame bookmark: "
          (bufferlo--bookmark-get-names #'bufferlo--bookmark-frame-handler)
          nil nil nil 'bufferlo-bookmark-frame-history
          (frame-parameter nil 'bufferlo-bookmark-frame-name))))
  (bufferlo--warn)
  (bookmark-store name (bufferlo--bookmark-frame-get name) no-overwrite)
  (set-frame-parameter nil 'bufferlo-bookmark-frame-name name)
  (message "Saved bufferlo frame bookmark: %s" name))

(defun bufferlo-bookmark-frame-load (name)
  "Load a frame bookmark; replace the current frame's state.
NAME is the bookmark's name."
  (interactive
   (list (completing-read
          "Load bufferlo frame bookmark: "
          (bufferlo--bookmark-get-names #'bufferlo--bookmark-frame-handler)
          nil nil nil 'bufferlo-bookmark-frame-history
          (frame-parameter nil 'bufferlo-bookmark-frame-name))))
  (bufferlo--warn)
  (let ((bookmark-fringe-mark nil))
    (bookmark-jump name #'ignore))
  (set-frame-parameter nil 'bufferlo-bookmark-frame-name name))

(defun bufferlo-bookmark-frame-save-current ()
  "Save the current frame to its associated bookmark.
The associated bookmark is determined by the name of the bookmark to
which the frame was last saved or (if not yet saved) from which it was
initially loaded.  Performs an interactive bookmark selection if no
associated bookmark exists."
  (interactive)
  (bufferlo--warn)
  (if-let (bm (frame-parameter nil 'bufferlo-bookmark-frame-name))
      (bufferlo-bookmark-frame-save bm)
    (call-interactively #'bufferlo-bookmark-frame-save)))

(defun bufferlo-bookmark-frame-load-current ()
  "Load the current frame's associated bookmark.
The associated bookmark is determined by the name of the bookmark to
which the frame was last saved or (if not yet saved) from which it was
initially loaded.  Performs an interactive bookmark selection if no
associated bookmark exists."
  (interactive)
  (bufferlo--warn)
  (if-let (bm (frame-parameter nil 'bufferlo-bookmark-frame-name))
      (bufferlo-bookmark-frame-load bm)
    (call-interactively #'bufferlo-bookmark-frame-load)))

(provide 'bufferlo)

;;; bufferlo.el ends here
