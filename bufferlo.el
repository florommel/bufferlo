;;; bufferlo.el --- Manage frame/tab-local buffer lists -*- lexical-binding: t -*-

;; Copyright (C) 2021-2024 Free Software Foundation, Inc.

;; Author: Florian Rommel <mail@florommel.de>
;;         Stephane Marks <shipmints@gmail.com>
;; Maintainer: Florian Rommel <mail@florommel.de>
;;             Stephane Marks <shipmints@gmail.com>
;; Url: https://github.com/florommel/bufferlo
;; Created: 2021-09-15
;; Version: 0.8
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
(require 'ibuffer)
(require 'ibuf-ext)

(defgroup bufferlo nil
  "Manage frame/tab-local buffer lists."
  :group 'convenience)

(defcustom bufferlo-prefer-local-buffers t
  "Use the frame `buffer-predicate' to prefer local buffers.
Without this option, buffers from across all frames are
presented. This means that a local buffer will be preferred to be
displayed when the current buffer disappears (buried or killed).

This also influences `next-buffer' and `previous-buffer'.

Set to \\='tabs for `next-buffer' and `previous-buffer' to respect
buffers local to the current tab, otherwise they will cycle
through buffers across the frame.

This variable must be set before enabling `bufferlo-mode'."
  :type 'symbol)

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

(defcustom bufferlo-kill-buffers-prompt nil
  "If non-nil, confirm before killing local or orphan buffers."
  :type 'boolean)

(defcustom bufferlo-bookmark-prefer-saveplace-point nil
  "If non-nil, and `save-place-mode' mode is on, inhibit point in bookmarks."
  :type 'boolean)

(defcustom bufferlo-bookmark-buffers-exclude-filters nil
  "Buffers that should be excluded from bufferlo bookmarks.
This is a list of regular expressions to filter buffer names."
  :type '(repeat regexp))

(defcustom bufferlo-bookmark-buffers-include-filters nil
  "Buffers that should be stored in bufferlo bookmarks.
This is a list of regular expressions to filter buffer names."
  :type '(repeat regexp))

(defcustom bufferlo-bookmark-frame-load-make-frame nil
  "If non-nil, create a new frame to hold a loaded frame bookmark."
  :type 'boolean)

(defcustom bufferlo-delete-frame-kill-buffers-save-bookmark-prompt nil
  "If non-nil, offer to save bookmark before killing the frame and buffers."
  :type 'boolean)

(defcustom bufferlo-delete-frame-kill-buffers-prompt nil
  "If non-nil, confirm before deleting the frame and killing buffers."
  :type 'boolean)

(defcustom bufferlo-close-tab-kill-buffers-save-bookmark-prompt nil
  "If non-nil, offer to save bookmark before closing the tab and killing buffers."
  :type 'boolean)

(defcustom bufferlo-close-tab-kill-buffers-prompt nil
  "If non-nil, confirm before closing the tab and killing buffers."
  :type 'boolean)

(defcustom bufferlo-bookmark-frame-load-policy 'replace-frame-retain-current-bookmark
  "Control loading a frame bookmark into a already-bookmarked frame.

\\='prompt allows you to select a policy interactively.

\\='disallow-replace prevents accidental replacement of
already-bookmarked frames, with the exception that a bookmarked
frame may be reloaded to restore its state.

\\='replace-frame-retain-current-bookmark replaces the frame
content using the existing frame bookmark name.

\\='replace-frame-adopt-loaded-bookmark replaces the frame content
and adopts the loaded bookmark name.

\\='merge adds new frame bookmark tabs to the existing frame,
retaining the existing bookmark name.

This policy is useful when
`bufferlo-bookmark-frame-load-make-frame' is not enabled or frame
loading is not overridden with a prefix argument that suppresses
making a new frame."
  :type '(radio (const :tag "Prompt" prompt)
                (const :tag "Disallow" disallow-replace)
                (const :tag "Replace frame, retain current bookmark name" replace-frame-retain-current-bookmark)
                (const :tag "Replace frame, adopt loaded bookmark name" replace-frame-adopt-loaded-bookmark)
                (const :tag "Merge" merge)))

(defcustom bufferlo-bookmark-frame-duplicate-policy 'allow
  "Control duplicate active frame bookmarks.
Duplicate active bookmarks cause potentially confusing race
conditions.

\\='prompt allows you to select a policy interactively.

\\='allow allows duplicates.

\\='clear silently clears the frame bookmark.

\\='clear-warn issues a warning message about the frame losing
its bookmark.

\\='raise will raise the frame with the existing bookmark."
  :type '(radio (const :tag "Prompt" prompt)
                (const :tag "Allow" allow)
                (const :tag "Raise" raise)))

(defcustom bufferlo-bookmark-frame-clone-policy 'allow
  "Control bookmark duplication on cloned and undeleted frames.
Duplicate active bookmarks cause potentially confusing race
conditions.

\\='prompt allows you to select a policy interactively.

\\='allow allows duplicates.

\\='disassociate will clear the bookmark on the newly cloned or
undeleted frame."
  :type '(radio (const :tag "Prompt" prompt)
                (const :tag "Allow" allow)
                (const :tag "Disassociate" disassociate)))

(defcustom bufferlo-bookmarks-load-tabs-make-frame nil
  "If non-nil, make a new frame for tabs loaded by `bufferlo-bookmarks-load'.
If nil, tab bookmarks are loaded into the current frame."
  :type 'boolean)

(defcustom bufferlo-bookmark-tab-replace-policy 'replace
  "Control whether loaded tabs replace current tabs or occupy new tabs.

\\='prompt allows you to select a policy interactively.

\\='replace clears the current tab and overwrites its content
with the loaded tab.

\\='new loads tab bookmarks into new tabs, honoring the user
option `tab-bar-new-tab-to'."
  :type '(radio (const :tag "Prompt" prompt)
                (const :tag "Replace)" replace)
                (const :tag "New" new)))

(defcustom bufferlo-bookmark-tab-duplicate-policy 'allow
  "Control duplicate active tab bookmarks.
Duplicate active bookmarks cause potentially confusing race
conditions.

\\='prompt allows you to select a policy interactively.

\\='allow allows duplicates.

\\='clear silently clears the tab bookmark which is natural
reified frame bookmark behavior.

\\='clear-warn issues a warning message about the tab losing its
bookmark.

\\='raise raises the first found existing tab bookmark and its
frame."
  :type '(radio (const :tag "Prompt" prompt)
                (const :tag "Allow" allow)
                (const :tag "Clear (silently)" clear)
                (const :tag "Clear (with message)" clear-warn)
                (const :tag "Raise" raise)))

(defcustom bufferlo-bookmark-tab-load-into-bookmarked-frame-policy 'allow
  "Control when a tab bookmark is loaded into an already-bookmarked frame.

\\='clear will silently clear the tab bookmark which is natural
reified frame bookmark behavior.

\\='clear-warn issues a warning message about the tab losing its
bookmark.

\\='allow will retain the tab bookmark to enable it to be saved
or updated. Note that the frame bookmark always supersedes the tab
bookmark when the frame bookmark is saved."
  :type '(radio (const :tag "Prompt" prompt)
                (const :tag "Allow" allow)
                (const :tag "Clear (silently)" clear)
                (const :tag "Clear (with message)" clear-warn)))

(defcustom bufferlo-bookmarks-save-duplicates-policy 'allow
  "Control duplicates when saving all bookmarks.

\\='prompt allows you to select a policy interactively.

\\='allow will save potentially differing content for the same
bookmark name multiple times with the last-one-saved taking
precedence. A warning message indicates the names of duplicate
bookmarks.

\\='disallow prevents the potentially confusing of overwriting
bookmark content for the same bookmark names. A warning message
indicates the names of duplicate bookmarks.

Note: when using bufferlo's auto-save feature and to avoid
repeated prompts and warnings, it is best to choose policies in
advance that prevent duplicate frame and tab bookmarks."
  :type '(radio (const :tag "Prompt" prompt)
                (const :tag "Allow" allow)
                (const :tag "Disallow" disallow)))

(defcustom bufferlo-bookmarks-save-frame-policy 'all
  "Control bufferlo bookmarks save frame selection behavior.

\\='current saves bookmarks on the current frame only.

\\='other saves bookmarks on non-current frames.

\\='all saves bookmarks across all frames."
  :type '(radio (const :tag "Current frame" current)
                (const :tag "Other frames" other)
                (const :tag "All frames" all)))

(defcustom bufferlo-bookmarks-save-predicate-functions (list #'bufferlo-bookmarks-save-all-p)
  "Functions to filter active bufferlo bookmarks to save.
These are applied when
`bufferlo-bookmarks-auto-save-idle-interval' is > 0, or manually
via `bufferlo-bookmarks-save'. Functions are passed the bufferlo
bookmark name and invoked until the first positive result. Set to
`#'bufferlo-bookmarks-save-all-p' to save all bookmarks or
provide your own predicates (note: be sure to remove
`#'bufferlo-bookmarks-save-all-p' from the list)."
  :type 'hook)

(defcustom bufferlo-bookmarks-load-predicate-functions nil
  "Functions to filter stored bufferlo bookmarks to load.
These are applied in `bufferlo-bookmarks-load' which might also
be invoked at Emacs startup time using `window-setup-hook'.
Functions are passed the bufferlo bookmark name and invoked until
the first positive result. Set to
`#'bufferlo-bookmarks-load-all-p' to load all bookmarks or
provide your own predicates."
  :type 'hook)

(defcustom bufferlo-bookmarks-save-at-emacs-exit 'nosave
  "Bufferlo can save active bookmarks at Emacs exit.

\\='nosave does not save any active bookmarks.

\\='all saves all active bufferlo bookmarks.

\\='pred honors the filter predicates
in `bufferlo-bookmarks-save-predicate-functions'."
  :type '(radio (const :tag "Do not save at exit" nosave)
                (const :tag "Predicate-filtered bookmarks" pred)
                (const :tag "All bookmarks" all)))

(defcustom bufferlo-bookmarks-load-at-emacs-startup 'noload
  "Bufferlo can load stored bookmarks at Emacs startup.

\\='noload does not load any stored bookmarks.

\\='all loads all stored bufferlo bookmarks.

\\='pred honors the filter predicates in
`bufferlo-bookmarks-load-predicate-functions'.

Note that `bufferlo-mode' must be enabled before
`window-setup-hook' is invoked for this policy to take effect."
  :type '(radio (const :tag "Do not load at startup" noload)
                (const :tag "Predicate-filtered bookmarks" pred)
                (const :tag "All bookmarks" all)))

(defcustom bufferlo-bookmarks-load-at-emacs-startup-tabs-make-frame nil
  "If nil, the initial frame is reused for restored tabs.
If non-nil, a new frame is created for restored tabs."
  :type 'boolean)

(defcustom bufferlo-ibuffer-bind-local-buffer-filter t
  "If non-nil, bind the local buffer filter and the orphan filter in ibuffer.
The local buffer filter is bound to \"/ l\" and the orphan filter to \"/ L\"."
  :type 'boolean)

(defcustom bufferlo-ibuffer-bind-keys nil
  "If non-nil, bind ibuffer convenience keys for bufferlo functions."
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

(defvar bufferlo--bookmarks-auto-save-timer nil
  "Timer to save bufferlo bookmarks.
This is controlled by `bufferlo-bookmarks-auto-save-idle-interval'.")

(defun bufferlo--bookmarks-auto-save-timer-maybe-cancel ()
  "Cancel and clear the bufferlo bookmark auto-save timer, if set."
  (when (timerp bufferlo--bookmarks-auto-save-timer)
    (cancel-timer bufferlo--bookmarks-auto-save-timer))
  (setq bufferlo--bookmarks-auto-save-timer nil))

(defvar bufferlo-bookmarks-auto-save-idle-interval) ; byte compiler
(defun bufferlo--bookmarks-auto-save-timer-maybe-start ()
  "Start the bufferlo auto-save bookmarks timer, if needed."
  (bufferlo--bookmarks-auto-save-timer-maybe-cancel)
  (when (> bufferlo-bookmarks-auto-save-idle-interval 0)
    (setq bufferlo--bookmarks-auto-save-timer
          (run-with-idle-timer bufferlo-bookmarks-auto-save-idle-interval t #'bufferlo-bookmarks-save))))

(defcustom bufferlo-bookmarks-auto-save-idle-interval 0
  "Save bufferlo bookmarks when Emacs has been idle this many seconds.
Set to 0 to disable the timer. Units are whole integer seconds."
  :type 'natnum
  :set (lambda (sym val)
         (set-default sym val)
         (bufferlo--bookmarks-auto-save-timer-maybe-start)))

(defcustom bufferlo-bookmarks-auto-save-messages nil
  "Control messages from the interval auto saver.

\\=nil inhibits all messages.

\\=t shows all messages.

\\='saved shows a message only when bookmarks have been saved.

\\='notsaved shows a message only when bookmarks have not been saved."
  :type '(radio (const :tag "None" nil)
                (const :tag "All" t)
                (const :tag "Saved only" saved)
                (const :tag "Not-saved only" notsaved)))

(defcustom bufferlo-mode-line-lighter-prefix " Bfl"
  "Bufferlo mode-line lighter prefix."
  :type 'string)

(defvar bufferlo-mode) ; byte compiler
(defun bufferlo-mode-line-format ()
  "Bufferlo mode-line format to display the current active frame or tab bookmark."
  (when bufferlo-mode
    (let ((fbm (frame-parameter nil 'bufferlo-bookmark-frame-name))
          (tbm (alist-get 'bufferlo-bookmark-tab-name (tab-bar--current-tab-find)))
          (maybe-space (if (display-graphic-p) "" " "))) ; tty rendering can be off for Ⓕ Ⓣ
      (concat bufferlo-mode-line-lighter-prefix
              "["
              (if fbm (concat "Ⓕ" maybe-space fbm)) ; the space accommodates tty rendering
              (if (and fbm tbm) " ")
              (if tbm (concat "Ⓣ" maybe-space tbm)) ; the space accommodates tty rendering
              "]"))))

(defcustom bufferlo-mode-line-lighter '(:eval (bufferlo-mode-line-format))
  "Bufferlo mode line definition."
  :type 'sexp
  :risky t)

(defconst bufferlo--command-line-noload-prefix "--bufferlo-noload")
(defvar bufferlo--command-line-noload nil)

(defun bufferlo--parse-command-line ()
  "Process bufferlo Emacs command-line arguments."
  (when-let (pos (seq-position command-line-args bufferlo--command-line-noload-prefix #'string-equal))
    (setq bufferlo--command-line-noload pos)
    (setq command-line-args (seq-remove-at-position command-line-args pos)))
  (when (file-exists-p (expand-file-name "bufferlo-noload" user-emacs-directory))
    (message "bufferlo-noload file found; inhibiting bufferlo bookmark loading")
    (setq bufferlo--command-line-noload t)))

(defun -bufferlo--parse-command-line-test ()
  "Internal test function for command-line processing."
  (let ((command-line-args (list "/usr/bin/emacs" "--name" "foobar" bufferlo--command-line-noload-prefix "-T" "title")))
    (setq bufferlo--command-line-noload nil)
    (message "command-line-args=%s" command-line-args)
    (message "bufferlo--command-line-noload=%s" bufferlo--command-line-noload)
    (bufferlo--parse-command-line)
    (message "bufferlo--command-line-noload=%s" bufferlo--command-line-noload)
    (message "command-line-args=%s" command-line-args)))

;;;###autoload
(define-minor-mode bufferlo-mode
  "Manage frame/tab-local buffers."
  :global t
  :require 'bufferlo
  :init-value nil
  :lighter bufferlo-mode-line-lighter
  :keymap nil
  (if bufferlo-mode
      (progn
        (bufferlo--parse-command-line) ; parse user-provided settings first
        ;; Prefer local buffers
        (when bufferlo-prefer-local-buffers
          (dolist (frame (frame-list))
            (bufferlo--set-buffer-predicate frame))
          (add-hook 'after-make-frame-functions #'bufferlo--set-buffer-predicate))
        (when (eq bufferlo-prefer-local-buffers 'tabs)
          (bufferlo--set-switch-to-prev-buffer-skip))
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
          (advice-add #'clone-frame :around #'bufferlo--clone-undelete-frame-advice))
        (when (>= emacs-major-version 29)
          (advice-add #'undelete-frame :around #'bufferlo--clone-undelete-frame-advice))
        ;; Switch-tab workaround
        (advice-add #'tab-bar-select-tab :around #'bufferlo--clear-buffer-lists-activate)
        (advice-add #'tab-bar--tab :after #'bufferlo--clear-buffer-lists)
        ;; Set up bookmarks save timer
        (bufferlo--bookmarks-auto-save-timer-maybe-start)
        ;; kill-emacs-hook save bookmarks option
        (when (not (eq bufferlo-bookmarks-save-at-emacs-exit 'nosave))
          (add-hook 'kill-emacs-hook #'bufferlo--bookmarks-save-at-emacs-exit))
        ;; load bookmarks at startup option
        (when (and (not bufferlo--command-line-noload)
                   (not (eq bufferlo-bookmarks-load-at-emacs-startup 'noload)))
          (add-hook 'window-setup-hook #'bufferlo--bookmarks-load-startup))
        ;; bookmark advice
        (advice-add 'bookmark-rename :around #'bufferlo--bookmark-rename-advice)
        (advice-add 'bookmark-delete :around #'bufferlo--bookmark-delete-advice))
    ;; Prefer local buffers
    (dolist (frame (frame-list))
      (bufferlo--reset-buffer-predicate frame))
    (when (eq bufferlo-prefer-local-buffers 'tabs)
      (bufferlo--reset-switch-to-prev-buffer-skip))
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
      (advice-remove #'clone-frame #'bufferlo--clone-undelete-frame-advice))
    (when (>= emacs-major-version 29)
      (advice-remove #'undelete-frame #'bufferlo--clone-undelete-frame-advice))
    ;; Switch-tab workaround
    (advice-remove #'tab-bar-select-tab #'bufferlo--clear-buffer-lists-activate)
    (advice-remove #'tab-bar--tab #'bufferlo--clear-buffer-lists)
    ;; Cancel bookmarks save timer
    (bufferlo--bookmarks-auto-save-timer-maybe-cancel)
    ;; kill-emacs-hook save bookmarks option
    (remove-hook 'kill-emacs-hook #'bufferlo--bookmarks-save-at-emacs-exit)
    ;; load bookmarks at startup option
    (remove-hook 'window-setup-hook #'bufferlo-bookmarks-load)
    ;; bookmark advice
    (advice-remove 'bookmark-rename #'bufferlo--bookmark-rename-advice)
    (advice-remove 'bookmark-delete #'bufferlo--bookmark-delete-advice)))

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
set the corresponding `buffer-list' / `buried-buffer-list' frame parameters.
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
It activates clearing the buffer lists for `tab-bar--tab'
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

;; via window.el switch-to-prev-buffer-skip-p
;; (funcall skip window buffer bury-or-kill)
(defun bufferlo--switch-to-prev-buffer-skip-p (_window buffer _bury-or-kill)
  "Restrict BUFFER to the current tab's locals for buffer switching.
Affects `switch-to-prev-buffer' and `switch-to-next-buffer'.
Includes hidden buffers."
  (not (bufferlo-local-buffer-p buffer nil (tab-bar--current-tab-index) t)))

(defvar bufferlo--switch-to-prev-buffer-skip-orig)

(defun bufferlo--set-switch-to-prev-buffer-skip ()
  "Set the buffer predicate of FRAME to `bufferlo--buffer-predicate'."
  (setq bufferlo--switch-to-prev-buffer-skip-orig switch-to-prev-buffer-skip)
  (setq switch-to-prev-buffer-skip #'bufferlo--switch-to-prev-buffer-skip-p))

(defun bufferlo--reset-switch-to-prev-buffer-skip ()
  "Reset `switch-to-prev-buffer-skip'."
  (setq switch-to-prev-buffer-skip bufferlo--switch-to-prev-buffer-skip-orig))

(defun bufferlo--buffer-predicate (buffer)
  "Return whether BUFFER is local to the current frame/tab.
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

(defun bufferlo--get-buffers (&optional frame tabnum)
  "Get the buffers of tab TABNUM in FRAME.
If FRAME is nil, the current frame is selected.
If TABNUM is nil, the current tab is selected.
If TABNUM is \\='all, all tabs of the frame are selected."
  (cond ((eq tabnum 'all)
         (seq-uniq (seq-mapcat (lambda (tb)
                                 (if (eq 'current-tab (car tb))
                                     (bufferlo--current-buffers frame)
                                   (bufferlo--get-tab-buffers tb)))
                               (funcall tab-bar-tabs-function frame))))
        (tabnum
         (let ((tab (nth tabnum (funcall tab-bar-tabs-function frame))))
           (if (eq 'current-tab (car tab))
               (bufferlo--current-buffers frame)
             (bufferlo--get-tab-buffers tab))))
        (t
         (bufferlo--current-buffers frame))))

(defun bufferlo-buffer-list (&optional frame tabnum include-hidden)
  "Return a list of all live buffers associated with the current frame and tab.
A non-nil value of FRAME selects a specific frame instead of the current one.
If TABNUM is nil, the current tab is used.  If it is non-nil, it specifies
a tab index in the given frame.  If INCLUDE-HIDDEN is set, include hidden
buffers, see `bufferlo-hidden-buffers'."
  (let ((list (bufferlo--get-buffers frame tabnum)))
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
      (if names
          (append ws (list (list 'bufferlo-buffer-list names)))
        ws))))

(defun bufferlo--window-state-put (state &optional window _ignore)
  "Restore the frame's buffer list from the window state.
Used as advice after `window-state-put'.  STATE is the window state.
WINDOW is the window in question.  IGNORE is not used and exists for
compatibility with the advised function."
  ;; We have to make sure that the window is live at this point.
  ;; `frameset-restore' may pass a window with a non-existing buffer
  ;; to `window-state-put', which in turn will delete that window
  ;; before the advice calls us.
  ;; This is not the case when we are called from `tab-bar-select-tab'.
  (when (or bufferlo--desktop-advice-active-force
            (and bufferlo--desktop-advice-active (window-live-p window)))
    ;; FIXME: Currently there is no distinction between buffers and
    ;;        buried buffers for desktop.el.
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
the advised functions."
  (let ((bufferlo--desktop-advice-active t))
    (apply oldfn args)))

(defun bufferlo--activate-force (oldfn &rest args)
  "Activate the advice for `bufferlo--window-state-{get,put}'.
OLDFN is the original function.  ARGS is for compatibility with
the advised functions."
  (let ((bufferlo--desktop-advice-active t)
        (bufferlo--desktop-advice-active-force t))
    (apply oldfn args)))

(defun bufferlo--clone-undelete-frame-advice (oldfn &rest args)
  "Activate the advice for `bufferlo--window-state-{get,put}'.
OLDFN is the original function.  ARGS is for compatibility with
the advised functions. Honors `bufferlo-bookmark-frame-clone-policy'."
  (let ((bufferlo--desktop-advice-active t)
        (bufferlo--desktop-advice-active-force t))
    (apply oldfn args))
  (let ((fbm (frame-parameter nil 'bufferlo-bookmark-frame-name))
        (clone-policy bufferlo-bookmark-frame-clone-policy))
    (when fbm
      (when (eq clone-policy 'prompt)
        (pcase (let ((read-answer-short t))
                 (with-local-quit
                   (read-answer "Disassociate cloned/undeleted frame bookmark: Allow, Disassociate "
                                '(("allow" ?a "Allow bookmark")
                                  ("disassociate" ?d "Disassociate bookmark")
                                  ("help" ?h "Help")
                                  ("quit" ?q "Quit--retains the bookmark")))))
          ("disassociate" (setq clone-policy 'disassociate))
          (_ (setq clone-policy 'allow)))) ; allow, quit cases
      (pcase clone-policy
        ('allow)
        ('disassociate
         (set-frame-parameter nil 'bufferlo-bookmark-frame-name nil))))))

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
  (dolist (buffer (bufferlo--get-exclusive-buffers nil nil t))
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

(defun bufferlo--get-captured-buffers (&optional exclude-frame exclude-tabnum)
  "Get all buffers that are in a local list of at least one frame or tab.
If EXCLUDE-FRAME is a frame, exclude the local buffer list of the tab with
the number EXCLUSIVE-TABNUM of this frame.
If EXCLUSIVE-TABNUM is nil, select the default tab.
If EXCLUSIVE-TABNUM is \\='all, select all tabs of the frame.
If EXCLUDE-FRAME is nil, do not exclude a local buffer list
and ignore EXCLUDE-TABNUM."
  (let* ((exclude-tab (when (and exclude-tabnum (not (eq exclude-tabnum 'all)))
                        (nth exclude-tabnum
                             (funcall tab-bar-tabs-function exclude-frame))))
         (get-inactive-tabs-buffers
          (lambda (f)
            (seq-mapcat
             (lambda (tb)
               (unless (and (eq f exclude-frame)
                            (or (eq exclude-tabnum 'all)
                                (eq tb exclude-tab)))
                 (bufferlo--get-tab-buffers tb)))
             (funcall tab-bar-tabs-function f))))
         (get-frames-buffers
          (lambda ()
            (seq-mapcat
             (lambda (f)
               (unless (and (eq f exclude-frame)
                            (or (eq exclude-tabnum 'all)
                                (not exclude-tab)
                                (eq 'current-tab (car exclude-tab))))
                 (bufferlo--current-buffers f)))
             (frame-list)))))
    (seq-uniq
     (append (seq-mapcat get-inactive-tabs-buffers (frame-list))
             (funcall get-frames-buffers)))))

(defun bufferlo--get-orphan-buffers ()
  "Get all buffers that are not in any local list of a frame or tab."
  (seq-filter (lambda (b)
                (not (memq b (bufferlo--get-captured-buffers))))
              (buffer-list)))

(defun bufferlo--get-exclusive-buffers (&optional frame tabnum invert)
  "Get all buffers that are exclusive to this frame and tab.
If FRAME is nil, use the current frame.
If TABNUM is nil, use the current tab.
If TABNUM is \\='all, kill all tabs of the frame.
If INVERT is non-nil, return the non-exclusive buffers instead."
  (let ((other-bufs (bufferlo--get-captured-buffers (or frame (selected-frame))
                                                    tabnum))
        (this-bufs (bufferlo--get-buffers frame tabnum)))
    (seq-filter (if invert
                    (lambda (b) (memq b other-bufs))
                  (lambda (b) (not (memq b other-bufs))))
                this-bufs)))

(defun bufferlo-kill-buffers (&optional killall frame tabnum internal-too)
  "Kill the buffers of the frame/tab-local buffer list.
By default, this will only kill buffers that are exclusive to the frame/tab.
If KILLALL (prefix argument) is given then buffers that are also present in the
local lists of other frames and tabs are killed too.
Buffers matching `bufferlo-kill-buffers-exclude-filters' are never killed.
If FRAME is nil, use the current frame.
If TABNUM is nil, use the current tab.
If TABNUM is \\='all, kill all tabs of the frame.
Ignores buffers whose names start with a space, unless optional
argument INTERNAL-TOO is non-nil."
  (interactive "P")
  (bufferlo--warn)
  (let ((kill t))
    (when bufferlo-kill-buffers-prompt
      (setq kill (y-or-n-p "Kill bufferlo local buffers? ")))
    (when kill
      (let* ((exclude (bufferlo--merge-regexp-list
                       (append '("a^") bufferlo-kill-buffers-exclude-filters)))
             (kill-list (if killall
                            (bufferlo--get-buffers frame tabnum)
                          (bufferlo--get-exclusive-buffers frame tabnum)))
             (buffers (seq-filter
                       (lambda (b)
                         (not (and
                               ;; (or internal-too (/= (aref (buffer-name b) 0) ?\s)) ; NOTE: this can cause null reference errors
                               (or internal-too (not (string-prefix-p " " (buffer-name b))))
                               (string-match-p exclude (buffer-name b)))))
                       kill-list)))
        (dolist (b buffers)
          (kill-buffer b))))))

(defun bufferlo-kill-orphan-buffers (&optional internal-too)
  "Kill all buffers that are not in any local list of a frame or tab.
Ignores buffers whose names start with a space, unless optional
argument INTERNAL-TOO is non-nil.
Buffers matching `bufferlo-kill-buffers-exclude-filters' are never killed."
  (interactive)
  (bufferlo--warn)
  (let ((kill t))
    (when bufferlo-kill-buffers-prompt
      (setq kill (y-or-n-p "Kill bufferlo orphan buffers? ")))
    (when kill
      (let* ((exclude (bufferlo--merge-regexp-list
                       (append '("a^") bufferlo-kill-buffers-exclude-filters)))
             (buffers (seq-filter
                       (lambda (b)
                         (not (and
                               ;; (or internal-too (/= (aref (buffer-name b) 0) ?\s)) ; NOTE: this can cause null reference errors
                               (or internal-too (not (string-prefix-p " " (buffer-name b))))
                               (string-match-p exclude (buffer-name b)))))
                       (bufferlo--get-orphan-buffers))))
        (dolist (b buffers)
          (kill-buffer b))))))

(defun bufferlo-delete-frame-kill-buffers (&optional frame internal-too)
  "Delete a frame and kill the local buffers of its tabs.
If FRAME is nil, kill the current frame.
Ignores buffers whose names start with a space, unless optional
argument INTERNAL-TOO is non-nil."
  (interactive)
  (bufferlo--warn)
  (let ((kill t)
        (fbm (frame-parameter nil 'bufferlo-bookmark-frame-name)))
    (when (and fbm
               bufferlo-delete-frame-kill-buffers-save-bookmark-prompt)
      (when (y-or-n-p
             (concat "Save frame bookmark \"" fbm "\"? "))
        (bufferlo-bookmark-frame-save-current)))
    (when bufferlo-delete-frame-kill-buffers-prompt
      (setq kill (y-or-n-p "Kill frame and its buffers? ")))
    (when kill
      (bufferlo-kill-buffers nil frame 'all internal-too)
      ;; TODO: Emacs 30 frame-deletable-p
      ;; account for top-level, non-child frames
      (setq frame (or frame (selected-frame)))
      (when (= 1 (length (seq-filter
                          (lambda (x) (null (frame-parameter x 'parent-frame)))
                          (frame-list))))
        (make-frame)) ; leave one for the user
      (delete-frame frame))))

(defun bufferlo-tab-close-kill-buffers (&optional killall internal-too)
  "Close the current tab and kill the local buffers.
The optional arguments KILLALL and INTERNAL-TOO are passed to
`bufferlo-kill-buffers'."
  (interactive "P")
  (bufferlo--warn)
  (let ((kill t)
        (tbm (alist-get 'bufferlo-bookmark-tab-name (tab-bar--current-tab-find))))
    (when (and tbm
               bufferlo-close-tab-kill-buffers-save-bookmark-prompt)
      (when (y-or-n-p
             (concat "Save tab bookmark \"" tbm "\"? "))
        (bufferlo-bookmark-tab-save-current)))
    (when bufferlo-close-tab-kill-buffers-prompt
      (setq kill (y-or-n-p "Kill tab and its buffers? ")))
    (when kill
      (bufferlo-kill-buffers killall nil nil internal-too)
      (tab-bar-close-tab))))

(defun bufferlo-isolate-project (&optional file-buffers-only)
  "Isolate a project in the frame or tab.
Remove all buffers that do not belong to the current project from
the local buffer list.  When FILE-BUFFERS-ONLY is non-nil or the
prefix argument is given, remove only buffers that visit a file.
Buffers matching `bufferlo-include-buffer-filters' are not removed."
  (interactive "P")
  (bufferlo--warn)
  (if-let ((curr-project (project-current))
           (include (bufferlo--merge-regexp-list
                     (append '("a^") bufferlo-include-buffer-filters))))
      (dolist (buffer (bufferlo-buffer-list))
        (when (and (not (string-match-p include (buffer-name buffer)))
                   (not (equal curr-project
                               (with-current-buffer buffer (project-current))))
                   (or (not file-buffers-only) (buffer-file-name buffer)))
          (bufferlo-remove buffer)))
    (message "Current buffer is not part of a project")))

(defun bufferlo-find-buffer (buffer-or-name)
  "Switch to the frame/tab containing BUFFER-OR-NAME in its local list.
If multiple frame or tabs contain the buffer, interactively prompt
for the to-be-selected frame and tab.
This does not select the buffer -- just the containing frame and tab."
  (interactive "b")
  (bufferlo--warn)
  (let* ((buffer (get-buffer buffer-or-name))
         (search-tabs (lambda (f)
                        (let ((i 0))
                          (mapcar
                           (lambda (tab)
                             (setq i (1+ i))
                             (when (bufferlo-local-buffer-p buffer f (1- i) t)
                               (list f (frame-parameter f 'name)
                                     (eq f (selected-frame))
                                     i (cdr (assq 'name tab)))))
                           (funcall tab-bar-tabs-function f)))))
         (search-frames (lambda (f)
                          (unless (frame-parameter f 'no-accept-focus)
                            (if (funcall tab-bar-tabs-function f)
                                ;; has tabs
                                (funcall search-tabs f)
                              ;; has no tabs
                              (when (bufferlo-local-buffer-p buffer f nil t)
                                (list (list f (frame-parameter f 'name)
                                            (eq f (selected-frame))
                                            nil nil)))))))
         (candidates (seq-filter 'identity
                                 (seq-mapcat
                                  (lambda (f)
                                    (funcall search-frames f))
                                  (frame-list))))
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
  "Switch to the frame/tab containing BUFFER-OR-NAME and select the buffer.
This is like `bufferlo-find-buffer' but additionally selects the buffer.
If the buffer is already visible in a non-selected window, select it."
  (interactive "b")
  (bufferlo--warn)
  (when (bufferlo-find-buffer buffer-or-name)
    (if-let (w (seq-find
                (lambda (w)
                  (eq (get-buffer buffer-or-name) (window-buffer w)))
                (window-list)))
        (select-window w)
      (switch-to-buffer buffer-or-name))))

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
This is the frame/tab-local equivalent to `switch-to-buffer'.
The arguments NORECORD and FORCE-SAME-WINDOW are passed to `switch-to-buffer'.
If the prefix argument is given, include all buffers."
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

(define-ibuffer-filter bufferlo-local-buffers
    "Limit current view to local buffers."
  (:description "local buffers" :reader nil)
  (bufferlo-local-buffer-p buf))

(define-ibuffer-filter bufferlo-orphan-buffers
    "Limit current view to orphan buffers."
  (:description "orphan buffers" :reader nil)
  (not (memq buf (bufferlo--get-captured-buffers))))

(when bufferlo-ibuffer-bind-local-buffer-filter
  (define-key ibuffer--filter-map (kbd "l")
              'ibuffer-filter-by-bufferlo-local-buffers)
  (define-key ibuffer--filter-map (kbd "L")
              'ibuffer-filter-by-bufferlo-orphan-buffers))

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

(define-ibuffer-op ibuffer-do-bufferlo-remove ()
  "Remove marked buffers from bufferlo's local buffer list."
  (
   :active-opstring "remove from bufferlo locals" ; prompt
   :opstring "removed from bufferlo locals:" ; success
   :modifier-p t
   :dangerous t
   :complex t
   :after (ibuffer-update nil t)
   )
  (when bufferlo-mode
    (bufferlo-remove buf)
    t))

(when bufferlo-ibuffer-bind-keys
  (define-key ibuffer-mode-map "-" #'ibuffer-do-bufferlo-remove))

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
      (when (and
             bufferlo-bookmark-prefer-saveplace-point
             record
             (featurep 'saveplace)
             save-place-mode)
        (bookmark-set-position record nil))
      (list (buffer-name buffer) record))))

(defun bufferlo--bookmark-filter-buffers (&optional frame)
  "Filter out buffers to exclude in bookmarks in FRAME which may be nil."
  (let* ((buffers (bufferlo-buffer-list frame nil t))
         (buffers (seq-union
                   (seq-remove
                    (lambda (buf)
                      (seq-filter
                       (lambda (regexp) (string-match-p regexp (buffer-name buf)))
                       bufferlo-bookmark-buffers-exclude-filters))
                    buffers)
                   (seq-filter
                    (lambda (buf)
                      (seq-filter
                       (lambda (regexp) (string-match-p regexp (buffer-name buf)))
                       bufferlo-bookmark-buffers-include-filters))
                    buffers))))
    buffers))

(defun bufferlo--bookmark-get-for-buffers-in-tab (frame)
  "Get bookmarks for all buffers of the tab TABNUM in FRAME."
  (with-selected-frame (or frame (selected-frame))
    (seq-filter #'identity
                (mapcar #'bufferlo--bookmark-get-for-buffer
                        (bufferlo--bookmark-filter-buffers frame)))))

(defun bufferlo--bookmark-tab-get (&optional frame)
  "Get the bufferlo tab bookmark for the current tab in FRAME.
FRAME specifies the frame; the default value of nil selects the current frame."
  `((buffer-bookmarks . ,(bufferlo--bookmark-get-for-buffers-in-tab frame))
    (buffer-list . ,(mapcar #'buffer-name (bufferlo-buffer-list frame nil t)))
    (window . ,(window-state-get (frame-root-window frame) 'writable))
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

(defun bufferlo--bookmark-tab-handler (bookmark &optional no-message embedded-tab)
  "Handle bufferlo tab bookmark.
The argument BOOKMARK is the to-be restored tab bookmark created
via `bufferlo--bookmark-tab-get'. If the optional argument
NO-MESSAGE is non-nil, inhibit the message after successfully
restoring the bookmark. If EMBEDDED-TAB is non-nil, indicate that
this bookmark is embedded in a frame bookmark."
  (catch :noload
    (let ((bookmark-name (if (null embedded-tab)
                             (bookmark-name-from-full-record bookmark)
                           nil))
          (msg))
      (when-let ((abm (assoc bookmark-name (bufferlo--active-bookmarks)))
                 (duplicate-policy bufferlo-bookmark-tab-duplicate-policy))
        (when (eq duplicate-policy 'prompt)
          (pcase (let ((read-answer-short t))
                   (with-local-quit
                     (read-answer "Tab bookmark already active: Allow, Clear bookmark after loading, Raise existing "
                                  '(("allow" ?a "Allow duplicate")
                                    ("clear" ?c "Clear the bookmark after loading")
                                    ("raise" ?r "Raise the existing tab bookmark")
                                    ("help" ?h "Help")
                                    ("quit" ?q "Quit with no changes")))))
            ("allow" (setq duplicate-policy 'allow))
            ("clear" (setq duplicate-policy 'clear))
            ("raise" (setq duplicate-policy 'raise))
            (_ (throw :noload t))))
        (pcase duplicate-policy
          ('allow)
          ('clear
           (setq bookmark-name nil))
          ('clear-warn
           (setq bookmark-name nil)
           (setq msg (concat msg "; cleared tab bookmark")))
          ('raise
           (bufferlo--bookmark-raise abm)
           (throw :noload t))))
      (unless embedded-tab
        (let ((replace-policy bufferlo-bookmark-tab-replace-policy))
          (when (eq replace-policy 'prompt)
            (pcase (let ((read-answer-short t))
                     (with-local-quit
                       (read-answer "Replace current tab, New tab "
                                    '(("replace" ?o "Replace tab")
                                      ("new" ?n "New tab")
                                      ("help" ?h "Help")
                                      ("quit" ?q "Quit with no changes")))))
              ("replace" (setq replace-policy 'replace))
              ("new" (setq replace-policy 'new))
              (_ (throw :noload t))))
          (pcase replace-policy
            ('replace)
            ('new
             (unless (consp current-prefix-arg) ; user new tab suppression
               (tab-bar-new-tab-to))))))
      (let* ((ws (copy-tree (alist-get 'window bookmark)))
             (dummy (generate-new-buffer " *bufferlo dummy buffer*")) ; TODO: needs unwind-protect or make-finalizer?
             (renamed
              (mapcar
               (lambda (bm)
                 (let ((orig-name (car bm))
                       (record (cadr bm)))
                   (set-buffer dummy)
                   (condition-case err
                       (progn (funcall (or (bookmark-get-handler record)
                                           'bookmark-default-handler)
                                       record)
                              (run-hooks 'bookmark-after-jump-hook))
                     (error
                      (ignore err)
                      (message "Bufferlo tab: Could not restore %s (error %s)" orig-name err)))
                   (unless (eq (current-buffer) dummy)
                     (unless (string-equal orig-name (buffer-name))
                       (cons orig-name (buffer-name))))))
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
        (window-state-put ws (frame-root-window) 'safe)
        (set-frame-parameter nil 'buffer-list bl)
        (set-frame-parameter nil 'buried-buffer-list nil)
        (let ((tbm bookmark-name))
          (when (and (not embedded-tab)
                     bookmark-name
                     (frame-parameter nil 'bufferlo-bookmark-frame-name))
            (let ((clear-policy bufferlo-bookmark-tab-load-into-bookmarked-frame-policy))
              (when (eq clear-policy 'prompt)
                (pcase (let ((read-answer-short t))
                         (with-local-quit
                           (read-answer "Tab bookmark conflicts with frame bookmark: Allow tab bookmark, Clear tab bookmark "
                                        '(("allow" ?a "Allow tab bookmark")
                                          ("clear" ?c "Clear tab bookmark")
                                          ("help" ?h "Help")
                                          ("quit" ?q "Quit--retains the bookmark")))))
                  ("clear" (setq clear-policy 'clear))
                  (_ (setq clear-policy 'allow)))) ; allow, quit cases
              (pcase clear-policy
                ('clear
                 (setq tbm nil))
                ('clear-warn
                 (setq tbm nil)
                 (setq msg (concat msg "; cleared tab bookmark")))
                ('allow))))
          (setf (alist-get 'bufferlo-bookmark-tab-name
                           (cdr (bufferlo--current-tab)))
                tbm))
        (unless no-message
          (message "Restored bufferlo tab bookmark%s%s"
                   (if bookmark-name (format ": %s" bookmark-name) "") (if msg msg "")))))))

(put #'bufferlo--bookmark-tab-handler 'bookmark-handler-type "B-Tab") ; short name here as bookmark-bmenu-list hard codes width of 8 chars

(defun bufferlo--bookmark-frame-get (&optional frame)
  "Get the bufferlo frame bookmark.
FRAME specifies the frame; the default value of nil selects the current frame."
  (let ((orig-tab (1+ (tab-bar--current-tab-index nil frame)))
        (tabs nil))
    (dotimes (i (length (funcall tab-bar-tabs-function frame)))
      (tab-bar-select-tab (1+ i))
      (let* ((curr (alist-get 'current-tab (funcall tab-bar-tabs-function frame)))
             (name (alist-get 'name curr))
             (explicit-name (alist-get 'explicit-name curr))
             (tbm (bufferlo--bookmark-tab-get frame)))
        (if explicit-name
            (push (cons 'tab-name name) tbm)
          (push (cons 'tab-name nil) tbm))
        (push tbm tabs)))
    (tab-bar-select-tab orig-tab)
    `((tabs . ,(reverse tabs))
      (current . ,orig-tab)
      (handler . ,#'bufferlo--bookmark-frame-handler))))

(defun bufferlo--bookmark-frame-handler (bookmark &optional no-message)
  "Handle bufferlo frame bookmark.
The argument BOOKMARK is the to-be restored frame bookmark created via
`bufferlo--bookmark-frame-get'.  The optional argument NO-MESSAGE inhibits
the message after successfully restoring the bookmark."
  (let ((new-frame)
        (keep-new-frame))
    (unwind-protect
        (catch :noload
          (let ((bookmark-name (bookmark-name-from-full-record bookmark))
                (duplicate-policy bufferlo-bookmark-frame-duplicate-policy)
                (msg))
            (if-let ((abm (assoc bookmark-name (bufferlo--active-bookmarks))))
                (progn
                  (when (eq duplicate-policy 'prompt)
                    (pcase (let ((read-answer-short t))
                             (with-local-quit
                               (read-answer "Frame bookmark already active: Allow, Clear bookmark after loading, Raise existing "
                                            '(("allow" ?a "Allow duplicate")
                                              ("clear" ?c "Clear the bookmark after loading")
                                              ("raise" ?r "Raise the frame with the existing bookmark")
                                              ("help" ?h "Help")
                                              ("quit" ?q "Quit with no changes")))))
                      ("allow" (setq duplicate-policy 'allow))
                      ("clear" (setq duplicate-policy 'clear))
                      ("raise" (setq duplicate-policy 'raise))
                      (_ (throw :noload t))))
                  (when (eq duplicate-policy 'raise)
                    (bufferlo--bookmark-raise abm)
                    (throw :noload t)))
              (setq duplicate-policy nil)) ; signal not a duplicate
            (when (and
                   bufferlo-bookmark-frame-load-make-frame
                   (not (consp current-prefix-arg)) ; user make-frame suppression
                   (not pop-up-frames)) ; make-frame implied by functions like `bookmark-jump-other-frame'
              (with-current-buffer (messages-buffer) ; least expensive (fundamental-mode)
                (setq new-frame (make-frame))))
            (let ((fbm (frame-parameter nil 'bufferlo-bookmark-frame-name))
                  (load-policy bufferlo-bookmark-frame-load-policy))
              (if fbm
                  (progn
                    (when (eq load-policy 'prompt)
                      (pcase (let ((read-answer-short t))
                               (with-local-quit
                                 (read-answer "Current frame already bookmarked: load and retain Current, Replace with new, Merge with existing "
                                              '(("current" ?c "Replace frame, retain the current bookmark")
                                                ("replace" ?r "Replace frame, adopt the loaded bookmark")
                                                ("merge" ?m "Merge the new tab content with the existing bookmark")
                                                ("help" ?h "Help")
                                                ("quit" ?q "Quit with no changes")))))
                        ("current" (setq load-policy 'replace-frame-retain-current-bookmark))
                        ("replace" (setq load-policy 'replace-frame-adopt-loaded-bookmark))
                        ("merge" (setq load-policy 'merge))
                        (_ (throw :noload t))))
                    (pcase load-policy
                      ('disallow-replace
                       (when (not (equal fbm bookmark-name)) ; allow reloads of existing bookmark
                         (unless no-message (message "Frame already bookmarked as %s; not loaded." fbm))
                         (throw :noload t)))
                      ('replace-frame-retain-current-bookmark
                       (setq msg (concat msg (format "; retained existing bookmark %s." fbm))))
                      ('replace-frame-adopt-loaded-bookmark
                       (setq msg (concat msg (format "; adopted loaded bookmark %s." fbm)))
                       (setq fbm bookmark-name))
                      ('merge
                       (setq msg (concat msg (format "; merged tabs from bookmark %s." bookmark-name))))))
                (setq fbm bookmark-name)) ; not already bookmarked
              (with-selected-frame (or new-frame (selected-frame))
                (unless (eq load-policy 'merge)
                  (if (>= emacs-major-version 28)
                      (tab-bar-tabs-set nil)
                    (set-frame-parameter nil 'tabs nil)))
                (let ((first (if (eq load-policy 'merge) nil t))
                      (tab-bar-new-tab-choice t))
                  (mapc
                   (lambda (tbm)
                     (if first
                         (setq first nil)
                       (tab-bar-new-tab-to))
                     (bufferlo--bookmark-tab-handler tbm t 'embedded-tab)
                     (when-let (tab-name (alist-get 'tab-name tbm))
                       (tab-bar-rename-tab tab-name)))
                   (alist-get 'tabs bookmark)))
                (tab-bar-select-tab (alist-get 'current bookmark))
                (pcase duplicate-policy
                  ('allow)
                  ('clear
                   (setq fbm nil))
                  ('clear-warn
                   (setq fbm nil)
                   (setq msg (concat msg "; cleared frame bookmark"))))
                (set-frame-parameter nil 'bufferlo-bookmark-frame-name fbm)))
            (when new-frame
              (setq keep-new-frame t))
            (unless no-message
              (message "Restored bufferlo frame bookmark%s%s"
                       (if bookmark-name (format ": %s" bookmark-name) "")
                       (if msg msg "")))))
      (if (and new-frame (not keep-new-frame))
          (delete-frame new-frame)
        (raise-frame (or new-frame (selected-frame)))))))

(put #'bufferlo--bookmark-frame-handler 'bookmark-handler-type "B-Frame") ; short name here as bookmark-bmenu-list hard codes width of 8 chars

(defun bufferlo-bookmark-set-location (bookmark-name-or-record &optional location)
  "Set the location of BOOKMARK-NAME-OR-RECORD to LOCATION or \\=\"\", if nil."
  (bookmark-prop-set bookmark-name-or-record 'location (or location ""))
  bookmark-name-or-record)

(defvar bufferlo--bookmark-handlers
  (list
   #'bufferlo--bookmark-tab-handler
   #'bufferlo--bookmark-frame-handler)
  "Bufferlo bookmark handlers.")

(defun bufferlo--bookmark-get-names (&rest handlers)
  "Get the names of all existing bookmarks for HANDLERS."
  (bookmark-maybe-load-default-file)
  (mapcar
   #'car
   (seq-filter
    (lambda (bm)
      (memq (alist-get 'handler (cdr bm)) (or handlers bufferlo--bookmark-handlers)))
    bookmark-alist)))

(defun bufferlo--current-tab ()
  "Get the current tab record."
  (if (>= emacs-major-version 28)
      (tab-bar--current-tab-find)
    (assq 'current-tab (funcall tab-bar-tabs-function nil))))

(defun bufferlo-bookmark-tab-save (name &optional no-overwrite no-message)
  "Save the current tab as a bookmark.
NAME is the bookmark's name. If NO-OVERWRITE is non-nil, record
the new bookmark without throwing away the old one. NO-MESSAGE
inhibits the save status message.

This function persists the current tab's state:
The resulting bookmark stores the window configuration and the local
buffer list of the current tab.  In addition, it saves the bookmark
state (not the contents) of the bookmarkable buffers in the tab's local
buffer list."
  (interactive
   (list (completing-read
          "Save bufferlo tab bookmark: "
          (bufferlo--bookmark-get-names #'bufferlo--bookmark-tab-handler)
          nil nil nil 'bufferlo-bookmark-tab-history
          (alist-get 'bufferlo-bookmark-tab-name (bufferlo--current-tab)))))
  (bufferlo--warn)
  (bookmark-store name (bufferlo-bookmark-set-location (bufferlo--bookmark-tab-get)) no-overwrite)
  (setf (alist-get 'bufferlo-bookmark-tab-name
                   (cdr (bufferlo--current-tab)))
        name)
  (unless no-message
    (message "Saved bufferlo tab bookmark: %s" name)))

(defun bufferlo-bookmark-tab-load (name)
  "Load a tab bookmark.
NAME is the bookmark's name.

`bufferlo-bookmark-tab-replace-policy' controls if the loaded
bookmark replaces the current tab or makes a new tab.

Specify a prefix argument to force reusing the current tab."
  (interactive
   (list (completing-read
          "Load bufferlo tab bookmark: "
          (bufferlo--bookmark-get-names #'bufferlo--bookmark-tab-handler)
          nil nil nil 'bufferlo-bookmark-tab-history
          (alist-get 'bufferlo-bookmark-tab-name (bufferlo--current-tab)))))
  (bufferlo--warn)
  (let ((bookmark-fringe-mark nil))
    (bookmark-jump name #'ignore)))

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
associated bookmark exists.

This reuses the current tab even if
`bufferlo-bookmark-tab-replace-policy' is set to \\='new."
  (interactive)
  (bufferlo--warn)
  (if-let (bm (alist-get 'bufferlo-bookmark-tab-name
                         (cdr (bufferlo--current-tab))))
      (let ((bufferlo-bookmark-tab-replace-policy 'replace) ; reload reuses current tab
            (bufferlo-bookmark-tab-duplicate-policy 'allow)) ; not technically a duplicate
        (bufferlo-bookmark-tab-load bm))
    (call-interactively #'bufferlo-bookmark-tab-load)))

(defun bufferlo-bookmark-frame-save (name &optional no-overwrite no-message)
  "Save the current frame as a bookmark.
NAME is the bookmark's name. If NO-OVERWRITE is non-nil, record
the new bookmark without throwing away the old one. If NO-MESSAGE
is non-nil, inhibit the save status message.

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
  (bookmark-store name (bufferlo-bookmark-set-location (bufferlo--bookmark-frame-get)) no-overwrite)
  (set-frame-parameter nil 'bufferlo-bookmark-frame-name name)
  (unless no-message
    (message "Saved bufferlo frame bookmark: %s" name)))

(defun bufferlo-bookmark-frame-load (name)
  "Load a frame bookmark.
NAME is the bookmark's name.

Replace the current frame's state if
`bufferlo-bookmark-frame-load-make-frame' is nil."
  (interactive
   (list (completing-read
          "Load bufferlo frame bookmark: "
          (bufferlo--bookmark-get-names #'bufferlo--bookmark-frame-handler)
          nil nil nil 'bufferlo-bookmark-frame-history
          (frame-parameter nil 'bufferlo-bookmark-frame-name))))
  (bufferlo--warn)
  (let ((bookmark-fringe-mark nil))
    (bookmark-jump name #'ignore)))

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
      (let ((bufferlo-bookmark-frame-load-make-frame nil) ; reload reuses the current frame
            (bufferlo-bookmark-frame-load-policy 'replace-frame-retain-current-bookmark)
            (bufferlo-bookmark-frame-duplicate-policy 'allow)) ; not technically a duplicate
        (bufferlo-bookmark-frame-load bm))
    (call-interactively #'bufferlo-bookmark-frame-load)))

(defun bufferlo-bookmark-frame-load-merge ()
  "Load a bufferlo frame bookmark merging its content into the current frame."
  (interactive)
  (let ((bufferlo-bookmark-frame-duplicate-policy 'allow)
        (bufferlo-bookmark-frame-load-policy 'merge)
        (bufferlo-bookmark-frame-load-make-frame nil))
    (call-interactively #'bufferlo-bookmark-frame-load)))

(defun bufferlo--active-bookmarks (&optional frames type)
  "Produces an alist of active bufferlo bookmarks.
The alist is of the form:
  ((bookmark-name .
    ((\\='type . type) (\\='frame . frame) (\\='tab-number . tab-number))) ...)
for the specified FRAMES,
filtered by TYPE, where type is:
  \\='fbm for frame bookmarks which include frame only or
  \\='tbm for tab bookmarks which include frame and tab numbers."
  (let ((abms))
    (dolist (frame (or frames (frame-list)))
      (when-let ((fbm (frame-parameter frame 'bufferlo-bookmark-frame-name)))
        (when (or (null type) (eq type 'fbm))
          (push (list fbm `((type . fbm)
                            (frame . ,frame))) abms)))
      (dolist (tab (funcall tab-bar-tabs-function frame))
        (when-let ((tbm (alist-get 'bufferlo-bookmark-tab-name tab)))
          (when (or (null type) (eq type 'tbm))
            (push (list tbm `((type . tbm)
                              (frame . ,frame)
                              (tab-number . ,(1+ (tab-bar--tab-index tab nil frame))))) abms)))))
    abms))

(defun bufferlo-bookmarks-save-all-p (_bookmark-name)
  "This predicate matches all bookmark names.
It is intended to be used in `bufferlo-bookmarks-save-predicate-functions'."
  t)

(defun bufferlo-bookmarks-load-all-p (_bookmark-name)
  "This predicate matches all bookmark names.
It is intended to be used in `bufferlo-bookmarks-load-predicate-functions'."
  t)

(defun bufferlo--active-bookmark-duplicates()
  "Produce a list of duplicated active bookmark names."
  (let ((abm-dupes)
        (abm-names (mapcar #'car (bufferlo--active-bookmarks))))
    (dolist (abm (seq-uniq abm-names))
      (when (> (seq-count (lambda (x) (equal x abm)) abm-names) 1)
        (push abm abm-dupes)))
    abm-dupes))

(defun bufferlo--bookmarks-save (active-bookmark-names active-bookmarks &optional no-message)
  "Save the bookmarks in ACTIVE-BOOKMARK-NAMES indexed by ACTIVE-BOOKMARKS.
Specify NO-MESSAGE to inhibit the bookmark save status message."
  (let ((bookmarks-saved nil)
        (start-time (current-time)))
    (let ((bookmark-save-flag nil)) ; inhibit built-in bookmark file saving until we're done
      (dolist (abm-name active-bookmark-names)
        (when-let* ((abm (assoc abm-name active-bookmarks))
                    (abm-type (alist-get 'type (cadr abm)))
                    (abm-frame (alist-get 'frame (cadr abm))))
          (with-selected-frame abm-frame
            (cond
             ((eq abm-type 'fbm)
              (bufferlo-bookmark-frame-save abm-name nil t))
             ((eq abm-type 'tbm)
              (let ((orig-tab-number (1+ (tab-bar--current-tab-index))))
                (tab-bar-select-tab (alist-get 'tab-number (cadr abm)))
                (bufferlo-bookmark-tab-save abm-name nil t)
                (tab-bar-select-tab orig-tab-number)
                )))
            (push abm-name bookmarks-saved)))))
    (cond
     (bookmarks-saved
      (let ((inhibit-message (or no-message
                                 (not (memq bufferlo-bookmarks-auto-save-messages (list 'saved t))))))
        (bookmark-save)
        (message "Saved bufferlo bookmarks: %s, in %.2f second(s)"
                 (mapconcat 'identity bookmarks-saved " ")
                 (float-time (time-subtract (current-time) start-time)))))
     (t
      (when (and (not no-message)
                 (memq bufferlo-bookmarks-auto-save-messages (list 'notsaved t)))
        (message "No bufferlo bookmarks saved."))))))

(defun bufferlo-bookmarks-save (&optional all)
  "Save active bufferlo bookmarks.
This is invoked via an optional idle timer which runs according
to `bufferlo-bookmarks-auto-save-idle-interval', or and is
optionally invoked at Emacs exit.

You may invoke this manually at any time to save active
bookmarks; however, doing so does not reset the save interval
timer.

Each bookmark is filtered according to
`bufferlo-bookmarks-save-predicate-functions'.

Specify ALL to ignore the predicates and save every active
bufferlo bookmark or use a prefix argument across ALL frames,
overriding `bufferlo-bookmarks-save-frame-policy'.

Note: if there are duplicate active bufferlo bookmarks, the last
one to be saved will take precedence.

Duplicate bookmarks are handled according to
`bufferlo-bookmarks-save-duplicates-policy'."
  (interactive)
  (catch :nosave
    (when-let ((duplicate-bookmarks (bufferlo--active-bookmark-duplicates))
               (duplicate-policy bufferlo-bookmarks-save-duplicates-policy))
      (when (eq duplicate-policy 'prompt)
        (pcase (let ((read-answer-short t))
                 (with-local-quit
                   (read-answer (format "Duplicate active bookmarks %s: Allow to save, Disallow to cancel " duplicate-bookmarks)
                                '(("allow" ?a "Allow duplicate")
                                  ("disallow" ?d "Disallow duplicates; cancel saving")
                                  ("help" ?h "Help")
                                  ("quit" ?q "Quit with no changes")))))
          ("allow" (setq duplicate-policy 'allow))
          ("disallow" (setq duplicate-policy 'disallow))
          (_ (throw :nosave t))))
      (pcase duplicate-policy
        ('allow)
        (_ (throw :nosave t))))
    (let ((bufferlo-bookmarks-save-predicate-functions
           (if (or all (consp current-prefix-arg))
               (list #'bufferlo-bookmarks-save-all-p)
             bufferlo-bookmarks-save-predicate-functions))
          (frames (if all
                      (frame-list)
                    (pcase bufferlo-bookmarks-save-frame-policy
                      ('current
                       (list (selected-frame)))
                      ('other
                       (seq-filter (lambda (x) (not (eq x (selected-frame)))) (frame-list)))
                      (_
                       (frame-list))))))
      (let ((abm-names-to-save)
            (abms (bufferlo--active-bookmarks frames)))
        (dolist (abm abms)
          (let ((abm-name (car abm)))
            (when (run-hook-with-args-until-success
                   'bufferlo-bookmarks-save-predicate-functions
                   abm-name)
              (push abm-name abm-names-to-save))))
        (bufferlo--bookmarks-save abm-names-to-save abms)))))

(defun bufferlo--bookmarks-save-at-emacs-exit ()
  "Save bufferlo bookmarks at Emacs exit.
This honors `bufferlo-bookmarks-save-at-emacs-exit' by predicate or
\\='all. Intended to be invoked via `kill-emacs-hook'."
  (bufferlo--bookmarks-auto-save-timer-maybe-cancel)
  (let ((bufferlo-bookmarks-save-predicate-functions
         (if (eq bufferlo-bookmarks-save-at-emacs-exit 'all)
             (list #'bufferlo-bookmarks-save-all-p)
           bufferlo-bookmarks-save-predicate-functions)))
    (bufferlo-bookmarks-save)))

(defun bufferlo--bookmarks-load-startup ()
  "Load bookmarks at startup."
  (let ((bufferlo-bookmarks-load-tabs-make-frame bufferlo-bookmarks-load-at-emacs-startup-tabs-make-frame))
    (bufferlo-bookmarks-load (eq bufferlo-bookmarks-load-at-emacs-startup 'all))))

(defun bufferlo-bookmarks-load (&optional all)
  "Load stored bufferlo bookmarks.
Invoke manually or via `window-setup-hook' to restore bookmarks
at Emacs startup.

Each bookmark is filtered according to
`bufferlo-bookmarks-load-predicate-functions'.

ALL, or a prefix argument, ignores the load predicates and loads
all stored bufferlo bookmarks. Tab bookmarks are loaded into the
current or new frame according to
`bufferlo-bookmarks-load-tabs-make-frame'."
  (interactive)
  (let ((bookmarks-loaded nil)
        (start-time (current-time))
        (orig-frame (selected-frame))
        (bufferlo-bookmarks-load-predicate-functions
         (if (or all (consp current-prefix-arg))
             (list #'bufferlo-bookmarks-load-all-p)
           bufferlo-bookmarks-load-predicate-functions)))
    ;; load tab bookmarks, making a new frame if required
    (let ((bufferlo-bookmark-tab-replace-policy 'replace) ; we handle making tabs in this loop
          (tab-bar-new-tab-choice t)
          (new-tab-frame nil))
      (dolist (bookmark-name (bufferlo--bookmark-get-names #'bufferlo--bookmark-tab-handler))
        (when (run-hook-with-args-until-success 'bufferlo-bookmarks-load-predicate-functions bookmark-name)
          (if (and bufferlo-bookmarks-load-tabs-make-frame (not new-tab-frame))
              (select-frame (setq new-tab-frame (make-frame)))
            (tab-bar-new-tab-to))
          (bufferlo-bookmark-tab-load bookmark-name)
          (push bookmark-name bookmarks-loaded))))
    ;; load frame bookmarks
    (dolist (bookmark-name (bufferlo--bookmark-get-names #'bufferlo--bookmark-frame-handler))
      (when (run-hook-with-args-until-success 'bufferlo-bookmarks-load-predicate-functions bookmark-name)
        (bufferlo-bookmark-frame-load bookmark-name)
        (push bookmark-name bookmarks-loaded)))
    (select-frame orig-frame)
    (when bookmarks-loaded
      (message "Loaded bufferlo bookmarks: %s, in %.2f seconds "
               (mapconcat 'identity bookmarks-loaded " ")
               (float-time (time-subtract (current-time) start-time))))))

;; TODO: handle option to save? prefix arg to save or not save?
(defun bufferlo-bookmarks-close-interactive ()
  "Prompt for active bufferlo bookmarks to close."
  (interactive)
  (let* ((abms (bufferlo--active-bookmarks))
         (abm-names (mapcar #'car abms))
         (comps
          (completion-all-completions
           (completing-read "Close bookmark(s) without saving: "
                            (lambda (str pred flag)
                              (pcase flag
                                ('metadata
                                 '(metadata (category . bookmark)))
                                (_
                                 (all-completions str abm-names pred)))))
           abm-names nil nil))
         (base-size (cdr (last comps))))
    (when base-size (setcdr (last comps) nil))
    (setq comps (seq-uniq comps))
    (bufferlo--close-active-bookmarks comps abms)))

(defun bufferlo-bookmarks-save-interactive ()
  "Prompt for active bufferlo bookmarks to save."
  (interactive)
  (let* ((abms (bufferlo--active-bookmarks))
         (abm-names (mapcar #'car abms))
         (comps
          (completion-all-completions
           (completing-read "Save bookmark(s): "
                            (lambda (str pred flag)
                              (pcase flag
                                ('metadata
                                 '(metadata (category . bookmark)))
                                (_
                                 (all-completions str abm-names pred)))))
           abm-names nil nil))
         (base-size (cdr (last comps))))
    (when base-size (setcdr (last comps) nil))
    (setq comps (seq-uniq comps))
    (bufferlo--bookmarks-save comps abms)))

(defun bufferlo-bookmarks-load-interactive ()
  "Prompt for bufferlo bookmarks to load.
Use a prefix argument to narrow the candidates to frame tabs, or
a double prefix argument to narrow to tab bookmark candidates."
  (interactive)
  (let* ((bookmark-names
          (apply 'bufferlo--bookmark-get-names
                 (cond
                  ((and (consp current-prefix-arg) (eq (prefix-numeric-value current-prefix-arg) 4)) (list #'bufferlo--bookmark-frame-handler))
                  ((and (consp current-prefix-arg) (eq (prefix-numeric-value current-prefix-arg) 16)) (list #'bufferlo--bookmark-tab-handler))
                  (t bufferlo--bookmark-handlers))))
         (comps
          (completion-all-completions
           (completing-read "Load bookmark(s): "
                            (lambda (str pred flag)
                              (pcase flag
                                ('metadata
                                 '(metadata (category . bookmark)))
                                (_
                                 (all-completions str bookmark-names pred)))))
           bookmark-names nil nil))
         (base-size (cdr (last comps))))
    (when base-size (setcdr (last comps) nil))
    (setq comps (seq-uniq comps))
    (dolist (bookmark-name comps)
      (bookmark-jump bookmark-name #'ignore))))

(defun bufferlo-maybe-clear-active-bookmark (&optional force)
  "Clear the current frame and/or tab bufferlo bookmark.
This clears the active bookmark name only if there is another
active bufferlo bookmark with the same name and FORCE is nil.

This is useful if an active bookmark has been loaded more than
once, and especially if you use the auto save feature and want to
ensure that only one bookmark is active.

FORCE will clear the bookmark even if it is currently unique.

Specify a prefix argument to imply FORCE."
  (interactive)
  (let* ((fbm (frame-parameter nil 'bufferlo-bookmark-frame-name))
         (tbm (alist-get 'bufferlo-bookmark-tab-name (tab-bar--current-tab-find)))
         (duplicate-fbm (> (length (seq-filter (lambda (x) (equal fbm (car x))) (bufferlo--active-bookmarks nil 'fbm))) 1))
         (duplicate-tbm (> (length (seq-filter (lambda (x) (equal tbm (car x))) (bufferlo--active-bookmarks nil 'tbm))) 1)))
    (when (or force (consp current-prefix-arg) duplicate-fbm)
      (set-frame-parameter nil 'bufferlo-bookmark-frame-name nil))
    (when (or force (consp current-prefix-arg) duplicate-tbm)
      (setf (alist-get 'bufferlo-bookmark-tab-name
                       (cdr (bufferlo--current-tab)))
            nil))))

(defun bufferlo-clear-active-bookmarks ()
  "Clear all active bufferlo frame and tab bookmarks.
This leaves all content untouched and does not impact stored bookmarks.

You will be prompted to confirm clearing (it cannot be undone)
unless a prefix argument is specified.

This is useful when you have accumulated a complex working set of
frames, tabs, buffers and want to save new bookmarks without
disturbing existing bookmarks, or where auto-saving is enabled
and you want to avoid overwriting stored bookmarks, perhaps with
transient work."
  (interactive)
  (when (or (consp current-prefix-arg)
            (y-or-n-p "Clear all active bufferlo bookmarks? "))
    (dolist (frame (frame-list))
      (set-frame-parameter frame 'bufferlo-bookmark-frame-name nil)
      (dolist (tab (funcall tab-bar-tabs-function frame))
        (setf (alist-get 'bufferlo-bookmark-tab-name tab) nil)))))

(defun bufferlo--close-active-bookmarks (active-bookmark-names active-bookmarks)
  "Close the bookmarks in ACTIVE-BOOKMARK-NAMES indexed by ACTIVE-BOOKMARKS."
  (let* ((abms (seq-filter
                (lambda (x) (member (car x) active-bookmark-names))
                active-bookmarks))
         (tbms (seq-filter
                (lambda (x) (eq 'tbm (alist-get 'type (cadr x))))
                abms))
         (fbms (seq-filter
                (lambda (x) (eq 'fbm (alist-get 'type (cadr x))))
                abms))
         (orig-frame (selected-frame))
         (orig-tab-name (alist-get 'name (bufferlo--current-tab)))) ; can't rely on index, it might disappear
    (dolist (abm tbms)
      (let ((abm-frame (alist-get 'frame (cadr abm)))
            (abm-tab-number (alist-get 'tab-number (cadr abm))))
        (with-selected-frame abm-frame
          (tab-bar-select-tab abm-tab-number)
          (let ((bufferlo-close-tab-kill-buffers-save-bookmark-prompt nil)
                (bufferlo-close-tab-kill-buffers-prompt nil))
            (bufferlo-tab-close-kill-buffers)))))
    (dolist (abm fbms)
      (let ((abm-frame (alist-get 'frame (cadr abm))))
        (with-selected-frame abm-frame
          (let ((bufferlo-delete-frame-kill-buffers-save-bookmark-prompt nil)
                (bufferlo-delete-frame-kill-buffers-prompt nil))
            (bufferlo-delete-frame-kill-buffers)))))
    ;; Frame and/or tab could now be gone.
    (when (frame-live-p orig-frame)
      (select-frame orig-frame)
      (let ((tab-index (tab-bar--tab-index-by-name orig-tab-name)))
        (if tab-index
            (tab-bar-select-tab (1+ tab-index)))))))

(defun bufferlo-bookmarks-close ()
  "Close all active bufferlo frame and tab bookmarks and kill their buffers.

You will be prompted to save bookmarks using filter predicates or
save all.

A prefix argument inhibits the prompt and bypasses saving."
  (interactive)
  (let* ((close t)
         (abms (bufferlo--active-bookmarks))
         (abm-names (mapcar #'car abms)))
    (if (null abms)
        (message "No active bufferlo bookmarks")
      (unless (consp current-prefix-arg)
        (pcase (let ((read-answer-short t))
                 (with-local-quit
                   (read-answer "Save bookmarks before closing them: All, Predicate, No save "
                                '(("all" ?a "Save all active bookmarks")
                                  ("pred" ?p "Save predicate-filtered bookmarks, if set")
                                  ("nosave" ?n "Don't save")
                                  ("help" ?h "Help")
                                  ("quit" ?q "Quit")))))
          ("all"
           (bufferlo-bookmarks-save 'all))
          ("pred"
           (bufferlo-bookmarks-save))
          ("nosave")
          (_ (setq close nil))))
      (when close
        (bufferlo--close-active-bookmarks abm-names abms)))))

(defun bufferlo--bookmark-raise (abm)
  "Raise ABM's frame/tab."
  (when-let ((abm-type (alist-get 'type (cadr abm)))
             (abm-frame (alist-get 'frame (cadr abm))))
    (with-selected-frame abm-frame
      (raise-frame)
      (when (eq abm-type 'tbm)
        (tab-bar-select-tab
         (alist-get 'tab-number (cadr abm)))))))

(defun bufferlo-bookmark-raise ()
  "Raise the selected bookmarked frame or tab.
Note: If there are duplicated bookmarks, the first one found is
raised."
  (interactive)
  (let* ((abms (bufferlo--active-bookmarks))
         (abm-names (mapcar #'car abms))
         (comps
          (completion-all-completions
           (completing-read "Select a bookmark to raise: "
                            (lambda (str pred flag)
                              (pcase flag
                                ('metadata
                                 '(metadata (category . bookmark)))
                                (_
                                 (all-completions str abm-names pred)))))
           abm-names nil nil))
         (base-size (cdr (last comps))))
    (when base-size (setcdr (last comps) nil))
    (setq comps (seq-uniq comps))
    (if (not (= (length comps) 1))
        (message "Please select a single bookmark to raise")
      (when-let* ((abm (assoc (car comps) abms)))
        (bufferlo--bookmark-raise abm)))))

;;; bookmark advisories

;; (defun bookmark-set (&optional name no-overwrite)
;; (defun bookmark-set-no-overwrite (&optional name push-bookmark)
;; Leave these alone for now. They warn about duplicate bookmarks.

;; (defun bookmark-rename (old-name &optional new-name)
(defun bufferlo--bookmark-rename-advice (oldfn &optional old-name new-name)
  "`bookmark-rename' advice to prevent renaming active bufferlo bookmarks.
OLDFN OLD-NAME NEW-NAME"
  (interactive)
  (if (called-interactively-p 'interactive)
      (setq old-name (bookmark-completing-read "Old bookmark name")))
  (if-let ((abm (assoc old-name (bufferlo--active-bookmarks))))
      (user-error "%s is an active bufferlo bookmark--close its frame/tab, or clear it before renaming" old-name)
    (if (called-interactively-p 'interactive)
        (funcall-interactively oldfn old-name new-name)
      (funcall oldfn old-name new-name))))

;; (defun bookmark-delete (bookmark-name &optional batch)
(defun bufferlo--bookmark-delete-advice (oldfn &optional bookmark-name batch)
  "`bookmark-delete' advice to prevent deleting active bufferlo bookmarks.
OLDFN BOOKMARK-NAME BATCH"
  (interactive)
  (if (called-interactively-p 'interactive)
      (setq bookmark-name (bookmark-completing-read "Delete bookmark"
                                                    bookmark-current-bookmark)))
  (if-let ((abm (assoc bookmark-name (bufferlo--active-bookmarks))))
      (user-error "%s is an active bufferlo bookmark--close its frame/tab, or clear it before deleting" bookmark-name)
    (if (called-interactively-p 'interactive)
        (funcall-interactively oldfn bookmark-name batch)
      (funcall oldfn bookmark-name batch))))

;; (defun bookmark-delete-all (&optional no-confirm)
;; Leave this alone for now. It does prompt for confirmation.

;;; Aliases:

(defalias 'bufferlo-bms-load            'bufferlo-bookmarks-load-interactive)
(defalias 'bufferlo-bms-save            'bufferlo-bookmarks-save-interactive)
(defalias 'bufferlo-bms-close           'bufferlo-bookmarks-close-interactive)
(defalias 'bufferlo-bm-raise            'bufferlo-bookmark-raise)
(defalias 'bufferlo-bm-tab-save         'bufferlo-bookmark-tab-save)
(defalias 'bufferlo-bm-tab-save-curr    'bufferlo-bookmark-tab-save-current)
(defalias 'bufferlo-bm-tab-load         'bufferlo-bookmark-tab-load)
(defalias 'bufferlo-bm-tab-load-curr    'bufferlo-bookmark-tab-load-current)
(defalias 'bufferlo-bm-frame-save       'bufferlo-bookmark-frame-save)
(defalias 'bufferlo-bm-frame-save-curr  'bufferlo-bookmark-frame-save-current)
(defalias 'bufferlo-bm-frame-load       'bufferlo-bookmark-frame-load)
(defalias 'bufferlo-bm-frame-load-curr  'bufferlo-bookmark-frame-load-current)
(defalias 'bufferlo-bm-frame-load-merge 'bufferlo-bookmark-frame-load-merge)

(provide 'bufferlo)

;;; bufferlo.el ends here
