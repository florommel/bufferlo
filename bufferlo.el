;;; bufferlo.el --- Frame/Tab Local Buffer Lists with Persistence -*- lexical-binding: t -*-

;; Copyright (C) 2021-2025 Free Software Foundation, Inc.

;; Author: Florian Rommel <mail@florommel.de>
;;         Stephane Marks <shipmints@gmail.com>
;; Maintainer: Florian Rommel <mail@florommel.de>
;;             Stephane Marks <shipmints@gmail.com>
;; Url: https://github.com/florommel/bufferlo
;; Created: 2021-09-15
;; Version: 1.1
;; Package-Requires: ((emacs "29.1"))
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

;; With bufferlo, every frame and tab (i.e., `tab-bar-mode' tab) has an
;; additional manageable local buffer list.  A buffer is added to the local
;; buffer list when displayed in the frame/tab (e.g., by opening a new file in
;; the tab or by switching to the buffer from the global buffer list).

;; Using Emacs's built-in buffer-list frame parameter, bufferlo integrates
;; seamlessly with all standard frame and tab management facilities, including
;; undeletion of frames and tabs, tab duplication and moving, frame cloning,
;; and session persistence with `desktop' (though bufferlo frame and tab
;; bookmarks offer an alternative persistence method).

;; Bufferlo provides extensive management functions for its local lists and
;; offers features on top of switch-buffer functions, buffer menu, and
;; `ibuffer'.  You can configure any command that selects a buffer to use the
;; local buffer list via bufferlo-anywhere-mode.

;; In addition, bufferlo offers lightweight Emacs bookmarks-based persistence
;; for frames, tabs, and sets of frames/tabs to help you manage your transient
;; workflows.  Bufferlo bookmarks are compatible with built-in features such
;; as `bookmark-bmenu-list' and third-party packages such as consult which
;; offers consult-bookmark for interactive bookmark selection.

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

(defcustom bufferlo-menu-bar-show t
  "Show the bufferlo menu on the menu bar."
  :package-version '(bufferlo . "1.1")
  :type 'boolean)

(defcustom bufferlo-menu-bar-list-buffers 'both
  "Show simple and/or `ibuffer' buffer list menu items.
Set to \\='both to show both.
Set to \\='simple to show simple only.
Set to \\='ibuffer to show `ibuffer' only."
  :package-version '(bufferlo . "1.1")
  :type '(radio (const :tag "Show both simple and `ibuffer'" both)
                (const :tag "Show simple only" simple)
                (const :tag "Show `ibuffer' only" ibuffer)))

(defcustom bufferlo-prefer-local-buffers t
  "Use the frame `buffer-predicate' to prefer local buffers.
Without this option, buffers from across all frames are
presented.  This means that a local buffer will be preferred to be
displayed when the current buffer disappears (buried or killed).

This also influences `next-buffer' and `previous-buffer'.

Set to \\='tabs for `next-buffer' and `previous-buffer' to respect
buffers local to the current tab, otherwise they will cycle
through buffers across the frame.

This variable must be set before enabling `bufferlo-mode'."
  :package-version '(bufferlo . "0.8")
  :type '(radio (const :tag "Prefer local buffers" t)
                (const :tag "Prefer local tab buffers" tabs)
                (const :tag "Display all buffers" nil)))

(defcustom bufferlo-include-buried-buffers t
  "Include buried buffers in the local list (`bufferlo-buffer-list').
Use `bufferlo-bury' to remove and bury a buffer if this is set to t."
  :package-version '(bufferlo . "0.8")
  :type 'boolean)

(defcustom bufferlo-include-buffer-filters nil
  "Buffers that should always get included in a new tab or frame.
This is a list of regular expressions that match buffer names.
This is applied on frame and tab creation.  Included buffers can be
explicitly removed later.
This overrides buffers excluded by `bufferlo-exclude-buffer-filters'."
  :package-version '(bufferlo . "0.8")
  :type '(repeat regexp))

(defcustom bufferlo-exclude-buffer-filters '(".*")
  "Buffers that should always get excluded in a new tab or frame.
This is a list of regular expressions that match buffer names.
This is applied on frame and tab creation.  Excluded buffers can be
added explicitly later.  Use `bufferlo-hidden-buffers' to permanently
hide buffers from the local list.
Buffers included by `bufferlo-include-buffer-filters' take precedence."
  :package-version '(bufferlo . "0.8")
  :type '(repeat regexp))

(defcustom bufferlo-hidden-buffers nil
  "List of regexps matching names of buffers to hide in the local buffer lists.
Matching buffers are hidden even if displayed in the current frame or tab."
  :package-version '(bufferlo . "0.8")
  :type '(repeat regexp))

(defcustom bufferlo-kill-buffers-exclude-filters
  '("\\` " "\\`\\*Messages\\*\\'" "\\`\\*scratch\\*\\'")
  "Buffers that should not be killed by `bufferlo-kill-buffers'.
This is a list of regular expressions that match buffer names."
  :package-version '(bufferlo . "0.8")
  :type '(repeat regexp))

(defcustom bufferlo-kill-buffers-prompt nil
  "If non-nil, confirm before killing local or orphan buffers."
  :package-version '(bufferlo . "1.1")
  :type 'boolean)

(defcustom bufferlo-kill-modified-buffers-policy nil
  "Bufferlo behavior when killing modified or process buffers.

This policy applies to all bufferlo functions that entail killing buffers,
e.g., `bufferlo-kill-buffers', `bufferlo-kill-orphan-buffers',
`bufferlo-tab-close-kill-buffers', `bufferlo-delete-frame-kill-buffers'.

This policy is useful if `shell-mode' or `eshell-mode' buffers are
active in a bufferlo-controlled frame or tab.

nil means default Emacs behavior which may prompt.  This may have
side effects.

\\='retain-modified means bufferlo will leave modified buffers as
is.

\\='retain-modified-kill-without-file-name will leave modified buffers
as is BUT will kill buffers that have no file name; this includes shell,
hidden, and special buffers that can not normally be saved.

\\='kill-modified instructs bufferlo to kill modified buffers
without remorse including those with running processes such as
`shell-mode' buffers."
  :package-version '(bufferlo . "1.1")
  :type '(radio (const :tag "Retain modified buffers" retain-modified)
                (const :tag "Retain modified buffers BUT kill buffers without file names"
                       retain-modified-kill-without-file-name)
                (const :tag "Kill modified buffers without prompting"
                       kill-modified)
                (const :tag "Default Emacs behavior (will prompt)" nil)))

(defcustom bufferlo-bookmark-inhibit-bookmark-point nil
  "If non-nil, inhibit point in bookmarks.
This is useful if `save-place-mode' mode is enabled and you want it to
handle the place restoration in bufferlo bookmarks."
  :package-version '(bufferlo . "1.1")
  :type 'boolean)

(defcustom bufferlo-bookmark-buffers-exclude-filters nil
  "Buffers that should be excluded from bufferlo bookmarks.
This is a list of regular expressions to filter buffer names.
Buffers included by `bufferlo-bookmark-buffers-include-filters' take
precedence."
  :package-version '(bufferlo . "1.1")
  :type '(repeat regexp))

(defcustom bufferlo-bookmark-buffers-include-filters nil
  "Buffers that should be stored in bufferlo bookmarks.
This is a list of regular expressions to filter buffer names.
This overrides buffers excluded by `bufferlo-bookmark-buffers-exclude-filters'."
  :package-version '(bufferlo . "1.1")
  :type '(repeat regexp))

(defcustom bufferlo-bookmark-frame-load-make-frame nil
  "If non-nil, create a new frame to hold a loaded frame bookmark.
Set to \\='restore-geometry to restore the frame geometry to that
when it was last saved."
  :package-version '(bufferlo . "1.1")
  :type '(radio (const :tag "Make a new frame" t)
                (const :tag "Make a new frame and restore its geometry"
                       restore-geometry)
                (const :tag "Reuse the current frame" nil)))

(defcustom bufferlo-delete-frame-kill-buffers-prompt nil
  "If non-nil, confirm before deleting the frame and killing buffers."
  :package-version '(bufferlo . "1.1")
  :type 'boolean)

(defcustom bufferlo-close-tab-kill-buffers-prompt nil
  "If non-nil, confirm before closing the tab and killing buffers."
  :package-version '(bufferlo . "1.1")
  :type 'boolean)

(defcustom bufferlo-bookmark-frame-save-on-delete nil
  "Control automatically saving the frame bookmark on frame deletion.

nil does not save the frame bookmark when deleting the frame.

t always saves the frame bookmark when deleting the frame.
Prompts for a new bookmark name if the frame is not associated with a bookmark.

\\='when-bookmarked saves the bookmark only if the frame is already associated
with a current bookmark.

\\='on-kill-buffers behaves like t but only for the function
`bufferlo-delete-frame-kill-buffers'.

\\='on-kill-buffers-when-bookmarked behaves like \\='when-bookmarked but only
for `bufferlo-delete-frame-kill-buffers'."
  :package-version '(bufferlo . "1.1")
  :type '(radio (const :tag "Do not save" nil)
                (const :tag "Always save" t)
                (const :tag "Only if the frame is already associated with a bookmark"
                       when-bookmarked)
                (const :tag "Only if killing buffers"
                       on-kill-buffers)
                (const :tag "Only if killing buffers and associated with a bookmark"
                       on-kill-buffers-when-bookmarked)))

(defcustom bufferlo-bookmark-tab-save-on-close nil
  "Control automatically saving the tab bookmark on tab deletion.

nil does not save the tab bookmark when closing the tab.

t always saves the tab bookmark when closing the tab.
Prompts for a new bookmark name if the tab is not associated with a bookmark.

\\='when-bookmarked saves the bookmark only if the tab is already associated
with a current bookmark.

\\='on-kill-buffers behaves like t but only for the function
`bufferlo-tab-close-kill-buffers'.

\\='on-kill-buffers-when-bookmarked behaves like \\='when-bookmarked but only
for `bufferlo-tab-close-kill-buffers'."
  :package-version '(bufferlo . "1.1")
  :type '(radio (const :tag "Do not save" nil)
                (const :tag "Always save" t)
                (const :tag "Only if the tab is already associated with a bookmark"
                       when-bookmarked)
                (const :tag "Only if killing buffers"
                       on-kill-buffers)
                (const :tag "Only if killing buffers and associated with a bookmark"
                       on-kill-buffers-when-bookmarked)))

(defcustom bufferlo-bookmark-frame-load-policy 'prompt
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
  :package-version '(bufferlo . "1.1")
  :type '(radio (const :tag "Prompt" prompt)
                (const :tag "Disallow" disallow-replace)
                (const :tag "Replace frame, retain current bookmark name"
                       replace-frame-retain-current-bookmark)
                (const :tag "Replace frame, adopt loaded bookmark name"
                       replace-frame-adopt-loaded-bookmark)
                (const :tag "Merge" merge)))

(defcustom bufferlo-bookmark-frame-duplicate-policy 'prompt
  "Control duplicate active frame bookmarks.
These options help you manage and avoid potential confusion from
duplicate active bookmarks.

\\='prompt allows you to select a policy interactively.

\\='allow allows duplicates.

\\='clear silently clears the frame bookmark.

\\='clear-warn issues a warning message about the frame losing
its bookmark.

\\='ignore bypasses the duplicate.

\\='raise will raise the frame with the existing bookmark.  Raise does
not apply when restoring bookmark sets.

Note: \\='raise is considered \\='clear during `bookmark-set' loading."
  :package-version '(bufferlo . "1.1")
  :type '(radio (const :tag "Prompt" prompt)
                (const :tag "Allow" allow)
                (const :tag "Clear (silently)" clear)
                (const :tag "Clear (with message)" clear-warn)
                (const :tag "Ignore" ignore)
                (const :tag "Raise" raise)))

(defcustom bufferlo-bookmark-frame-persist-frame-name nil
  "If non-nil, store frame's name in its bookmark, restore when loading."
  :package-version '(bufferlo . "1.2")
  :type 'boolean)

(defcustom bufferlo-bookmark-tab-restore-explicit-name t
  "If non-nil, restore the tab's explicit name when loading a tab bookmark."
  :package-version '(bufferlo . "1.2")
  :type 'boolean)

(defcustom bufferlo-bookmarks-load-tabs-make-frame nil
  "If non-nil, make a new frame for tabs loaded by `bufferlo-bookmarks-load'.
If nil, tab bookmarks are loaded into the current frame."
  :package-version '(bufferlo . "1.1")
  :type 'boolean)

(defcustom bufferlo-bookmark-restore-tab-groups nil
  "Control the restoration of tab groups in frame and tab bookmarks

nil never restores tab groups.

t always restores tab groups.

\\='tabs only restores tab groups for tab bookmarks.

\\='frames only restores tab groups for frame bookmarks."
  :package-version '(bufferlo . "1.2")
  :type '(radio (const :tag "Never" nil)
                (const :tag "Always" t)
                (const :tag "Only for tab bookmarks" tabs)
                (const :tag "Only for frame bookmarks" frames)))

(defcustom bufferlo-bookmark-tab-replace-policy 'replace
  "Control whether loaded tabs replace current tabs or occupy new tabs.

\\='prompt allows you to select a policy interactively.

\\='replace clears the current tab and overwrites its content
with the loaded tab.

\\='new loads tab bookmarks into new tabs, honoring the user
option `tab-bar-new-tab-to'."
  :package-version '(bufferlo . "1.1")
  :type '(radio (const :tag "Prompt" prompt)
                (const :tag "Replace" replace)
                (const :tag "New" new)))

(defcustom bufferlo-bookmark-tab-duplicate-policy 'prompt
  "Control duplicate active tab bookmarks.
These options help you manage and avoid potential confusion from
duplicate active bookmarks.

\\='prompt allows you to select a policy interactively.

\\='allow allows duplicates.

\\='clear silently clears the tab bookmark which is natural
reified frame bookmark behavior.

\\='clear-warn issues a warning message about the tab losing its
bookmark.

\\='ignore bypasses the duplicate.

\\='raise raises the first found existing tab bookmark and its frame.
Raise does not apply when restoring bookmark sets or tabs embedded
within a frame bookmark.

Note: \\='raise is considered \\='clear during `bookmark-set' loading."
  :package-version '(bufferlo . "1.1")
  :type '(radio (const :tag "Prompt" prompt)
                (const :tag "Allow" allow)
                (const :tag "Clear (silently)" clear)
                (const :tag "Clear (with message)" clear-warn)
                (const :tag "Ignore" ignore)
                (const :tag "Raise" raise)))

(defcustom bufferlo-bookmark-tab-in-bookmarked-frame-policy 'prompt
  "Control how a tab bookmark is loaded into an already-bookmarked frame.

This also warns about setting a new frame bookmark on a frame
that has tab bookmarks, and vice versa setting a tab bookmark on
a bookmarked frame.

\\='clear will silently clear the tab bookmark which is natural
reified frame bookmark behavior.

\\='clear-warn issues a warning message about the tab losing its
bookmark.

\\='allow will retain the tab bookmark to enable it to be saved
or updated.  Note that the frame bookmark always supersedes the tab
bookmark if the frame bookmark is saved."
  :package-version '(bufferlo . "1.1")
  :type '(radio (const :tag "Prompt" prompt)
                (const :tag "Allow" allow)
                (const :tag "Clear (silently)" clear)
                (const :tag "Clear (with message)" clear-warn)))

(defcustom bufferlo-bookmark-tab-failed-buffer-policy nil
  "Control failed buffer bookmark restore handling.

This controls the handling of buffers in the bookmark's local buffer list
whose individual bookmark could not be restored (e.g., because the file
does not exist anymore) and for buffers that were not bookmarkable at all.

\\='placeholder creates a unique placeholder buffer in place of the
buffer that could not be restored.  By default, the placeholder buffer has
a special name.  This buffer will not have a file associated with it.
Each bookmark gets its own unique buffer name.

\\='placeholder-orig creates a placeholder buffer with the original
buffer name.  This buffer will not have a file associated with it.
If a buffer with the same name already exists, bufferlo does not create a
placeholder buffer but uses this buffer instead.

Use a string to select or create the buffer named by the string; e.g.,
\"*scratch*\".

Use a function that returns a buffer.  The function is passed the
original buffer name that failed to load.

nil does not create placeholder buffers for failed bookmarks.  However,
similar to the \\='placeholder-orig policy, if a buffer with the same name
exists in the Emacs session, bufferlo will use this buffer.
If all buffers fail to restore and no matching existing buffers are found,
the default buffer shown will be chosen by Emacs."
  :package-version '(bufferlo . "1.1")
  :type '(radio (const :tag "Placeholder" placeholder)
                (const :tag "Placeholder w/failed buffer name" placeholder-orig)
                (string :tag "Buffer to select")
                (function :tag "Function to call")
                (const :tag "Ignore" nil)))

(defcustom bufferlo-bookmarks-save-duplicates-policy 'prompt
  "Control duplicates when saving all bookmarks.

\\='prompt allows you to select a policy interactively.

\\='allow will save potentially differing content for the same
bookmark name multiple times with the last-one-saved taking
precedence.  A warning message indicates the names of duplicate
bookmarks.

\\='disallow prevents the potentially confusing of overwriting
bookmark content for the same bookmark names.  A warning message
indicates the names of duplicate bookmarks.

Note: When using bufferlo's auto-save feature, and to avoid
repeated prompts and warnings, it is best to choose policies in
advance that prevent duplicate frame and tab bookmarks."
  :package-version '(bufferlo . "1.1")
  :type '(radio (const :tag "Prompt" prompt)
                (const :tag "Allow" allow)
                (const :tag "Disallow" disallow)))

(defcustom bufferlo-bookmarks-save-frame-policy 'all
  "Control bufferlo bookmarks save frame selection behavior.

\\='current saves bookmarks on the current frame only.

\\='other saves bookmarks on non-current frames.

\\='all saves bookmarks across all frames."
  :package-version '(bufferlo . "1.1")
  :type '(radio (const :tag "Current frame" current)
                (const :tag "Other frames" other)
                (const :tag "All frames" all)))

(defcustom bufferlo-bookmarks-save-predicate-functions
  (list #'bufferlo-bookmarks-save-all-p)
  "Functions to filter active bufferlo bookmarks to save.
These are applied when `bufferlo-bookmarks-auto-save-interval' is > 0,
or manually via `bufferlo-bookmarks-save'.  Functions are passed the
bufferlo bookmark name and invoked until the first positive result.  Set
to `#'bufferlo-bookmarks-save-all-p' to save all bookmarks or provide
your own predicates (note: be sure to remove
`#'bufferlo-bookmarks-save-all-p' from the list)."
  :package-version '(bufferlo . "1.1")
  :type 'hook)

(defcustom bufferlo-bookmarks-load-predicate-functions nil
  "Functions to filter stored bufferlo bookmarks to load.
These are applied in `bufferlo-bookmarks-load' which might also
be invoked at Emacs startup time using `window-setup-hook'.
Functions are passed the bufferlo bookmark name and invoked until
the first positive result.  Set to
`#'bufferlo-bookmarks-load-all-p' to load all bookmarks or
provide your own predicates."
  :package-version '(bufferlo . "1.1")
  :type 'hook)

(defcustom bufferlo-bookmarks-save-at-emacs-exit 'nosave
  "Bufferlo can save active bookmarks at Emacs exit.

\\='nosave does not save any active bookmarks.

\\='all saves all active bufferlo bookmarks.

\\='pred honors the filter predicates
in `bufferlo-bookmarks-save-predicate-functions'."
  :package-version '(bufferlo . "1.1")
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
  :package-version '(bufferlo . "1.1")
  :type '(radio (const :tag "Do not load at startup" noload)
                (const :tag "Predicate-filtered bookmarks" pred)
                (const :tag "All bookmarks" all)))

(defcustom bufferlo-bookmarks-load-at-emacs-startup-tabs-make-frame nil
  "If nil, the initial frame is reused for restored tabs.
If non-nil, a new frame is created for restored tabs."
  :package-version '(bufferlo . "1.1")
  :type 'boolean)

(defcustom bufferlo-ibuffer-bind-local-buffer-filter t
  "If non-nil, bind the local buffer filter and the orphan filter in ibuffer.
The local buffer filter is bound to \"/ l\" and the orphan filter to \"/ L\"."
  :package-version '(bufferlo . "0.8")
  :type 'boolean)

(defcustom bufferlo-ibuffer-bind-keys t
  "If non-nil, bind ibuffer convenience keys for bufferlo functions."
  :package-version '(bufferlo . "1.1")
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
  :package-version '(bufferlo . "0.8")
  :type 'string)

(defcustom bufferlo-local-scratch-buffer-initial-major-mode nil
  "The initial major mode for local scratch buffers.
If nil, the local scratch buffers' major mode is set to `initial-major-mode'."
  :package-version '(bufferlo . "0.8")
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
  :package-version '(bufferlo . "0.8")
  :type '(choice (repeat   :tag "Filter specific functions" function)
                 (const    :tag "All functions" t)
                 (function :tag "Custom filter function")))

(defcustom bufferlo-anywhere-filter-type 'exclude
  "Determines whether `bufferlo-anywhere-filter' is an include or exclude filter.
Set this to `include' or `exclude'."
  :package-version '(bufferlo . "0.8")
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
  :package-version '(bufferlo . "0.8")
  :type 'hook)

(defcustom bufferlo-bookmark-tab-handler-functions nil
  "Abnormal hooks to call after a bookmark tab is handled.
Each function takes the following arguments:
  bookmark-name: source bookmark name
  effective-bookmark-name: nil, if tab bookmark cleared
  tab: the handled tab
  restored-buffer-names: list of restored buffer names
  skipped-buffer-names: list of skipped buffer names"
  :package-version '(bufferlo . "1.1")
  :type 'hook)

(defcustom bufferlo-bookmark-frame-handler-functions nil
  "Abnormal hooks to call after a bookmark frame is handled.
Each function takes the following arguments:
  bookmark-name: source bookmark name
  effective-bookmark-name: nil, if frame bookmark cleared
  new-frame-p: t if this is a new frame, nil if a reused frame
  frame: the handled frame"
  :package-version '(bufferlo . "1.1")
  :type 'hook)

(defcustom bufferlo-bookmark-set-handler-functions nil
  "Abnormal hooks to call after a bookmark set is handled.
Each function takes the following arguments:
  bookmark-name: source bookmark name
  set-bookmark-names: bookmark names handled"
  :package-version '(bufferlo . "1.1")
  :type 'hook)

(defvar bufferlo--desktop-advice-active nil)
(defvar bufferlo--desktop-advice-active-force nil)

(defvar bufferlo--clear-buffer-lists-active nil)

(defvar bufferlo--bookmarks-auto-save-timer nil
  "Timer to save bufferlo bookmarks.
This is controlled by `bufferlo-bookmarks-auto-save-interval'.")

(defun bufferlo--bookmarks-auto-save-timer-maybe-cancel ()
  "Cancel and clear the bufferlo bookmark auto-save timer, if set."
  (when (timerp bufferlo--bookmarks-auto-save-timer)
    (cancel-timer bufferlo--bookmarks-auto-save-timer))
  (setq bufferlo--bookmarks-auto-save-timer nil))

(defvar bufferlo-bookmarks-auto-save-interval) ; byte compiler
(defun bufferlo--bookmarks-auto-save-timer-maybe-start ()
  "Start the bufferlo auto-save bookmarks timer, if needed."
  (bufferlo--bookmarks-auto-save-timer-maybe-cancel)
  (when (and (integerp bufferlo-bookmarks-auto-save-interval)
             (> bufferlo-bookmarks-auto-save-interval 0))
    (setq bufferlo--bookmarks-auto-save-timer
          (run-with-timer
           bufferlo-bookmarks-auto-save-interval
           nil ; We reschedule in `bufferlo-bookmarks-save'.
           #'bufferlo-bookmarks-save))))

(defcustom bufferlo-bookmarks-auto-save-interval 0
  "Save bufferlo bookmarks every interval of this many seconds.
Set to 0 to disable the timer.  Units are whole integer seconds."
  :package-version '(bufferlo . "1.1")
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
  :package-version '(bufferlo . "1.1")
  :type '(radio (const :tag "None" nil)
                (const :tag "All" t)
                (const :tag "Saved only" saved)
                (const :tag "Not-saved only" notsaved)))

(defcustom bufferlo-set-restore-geometry-policy 'all
  "Bufferlo frame restoration geometry policy.
This affects frame bookmarks inside a bookmark set.

\\='all restores both frame and tab bookmark frame geometries.

\\='frames restores only frame bookmark geometry.

\\='tab-frame restores only tab bookmark logical frame geometry."
  :package-version '(bufferlo . "1.1")
  :type '(radio (const :tag "All" all)
                (const :tag "Frames" frames)
                (const :tag "Tabs" tab-frames)))

(defcustom bufferlo-set-restore-tabs-reuse-init-frame nil
  "Restore first tabs from a bookmark set's frame to the current frame.
This affects the first frame of tab bookmarks from a bookmark set.
Subsequent frames of tab bookmarks are restored to their own frames."
  :package-version '(bufferlo . "1.1")
  :type '(radio (const :tag "Reuse" reuse)
                (const :tag "Reuse & reset geometry" reuse-reset-geometry)
                (const :tag "New frame" nil)))

(defcustom bufferlo-set-restore-ignore-already-active nil
  "Ignore already active bookmarks when restoring a bookmark set.
\\='prompt offers to bulk ignore loading active bookmarks
\\='ignore always ignores loading active bookmarks
\\='nil means default to potential duplicate bookmark policies"
  :package-version '(bufferlo . "1.1")
  :type '(radio (const :tag "Prompt" prompt)
                (const :tag "Ignore" ignore)
                (const :tag "Default duplicate policies" nil)))

(defcustom bufferlo-frameset-restore-geometry 'bufferlo
  "Frameset restore geometry handling control.

\\='native uses Emacs built-in geometry handling.

\\='bufferlo uses bufferlo's geometry handling.

Set to nil to ignore geometry handling."
  :package-version '(bufferlo . "1.1")
  :type '(radio (const :tag "Emacs" native)
                (const :tag "Bufferlo" bufferlo)
                (const :tag "Ignore" nil)))

(defcustom bufferlo-frameset-save-filter nil
  "Extra Emacs frame parameters to filter before saving a `frameset'.
Use this if you define custom frame parameters, or you use
packages that do, and you want to avoid storing such parameters
in bufferlo framesets."
  :package-version '(bufferlo . "1.1")
  :type '(repeat symbol))

(defcustom bufferlo-frameset-restore-filter nil
  "Extra Emacs frame parameters to filter before restoring a `frameset'.
Use this if you define custom frame parameters, or you use
packages that do, and you want to ensure they are filtered in
advance of restoring bufferlo framesets."
  :package-version '(bufferlo . "1.1")
  :type '(repeat symbol))

(defcustom bufferlo-frameset-restore-function
  #'bufferlo-frameset-restore-default
  "Function to restore a frameset, which see `frameset-restore'.
It defaults to `bufferlo-frameset-restore-default'.

The function accepts a single parameter, the `frameset' to restore."
  :package-version '(bufferlo . "1.1")
  :type 'function)

(defcustom bufferlo-frameset-restore-parameters-function
  #'bufferlo-frameset-restore-parameters-default
  "Function to create parameters for `frameset-restore', which see.

The function should create a plist of the form:

  (list :reuse-frames value
        :force-display value
        :force-onscreen value
        :cleanup-frames value)

where each property is as documented by `frameset-restore'.

It defaults to `bufferlo-frameset-restore-parameters-default'."
  :package-version '(bufferlo . "1.1")
  :type 'function)

(defcustom bufferlo-frame-geometry-function
  #'bufferlo-frame-geometry-default
  "Function to produce a bufferlo-frame-geometry alist.
It defaults to `bufferlo-frame-geometry-default'.

The function takes one parameter, FRAME, for which geometry is to
be ascertained.  See `bufferlo-frame-geometry-default' for
the returned alist form.

Replace this function with your own if the default produces
suboptimal results for your platform."
  :package-version '(bufferlo . "1.1")
  :type 'function)

(defcustom bufferlo-set-frame-geometry-function
  #'bufferlo-set-frame-geometry-default
  "Function to set frame geometry based on bufferlo-frame-geometry alist.
It defaults to `bufferlo-set-frame-geometry-default', which see for
parameters.

Replace this function with your own if the default produces
suboptimal results for your platform."
  :package-version '(bufferlo . "1.1")
  :type 'function)

(defcustom bufferlo-frame-sleep-for 0
  "Window manager catch-up delay for changing frame parameters.
Delay is specified in seconds using `sleep-for', which see.
GTK/GNOME seems to need 0.3 seconds.  YMMV.
No delay seems needed on macOS."
  :package-version '(bufferlo . "1.1")
  :type 'natnum)

(defcustom bufferlo-mode-line-prefix "Bfl"
  "Bufferlo mode-line prefix."
  :package-version '(bufferlo . "1.1")
  :type 'string)

(defcustom bufferlo-mode-line-left-prefix "["
  "Bufferlo mode-line left-hand prefix for an active tab/frame/set bookmark."
  :package-version '(bufferlo . "1.1")
  :type 'string)

(defcustom bufferlo-mode-line-right-suffix "]"
  "Bufferlo mode-line right-hand prefix for an active tab/frame/set bookmark."
  :package-version '(bufferlo . "1.1")
  :type 'string)

(defcustom bufferlo-mode-line-frame-prefix "F:"
  "Bufferlo mode-line frame prefix."
  :package-version '(bufferlo . "1.1")
  :type 'string)

(defcustom bufferlo-mode-line-tab-prefix "T:"
  "Bufferlo mode-line tab prefix."
  :package-version '(bufferlo . "1.1")
  :type 'string)

(defcustom bufferlo-mode-line-set-active-prefix "S"
  "Bufferlo mode-line frame prefix."
  :package-version '(bufferlo . "1.1")
  :type 'string)

(defcustom bufferlo-mode-line-delimiter "|"
  "Delimiter between multiple bookmarks."
  :package-version '(bufferlo . "1.1")
  :type 'string)

(defvar bufferlo-mode) ; byte compiler
(defvar bufferlo-mode-line-menu) ; byte compiler

(defun bufferlo--mode-line-format-helper (abm str face)
  "Bufferlo mode-line helper to add face and mouse features.
Where ABM is the current active bookmark, STR is the mode-line
string, FACE is the face for STR."
  (propertize
   str 'face face
   'mouse-face 'mode-line-highlight
   'help-echo (lambda (&rest _)
                (concat
                 (unless (equal abm "")
                   (format "Active bufferlo bookmark: %s\n" abm))
                 "mouse-1: Display minor mode menu\n"
                 "mouse-2: Show help for minor mode"))
   'keymap (let ((map (make-sparse-keymap)))
             (define-key map [mode-line down-mouse-1]
                         bufferlo-mode-line-menu)
             (define-key map [mode-line down-mouse-3]
                         bufferlo-mode-line-menu)
             (define-key map [mode-line mouse-2]
                         (lambda ()
                           (interactive)
                           (describe-function 'bufferlo-mode)))
             map)))

(defvar bufferlo--active-sets) ; byte compiler

(defun bufferlo-mode-line-format ()
  "Bufferlo mode-line format to display the current active frame or tab bookmark."
  (when bufferlo-mode
    (let* ((fbm (frame-parameter nil 'bufferlo-bookmark-frame-name))
           (tbm (alist-get 'bufferlo-bookmark-tab-name
                           (tab-bar--current-tab-find
                            (frame-parameter nil 'tabs))))
           (set-active (> (length bufferlo--active-sets) 0))
           (cache (window-parameter nil 'bufferlo--mode-line-cache)))
      (if (equal (cdr cache) (list fbm tbm set-active))
          (car cache)
        (let* ((abm (concat (when fbm (format "%s (Frame)" fbm))
                            (when (and fbm tbm) ", ")
                            (when tbm (format "%s (Tab)" tbm))))
               (str (concat
                     (bufferlo--mode-line-format-helper
                      abm bufferlo-mode-line-prefix 'bufferlo-mode-line-face)
                     (when (and bufferlo-mode-line-left-prefix
                                (or set-active fbm tbm))
                       (bufferlo--mode-line-format-helper
                        abm
                        bufferlo-mode-line-left-prefix
                        'bufferlo-mode-line-face))
                     (when set-active
                       (bufferlo--mode-line-format-helper
                        abm
                        (concat bufferlo-mode-line-set-active-prefix
                                (when (or fbm tbm) bufferlo-mode-line-delimiter))
                        'bufferlo-mode-line-set-face))
                     (when fbm
                       (bufferlo--mode-line-format-helper
                        abm
                        (concat bufferlo-mode-line-frame-prefix
                                fbm
                                (when tbm bufferlo-mode-line-delimiter))
                        'bufferlo-mode-line-frame-bookmark-face))
                     (when tbm
                       (bufferlo--mode-line-format-helper
                        abm
                        (concat bufferlo-mode-line-tab-prefix tbm)
                        'bufferlo-mode-line-tab-bookmark-face))
                     (when (and bufferlo-mode-line-right-suffix
                                (or set-active fbm tbm))
                       (bufferlo--mode-line-format-helper
                        abm
                        bufferlo-mode-line-right-suffix
                        'bufferlo-mode-line-face))))
               (str (if (string-empty-p str) "" (concat " " str))))
          (set-window-parameter nil 'bufferlo--mode-line-cache
                                (list str fbm tbm set-active))
          str)))))

(defvar bufferlo-mode-line)

(defun bufferlo--reset-mode-line ()
  "Remove the current bufferlo mode line entry."
  (setq mode-line-misc-info (delq (assq 'bufferlo-mode mode-line-misc-info)
                                  mode-line-misc-info)))

(defun bufferlo--set-mode-line ()
  "Set the current bufferlo mode line entry."
  (setq mode-line-misc-info (cons (list 'bufferlo-mode bufferlo-mode-line)
                                  mode-line-misc-info)))

(defcustom bufferlo-mode-line '(:eval (bufferlo-mode-line-format))
  "Bufferlo mode line definition."
  :package-version '(bufferlo . "1.1")
  :type 'sexp
  :set (lambda (variable value)
         (bufferlo--reset-mode-line) ; do before we overwrite the value
         (set-default variable value)
         (bufferlo--set-mode-line))
  :initialize #'custom-initialize-default
  :risky t)

(defgroup bufferlo-faces nil
  "Faces used in `bufferlo-mode'."
  :package-version '(bufferlo . "1.1")
  :group 'bufferlo
  :group 'faces)

(defface bufferlo-mode-line-face nil
  "`bufferlo-mode' mode-line base face."
  :package-version '(bufferlo . "1.1"))

(defface bufferlo-mode-line-frame-bookmark-face
  '((t :inherit bufferlo-mode-line-face))
  "`bufferlo-mode' mode-line frame bookmark indicator face."
  :package-version '(bufferlo . "1.1"))

(defface bufferlo-mode-line-tab-bookmark-face
  '((t :inherit bufferlo-mode-line-face))
  "`bufferlo-mode' mode-line tab bookmark indicator face."
  :package-version '(bufferlo . "1.1"))

(defface bufferlo-mode-line-set-face
  '((t :inherit bufferlo-mode-line-face))
  "`bufferlo-mode' mode-line bookmark-set active indicator face."
  :package-version '(bufferlo . "1.1"))

(defconst bufferlo--command-line-noload-prefix "--bufferlo-noload")
(defvar bufferlo--command-line-noload nil)

(defun bufferlo--parse-command-line ()
  "Process bufferlo Emacs command-line arguments."
  (when-let* ((pos (seq-position command-line-args
                                 bufferlo--command-line-noload-prefix
                                 #'string-equal)))
    (setq bufferlo--command-line-noload pos)
    (setq command-line-args (seq-remove-at-position command-line-args pos)))
  (when (file-exists-p (expand-file-name "bufferlo-noload" user-emacs-directory))
    (message "bufferlo-noload file found; inhibiting bufferlo bookmark loading")
    (setq bufferlo--command-line-noload t)))

(defun -bufferlo--parse-command-line-test ()
  "Internal test function for command-line processing."
  (let ((command-line-args (list "/usr/bin/emacs" "--name" "foobar"
                                 bufferlo--command-line-noload-prefix
                                 "-T" "title")))
    (setq bufferlo--command-line-noload nil)
    (message "command-line-args=%s" command-line-args)
    (message "bufferlo--command-line-noload=%s" bufferlo--command-line-noload)
    (bufferlo--parse-command-line)
    (message "bufferlo--command-line-noload=%s" bufferlo--command-line-noload)
    (message "command-line-args=%s" command-line-args)))

(defvar bufferlo-mode-map (make-sparse-keymap)
  "`bufferlo-mode' keymap.")

(defvar bufferlo--bookmark-handlers
  (list
   #'bufferlo--bookmark-tab-handler
   #'bufferlo--bookmark-frame-handler
   #'bufferlo--bookmark-set-handler)
  "Bufferlo bookmark handlers.")

(defconst bufferlo--bookmark-type-names
  '((tbm . "B-Tab")
    (fbm . "B-Frame")
    (sbm . "B-Set")))

;;;###autoload
(define-minor-mode bufferlo-mode
  "Manage frame/tab-local buffers."
  :global t
  :require 'bufferlo
  :init-value nil
  :lighter nil
  :keymap bufferlo-mode-map
  (bufferlo--reset-mode-line)
  (if bufferlo-mode
      (progn
        (unless after-init-time
          (bufferlo--parse-command-line)) ; parse user-provided settings first
        ;; Prefer local buffers
        (when bufferlo-prefer-local-buffers
          (dolist (frame (frame-list))
            (bufferlo--set-buffer-predicate frame))
          (add-hook 'after-make-frame-functions
                    #'bufferlo--set-buffer-predicate))
        (when (eq bufferlo-prefer-local-buffers 'tabs)
          (bufferlo--set-switch-to-prev-buffer-skip))
        ;; Include/exclude buffers
        (add-hook 'after-make-frame-functions
                  #'bufferlo--include-exclude-buffers)
        (add-hook 'tab-bar-tab-post-open-functions
                  #'bufferlo--tab-include-exclude-buffers)
        ;; Save/restore local buffer list
        (advice-add #'window-state-get :around #'bufferlo--window-state-get)
        (advice-add #'window-state-put :after #'bufferlo--window-state-put)
        ;; Desktop support
        (advice-add #'frameset--restore-frame :around #'bufferlo--activate)
        ;; Duplicate/move tabs
        (advice-add #'tab-bar-select-tab :around #'bufferlo--activate-force)
        ;; Clone & undelete frame
        (advice-add #'clone-frame :around
                    #'bufferlo--clone-undelete-frame-advice)
        (advice-add #'undelete-frame :around
                    #'bufferlo--clone-undelete-frame-advice)
        ;; Undo close tab duplicate check
        (if (< emacs-major-version 31)
            (advice-add #'tab-bar-undo-close-tab
                        :around #'bufferlo--tab-bar-undo-close-tab-advice)
          (add-hook 'tab-bar-post-undo-close-tab-functions
                    #'bufferlo--tab-post-undo-close-tab-function))
        ;; Switch-tab workaround
        (when (< emacs-major-version 31)
          (advice-add #'tab-bar-select-tab
                      :around #'bufferlo--clear-buffer-lists-activate)
          (advice-add #'tab-bar--tab
                      :after #'bufferlo--clear-buffer-lists))
        ;; Set up bookmarks save timer
        (bufferlo--bookmarks-auto-save-timer-maybe-start)
        ;; kill-emacs-hook save bookmarks option
        (when (not (eq bufferlo-bookmarks-save-at-emacs-exit 'nosave))
          (add-hook 'kill-emacs-hook #'bufferlo--bookmarks-save-at-emacs-exit))
        ;; load bookmarks at startup option
        (unless after-init-time
          (when (and (not bufferlo--command-line-noload)
                     (not (eq bufferlo-bookmarks-load-at-emacs-startup 'noload)))
            (add-hook 'window-setup-hook #'bufferlo--bookmarks-load-startup)))
        ;; Save bookmark on close-tab and delete-frame
        (add-hook 'tab-bar-tab-pre-close-functions
                  #'bufferlo-bookmark--tab-save-on-close)
        (add-hook 'delete-frame-functions
                  #'bufferlo-bookmark--frame-save-on-delete)
        ;; bookmark advice
        (advice-add #'bookmark--jump-via :around #'bufferlo--bookmark--jump-via-advice)
        (advice-add #'bookmark-rename :around #'bufferlo--bookmark-rename-advice)
        (advice-add #'bookmark-delete :around #'bufferlo--bookmark-delete-advice)
        ;; mode line
        (bufferlo--set-mode-line))
    ;; Prefer local buffers
    (dolist (frame (frame-list))
      (bufferlo--reset-buffer-predicate frame))
    (when (eq bufferlo-prefer-local-buffers 'tabs)
      (bufferlo--reset-switch-to-prev-buffer-skip))
    (remove-hook 'after-make-frame-functions #'bufferlo--set-buffer-predicate)
    ;; Include/exclude buffers
    (remove-hook 'after-make-frame-functions
                 #'bufferlo--include-exclude-buffers)
    (remove-hook 'tab-bar-tab-post-open-functions
                 #'bufferlo--tab-include-exclude-buffers)
    ;; Save/restore local buffer list
    (advice-remove #'window-state-get #'bufferlo--window-state-get)
    (advice-remove #'window-state-put #'bufferlo--window-state-put)
    ;; Desktop support
    (advice-remove #'frameset--restore-frame #'bufferlo--activate)
    ;; Duplicate/move tabs
    (advice-remove #'tab-bar-select-tab #'bufferlo--activate-force)
    ;; Clone & undelete frame
    (advice-remove #'clone-frame #'bufferlo--clone-undelete-frame-advice)
    (advice-remove #'undelete-frame #'bufferlo--clone-undelete-frame-advice)
    ;; Undo close tab duplicate check
    (if (< emacs-major-version 31)
        (advice-remove #'tab-bar-undo-close-tab
                       #'bufferlo--tab-bar-undo-close-tab-advice)
      (remove-hook 'tab-bar-post-undo-close-tab-functions
                   #'bufferlo--tab-post-undo-close-tab-function))
    ;; Switch-tab workaround
    (when (< emacs-major-version 31)
      (advice-remove #'tab-bar-select-tab #'bufferlo--clear-buffer-lists-activate)
      (advice-remove #'tab-bar--tab #'bufferlo--clear-buffer-lists))
    ;; Cancel bookmarks save timer
    (bufferlo--bookmarks-auto-save-timer-maybe-cancel)
    ;; kill-emacs-hook save bookmarks option
    (remove-hook 'kill-emacs-hook #'bufferlo--bookmarks-save-at-emacs-exit)
    ;; load bookmarks at startup option
    (remove-hook 'window-setup-hook #'bufferlo-bookmarks-load)
    ;; Save bookmark on close-tab and delete-frame
    (remove-hook 'tab-bar-tab-pre-close-functions
                 #'bufferlo-bookmark--tab-save-on-close)
    (remove-hook 'delete-frame-functions
                 #'bufferlo-bookmark--frame-save-on-delete)
    ;; bookmark advice
    (advice-remove #'bookmark--jump-via #'bufferlo--bookmark--jump-via-advice)
    (advice-remove #'bookmark-rename #'bufferlo--bookmark-rename-advice)
    (advice-remove #'bookmark-delete #'bufferlo--bookmark-delete-advice)))

(defun bufferlo--current-bookmark-name ()
  "Current bufferlo bookmark name, where frame beats tab."
  (if-let* ((fbm (frame-parameter nil 'bufferlo-bookmark-frame-name)))
      fbm
    (if-let* ((tbm (alist-get 'bufferlo-bookmark-tab-name
                              (cdr (bufferlo--current-tab)))))
        tbm
      nil)))

(defvar bufferlo-menu-item-raise
  '("Raise"
    :help "Raise an open bufferlo bookmark"
    :active (> (length (bufferlo--active-bookmarks)) 0)
    :filter (lambda (&optional _)
              (let* ((abms (bufferlo--active-bookmarks))
                     (abm-names (mapcar #'car abms))
                     (current-bm-name (bufferlo--current-bookmark-name)))
                (mapcar (lambda (abm-name)
                          (vector abm-name
                                  `(bufferlo--bookmark-raise-by-name ,abm-name)
                                  :style 'radio
                                  :selected (equal abm-name current-bm-name)))
                        abm-names)))))

(easy-menu-define bufferlo-mode-menu bufferlo-mode-map
  "`bufferlo-mode' menu."
  `("Bufferlo" :visible (and bufferlo-mode bufferlo-menu-bar-show)
    ["Buffer Management" :active nil]
    ["Local Buffers..."              bufferlo-list-buffers                   :help "Display a list of local buffers"              :visible (memq bufferlo-menu-bar-list-buffers '(both simple))]
    ["Orphan Buffers..."             bufferlo-list-orphan-buffers            :help "Display a list of orphan buffers"             :visible (memq bufferlo-menu-bar-list-buffers '(both simple))]
    ["Local Buffers (ibuffer)..."    bufferlo-ibuffer                        :help "Invoke `ibuffer' filtered for local buffers"  :visible (memq bufferlo-menu-bar-list-buffers '(both ibuffer))]
    ["Orphan Buffers (ibuffer)..."   bufferlo-ibuffer-orphans                :help "Invoke `ibuffer' filtered for orphan buffers" :visible (memq bufferlo-menu-bar-list-buffers '(both ibuffer))]
    ["Clear Buffer Locals"           bufferlo-clear                          :help "Clear the frame/tab's buffer list, except for the current buffer"]
    ["Remove Buffer from Locals..."  bufferlo-remove                         :help "Remove buffer from the frame/tab's buffer list"]
    ["Remove Non Exclusives"         bufferlo-remove-non-exclusive-buffers   :help "Remove all buffers from the local buffer list that are not exclusive to it"]
    ["Bury and Remove from Locals"   bufferlo-bury                           :help "Bury and remove the buffer specified by BUFFER-OR-NAME from the local list"]
    ["Kill Local Buffers..."         bufferlo-kill-buffers                   :help "Kill the buffers of the frame/tab-local buffer list"]
    ["Kill Orphan Buffers..."        bufferlo-kill-orphan-buffers            :help "Kill all buffers that are not in any local list of a frame or tab"]
    ("Find/Switch"
     ["Find..."                      bufferlo-find-buffer                    :help "Switch to the frame/tab containing buffer in its local list"]
     ["Find & Switch..."             bufferlo-find-buffer-switch             :help "Switch to the frame/tab containing buffer and select the buffer"]
     ["Display..."                   bufferlo-switch-to-buffer               :help "Display the selected buffer in the selected window"]
     )
    ("*scratch*"
     ["*scratch*..."                 bufferlo-switch-to-scratch-buffer       :help "Switch to the scratch buffer"]
     ["Local *scratch*..."           bufferlo-switch-to-local-scratch-buffer :help "Switch to the local scratch buffer"]
     ["Toggle *scratch*..."          bufferlo-toggle-local-scratch-buffer    :help "Switch to the local scratch buffer or bury it if it is already selected"]
     )
    ["Isolate Project"               bufferlo-isolate-project                :help "Isolate a project in the frame or tab" :active (project-current)]
    "--"
    ["Bookmarks" :active nil]
    ["Load..."                 bufferlo-bms-load                    :help "Load specified bookmarks"]
    ["Save..."                 bufferlo-bms-save                    :help "Save specified bookmarks"]
    ["Close/Kill..."           bufferlo-bms-close                   :help "Close/kill specified bookmarks"]
    ["Save Current"            bufferlo-bm-save                     :help "Save the current tab bookmark"]
    ["Reload Current"          bufferlo-bm-load                     :help "Reload a tab bookmark replacing existing state"]
    ["Close/Kill Current..."   bufferlo-bm-close                    :help "Close the current tab bookmark and kill its buffers"]
    ["Raise..."                bufferlo-bookmark-raise              :help "Raise an active bufferlo bookmark"]
    ,bufferlo-menu-item-raise ; sub-menu of actives to select that also lives in the mode line
    ["Clear Actives..."        bufferlo-clear-active-bookmarks      :help "Clear active bookmarks"]
    ["Clear Active (if duped)" bufferlo-maybe-clear-active-bookmark :help "Clear active bookmark if already in use elsewhere"]
    "--"
    ;; ["Tab Bookmarks" :active nil]
    ("Tab Bookmarks"
     ["Create..."           bufferlo-bm-tab-save         :help "Create a new tab bookmark"]
     ["Load..."             bufferlo-bm-tab-load         :help "Load a tab bookmark"]
     ["Save Current"        bufferlo-bm-tab-save-curr    :help "Save the current tab bookmark"]
     ["Reload Current"      bufferlo-bm-tab-load-curr    :help "Reload a tab bookmark replacing existing state"]
     ["Close/Kill Current"  bufferlo-bm-tab-close-curr   :help "Close the current tab bookmark and kill its buffers"]
     )
    ;; "--"
    ;; ["Frame Bookmarks" :active nil]
    ("Frame Bookmarks"
     ["Create..."           bufferlo-bm-frame-save       :help "Create a new frame bookmark"]
     ["Load..."             bufferlo-bm-frame-load       :help "Load a frame bookmark"]
     ["Merge..."            bufferlo-bm-frame-load-merge :help "Merge a frame bookmark tabs into the current frame"]
     ["Save Current"        bufferlo-bm-frame-save-curr  :help "Save the current frame bookmark"]
     ["Reload Current"      bufferlo-bm-frame-load-curr  :help "Reload a frame bookmark replacing existing state"]
     ["Close/Kill Current"  bufferlo-bm-frame-close-curr :help "Close the current frame bookmark and kill its buffers"]
     )
    ;; "--"
    ;; ["Bookmark Sets" :active nil]
    ("Bookmark Sets"
     ["Create..."           bufferlo-set-save            :help "Create a new bookmark set"]
     ["Load..."             bufferlo-set-load            :help "Load a bookmark set"]
     ["Save Current..."     bufferlo-set-save-curr       :help "Save the specified bookmark sets"]
     ["Add..."              bufferlo-set-add             :help "Add bookmark(s) to a set"]
     ["Remove..."           bufferlo-set-remove          :help "Remove bookmark(s) from a set"]
     ["Close/Kill..."       bufferlo-set-close           :help "Close the specified bookmark sets (kills frames, tabs, buffers)"]
     ["Clear..."            bufferlo-set-clear           :help "Clear the specified bookmark set (does not kill frames, tabs, buffers)"]
     ["List..."             bufferlo-set-list            :help "List the bookmarks in specified active bookmark sets"]
     )
    ;; "--"
    ;; ["Bookmark Management" :active nil]
    ("Bookmark Management"
     ["Emacs Bookmarks..." bookmark-bmenu-list :help "Emacs bookmarks"]
     ["Rename Bookmark..." (lambda ()
                             (interactive)
                             (let ((last-nonmenu-event "")) ; (listp nil) returns t so we hack it to be nil
                               (call-interactively #'bookmark-rename)))
      :help "Rename a bookmark"]
     ["Delete Bookmark..." (lambda ()
                             (interactive)
                             (let ((last-nonmenu-event "")) ; (listp nil) returns t so we hack it to be nil
                               (call-interactively #'bookmark-delete)))
      :help "Delete a bookmark"]
     )
    "--"
    ;; customize
    ["Customize Bufferlo" (lambda () (interactive) (customize-group "bufferlo"))]))

(easy-menu-define bufferlo-mode-line-menu nil
  "`bufferlo-mode' mode-line menu."
  `("Bufferlo"
    ,bufferlo-menu-item-raise))

;; NOTE: Undocumented in `make-frame' that the current buffer cannot be
;; conventionally hidden (space as first character). `with-temp-buffer'
;; doesn't work either in this context (for the same reason).
;; TODO: In Emacs 31, bind expose-hidden-buffer t to allow hidden buffers.
(defmacro bufferlo--with-temp-buffer (&rest body)
  "Execute BODY with \"*bufferlo temp buffer*\" current buffer."
  (let ((buff-name (generate-new-buffer-name "*bufferlo temp buffer*")))
    (with-current-buffer (get-buffer-create buff-name t)
      (unwind-protect
          `(progn ,@body)
        (kill-buffer buff-name)))))

(defun bufferlo--make-frame (&optional restore-geometry)
  "Make a new frame with `fullscreen' suppressed if RESTORE-GEOMETRY is non nil."
  (make-frame (if restore-geometry '((fullscreen . nil)) nil)))

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

(defun bufferlo-local-buffers ()
  "Return a list of local buffers for the current frame."
  (seq-filter #'bufferlo-local-buffer-p
              (buffer-list)))

(defun bufferlo-non-local-buffers ()
  "Return a list of non-local buffers for the current frame."
  (seq-filter #'bufferlo-non-local-buffer-p
              (buffer-list)))

(defun bufferlo--clear-buffer-lists (&optional frame)
  "This is a workaround advice function to fix tab-bar's tab switching behavior.
On `tab-bar-select-tab', if `wc-bl' or `wc-bbl' is nil, the function does not
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
  (when (eq (frame-parameter frame 'buffer-predicate)
            #'bufferlo--buffer-predicate)
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
  (unless (eq tab-bar-new-tab-choice 'clone)
    (bufferlo--include-exclude-buffers nil)))

(defun bufferlo--current-buffers (frame)
  "Get the buffers of the current tab in FRAME."
  (seq-filter
   #'buffer-live-p
   (if bufferlo-include-buried-buffers
       (append
        (frame-parameter frame 'buffer-list)
        (frame-parameter frame 'buried-buffer-list))
     (frame-parameter frame 'buffer-list))))

(defun bufferlo--get-tab-buffers (tab)
  "Extract buffers from the given TAB structure."
  (seq-filter
   #'buffer-live-p
   (or
    (if bufferlo-include-buried-buffers
        (append
         (cdr (assq 'wc-bl tab))
         (cdr (assq 'wc-bbl tab)))
      (cdr (assq 'wc-bl tab)))
    ;; fallback to bufferlo-buffer-list, managed by bufferlo--window-state-*
    (mapcar #'get-buffer
            (car (cdr (assq 'bufferlo-buffer-list (assq 'ws tab))))))))

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
        list
      (seq-filter (lambda (buffer)
                    (let ((hidden (bufferlo--merge-regexp-list
                                   (append '("a^") bufferlo-hidden-buffers))))
                      (not (string-match-p hidden (buffer-name buffer)))))
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
  "Activate the advice for `clone-frame' and `undelete-frame'.
OLDFN is the original function.  ARGS is for compatibility with the
advised functions.  Honors `bufferlo-bookmark-frame-duplicate-policy'."
  (let ((bufferlo--desktop-advice-active t)
        (bufferlo--desktop-advice-active-force t))
    (apply oldfn args))
  (when-let* ((bookmark-name (frame-parameter nil 'bufferlo-bookmark-frame-name))
              (abm (assoc bookmark-name (bufferlo--active-bookmarks)))
              (this+at-least-one-other
               (> (seq-count (lambda (x) (equal bookmark-name (car x)))
                             (bufferlo--active-bookmarks))
                  1)))
    (let ((msg nil))
      (cl-labels
          ((msg-append (s) (setq msg (concat msg "; " s))))
        (when
            (catch :abort
              ;; `bufferlo--bookmark-get-duplicate-policy' throws :abort
              (let ((duplicate-policy (bufferlo--bookmark-get-duplicate-policy
                                       bookmark-name
                                       "frame"
                                       bufferlo-bookmark-frame-duplicate-policy
                                       'undelete)))
                (pcase duplicate-policy
                  ('allow)
                  ('clear
                   (setq bookmark-name nil))
                  ('clear-warn
                   (setq bookmark-name nil)
                   (msg-append "cleared frame bookmark"))
                  ('ignore
                   (throw :abort t))
                  ('raise
                   ;; NOTE: We throw nil here!
                   ;; We delete the frame ourselves before raising.
                   (delete-frame)
                   (bufferlo--bookmark-raise abm)
                   (throw :abort nil)))
                (set-frame-parameter nil 'bufferlo-bookmark-frame-name
                                     bookmark-name))
              (when msg
                (message "Undelete frame bufferlo bookmark%s%s"
                         (if bookmark-name (format ": %s" bookmark-name) "")
                         (or msg "")))
              nil)
          (delete-frame))))))

(defun bufferlo--tab-post-undo-close-tab-function (tab)
  "Handle `tab-bar-undo-close-tab' TAB.
Honors `bufferlo-bookmark-tab-duplicate-policy'."
  (when-let* ((bookmark-name (alist-get 'bufferlo-bookmark-tab-name tab))
              (this+at-least-one-other
               (> (seq-count (lambda (x) (equal bookmark-name (car x)))
                             (bufferlo--active-bookmarks))
                  1)))
    (let ((msg nil))
      (cl-labels
          ((msg-append (s) (setq msg (concat msg "; " s))))
        (when
            (catch :abort
              (let ((duplicate-policy (bufferlo--bookmark-get-duplicate-policy
                                       bookmark-name "tab"
                                       bufferlo-bookmark-tab-duplicate-policy
                                       'undelete)))
                (pcase duplicate-policy
                  ('allow)
                  ('clear
                   (setq bookmark-name nil))
                  ('clear-warn
                   (setq bookmark-name nil)
                   (msg-append "cleared tab bookmark"))
                  ('ignore
                   (throw :abort t))
                  ('raise
                   ;; NOTE: We throw nil here!
                   ;; We delete the frame ourselves before raising.
                   (let (tab-bar-tab-prevent-close-functions)
                     (tab-bar-close-tab))
                   ;; Find bookmark to raise; tab numbers changes when closing.
                   (bufferlo--bookmark-raise
                    (assoc bookmark-name (bufferlo--active-bookmarks)))
                   (throw :abort nil)))
                (setf (alist-get 'bufferlo-bookmark-tab-name
                                 (cdr tab))
                      bookmark-name))
              (when msg
                (message "Undo close tab bufferlo bookmark%s%s"
                         (if bookmark-name (format ": %s" bookmark-name) "")
                         (or msg "")))
              nil)
          (let (tab-bar-tab-prevent-close-functions)
            (tab-bar-close-tab)))))))

(defun bufferlo--tab-bar-undo-close-tab-advice (oldfn &rest args)
  "Activate the advice for `tab-bar-undo-close-tab'.
Pass ARGS to OLDFN."
  (let ((bufferlo--desktop-advice-active t)
        (bufferlo--desktop-advice-active-force t))
    (apply oldfn args))
  (bufferlo--tab-post-undo-close-tab-function (bufferlo--current-tab)))

(defsubst bufferlo--warn ()
  "Warn if `bufferlo-mode' is not enabled."
  (defvar bufferlo--warn-current-command nil)
  (when (and (not bufferlo-mode)
             (not (eq this-command bufferlo--warn-current-command)))
    (setq bufferlo--warn-current-command this-command)
    (message (format "Warning: %s: bufferlo-mode should be enabled"
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
  (let ((exclude-tab (when (and exclude-tabnum (not (eq exclude-tabnum 'all)))
                       (nth exclude-tabnum
                            (funcall tab-bar-tabs-function exclude-frame)))))
    (cl-labels
        ((get-inactive-tabs-buffers (f)
           (seq-mapcat
            (lambda (tb)
              (unless (and (eq f exclude-frame)
                           (or (eq exclude-tabnum 'all)
                               (eq tb exclude-tab)))
                (bufferlo--get-tab-buffers tb)))
            (funcall tab-bar-tabs-function f)))
         (get-frames-buffers ()
           (seq-mapcat
            (lambda (f)
              (unless (and (eq f exclude-frame)
                           (or (eq exclude-tabnum 'all)
                               (not exclude-tab)
                               (eq 'current-tab (car exclude-tab))))
                (bufferlo--current-buffers f)))
            (frame-list))))
      (seq-uniq
       (append (seq-mapcat #'get-inactive-tabs-buffers (frame-list))
               (get-frames-buffers))))))

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

(defvar bufferlo--kill-buffer-frame-or-tab-closing nil
  "Bind to non-nil when closing frame/tab and calling bufferlo kill buffers.")

(defun bufferlo--kill-buffer-safely (buffer)
  "Kill BUFFER respecting that `replace-buffer-in-windows' might kill the frame."
  ;; bug#71386
  ;; These shenanigans are needed because `kill-buffer' calls
  ;; `replace-buffer-in-windows' which, without regard to other
  ;; tabs on the frame that contain "potential windows" in their
  ;; window configurations... "If that window is the only window
  ;; on its frame, delete its frame when there are other frames
  ;; left [on the terminal]."  What it should do when a tab is
  ;; active, is either leave a placeholder buffer, or close the
  ;; tab and signal that it did either of those things.
  ;;
  ;; "In any other case, `replace-buffer-in-windows' calls
  ;; `switch-to-prev-buffer' to display some other buffer in that
  ;; window."  If a bufferlo-managed tab has only a single buffer
  ;; and no `window-prev-buffers', we concoct one to retain the
  ;; window before closing the tab.
  (let ((frame-auto-hide-function) ; inhibit automatic frame deletion
        ;; No interference for buffer replacement selection
        (switch-to-prev-buffer-skip)
        (switch-to-prev-buffer-skip-regexp))
    (when (and (one-window-p 'no-mini)
               (eq (window-deletable-p) 'frame))
      ;; If this is the final window on the frame, and the frame would be
      ;; deleted by kill-buffer / replace-buffer-in-windows, leave one live
      ;; buffer to prevent the frame being killed.  The bufferlo calling
      ;; functions that close tabs and frames will handle tab/frame closing.
      (switch-to-buffer " *bufferlo temp*" 'norecord 'force-same-window)
      ;; This prevents the hidden buffer from visually leaking when the
      ;; calling bufferlo function is not intending to close the tab or frame.
      (unless bufferlo--kill-buffer-frame-or-tab-closing
        (switch-to-prev-buffer)))
    (kill-buffer buffer)))

(defun bufferlo--kill-buffer-forced (buffer)
  "Forcibly kill BUFFER, even if modified."
  (let ((kill-buffer-query-functions nil))
    (with-current-buffer buffer
      (set-buffer-modified-p nil)
      (bufferlo--kill-buffer-safely buffer))))

(defun bufferlo--kill-buffer (buffer)
  "Kill BUFFER respecting `bufferlo-kill-modified-buffers-policy'."
  (condition-case-unless-debug err
      (pcase bufferlo-kill-modified-buffers-policy
        ('retain-modified
         (unless (buffer-modified-p buffer)
           (bufferlo--kill-buffer-safely buffer)))
        ('retain-modified-kill-without-file-name
         (if (not (buffer-file-name buffer))
             (bufferlo--kill-buffer-forced buffer)
           (unless (buffer-modified-p buffer)
             ;; No prompting (these are unmodified buffers)
             (let ((kill-buffer-query-functions))
               (bufferlo--kill-buffer-safely buffer)))))
        ('kill-modified
         (bufferlo--kill-buffer-forced buffer))
        (_ (bufferlo--kill-buffer-safely buffer)))
    (error (message "Bufferlo could not kill buffer `%s': %S"
                    (buffer-name buffer) (error-message-string err)))))

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
  (when (or (not bufferlo-kill-buffers-prompt)
            (y-or-n-p "Kill bufferlo local buffers? "))
    (let* ((exclude (bufferlo--merge-regexp-list
                     (append '("a^") bufferlo-kill-buffers-exclude-filters)))
           (kill-list (if killall
                          (bufferlo--get-buffers frame tabnum)
                        (bufferlo--get-exclusive-buffers frame tabnum)))
           (buffers (seq-filter
                     (lambda (b)
                       (not (or
                             (and (not internal-too)
                                  (string-prefix-p " " (buffer-name b)))
                             (string-match-p exclude (buffer-name b)))))
                     kill-list)))
      (dolist (b buffers)
        (bufferlo--kill-buffer b)))))

(defun bufferlo-kill-orphan-buffers (&optional internal-too)
  "Kill all buffers that are not in any local list of a frame or tab.
Ignores buffers whose names start with a space, unless optional
argument INTERNAL-TOO is non-nil.
Buffers matching `bufferlo-kill-buffers-exclude-filters' are never killed."
  (interactive)
  (bufferlo--warn)
  (when (or (not bufferlo-kill-buffers-prompt)
            (y-or-n-p "Kill bufferlo local buffers? "))
    (let* ((exclude (bufferlo--merge-regexp-list
                     (append '("a^") bufferlo-kill-buffers-exclude-filters)))
           (buffers (seq-filter
                     (lambda (b)
                       (not (or
                             (and (not internal-too)
                                  (string-prefix-p " " (buffer-name b)))
                             (string-match-p exclude (buffer-name b)))))
                     (bufferlo--get-orphan-buffers))))
      (dolist (b buffers)
        (bufferlo--kill-buffer b)))))

(defun bufferlo-delete-frame-kill-buffers (&optional frame internal-too)
  "Delete a frame and kill the local buffers of its tabs.
If FRAME is nil, kill the current frame.
Ignores buffers whose names start with a space, unless optional
argument INTERNAL-TOO is non-nil."
  (interactive)
  (bufferlo--warn)
  (setq frame (or frame (selected-frame)))
  (when (or (not bufferlo-delete-frame-kill-buffers-prompt)
            (y-or-n-p "Kill frame and its buffers? "))
    (let ((fbm (frame-parameter frame 'bufferlo-bookmark-frame-name)))
      (cl-labels
          ((save-as-current (frame)
             ;; We need this if called in a batch
             (with-selected-frame frame
               (bufferlo-bookmark-frame-save-current))))
        (pcase bufferlo-bookmark-frame-save-on-delete
          ((or 't 'on-kill-buffers)
           (when (y-or-n-p (format-message "Save frame bookmark `%s'? " fbm))
             (save-as-current frame)))
          ((or 'when-bookmarked 'on-kill-buffers-when-bookmarked)
           (when fbm (save-as-current frame))))
        ;; If batch, raise frame in case of prompts for buffers that need saving.
        (raise-frame frame)
        (let ((bufferlo-kill-buffers-prompt nil)
              (bufferlo--kill-buffer-frame-or-tab-closing t))
          (bufferlo-kill-buffers nil frame 'all internal-too))
        ;; kill-buffer calls replace-buffer-in-windows which will
        ;; delete windows *and* their frame so we have to test if
        ;; the frame in question is still live.
        (when (frame-live-p frame)
          ;; TODO: Emacs 30 frame-deletable-p
          ;; account for top-level, non-child frames
          (when (= 1 (length (seq-filter
                              (lambda (x) (null (frame-parameter x 'parent-frame)))
                              (frame-list))))
            (make-frame)) ; leave one for the user
          (let ((bufferlo-bookmark-frame-save-on-delete nil))
            (delete-frame frame)))))))

(defun bufferlo-tab-close-kill-buffers (&optional killall internal-too)
  "Close the current tab and kill the local buffers.
The optional arguments KILLALL and INTERNAL-TOO are passed to
`bufferlo-kill-buffers'."
  (interactive "P")
  (bufferlo--warn)
  (when (or (not bufferlo-close-tab-kill-buffers-prompt)
            (y-or-n-p "Kill tab and its buffers? "))
    (let* ((orig-frame (selected-frame))
           (orig-tab (bufferlo--current-tab))
           (tbm (alist-get 'bufferlo-bookmark-tab-name orig-tab))
           kill-buffer-closed-tab)
      (pcase bufferlo-bookmark-tab-save-on-close
        ((or 't 'on-kill-buffers)
         (when (y-or-n-p (format-message "Save tab bookmark `%s'? " tbm))
           (bufferlo-bookmark-tab-save-current)))
        ((or 'when-bookmarked 'on-kill-buffers-when-bookmarked)
         (when tbm (bufferlo-bookmark-tab-save tbm))))
      (let* ((bufferlo-kill-buffers-prompt nil)
             (bufferlo--kill-buffer-frame-or-tab-closing t)
             ;; Emacs 31 `window--delete' can call tab-bar-close-tab
             (tab-bar-tab-prevent-close-functions nil)
             (tab-bar-tab-pre-close-functions
              (list (lambda (_tab _last-tab-p)
                      (setq kill-buffer-closed-tab t)))))
        (bufferlo-kill-buffers killall nil nil internal-too))
      (let ((bufferlo-bookmark-tab-save-on-close nil)
            (tab-bar-close-last-tab-choice 'delete-frame))
        ;; Close the tab only if we can detect that it's hasn't been closed by
        ;; `'kill-buffer' (via `replace-buffer-in-windows',
        ;; `window-deletable-p', `window--delete').
        (unless (or kill-buffer-closed-tab
                    (not (eq orig-frame (selected-frame)))
                    (not (eq orig-tab (bufferlo--current-tab))))
          ;; Catch errors in case this is the last tab on the last frame
          (ignore-errors (tab-bar-close-tab)))))))

(defun bufferlo-isolate-project (&optional file-buffers-only)
  "Isolate a project in the frame or tab.
Remove all buffers that do not belong to the current project from the
local buffer list.  If FILE-BUFFERS-ONLY is non-nil or the prefix
argument is given, remove only buffers that visit a file.  Buffers
matching `bufferlo-include-buffer-filters' are not removed."
  (interactive "P")
  (bufferlo--warn)
  (if-let* ((curr-project (project-current))
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
  (let ((buffer (get-buffer buffer-or-name)))
    (cl-labels
        ((search-tabs (f)
           (let ((i 0))
             (mapcar
              (lambda (tab)
                (setq i (1+ i))
                (when (bufferlo-local-buffer-p buffer f (1- i) t)
                  (list f (frame-parameter f 'name)
                        (eq f (selected-frame))
                        i (cdr (assq 'name tab)))))
              (funcall tab-bar-tabs-function f))))
         (search-frames (f)
           (unless (frame-parameter f 'no-accept-focus)
             (if (funcall tab-bar-tabs-function f)
                 ;; has tabs
                 (search-tabs f)
               ;; has no tabs
               (when (bufferlo-local-buffer-p buffer f nil t)
                 (list (list f (frame-parameter f 'name)
                             (eq f (selected-frame))
                             nil nil)))))))
      (let* ((candidates (seq-filter #'identity
                                     (seq-mapcat #'search-frames (frame-list))))
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
                            nil 'require-match)
                         (caar candidates)))
             (selected (assoc selected candidates)))
        (if (not selected)
            (message "Orphan: No frame/tab contains buffer '%s'" (buffer-name buffer))
          (let ((frame (nth 1 selected))
                (tab-index (nth 4 selected)))
            (select-frame-set-input-focus frame)
            (when tab-index
              (tab-bar-select-tab tab-index))
            frame))))))

(defun bufferlo-find-buffer-switch (buffer-or-name)
  "Switch to the frame/tab containing BUFFER-OR-NAME and select the buffer.
This is like `bufferlo-find-buffer' but additionally selects the buffer.
If the buffer is already visible in a non-selected window, select it."
  (interactive "b")
  (bufferlo--warn)
  (when (bufferlo-find-buffer buffer-or-name)
    (if-let* ((w (seq-find
                  (lambda (w)
                    (eq (get-buffer buffer-or-name) (window-buffer w)))
                  (window-list))))
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
                    (generate-new-buffer-name
                     bufferlo-local-scratch-buffer-name)))
      (with-current-buffer buffer
        (when (eq major-mode 'fundamental-mode)
          (funcall (or bufferlo-local-scratch-buffer-initial-major-mode
                       initial-major-mode
                       #'ignore)))))
    buffer))

(defun bufferlo-create-local-scratch-buffer ()
  "Create a local scratch buffer and return it."
  (get-buffer-create (generate-new-buffer-name
                      bufferlo-local-scratch-buffer-name)))

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
          (name (or (seq-find
                     (lambda (b)
                       (string-match-p
                        "\\`\\*Bufferlo Local Buffer List\\*\\(<[0-9]*>\\)?\\'"
                        (buffer-name b)))
                     (bufferlo-buffer-list))
                    (generate-new-buffer-name "*Bufferlo Local Buffer List*")))
          (buffer (get-buffer-create name)))
     (with-current-buffer buffer
       (Buffer-menu-mode)
       (setq bufferlo--buffer-menu-this-frame (selected-frame))
       (setq Buffer-menu-files-only nil)
       (setq Buffer-menu-buffer-list #'bufferlo--local-buffer-list-this-frame)
       (setq Buffer-menu-filter-predicate nil)
       (list-buffers--refresh
        #'bufferlo--local-buffer-list-this-frame old-buffer)
       (tabulated-list-print)
       (revert-buffer))
     buffer)))

(defun bufferlo-list-orphan-buffers ()
  "Display a list of orphan buffers."
  (interactive)
  (bufferlo--warn)
  (display-buffer
   (let* ((old-buffer (current-buffer))
          (name "*Bufferlo Orphan Buffer List*")
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

(defmacro bufferlo--ibuffer-do-wrapper ()
  "Wrapper to support both <31 and 31+ `define-ibuffer-op macro'."
  (if (< emacs-major-version 31)
      '(define-ibuffer-op ibuffer-do-bufferlo-remove ()
         "Remove marked buffers from bufferlo's local buffer list."
         (
          :active-opstring "remove from bufferlo locals"
          :opstring "removed from bufferlo locals:"
          :modifier-p t
          :dangerous t
          :complex t
          :after (ibuffer-update nil t)
          )
         (when bufferlo-mode
           (bufferlo-remove buf)
           t))

    (defun bufferlo--ibuffer-do-bufferlo-remove-prompt (op)
      "`ibuffer' prompt helper for OP."
      (let ((bookmark-name (bufferlo--current-bookmark-name)))
        (format "%s from %slocals:" op
                (if bookmark-name
                    (format-message "bufferlo bookmark `%s' " bookmark-name)
                  ""))))

    '(define-ibuffer-op ibuffer-do-bufferlo-remove ()
       "Remove marked buffers from bufferlo's local buffer list."
       (
        :active-opstring (lambda () (bufferlo--ibuffer-do-bufferlo-remove-prompt "remove"))
        :opstring (lambda () (bufferlo--ibuffer-do-bufferlo-remove-prompt "removed"))
        :modifier-p t
        :dangerous t
        :complex t
        :after (ibuffer-update nil t)
        )
       (when bufferlo-mode
         (bufferlo-remove buf)
         t))
    ))
(bufferlo--ibuffer-do-wrapper)

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
the next command, if the mode is enabled."
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

(defun bufferlo--bookmark-get-bookmark (bookmark-name-or-record)
  "Guarded `bookmark-get-bookmark' for BOOKMARK-NAME-OR-RECORD.
`bookmark-get-bookmark' calls `error' which we want to trap.
Returns the bookmark record if succeeded, nil if failed."
  (ignore-errors
    (bookmark-get-bookmark bookmark-name-or-record)))

(defun bufferlo--bookmark-jump (bookmark)
  "Guarded `bookmark-jump' for BOOKMARK.
It prevents the insertion of a fringe mark and calls `bookmark-jump' with an
empty (no-op) display-func."
  (condition-case err
      (let ((bookmark-fringe-mark nil))
        (bookmark-jump bookmark #'ignore)
        t)
    (progn
      (message (delay-warning 'bufferlo
                              (format "Error %S when jumping to bookmark %S"
                                      err bookmark)))
      nil)))

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
             bufferlo-bookmark-inhibit-bookmark-point
             record)
        (bookmark-set-position record nil))
      (list (buffer-name buffer) record))))

(defun bufferlo--bookmark-filter-buffers (&optional frame)
  "Filter out buffers to exclude for bookmarks.
Filters the buffers according to `bufferlo-bookmark-buffers-exclude-filters' and
`bufferlo-bookmark-buffers-include-filters'.  The argument FRAME determines the
local buffer list to use.  If it is nil, the current frame is used."
  (let* ((buffers (bufferlo-buffer-list frame nil t))
         (buffers-excl (seq-remove
                        (lambda (buf)
                          (seq-filter
                           (lambda (regexp)
                             (string-match-p regexp (buffer-name buf)))
                           bufferlo-bookmark-buffers-exclude-filters))
                        buffers))
         (buffers-incl (seq-filter
                        (lambda (buf)
                          (seq-filter
                           (lambda (regexp)
                             (string-match-p regexp (buffer-name buf)))
                           bufferlo-bookmark-buffers-include-filters))
                        buffers)))
    (seq-union buffers-excl buffers-incl)))

(defun bufferlo--bookmark-get-for-buffers-in-tab (buffers)
  "Get bookmarks for all BUFFERS of the selected tab in FRAME."
  (seq-filter #'identity
              (mapcar #'bufferlo--bookmark-get-for-buffer
                      buffers)))

(defun bufferlo--bookmark-tab-make ()
  "Make the tab bookmark record for the current frame and tab."
  (let ((filtered-buffers
         (bufferlo--bookmark-filter-buffers))
        (current-tab (bufferlo--current-tab)))
    `((tab-explicit-name . ,(when (alist-get 'explicit-name current-tab)
                              (alist-get 'name current-tab)))
      (tab-group . ,(alist-get 'group current-tab))
      (buffer-bookmarks . ,(bufferlo--bookmark-get-for-buffers-in-tab
                            filtered-buffers))
      (buffer-list . ,(mapcar #'buffer-name
                              filtered-buffers))
      (window . ,(window-state-get (frame-root-window) 'writable))
      (handler . ,#'bufferlo--bookmark-tab-handler))))

(defun bufferlo--ws-replace-buffer-names (ws replace-alist)
  "Replace buffer names according to REPLACE-ALIST in the window state WS."
  (mapc (lambda (el)
          (when (memq (car el) '(leaf vc hc))
            (bufferlo--ws-replace-buffer-names el replace-alist)))
        (if (consp (car ws))
            (list (cdr ws))
          (cdr ws)))
  ;; Replace name in the buffer field
  (when-let* ((buffer-loc (assq 'buffer ws))
              (buffer (cadr buffer-loc))
              (replace (assoc buffer replace-alist)))
    (setf (cadr buffer-loc) (cdr replace)))
  ;; Replace names in the prev-buffers list
  (when-let* ((prev-buffers-loc (assq 'prev-buffers ws))
              (prev-buffers (cdr prev-buffers-loc)))
    (setf (cdr prev-buffers-loc)
          (mapcar (lambda (be)
                    (if-let ((replace (assoc (car be) replace-alist)))
                        (cons (cdr replace) (cdr be))
                      be))
                  prev-buffers))))

(defvar bufferlo--bookmark-set-loading nil
  "Let bind to t when a bookmark set is being loaded.
This controls `bufferlo--bookmark-get-duplicate-policy' to inhibit raise
and quit which are cumbersome during set loading.")

(defun bufferlo--bookmark-get-duplicate-policy (bookmark-name thing default-policy mode &optional embedded-tab)
  "Get the duplicate policy for THING BOOKMARK-NAME.
THING should be either \"frame\" or \"tab\".
Ask the user if DEFAULT-POLICY is set to \\='prompt.
MODE can be one of \\='load \\='save \\='undelete, depending on the
invoking action.
EMBEDDED-TAB is non-nil if the tab bookmark is embedded in a frame
bookmark.  This functions throws :abort when the user quits.

The variable `bufferlo--bookmark-set-loading' should be non-nil if the
function is invoked as part of a bookmark set restoration.

The functions presents the user with the following options:
  allow, clear, ignore, raise, help, quit

Depending on the inputs, not all of these options are visible.

In case of a duplicate tab:
- solo tab: all options
- undo close tab: all options
- solo tab in bookmarked frame (default: prompt): all options
- solo tab in bookmarked frame (default: no prompt): all options
- solo tab in a set (default: prompt): allow, clear, ignore, disallow raise
- solo tab in a set (default: no prompt), allow, clear, ignore, disallow raise
- embedded tab in a set: allow, clear, ignore,
  disallow prompt (coerce to ignore), disallow raise (coerce to ignore)

In case of a duplicate frame:
- solo frame: all options
- undelete frame: all options
- frame in a set: allow, clear, ignore, disallow prompt (coerce to ignore),
  disallow raise (coerce to ignore)"
  (cond ((and bufferlo--bookmark-set-loading
              (or embedded-tab (equal thing "frame")))
         ;; An embedded tab in a set, or a frame in a set:
         ;;   allow, clear, ignore, disallow prompt (coerce to ignore),
         ;;   disallow raise (coerce to ignore)
         (pcase default-policy
           ('prompt 'ignore)
           ('allow default-policy)
           ('clear default-policy)
           ('clear-warn default-policy)
           ('ignore default-policy)
           ('raise 'ignore)))

        ((and bufferlo--bookmark-set-loading
              (equal thing "tab")
              (not (eq default-policy 'prompt)))
         ;; A solo tab in a set (and default: no prompt):
         ;;   allow, clear, ignore, disallow prompt, disallow raise
         (pcase default-policy
           ('allow default-policy)
           ('clear default-policy)
           ('clear-warn default-policy)
           ('ignore default-policy)
           ('raise 'ignore)))

        ((not (eq default-policy 'prompt))
         ;; A tab in a frame; do not prompt:
         ;;   allow, clear, ignore, disallow raise (coerce to ignore)
         (if embedded-tab
             (pcase default-policy
               ('allow default-policy)
               ('clear default-policy)
               ('clear-warn default-policy)
               ('ignore default-policy)
               ('raise 'ignore))
           ;; allow all others
           default-policy))

        (t ; Prompt for a policy
         (let* ((mode-text (pcase mode
                             ('save
                              "Clear other bookmark")
                             ('load
                              "Clear bookmark after loading")
                             ('undelete ; invalid in bufferlo--bookmark-set-loading
                              "Clear bookmark after undeleting/undoing")))
                ;; A solo tab in a set (and default: prompt):
                ;;   allow, clear, ignore, disallow raise
                (disallow-raise (and bufferlo--bookmark-set-loading
                                     (equal thing "tab")))
                (question (concat (format-message "%s bookmark `%s' already active: "
                                                  (capitalize thing)
                                                  bookmark-name)
                                  "Allow"
                                  (format ", %s" mode-text) ; clear thing
                                  ", Ignore"
                                  (unless disallow-raise
                                    (format ", Raise existing"))
                                  " "))
                (a-allow `("allow" ?a "Allow duplicate"))
                (a-clear `("clear" ?c
                           ,(pcase mode
                              ('save
                               (format "Clear the other %s's bookmark association"
                                       thing))
                              ('load
                               (format "Clear this %s's bookmark association after loading"
                                       thing))
                              ('undelete
                               (format "Clear this %s's bookmark association after undeleting/undoing"
                                       thing)))))
                (a-ignore `("ignore" ?i "Ignore duplicate"))
                (a-raise `("raise" ?r
                           ,(format "Raise the %s with the active bookmark and quit"
                                    thing)))
                (a-help `("help" ?h "Help"))
                (a-quit `("quit" ?q ,(format "Quit to %s"
                                             (if bufferlo--bookmark-set-loading
                                                 "ignore"
                                               "abort"))))
                ;; An embedded tab in a set: all options
                ;; A solo tab in a set: allow, clear, ignore, disallow raise
                (answers (if (or embedded-tab
                                 (and bufferlo--bookmark-set-loading
                                      (equal thing "tab")))
                             (list a-allow a-clear a-ignore a-help a-quit)
                           (list a-allow a-clear a-ignore a-raise a-help a-quit))))
           (pcase (with-local-quit
                    (read-answer question answers))
             ("allow" 'allow)
             ("clear" 'clear)
             ("ignore" 'ignore)
             ("raise" 'raise)
             (_ (if bufferlo--bookmark-set-loading
                    'ignore
                  (throw :abort t))))))))

(defun bufferlo--bookmark-tab-get-replace-policy ()
  "Get the replace policy for tab bookmarks.
Prompt if `bufferlo-bookmark-tab-replace-policy' is set to \\='prompt.
This functions throws :abort when the user quits."
  (if (not (eq bufferlo-bookmark-tab-replace-policy 'prompt))
      bufferlo-bookmark-tab-replace-policy
    (pcase (with-local-quit
             (read-answer "Replace current tab, New tab "
                          '(("replace" ?o "Replace tab")
                            ("new" ?n "New tab")
                            ("help" ?h "Help")
                            ("quit" ?q "Quit to abort"))))
      ("replace" 'replace)
      ("new" 'new)
      (_ (throw :abort t)))))

(defun bufferlo--bookmark-tab-get-clear-policy (mode)
  "Get the clear policy for tab bookmarks.
Prompt if `bufferlo-bookmark-tab-in-bookmarked-frame-policy' is
set to \\='prompt.  This functions throws :abort when the user quits.
MODE is either \\='load, \\='save, or \\='save-frame, depending on the
invoking action.  This functions throws :abort when the user quits."
  (if (not (eq bufferlo-bookmark-tab-in-bookmarked-frame-policy 'prompt))
      bufferlo-bookmark-tab-in-bookmarked-frame-policy
    (pcase (with-local-quit
             (read-answer
              (concat
               (pcase mode
                 ('load "Tab bookmark conflicts with frame bookmark: ")
                 ('save "Frame already bookmarked: ")
                 ('save-frame "Tabs in this frame are bookmarked: "))
               (format "Allow tab bookmark, Clear %s bookmark "
                       (if (eq mode 'save) "frame" "tab")))
              `(("allow" ?a "Allow tab bookmark")
                ("clear" ?c ,(if (eq mode 'save)
                                 "Clear frame bookmark, set tab bookmark"
                               "Clear tab bookmark"))
                ("help" ?h "Help")
                ("quit" ?q "Quit to abort"))))
      ("allow" 'allow)
      ("clear" 'clear)
      (_ (throw :abort t)))))

(defun bufferlo--bookmark-insert-placeholer (orig-name)
  "`bufferlo--bookmark-tab-handler' helper function.
Use ORIG-NAME to create a placeholder buffer for buffers that failed to
restore."
  (let ((buffer-existed (get-buffer orig-name))
        (fail-buffer
         (cond
          ((eq 'placeholder
               bufferlo-bookmark-tab-failed-buffer-policy)
           ;; Do not insert a placeholder for a placeholder
           (if (string-match-p "\\`\\*bufferlo failed buffer .*\\*\\'" orig-name)
               (generate-new-buffer orig-name)
             (generate-new-buffer (format-message "*bufferlo failed buffer `%s'*"
                                                  orig-name))))
          ((eq 'placeholder-orig
               bufferlo-bookmark-tab-failed-buffer-policy)
           (get-buffer-create orig-name))
          ((stringp
            bufferlo-bookmark-tab-failed-buffer-policy)
           (get-buffer-create
            bufferlo-bookmark-tab-failed-buffer-policy))
          ((functionp
            bufferlo-bookmark-tab-failed-buffer-policy)
           (funcall
            bufferlo-bookmark-tab-failed-buffer-policy
            orig-name))
          (t nil))))
    (when fail-buffer
      (switch-to-buffer fail-buffer nil 'force-same-window)
      (when (and (not buffer-existed)
                 (memq bufferlo-bookmark-tab-failed-buffer-policy
                       '(placeholder placeholder-orig)))
        (insert
         (format-message
          "Bufferlo could not restore buffer `%s'" orig-name))
        (set-buffer-modified-p nil)))))

(defvar bufferlo--bookmark-handler-no-message nil)

(defun bufferlo--bookmark-tab-handler (bookmark &optional not-jump no-message embedded-tab)
  "Handle bufferlo tab bookmark.
The argument BOOKMARK is the to-be restored tab bookmark record created
via `bufferlo--bookmark-tab-make'.

NOT-JUMP should be non-nil when called directly vs. from `bookmark-jump'.

If the optional argument NO-MESSAGE is non-nil, inhibit the message
after successfully restoring the bookmark.

If EMBEDDED-TAB is non-nil, indicate that this bookmark is embedded in a
frame bookmark.

The variable `bufferlo--bookmark-set-loading' is consulted.

Returns nil on success, non-nil on abort."
  (catch :abort
    (let* ((bookmark-name (if (not embedded-tab)
                              (bookmark-name-from-full-record bookmark)
                            nil))
           (orig-bookmark-name bookmark-name)
           (abm (assoc bookmark-name (bufferlo--active-bookmarks)))
           disconnect-tbm-p
           restored-buffer-names
           skipped-buffer-names
           msg)
      (cl-labels
          ((msg-append (s) (setq msg (concat msg "; " s))))
        ;; Bookmark already loaded in another tab?
        (when abm
          ;; Throws :abort
          (let ((duplicate-policy (bufferlo--bookmark-get-duplicate-policy
                                   bookmark-name "tab"
                                   bufferlo-bookmark-tab-duplicate-policy
                                   'load
                                   embedded-tab)))
            (pcase duplicate-policy
              ('allow)
              ('clear
               (setq bookmark-name nil))
              ('clear-warn
               (setq bookmark-name nil)
               (msg-append "cleared tab bookmark"))
              ('ignore
               (throw :abort t))
              ('raise
               (bufferlo--bookmark-raise abm)
               (throw :abort t)))))

        ;; Bookmark not loaded as part of a frame bookmark or in a set?
        ;; Frame and set handlers manage tabs, so we don't do it here.
        (unless (or embedded-tab bufferlo--bookmark-set-loading)

          ;; Handle an independent tab bookmark on a frame with an
          ;; active frame bookmark.  Do this first, before a new tab is
          ;; created.
          (when (and bookmark-name
                     (frame-parameter nil 'bufferlo-bookmark-frame-name))
            ;; Throws :abort
            (let ((clear-policy (bufferlo--bookmark-tab-get-clear-policy 'load)))
              (pcase clear-policy
                ('clear
                 (setq disconnect-tbm-p t))
                ('clear-warn
                 (setq disconnect-tbm-p t)
                 (msg-append "cleared tab bookmark")))))

          ;; Replace current tab or create new tab?
          ;; Throws :abort
          (let ((replace-policy (bufferlo--bookmark-tab-get-replace-policy)))
            (pcase replace-policy
              ('replace)
              ('new
               (unless (consp current-prefix-arg) ; user new tab suppression
                 (let ((tab-bar-new-tab-choice t))
                   (tab-bar-new-tab-to)
                   (let ((current-tab (cdr (bufferlo--current-tab)))
                         (tab-explicit-name (alist-get 'tab-explicit-name bookmark))
                         (tab-group (alist-get 'tab-group bookmark)))
                     (when tab-explicit-name
                       (setf (alist-get 'name current-tab) tab-explicit-name)
                       (setf (alist-get 'explicit-name current-tab) t))
                     (when tab-group
                       (tab-bar-change-tab-group tab-group)))))))))

        ;; Do the real work: restore the tab.
        ;; NOTE: No :abort throws after this point.
        (let* ((ws (copy-tree (alist-get 'window bookmark)))
               (dummy (generate-new-buffer " *bufferlo dummy buffer*"))
               (restore (lambda (bm)
                          (let ((orig-name (car bm))
                                (record (cadr bm))
                                (restore-failed))

                            (set-buffer dummy)
                            ;; Test if bookmark-handler did not complain...
                            (setq restore-failed
                                  (condition-case err
                                      (progn
                                        (funcall (or (bookmark-get-handler record)
                                                     'bookmark-default-handler)
                                                 record)
                                        (run-hooks 'bookmark-after-jump-hook)
                                        nil)
                                    (error
                                     (message "Bufferlo bookmark: Could not restore %s (error %s)"
                                              orig-name err)
                                     t)))
                            ;; ...then test that the buffer actually changed.
                            (setq restore-failed (or restore-failed
                                                     (eq (current-buffer) dummy)))

                            (if restore-failed
                                (progn
                                  (bufferlo--bookmark-insert-placeholer orig-name)
                                  (push orig-name skipped-buffer-names))
                              (push orig-name restored-buffer-names))

                            (unless (eq (current-buffer) dummy)
                              ;; Return a list of (cons <string> <buffer>).
                              ;; The buffer may be renamed later (by uniquify).
                              ;; Using the buffer name directly would not
                              ;; account for this!
                              (cons orig-name (current-buffer))))))

               (renamed (mapcar restore (alist-get 'buffer-bookmarks bookmark)))
               (replace-renamed (lambda (b)
                                  (if-let* ((replace
                                             (assoc b renamed)))
                                      (cdr replace) b)))
               (bm-buffer-list (mapcar replace-renamed
                                       (alist-get 'buffer-list bookmark)))
               ;; Some of the items may already be buffers after renaming.
               ;; Others are still buffer names (strings).  These items had no
               ;; bookmark associated with them.
               (bm-buffer-list (seq-filter #'get-buffer bm-buffer-list))
               (bm-buffer-list (mapcar #'get-buffer bm-buffer-list)))

          (kill-buffer dummy)

          ;; Note that we replace buffer names with buffers in ws.
          ;; `window-state-put' accepts this.
          (bufferlo--ws-replace-buffer-names ws renamed)

          ;; Restore tab name
          (when (or embedded-tab bufferlo-bookmark-tab-restore-explicit-name)
            (when-let* ((tab-name (alist-get 'tab-explicit-name bookmark)))
              (tab-bar-rename-tab tab-name)))

          ;; Restore tab group
          (when (or (eq bufferlo-bookmark-restore-tab-groups t)
                    (and embedded-tab (eq bufferlo-bookmark-restore-tab-groups 'frames))
                    (and (not embedded-tab) (eq bufferlo-bookmark-restore-tab-groups 'tabs)))
            (when-let* ((tab-group (alist-get 'tab-group bookmark)))
              (tab-bar-change-tab-group tab-group)))

          ;; We do the following to work around two problems with
          ;; bookmark--jump-via.  In older versions, when called
          ;; interactively and not through bufferlo commands, it calls a
          ;; display-function which could interfere with
          ;; window-state-put.
          ;;
          ;; In Emacs 31, bookmark--jump-via wraps the bookmark-handler
          ;; call with save-window-excursion which restores the
          ;; window-configuration after we've just restored the one from
          ;; the bookmark.  We let bookmark--jump-via be evil and defer
          ;; window-state-put until after bookmark--jump-via is done.
          (let ((bm-after-jump-hook-sym (gensym "bufferlo-bm-after-jump-"))
                (frame (selected-frame))
                (tab-number (1+ (tab-bar--current-tab-index)))
                (buffer (current-buffer)))
            (fset bm-after-jump-hook-sym
                  (lambda ()
                    (remove-hook 'bookmark-after-jump-hook bm-after-jump-hook-sym)
                    (with-selected-frame frame ; defensive
                      (let ((tab-bar-tab-post-select-functions))
                        (tab-bar-select-tab tab-number) ; defensive
	                (window-state-put ws (frame-root-window) 'safe)
                        (set-frame-parameter nil 'buffer-list bm-buffer-list)
                        (set-frame-parameter nil 'buried-buffer-list nil)
                        (setf (alist-get 'bufferlo-bookmark-tab-name
                                         (cdr (bufferlo--current-tab)))
                              (unless disconnect-tbm-p bookmark-name))
                        (sit-for 0)
                        (run-hook-with-args
                         'bufferlo-bookmark-tab-handler-functions
                         bookmark-name
                         (unless disconnect-tbm-p bookmark-name)
                         (bufferlo--current-tab)
                         restored-buffer-names
                         skipped-buffer-names)
                        buffer))))
            (add-hook 'bookmark-after-jump-hook bm-after-jump-hook-sym -99)
            (when not-jump
              (run-hooks 'bookmark-after-jump-hook))))

        ;; Log message
        (unless (or no-message bufferlo--bookmark-handler-no-message)
          (message "Restored bufferlo tab bookmark%s%s%s%s"
                   (if orig-bookmark-name (format ": %s" orig-bookmark-name) "")
                   (or msg "")
                   (if restored-buffer-names
                       (format " (%s)"
                               (mapconcat #'identity restored-buffer-names ", ")) "")
                   (if skipped-buffer-names
                       (format " (skipped: %s)"
                               (mapconcat #'identity skipped-buffer-names ", ")) "")))
        ;; Explicitly return success; abort returns non-nil
        nil))))

;; We use a short name here as bookmark-bmenu-list hard codes width of 8 chars
(put #'bufferlo--bookmark-tab-handler 'bookmark-handler-type "B-Tab")
(put #'bufferlo--bookmark-tab-handler 'bookmark-inhibit 'insert)

(defun bufferlo--bookmark-frame-make ()
  "Make a bufferlo frame bookmark record for the current frame."
  (let ((tabs (funcall tab-bar-tabs-function))
        (orig-tab (1+ (tab-bar--current-tab-index)))
        (tab-bar-tab-post-select-functions)
        tabs-to-bookmark)
    (dotimes (i (length tabs))
      (tab-bar-select-tab (1+ i))
      (let* ((curr (alist-get 'current-tab tabs))
             (name (alist-get 'name curr))
             (explicit-name (alist-get 'explicit-name curr))
             (tbm (bufferlo--bookmark-tab-make)))
        (if explicit-name
            (push (cons 'tab-name name) tbm)
          (push (cons 'tab-name nil) tbm))
        (push tbm tabs-to-bookmark)))
    (tab-bar-select-tab orig-tab)
    `((tabs . ,(reverse tabs-to-bookmark))
      (current . ,orig-tab)
      (bufferlo--frame-name . ,(when bufferlo-bookmark-frame-persist-frame-name
                                 (frame-parameter nil 'name)))
      (bufferlo--frame-geometry . ,(funcall bufferlo-frame-geometry-function
                                            (selected-frame)))
      (handler . ,#'bufferlo--bookmark-frame-handler))))

(defun bufferlo--bookmark-frame-get-load-policy ()
  "Get the load policy for frame bookmarks.
Prompt if `bufferlo-bookmark-frame-load-policy' is set to \\='prompt.
This functions throws :abort when the user quits."
  (if (not (eq bufferlo-bookmark-frame-load-policy 'prompt))
      bufferlo-bookmark-frame-load-policy
    (pcase (with-local-quit
             (read-answer
              (concat
               "Current frame already bookmarked: "
               "load and retain Current, Replace with new, Merge with existing ")
              '(("current" ?c "Replace frame, retain the current bookmark")
                ("replace" ?r "Replace frame, adopt the loaded bookmark")
                ("merge" ?m "Merge the new tab content with the existing bookmark")
                ("help" ?h "Help")
                ("quit" ?q "Quit to abort"))))
      ("current" 'replace-frame-retain-current-bookmark)
      ("replace" 'replace-frame-adopt-loaded-bookmark)
      ("merge" 'merge)
      (_ (throw :abort t)))))

(defun bufferlo--bookmark-frame-handler (bookmark &optional _not-jump no-message)
  "Handle bufferlo frame bookmark.
The argument BOOKMARK is the to-be restored frame bookmark record
created via `bufferlo--bookmark-frame-make'.

The optional argument NO-MESSAGE inhibits the message after successfully
restoring the bookmark.

NOT-JUMP should be non-nil when called directly vs. from `bookmark-jump'.

Returns nil on success, non-nil on abort."
  (catch :abort
    (let* ((bookmark-name (bookmark-name-from-full-record bookmark))
           (abm (assoc bookmark-name (bufferlo--active-bookmarks)))
           (fbm (frame-parameter nil 'bufferlo-bookmark-frame-name))
           (new-frame-p (and bufferlo-bookmark-frame-load-make-frame ; nil if set loading
                             ;; User make-frame suppression
                             (not (consp current-prefix-arg))
                             ;; make-frame implied by functions like
                             ;; `bookmark-jump-other-frame'
                             (not pop-up-frames)))
           duplicate-policy
           load-policy
           msg)
      (cl-labels
          ((msg-append (s) (setq msg (concat msg "; " s))))

        ;; Bookmark already loaded in another frame?
        (when abm
          (setq duplicate-policy (bufferlo--bookmark-get-duplicate-policy
                                  bookmark-name "frame"
                                  bufferlo-bookmark-frame-duplicate-policy 'load))
          (pcase duplicate-policy
            ('ignore
             (throw :abort t))
            ('raise
             (bufferlo--bookmark-raise abm)
             (throw :abort t))))

        ;; If new frame, no conflict; go with the bookmark's name.
        (if new-frame-p
            (setq fbm bookmark-name)
          ;; No currently active bookmark in the frame?
          (if (not fbm)
              ;; Set active bookmark
              (setq fbm bookmark-name)
            ;; Handle existing bookmark according to the load policy
            (setq load-policy (bufferlo--bookmark-frame-get-load-policy))
            (pcase load-policy
              ('disallow-replace
               ;; Allow reloads of existing bookmark
               (when (not (equal fbm bookmark-name))
                 (unless no-message
                   (message "Frame already bookmarked as %s; not loaded." fbm))
                 (throw :abort t)))
              ('replace-frame-retain-current-bookmark
               (msg-append (format "retained existing bookmark %s." fbm)))
              ('replace-frame-adopt-loaded-bookmark
               (msg-append (format "adopted loaded bookmark %s." fbm))
               (setq fbm bookmark-name))
              ('merge
               (msg-append (format "merged tabs from bookmark %s."
                                   bookmark-name))))))

        ;; Do the real work with the target frame selected
        ;; (current or newly created)
        ;; NOTE: No :abort throws after this point
        (bufferlo--with-temp-buffer
         (let ((frame (if new-frame-p
                          (bufferlo--make-frame
                           (eq bufferlo-bookmark-frame-load-make-frame
                               'restore-geometry))
                        (selected-frame))))
           (with-selected-frame frame
             (when new-frame-p
               ;; Restore name
               (when bufferlo-bookmark-frame-persist-frame-name
                 (when-let* ((frame-name (alist-get 'bufferlo--frame-name bookmark)))
                   (set-frame-name frame-name)))
               ;; Restore geometry
               (when (and (display-graphic-p)
                          (eq bufferlo-bookmark-frame-load-make-frame
                              'restore-geometry))
                 (when-let* ((fg (alist-get 'bufferlo--frame-geometry bookmark)))
                   (funcall bufferlo-set-frame-geometry-function fg))))

             ;; Clear existing tabs unless merging
             (unless (eq load-policy 'merge)
               (tab-bar-tabs-set nil))

             ;; Load tabs
             (let ((first (if (eq load-policy 'merge) nil t))
                   (tab-bar-new-tab-choice t))
               (mapc
                (lambda (tbm)
                  (let ((orig-buffer (current-buffer)))
                    (unless first
                      (tab-bar-new-tab-to))
                    ;; NOTE: This is defensive code.  There should be no aborts
                    ;; for an embedded-tab and bufferlo--bookmark-tab-handler
                    ;; disallows raise for an embedded-tab to avoid selected
                    ;; frame/tab state issues..  Embedded tabs in frames carry
                    ;; no bookmarks of their own, so no duplicates are possible
                    ;; and other user prompts are bypassed.
                    ;;
                    ;; Handler abort is non-nil.
                    (if (bufferlo--bookmark-tab-handler tbm 'not-jump
                                                        'no-message 'embedded-tab)
                        (if first
                            (let ((switch-to-buffer-obey-display-actions))
                              (switch-to-buffer orig-buffer 'no-record
                                                'force-same-window))
                          (let (tab-bar-tab-prevent-close-functions)
                            (tab-bar-close-tab))))
                    (setq first nil)))
                (alist-get 'tabs bookmark)))
             ;; NOTE: We might not find a 'current tab if the tab handler aborts
             ;; (should never happen).
             (tab-bar-select-tab (alist-get 'current bookmark))

             ;; Handle duplicate frame bookmark
             (when abm
               (pcase duplicate-policy
                 ;; Do nothing for 'allow or nil
                 ('clear
                  (setq fbm nil))
                 ('clear-warn
                  (setq fbm nil)
                  (msg-append "cleared frame bookmark"))))

             (set-frame-parameter nil 'bufferlo-bookmark-frame-name fbm))

           ;; Select and raise the restored frame outside the context
           ;; of with-selected-frame
           (select-frame-set-input-focus frame)

           (run-hook-with-args
            'bufferlo-bookmark-frame-handler-functions
            bookmark-name
            fbm
            new-frame-p
            frame)))

        (unless (or new-frame-p pop-up-frames)
          ;; Switch to the to-be-selected buffer in the current frame.
          ;; This is a workaround for bookmark-jump if called with display-func
          ;; set to something like pop-to-buffer-same-window (the default).
          ;; Without this, the previously selected buffer will leak into the
          ;; loaded frame bookmark.
          (switch-to-buffer (window-buffer (frame-selected-window nil))))

        ;; Log message
        (unless (or no-message bufferlo--bookmark-handler-no-message)
          (message "Restored bufferlo frame bookmark%s%s"
                   (if bookmark-name (format ": %s" bookmark-name) "")
                   (or msg "")))
        ;; Explicitly return success; abort returns non-nil
        nil))))

;; We use a short name here as bookmark-bmenu-list hard codes width of 8 chars
(put #'bufferlo--bookmark-frame-handler 'bookmark-handler-type "B-Frame")
(put #'bufferlo--bookmark-frame-handler 'bookmark-inhibit 'insert)

(defun bufferlo--bookmark-set-location (bookmark-name-or-record &optional location)
  "Set the location of BOOKMARK-NAME-OR-RECORD to LOCATION or \\=\"\", if nil."
  (bookmark-prop-set bookmark-name-or-record 'location (or location ""))
  bookmark-name-or-record)

(defun bufferlo--bookmark-completion-table (candidates &optional no-sort)
  "Completing read helper.
CANDIDATES should be a list from which to select candidates.
When non-nil, NO-SORT uses the natural order of the CANDIDATES list."
  (lambda (string pred action)
    (cond
     ((eq action 'metadata)
      `(metadata . ,(cons '(category . bookmark)
                          (when no-sort
                            '((display-sort-function . identity))))))
     (t
      (complete-with-action action candidates string pred)))))

(defun bufferlo--bookmark-completing-read (prompt candidates &optional no-sort)
  "Common bufferlo bookmark `completing-read'.
PROMPT is the prompt text ending with a space.
CANDIDATES are the prompt options to select.
When non-nil, NO-SORT uses the natural order of the CANDIDATES list."
  (completing-read prompt
                   (bufferlo--bookmark-completion-table candidates no-sort)
                   nil 'require-match nil 'bufferlo-bookmark-history))

(defun bufferlo--bookmark-completing-read-multiple (prompt candidates &optional no-sort)
  "Common bufferlo bookmark `completing-read-multiple'.
PROMPT is the prompt text ending with a space.
CANDIDATES are the prompt options to select.
When non-nil, NO-SORT uses the natural order of the CANDIDATES list."
  (let* ((comps
          (delete-dups
           (completing-read-multiple
            prompt
            (bufferlo--bookmark-completion-table candidates no-sort)
            nil 'require-match nil 'bufferlo-bookmark-history)))
         (comps (seq-intersection
                 (mapcar (lambda (x) (substring-no-properties x)) comps)
                 candidates)))
    comps))

;; filter out vs. frameset-persistent-filter-alist
(defvar bufferlo--frameset-save-filter
  '(;; bufferlo parameters
    bufferlo-bookmark-frame-name
    ;; Emacs parameters
    alpha
    alpha-background
    auto-lower
    auto-raise
    background-color
    background-mode
    border-color
    border-width
    bottom-divider-width
    buffer-predicate
    child-frame-border-width
    cursor-color
    cursor-type
    display
    display-type
    environment
    explicit-name
    font
    font-parameter
    foreground-color
    horizontal-scroll-bars
    icon-name
    icon-type
    inhibit-double-buffering
    internal-border-width
    ;; last-focus-update
    left-fringe
    line-spacing
    menu-bar-lines
    minibuffer
    modeline
    mouse-color
    ;; name ; ???
    no-accept-focus
    no-focus-on-map
    no-special-glyphs
    ns-appearance
    ns-transparent-titlebar
    outer-window-id
    override-redirect
    right-divider-width
    right-fringe
    screen-gamma
    scroll-bar-background
    scroll-bar-foreground
    scroll-bar-height
    scroll-bar-width
    shaded
    skip-taskbar
    sticky
    tabs
    tab-bar-lines
    title
    tool-bar-lines
    tool-bar-position
    tty
    tty-type
    undecorated
    unsplittable
    use-frame-synchronization
    vertical-scroll-bars
    visibility
    wait-for-wm
    z-group))

(defvar bufferlo--frameset-restore-filter
  '(;; Emacs parameters
    GUI:bottom
    GUI:font
    GUI:fullscreen
    GUI:height
    GUI:left
    GUI:right
    GUI:top
    GUI:width
    bottom
    fontsize
    frameset--text-pixel-height
    frameset--text-pixel-width
    fullscreen
    height
    left
    right
    top
    width))

(defun bufferlo-frame-geometry-default (frame)
  "Produce an alist for FRAME pixel-level geometry.
The alist is of the form:

  ((left . pixels)
   (top . pixels)
   (width . pixels)
   (height . pixels))

Return nil if no pixel-level geometry is available; for example, if the
display is a tty."
  (if (display-graphic-p frame)
      `((left . ,(frame-parameter frame 'left))
        (top . ,(frame-parameter frame 'top))
        (width . ,(frame-text-width frame))
        (height .,(frame-text-height frame)))
    nil))

(defun bufferlo-set-frame-geometry-default (frame-geometry &optional frame)
  "Set FRAME-GEOMETRY as produced by `bufferlo-frame-geometry-default'.
Geometry set for FRAME or the current frame, if nil."
  ;; Some window managers need an extra display cycle for frame
  ;; changes to take effect from Emacs's perspective, so we add
  ;; needed sit-for calls.
  (setq frame (or frame (selected-frame)))
  (let-alist frame-geometry
    ;; The sleeps (sleep-for) wait for window managers to catch up.
    ;; Be defensive in case the geometry was stored from a tty.
    (when (and .left .top .width .height)
      (let ((frame-resize-pixelwise t)
            (frame-inhibit-implied-resize t))
        (set-frame-position frame .left .top)
        (sleep-for bufferlo-frame-sleep-for)
        ;; Clamp size to restore frames larger than the current display size.
        (set-frame-size frame
                        (min .width (display-pixel-width))
                        (min .height (display-pixel-height))
                        'pixelwise)
        (sleep-for bufferlo-frame-sleep-for)))))

(defvar bufferlo--active-sets nil
  "Global active bufferlo sets.
This is an alist of the form:
  ((set-name ('bufferlo--bookmark-names . name-list))).")

(defun bufferlo--bookmark-set-make (active-bookmark-names tabsets frameset)
  "Make a bufferlo bookmark set.

ACTIVE-BOOKMARK-NAMES defines the bookmarks for the stored
bookmark set.

TABSETS is a list of tab bookmark names organized in sub-lists
representing logical container frames.

FRAMESET is a bufferlo-filtered `frameset'."
  (let ((bookmark-record (bookmark-make-record-default t t 0))) ; (&optional no-file no-context posn)
    (bookmark-prop-set bookmark-record
                       'bufferlo-bookmark-names
                       (if (consp active-bookmark-names)
                           active-bookmark-names
                         (list active-bookmark-names)))
    (bookmark-prop-set bookmark-record
                       'bufferlo-tabsets (prin1-to-string tabsets))
    (bookmark-prop-set bookmark-record
                       'bufferlo-frameset (prin1-to-string frameset))
    (bookmark-prop-set bookmark-record
                       'handler #'bufferlo--bookmark-set-handler)
    bookmark-record))

(defun bufferlo-frameset-restore-parameters-default ()
  "Function to create parameters for `frameset-restore', which see."
  (list :reuse-frames nil
        :force-display t
        :force-onscreen (display-graphic-p)
        :cleanup-frames nil))

(defun bufferlo-frameset-restore-default (frameset)
  "Invoke `frameset-restore' with FRAMESET, which see."
  (let ((params (funcall bufferlo-frameset-restore-parameters-function))
        ;; frameset-restore checks for fullscreen in frame parameters
        ;; and its handling is wonky and the restore filter has no
        ;; effect, so we remove it locally.
        (default-frame-alist (assq-delete-all 'fullscreen
                                              (copy-tree default-frame-alist))))
    (with-temp-buffer
      (ignore-errors
        ;; Sadly, frameset-restore returns neither a status nor a list
        ;; of restored frames.
        (frameset-restore
         frameset
         :filters
         (when (memq bufferlo-frameset-restore-geometry '(bufferlo nil))
           (let ((filtered-alist
                  (copy-tree frameset-persistent-filter-alist)))
             (mapc (lambda (sym) (setf (alist-get sym filtered-alist) :never))
                   (seq-union bufferlo--frameset-restore-filter
                              bufferlo-frameset-restore-filter))
             filtered-alist))
         :reuse-frames (plist-get params :reuse-frames)
         :force-display (plist-get params :force-display)
         :force-onscreen (plist-get params :force-onscreen)
         :cleanup-frames (plist-get params :cleanup-frames))))))

(defun bufferlo--bookmark-set-handler (bookmark-record &optional _not-jump no-message)
  "Handle bufferlo bookmark set.
The argument BOOKMARK-RECORD is the to-be restored bookmark set created
via `bufferlo--bookmark-set-make'.  The optional argument NO-MESSAGE
inhibits the message after successfully restoring the bookmark.  The
list of restored bookmarks indicates bookmarks that were already active
with an asterisk.

NOT-JUMP should be non-nil when called directly vs. from `bookmark-jump'.

Returns nil on success, non-nil on abort."
  (let* ((bookmark-name (bookmark-name-from-full-record bookmark-record))
         (bufferlo-bookmark-names (bookmark-prop-get bookmark-record
                                                     'bufferlo-bookmark-names))
         (abms (bufferlo--active-bookmarks))
         (abm-names (mapcar #'car abms))
         (already-abm-names (seq-intersection
                             bufferlo-bookmark-names
                             abm-names))
         ignore-already-active
         (bufferlo--bookmark-set-loading t)
         (tabsets-str (bookmark-prop-get bookmark-record 'bufferlo-tabsets))
         (frameset-str (bookmark-prop-get bookmark-record 'bufferlo-frameset)))

    (when (assoc bookmark-name bufferlo--active-sets)
      (user-error "Bufferlo set `%s' is already active" bookmark-name))

    (unless (readablep tabsets-str)
      (error "Bufferlo bookmark set %s: unreadable tabsets"
             bookmark-name))

    (unless (readablep frameset-str)
      (error "Bufferlo bookmark set %s: unreadable frameset"
             bookmark-name))

    (when already-abm-names
      (pcase bufferlo-set-restore-ignore-already-active
        ('prompt
         (setq ignore-already-active
               (y-or-n-p "Ignore all already-active bookmarks? ")))
        ('ignore
         (setq ignore-already-active t))
        (_ (setq ignore-already-active nil))))

    ;; Restore tabsets (tabsets can be nil despite readablep)
    (when-let* ((tabsets (car (read-from-string tabsets-str)))
                (first-tab-frame t))
      (bufferlo--with-temp-buffer
       (dolist (tab-group tabsets)
         (when (or (not first-tab-frame)
                   (and first-tab-frame
                        (not bufferlo-set-restore-tabs-reuse-init-frame)))
           (select-frame (bufferlo--make-frame
                          (eq bufferlo-set-restore-tabs-reuse-init-frame
                              'reuse-reset-geometry))))
         (when-let* ((fg (alist-get 'bufferlo--frame-geometry tab-group)))
           (when (and
                  (display-graphic-p)
                  (memq bufferlo-set-restore-geometry-policy '(all tab-frames))
                  (or (not first-tab-frame)
                      (and first-tab-frame
                           (eq bufferlo-set-restore-tabs-reuse-init-frame
                               'reuse-reset-geometry))))
             (funcall bufferlo-set-frame-geometry-function fg)))
         (when-let* ((tbm-names (alist-get 'bufferlo--tbms tab-group)))
           (let ((bufferlo-bookmark-tab-replace-policy 'replace)
                 (tab-bar-new-tab-choice t)
                 (first-tab
                  (or (not first-tab-frame)
                      (and first-tab-frame
                           (not bufferlo-set-restore-tabs-reuse-init-frame)))))
             (dolist (tbm-name tbm-names)
               (unless (and ignore-already-active
                            (member tbm-name already-abm-names))
                 (when-let* ((tbm-bookmark-record
                              (bufferlo--bookmark-get-bookmark tbm-name)))
                   (let ((orig-buffer (current-buffer)))
                     (unless first-tab
                       (tab-bar-new-tab-to))
                     ;; NOTE: bufferlo--bookmark-tab-handler disallows raise for
                     ;; embedded-tab to avoid selected frame/tab state issues
                     ;; Handler abort is non-nil.
                     (when (bufferlo--bookmark-tab-handler tbm-bookmark-record
                                                           'not-jump)
                       (if first-tab
                           (let ((switch-to-buffer-obey-display-actions))
                             (switch-to-buffer orig-buffer 'no-record
                                               'force-same-window))
                         (let (tab-bar-tab-prevent-close-functions)
                           (tab-bar-close-tab))))))
                 (setq first-tab nil)))))
         (setq first-tab-frame nil)))
      (select-frame-set-input-focus (selected-frame)))

    ;; Restore framesets (framesets can be nil despite readablep)
    (when-let* ((frameset (car (read-from-string frameset-str))))
      (unless (frameset-valid-p frameset)
        (error "Bufferlo bookmark set %s: invalid frameset"
               bookmark-name))
      (funcall bufferlo-frameset-restore-function frameset)
      (dolist (frame (frame-list))
        (with-selected-frame frame
          ;; 'bufferlo--frame-to-restore is a hint from
          ;; `bufferlo-frameset-restore-default'
          (when (frame-parameter nil 'bufferlo--frame-to-restore)
            (when-let* ((fbm-name (frame-parameter
                                   nil 'bufferlo--bookmark-frame-name))
                        (fbm-bookmark-record (bufferlo--bookmark-get-bookmark
                                              fbm-name)))
              (if (and ignore-already-active
                       (member fbm-name already-abm-names))
                  (delete-frame)
                (let ((bufferlo-bookmark-frame-load-make-frame nil)
                      (bufferlo-bookmark-frame-load-policy
                       'replace-frame-adopt-loaded-bookmark)
                      (bufferlo--bookmark-handler-no-message t))
                  ;; NOTE: bufferlo--bookmark-frame-handler disallows raise
                  ;; for frames in sets to avoid selected frame/tab state issues
                  ;; Handler abort is non-nil.
                  (if (bufferlo--bookmark-frame-handler fbm-bookmark-record
                                                        'not-jump)
                      (delete-frame)
                    (when (and
                           (display-graphic-p frame)
                           (memq bufferlo-set-restore-geometry-policy
                                 '(all frames)))
                      (when-let* ((fg (frame-parameter
                                       nil 'bufferlo--frame-geometry)))
                        (funcall bufferlo-set-frame-geometry-function fg)))
                    (set-frame-parameter nil 'bufferlo--frame-to-restore nil))
                  (select-frame-set-input-focus (selected-frame)))))))))

    ;; Add the set to the active list
    (push `(,bookmark-name (bufferlo-bookmark-names . ,bufferlo-bookmark-names))
          bufferlo--active-sets)

    (run-hook-with-args
     'bufferlo-bookmark-set-handler-functions
     bookmark-name
     bufferlo-bookmark-names)

    (unless (or no-message bufferlo--bookmark-handler-no-message)
      ;; Indicate bookmarks that were already active with an asterisk
      (message "Restored bufferlo bookmark set %s (%s)"
               bookmark-name
               (mapconcat (lambda (x)
                            (if (member x already-abm-names)
                                (concat "*" x)
                              x))
                          bufferlo-bookmark-names
                          ", ")))
    ;; Explicitly return success; abort returns non-nil
    nil))

;; We use a short name here as bookmark-bmenu-list hard codes width of 8 chars
(put #'bufferlo--bookmark-set-handler 'bookmark-handler-type "B-Set")
(put #'bufferlo--bookmark-set-handler 'bookmark-inhibit 'insert)

(defun bufferlo--set-save (bookmark-name active-bookmark-names active-bookmarks
                                         &optional no-overwrite no-message msg)
  "Save a bufferlo bookmark set for the specified active bookmarks.
Store the set in BOOKMARK-NAME for the named bookmarks in
ACTIVE-BOOKMARK-NAMES represented in ACTIVE-BOOKMARKS.

Frame bookmarks are stored with their geometry for optional
restoration.

Tab bookmarks are stored in groups associated with their current
frame.  New frames will be created to hold tab bookmarks in the
same grouping.  Order may not be preserved.  Tab frame geometry is
stored for optional restoration.

If NO-OVERWRITE is non-nil, record the new bookmark without throwing
away the old one.  NO-MESSAGE inhibits the save status message.  If MSG
is non-nil, it is added to the save message."
  (let* ((abms (seq-filter
                (lambda (x) (member (car x) active-bookmark-names))
                active-bookmarks))
         (tbms (seq-filter
                (lambda (x) (eq (alist-get 'type (cadr x)) 'tbm))
                abms))
         (tbm-frame-groups (seq-group-by
                            (lambda (x) (alist-get 'frame (cadr x)))
                            tbms))
         (fbms (seq-filter
                (lambda (x) (eq (alist-get 'type (cadr x)) 'fbm))
                abms))
         (fbm-frames (mapcar (lambda (x) (alist-get 'frame (cadr x))) fbms))
         (tabsets)
         (frameset))

    (when (= (length abms) 0)
      (user-error "Specify at least one active bufferlo bookmark"))

    (setq tabsets
          (mapcar (lambda (group)
                    (let ((tbm-frame (car group))
                          (tbm-names (nreverse (mapcar #'car (cdr group)))))
                      `((bufferlo--frame-geometry
                         . ,(funcall bufferlo-frame-geometry-function tbm-frame))
                        (bufferlo--tbms . ,tbm-names))))
                  tbm-frame-groups))

    (when fbm-frames
      ;; Set a flag we can use to identify restored frames (this
      ;; is removed in the handler during frame restoration). Save
      ;; frame geometries for more accurate restoration than
      ;; frameset-restore provides.
      ;;
      ;; Squirrel away 'bufferlo-bookmark-frame-name which we ask
      ;; frameset-save to filter out to avoid restored frames
      ;; being considered bookmarked as they need duplicate
      ;; detection.
      (dolist (frame fbm-frames)
        (set-frame-parameter frame 'bufferlo--frame-to-restore t)
        (set-frame-parameter frame 'bufferlo--frame-geometry
                             (funcall bufferlo-frame-geometry-function
                                      frame))
        (set-frame-parameter frame 'bufferlo--bookmark-frame-name
                             (frame-parameter frame
                                              'bufferlo-bookmark-frame-name)))
      ;; frameset-save squirrels away width/height text-pixels iff
      ;; fullscreen is not nil and frame-resize-pixelwise is t.
      (let ((frame-resize-pixelwise t))
        (setq frameset
              (frameset-save
               fbm-frames
               :app 'bufferlo
               :name bookmark-name
               :predicate (lambda (x)
                            (not (frame-parameter x 'parent-frame)))
               :filters
               (let ((filtered-alist
                      (copy-tree frameset-persistent-filter-alist)))
                 (mapc (lambda (sym)
                         (setf (alist-get sym filtered-alist) :never))
                       (seq-union bufferlo--frameset-save-filter
                                  bufferlo-frameset-save-filter))
                 filtered-alist)))))

    (bookmark-store bookmark-name
                    (bufferlo--bookmark-set-location
                     (bufferlo--bookmark-set-make
                      active-bookmark-names tabsets frameset))
                    no-overwrite)
    (unless no-message
      (message "Saved bookmark set `%s' containing: %s%s"
               bookmark-name
               (mapconcat #'identity active-bookmark-names ", ")
               (if msg msg "")))))

(defun bufferlo-set-save-interactive (bookmark-name
                                      &optional no-overwrite no-message)
  "Save a bufferlo bookmark set for selected active bookmarks.
Save the bookmark set under BOOKMARK-NAME.

Tab bookmarks are grouped based on their shared frame along with
the frame's geometry.

Frame bookmarks represent themselves.

If NO-OVERWRITE is non-nil, record the new bookmark without
throwing away the old one.  NO-MESSAGE inhibits the save status
message.

Warn if this bookmark will overwrite a tab or frame bookmark, and clear
them, if active, when overwriting."
  (interactive
   (list (completing-read
          "Save bufferlo bookmark set as: "
          (bufferlo--bookmark-get-names #'bufferlo--bookmark-set-handler)
          nil nil nil 'bufferlo-bookmark-set-history nil)))
  (bufferlo--warn)
  (catch :abort
    (let* ((tab-bm-names (bufferlo--bookmark-get-names
                          #'bufferlo--bookmark-tab-handler))
           (frame-bm-names (bufferlo--bookmark-get-names
                            #'bufferlo--bookmark-frame-handler))
           (is-tab-bm (member bookmark-name tab-bm-names))
           (is-frame-bm (member bookmark-name frame-bm-names))
           clear-active-tab-bm
           clear-active-frame-bm)

      (cond
       ;; Overwriting a tab bookmark of the same name?  If we proceed, and the
       ;; tab bookmark is active, mark it to deactivate, leaving its buffers
       ;; intact, and after we know the replacement bookmark will be saved.
       (is-tab-bm
        (if (y-or-n-p (format "Overwrite the bufferlo tab bookmark `%s'? "
                              bookmark-name))
            (setq clear-active-tab-bm
                  (assoc bookmark-name (bufferlo--active-bookmarks nil 'tbm)))
          (throw :abort t)))
       ;; Overwriting a frame bookmark of the same name?  If so, and the frame
       ;; bookmark is active, mark it to deactivate, leaving its buffers
       ;; intact, and after we know the replacement bookmark will be saved.
       (is-frame-bm
        (if (y-or-n-p (format "Overwrite the bufferlo frame bookmark `%s'? "
                              bookmark-name))
            (setq clear-active-frame-bm
                  (assoc bookmark-name (bufferlo--active-bookmarks nil 'fbm)))
          (throw :abort t))))

      ;; Confirm if the about-to-be set bookmark is contained in a set, as it
      ;; will not be loadable once converted.  (If this is a set, it will not
      ;; be in a set.)
      (when-let* ((containing-sets (bufferlo--sets-containing-bookmark
                                    bookmark-name)))
        (unless (y-or-n-p (format
                           "Warning: `%s' is contained in set(s) %s and will be unloadable; proceed? "
                           bookmark-name (mapconcat #'identity containing-sets ", ")))
          (throw :abort t)))

      (let* ((abms (bufferlo--active-bookmarks))
             (abm-names (mapcar #'car abms))
             ;; If we are about to overwrite a tab or frame bm, remove that
             ;; name from the list of bookmarks available for the new set.
             (abm-names (if (or is-tab-bm
                                is-frame-bm)
                            (remove bookmark-name abm-names)
                          abm-names))
             (comps (bufferlo--bookmark-completing-read-multiple
                     (format "Add bookmark(s) to %s: " bookmark-name) abm-names))
             msg)

        ;; Do not create an empty bookmark set.
        (when (not (length> comps 0))
          (message "Select at least one bookmark to create the set")
          (throw :abort t))

        (cl-labels
            ((msg-append (s) (setq msg (concat msg "; " s))))

          (cond
           ;; Clear the about-to-be overwritten tab bookmark.
           (clear-active-tab-bm
            (msg-append "cleared overwritten tab bookmark")
            (bufferlo--clear-tab-bookmarks-by-name bookmark-name))
           ;; Clear the about-to-be overwritten frame bookmark.
           (clear-active-frame-bm
            (msg-append "cleared overwritten frame bookmark")
            (bufferlo--clear-frame-bookmarks-by-name bookmark-name)))

          ;; Finally, save the bookmark, and replace the active bookmark.
          (bufferlo--set-save bookmark-name comps abms no-overwrite no-message msg)
          (setq bufferlo--active-sets
                (assoc-delete-all bookmark-name bufferlo--active-sets #'equal))
          (push
           `(,bookmark-name (bufferlo-bookmark-names . ,comps))
           bufferlo--active-sets))))))

(defun bufferlo--set-get-constituents (bsets abms)
  "Get the constituents of the given `bookmark-sets' from the list of bookmarks.
BSETS is a list of the requested sets and ABMS is a list of all bookmarks to
consider (usually all active bookmarks)."
  (let* ((abm-names (mapcar #'car abms))
         (abm-names (seq-mapcat
                     (lambda (set-name)
                       (seq-intersection
                        (alist-get 'bufferlo-bookmark-names
                                   (assoc set-name bufferlo--active-sets))
                        abm-names))
                     bsets)))
    (seq-uniq abm-names)))

(defun bufferlo--sets-containing-bookmark (bookmark-name)
  "Return a list of set bookmark names that contain BOOKMARK-NAME."
  (let (sets)
    (dolist (bookmark-set-name
             (bufferlo--bookmark-get-names #'bufferlo--bookmark-set-handler))
      (when-let* ((bookmark-record
                   (bufferlo--bookmark-get-bookmark bookmark-set-name)))
        (when (member bookmark-name
                      (alist-get 'bufferlo-bookmark-names bookmark-record))
          (push (car bookmark-record) sets))))
    sets))

(defun bufferlo-set-save-current-interactive ()
  "Save active constituents in selected `bookmark-sets'."
  (interactive)
  (bufferlo--warn)
  (let* ((candidates (mapcar #'car bufferlo--active-sets))
         (comps (bufferlo--bookmark-completing-read-multiple
                 "Select sets to save: "
                 candidates))
         (abms (bufferlo--active-bookmarks))
         (abm-names-to-save (bufferlo--set-get-constituents comps abms)))
    (bufferlo--bookmarks-save abm-names-to-save abms)))

(defun bufferlo-set-add-interactive (bookmark-name)
  "Select active bookmarks to add to an active bookmark set.
Amend the bookmark set BOOKMARK-NAME."
  (interactive
   (list (completing-read
          "Bookmark set to add to: "
          bufferlo--active-sets
          nil nil nil 'bufferlo-bookmark-set-history nil)))
  (bufferlo--warn)
  (let* ((abms (bufferlo--active-bookmarks))
         (abm-names
          (seq-difference
           (mapcar #'car abms)
           (bufferlo--set-get-constituents (list bookmark-name) abms)))
         (comps (bufferlo--bookmark-completing-read-multiple
                 (format "Add bookmark(s) to %s: " bookmark-name)
                 abm-names))
         (bookmark-names (append
                          comps
                          (alist-get
                           'bufferlo-bookmark-names
                           (assoc bookmark-name bufferlo--active-sets)))))
    (bufferlo--set-save bookmark-name bookmark-names abms)
    (setf (alist-get 'bufferlo-bookmark-names
                     (alist-get bookmark-name
                                bufferlo--active-sets nil nil #'equal))
          bookmark-names)))

(defun bufferlo-set-remove-interactive (bookmark-name)
  "Select active bookmarks to remove from an active bookmark set.
Amend the bookmark set BOOKMARK-NAME."
  (interactive
   (list (completing-read
          "Bookmark set to remove from: "
          bufferlo--active-sets
          nil nil nil 'bufferlo-bookmark-set-history nil)))
  (bufferlo--warn)
  (let* ((abms (bufferlo--active-bookmarks))
         (abm-names
          (bufferlo--set-get-constituents (list bookmark-name) abms))
         (comps (bufferlo--bookmark-completing-read-multiple
                 (format "Remove bookmark(s) from %s: " bookmark-name)
                 abm-names))
         (bookmark-names (seq-remove
                          (lambda (elt) (member elt comps))
                          abm-names)))
    (when (= (length bookmark-names) 0)
      (user-error "A bookmark set must retain at least one bookmark"))
    (bufferlo--set-save bookmark-name bookmark-names abms)
    (setf (alist-get 'bufferlo-bookmark-names
                     (alist-get bookmark-name
                                bufferlo--active-sets nil nil #'equal))
          bookmark-names)))

(defun bufferlo-set-load-interactive ()
  "Prompt for bufferlo set bookmarks to load."
  (interactive)
  (let ((current-prefix-arg '(64))) ; emulate C-u C-u C-u
    (call-interactively 'bufferlo-bookmarks-load-interactive)))

(defun bufferlo--set-clear-all ()
  "Clear all active `bookmark-sets'.
This does not close active frame and tab bookmarks."
  (setq bufferlo--active-sets nil))

(defun bufferlo--set-clear (names)
  "Clear active bookmarks set NAMES.
This does not close associated active frame and tab bookmarks."
  (mapc (lambda (x)
          (setq bufferlo--active-sets
                (assoc-delete-all x bufferlo--active-sets)))
        names))

(defun bufferlo-set-clear-interactive ()
  "Clear the specified `bookmark-sets'.
Do not close sets' associated bookmarks or kill buffers."
  (interactive)
  (bufferlo--warn)
  (let* ((candidates (mapcar #'car bufferlo--active-sets))
         (comps (bufferlo--bookmark-completing-read-multiple
                 "Select sets to clear: "
                 candidates)))
    (bufferlo--set-clear comps)))

(defun bufferlo-set-close-interactive ()
  "Close the specified `bookmark-sets'.
Close each set's associated bookmarks and kill their buffers."
  (interactive)
  (bufferlo--warn)
  (let* ((candidates (mapcar #'car bufferlo--active-sets))
         (comps (bufferlo--bookmark-completing-read-multiple
                 "Select sets to close/kill: "
                 candidates))
         (abms (bufferlo--active-bookmarks))
         (abm-names-to-close (bufferlo--set-get-constituents comps abms)))
    (bufferlo--close-active-bookmarks abm-names-to-close abms)
    (bufferlo--set-clear comps)))



(defvar-keymap bufferlo--set-list-mode-map
  :parent special-mode-map
  "<mouse-1>" #'bufferlo--set-list-raise-bookmark-mouse
  "RET"       #'bufferlo--set-list-raise-bookmark-kb)

(define-derived-mode bufferlo--set-list-mode special-mode "bufferlo-set-list"
  "Major mode for bufferlo set list."
  (setq-local help-at-pt-display-when-idle t)
  (help-at-pt-set-timer)
  (cursor-intangible-mode)
  (cursor-face-highlight-mode))

(defun bufferlo--set-list-raise-bookmark-mouse (event)
  "Handle mouse EVENT."
  (interactive "e")
  (when-let* ((pos (event-start event))
              (bname (get-text-property (posn-point pos) 'bookmark-name)))
    (quit-window)
    (bufferlo--bookmark-raise-by-name bname)))

(defun bufferlo--set-list-raise-bookmark-kb ()
  "Handle keyboard event."
  (interactive)
  (when-let* ((bname (get-text-property (point) 'bookmark-name)))
    (quit-window)
    (bufferlo--bookmark-raise-by-name bname)))

(defconst bufferlo--set-list-buffer-name " *bufferlo set list*")

(defun bufferlo-set-list-interactive ()
  "Enumerate the bookmarks in active `bookmark-sets'."
  (interactive)
  (bufferlo--warn)
  (let* ((candidates (mapcar #'car bufferlo--active-sets))
         (comps (bufferlo--bookmark-completing-read-multiple
                 "Select sets to enumerate: "
                 candidates)))
    (let ((abms (bufferlo--active-bookmarks)))
      (cl-labels
          ((intangible-text (&rest text)
             (let* ((text (mapconcat #'identity text))
                    (len (length text)))
               (add-text-properties 0 len
                                    (list
                                     'field t
                                     'rear-nonsticky t
                                     'front-sticky t
                                     'intangible t
                                     'cursor-intangible t
                                     'inhibit-isearch t)
                                    text)
               text)))
        (with-current-buffer (get-buffer-create bufferlo--set-list-buffer-name)
          (let ((buffer-undo-list t))
            (read-only-mode -1)
            (erase-buffer))
          (let ((start-point))
            (insert (intangible-text
                     "----- Bufferlo Bookmarks Sets -----"
                     "\n"
                     "(RET or mouse-1 to raise a bookmark, q to quit)"
                     "\n"
                     "\n"))
            (dolist (set-name (sort comps #'string<))
              (insert (intangible-text
                       (format-message "Set `%s':\n" set-name)))
              (unless start-point (setq start-point (1+ (point))))
              (dolist (bname (sort
                              (alist-get 'bufferlo-bookmark-names
                                         (assoc set-name bufferlo--active-sets))
                              #'string<))
                (when-let* ((abm (cadr (assoc bname abms))))
                  (let* ((type (alist-get 'type abm))
                         (frame (alist-get 'frame abm))
                         (fname (or (frame-parameter frame 'explicit-name)
                                    (frame-parameter frame 'name)))
                         (tab-number (alist-get 'tab-number abm))
                         (text (format "  %-20s %-8s %-25s %s"
                                       (truncate-string-to-width bname 20 nil nil t)
                                       (alist-get type bufferlo--bookmark-type-names)
                                       (truncate-string-to-width fname 25 nil nil t)
                                       (if tab-number
                                           (format "tab:%d" tab-number)
                                         "")))
                         (len (length text)))
                    (add-text-properties 0 len
                                         (list
                                          'bookmark-name bname
                                          'help-echo (format "RET or mouse-1: Raise bookmark %s" bname)
                                          'kbd-help nil ; nil to use help-echo text
                                          'mouse-face 'highlight
                                          'cursor-face 'region)
                                         text)
                    (insert text)
                    (insert (intangible-text "\n")))))
              (insert (intangible-text "\n")))
            (insert (intangible-text
                     "----- END -----"
                     "\n"))
            (bufferlo--set-list-mode)
            (goto-char start-point)
            (pop-to-buffer (current-buffer) nil 'norecord)))))))



(defun bufferlo--bookmark-get-names (&rest handlers)
  "Get the names of all existing bookmarks for HANDLERS."
  (bookmark-maybe-load-default-file)
  (mapcar
   #'car
   (seq-filter
    (lambda (bm)
      (memq (alist-get 'handler (cdr bm))
            (or handlers bufferlo--bookmark-handlers)))
    bookmark-alist)))

(defun bufferlo--current-tab ()
  "Get the current tab record."
  (tab-bar--current-tab-find))

(defun bufferlo--bookmark-tab-save (name &optional no-overwrite no-message msg)
"Save the current tab as a bookmark.
NAME is the bookmark's name.  If NO-OVERWRITE is non-nil, record
the new bookmark without throwing away the old one.  NO-MESSAGE
inhibits the save status message.  If MSG is non-nil, it is added
to the save message.

This function operates on the current frame and its current tab."
(bookmark-store name (bufferlo--bookmark-set-location
                      (bufferlo--bookmark-tab-make))
                no-overwrite)
(setf (alist-get 'bufferlo-bookmark-tab-name
                 (cdr (bufferlo--current-tab)))
      name)
(unless no-message
  (message "Saved bufferlo tab bookmark: %s%s" name (if msg msg ""))))

(defun bufferlo-bookmark-tab-save (name &optional no-overwrite no-message)
  "Save the current tab as a bookmark.
NAME is the bookmark's name.  If NO-OVERWRITE is non-nil, record
the new bookmark without throwing away the old one.  NO-MESSAGE
inhibits the save status message.

This function persists the current tab's state:
The resulting bookmark stores the window configuration and the local
buffer list of the current tab.  In addition, it saves the bookmark
state (not the contents) of the bookmarkable buffers in the tab's local
buffer list.

Use `bufferlo-bookmark-tab-in-bookmarked-frame-policy' to
influence how this function handles setting a tab bookmark in the
presence of a frame bookmark.  Using both together is allowed, but
is not recommended.

Warn if this bookmark will overwrite a set or frame bookmark, and clear
them, if active, when overwriting."
  (interactive
   (list (completing-read
          "Save bufferlo tab bookmark: "
          (bufferlo--bookmark-get-names #'bufferlo--bookmark-tab-handler)
          nil nil nil 'bufferlo-bookmark-tab-history
          (alist-get 'bufferlo-bookmark-tab-name (bufferlo--current-tab)))))
  (bufferlo--warn)
  (catch :abort
    (let* ((abm (assoc name (bufferlo--active-bookmarks)))
           (tbm (alist-get 'bufferlo-bookmark-tab-name
                           (tab-bar--current-tab-find)))
           (set-bm-names (bufferlo--bookmark-get-names
                          #'bufferlo--bookmark-set-handler))
           (frame-bm-names (bufferlo--bookmark-get-names
                            #'bufferlo--bookmark-frame-handler))
           (is-set-bm (member name set-bm-names))
           (is-frame-bm (member name frame-bm-names))
           clear-active-set-bm
           clear-active-frame-bm
           msg)

      (cond
       ;; Overwriting a set bookmark of the same name?  If so, and the set
       ;; bookmark is active, mark it to deactivate, leaving its bookmarks and
       ;; buffers intact, and after we know the replacement bookmark will be
       ;; saved.
       (is-set-bm
        (if (y-or-n-p (format "Overwrite the bufferlo set bookmark `%s'? " name))
            (setq clear-active-set-bm
                  (assoc name bufferlo--active-sets))
          (throw :abort t)))
       ;; Overwriting a frame bookmark of the same name?  If so, and the frame
       ;; bookmark is active, mark it to deactivate, leaving its buffers
       ;; intact, and after we know the replacement bookmark will be saved.
       (is-frame-bm
        (if (y-or-n-p (format "Overwrite the bufferlo frame bookmark `%s'? " name))
            (setq clear-active-frame-bm
                  (assoc name (bufferlo--active-bookmarks nil 'fbm)))
          (throw :abort t))))

      (cl-labels
          ((msg-append (s) (setq msg (concat msg "; " s))))

        ;; Only check policies when the bm is a tab bm, and not already
        ;; associated with this tab.
        (unless (or is-set-bm
                    is-frame-bm
                    (and
                     tbm
                     (equal tbm (car abm))))

          ;; Bookmark already loaded in another tab?
          (when abm
            (pcase (bufferlo--bookmark-get-duplicate-policy
                    name "tab" bufferlo-bookmark-tab-duplicate-policy 'save)
              ('allow)
              ('clear
               (bufferlo--clear-tab-bookmarks-by-name name))
              ('clear-warn
               (bufferlo--clear-tab-bookmarks-by-name name)
               (msg-append "cleared duplicate active tab bookmark"))
              ('ignore
               (throw :abort t))
              ('raise
               (bufferlo--bookmark-raise abm)
               (throw :abort t))))

          ;; Tab inside a frame bookmark?
          (when (frame-parameter nil 'bufferlo-bookmark-frame-name)
            (pcase (bufferlo--bookmark-tab-get-clear-policy 'save)
              ('allow)
              ('clear
               (set-frame-parameter nil 'bufferlo-bookmark-frame-name nil))
              ('clear-warn
               (set-frame-parameter nil 'bufferlo-bookmark-frame-name nil)
               (msg-append "cleared frame bookmark"))
              (_ ))))

        (cond
         ;; Clear the about-to-be overwritten set bookmark.
         (clear-active-set-bm
          (msg-append "cleared overwritten set bookmark")
          (bufferlo--clear-set-bookmarks-by-name name))
         ;; Clear the about-to-be overwritten frame bookmark.
         (clear-active-frame-bm
          (msg-append "cleared overwritten frame bookmark")
          (bufferlo--clear-frame-bookmarks-by-name name)))

        ;; Finally, save the bookmark
        (bufferlo--bookmark-tab-save name no-overwrite no-message msg)))))

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
          nil 'require-match nil 'bufferlo-bookmark-tab-history
          (alist-get 'bufferlo-bookmark-tab-name (bufferlo--current-tab)))))
  (bufferlo--warn)
  (when-let* ((bookmark-record (bufferlo--bookmark-get-bookmark name)))
    (bufferlo--bookmark-tab-handler bookmark-record 'not-jump)))

(defun bufferlo-bookmark-tab-save-current ()
  "Save the current tab to its associated bookmark.
The associated bookmark is determined by the name of the bookmark to
which the tab was last saved or (if not yet saved) from which it was
initially loaded.  Performs an interactive bookmark selection if no
associated bookmark exists."
  (interactive)
  (bufferlo--warn)
  (if-let* ((bm (alist-get 'bufferlo-bookmark-tab-name
                           (cdr (bufferlo--current-tab)))))
      (bufferlo--bookmark-tab-save bm)
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
  (if-let* ((bm (alist-get 'bufferlo-bookmark-tab-name
                           (cdr (bufferlo--current-tab)))))
      ;; On reload, always reuse the existing tab (don't make a new one)
      (let ((bufferlo-bookmark-tab-replace-policy 'replace)
            ;; The bookmark is detected as a duplicate bookmark, allow it here
            (bufferlo-bookmark-tab-duplicate-policy 'allow))
        (bufferlo-bookmark-tab-load bm))
    (call-interactively #'bufferlo-bookmark-tab-load)))

(defun bufferlo--clear-tab-bookmarks-by-name (bookmark-name)
  "Clear BOOKMARK-NAME tab bookmarks across all frames and their tabs."
  (dolist (frame (frame-list))
    (tab-bar-tabs-set
     (mapcar (lambda (tab)
               (let ((tbm (alist-get 'bufferlo-bookmark-tab-name tab)))
                 (if (and tbm (equal tbm bookmark-name))
                     (assq-delete-all 'bufferlo-bookmark-tab-name tab)
                   tab)))
             (funcall tab-bar-tabs-function frame))
     frame)))

(defun bufferlo--clear-frame-bookmarks-by-name (bookmark-name)
  "Clear BOOKMARK-NAME frame bookmarks across all frames."
  (dolist (frame (frame-list))
    (when (equal bookmark-name
                 (frame-parameter frame 'bufferlo-bookmark-frame-name))
      (set-frame-parameter frame 'bufferlo-bookmark-frame-name nil))))

(defun bufferlo--clear-set-bookmarks-by-name (bookmark-name)
  "Clear BOOKMARK-NAME set bookmark."
  (setq bufferlo--active-sets
        (assoc-delete-all bookmark-name bufferlo--active-sets #'equal)))

(defun bufferlo--bookmark-frame-save (name &optional no-overwrite no-message msg)
  "Save the current frame as a bookmark.
NAME is the bookmark's name.  If NO-OVERWRITE is non-nil, record
the new bookmark without throwing away the old one.  If NO-MESSAGE
is non-nil, inhibit the save status message.  If MSG is non-nil,
it is added to the save message."
  (bookmark-store name (bufferlo--bookmark-set-location
                        (bufferlo--bookmark-frame-make))
                  no-overwrite)
  (set-frame-parameter nil 'bufferlo-bookmark-frame-name name)
  (unless no-message
    (message "Saved bufferlo frame bookmark: %s%s" name (if msg msg ""))))

(defun bufferlo-bookmark-frame-save (name &optional no-overwrite no-message)
  "Save the current frame as a bookmark.
NAME is the bookmark's name.  If NO-OVERWRITE is non-nil, record
the new bookmark without throwing away the old one.  If NO-MESSAGE
is non-nil, inhibit the save status message.

This function persists the current frame's state: The resulting bookmark
stores the frame's window configurations, active tabs, and the local
buffer lists those tabs.  In addition, it saves the bookmark state (not
the contents) of the bookmarkable buffers for each tab.

Use `bufferlo-bookmark-tab-in-bookmarked-frame-policy' to
influence how this function handles setting a frame bookmark in
the presence of bookmarked tabs.  Using both together is allowed,
but is not recommended.

Warn if this bookmark will overwrite a set or tab bookmark, and clear
them, if active, when overwriting."
  (interactive
   (list (completing-read
          "Save bufferlo frame bookmark: "
          (bufferlo--bookmark-get-names #'bufferlo--bookmark-frame-handler)
          nil nil nil 'bufferlo-bookmark-frame-history
          (frame-parameter nil 'bufferlo-bookmark-frame-name))))
  (bufferlo--warn)
  (catch :abort
    (let* ((abm (assoc name (bufferlo--active-bookmarks)))
           (fbm (frame-parameter nil 'bufferlo-bookmark-frame-name))
           (set-bm-names (bufferlo--bookmark-get-names
                          #'bufferlo--bookmark-set-handler))
           (tab-bm-names (bufferlo--bookmark-get-names
                          #'bufferlo--bookmark-tab-handler))
           (is-set-bm (member name set-bm-names))
           (is-tab-bm (member name tab-bm-names))
           clear-active-set-bm
           clear-active-tab-bm
           msg)

      (cond
       ;; Overwriting a set bookmark of the same name?  If so, and the set
       ;; bookmark is active, mark it to deactivate, leaving its bookmarks and
       ;; buffers intact, and after we know the replacement bookmark will be
       ;; saved.
       (is-set-bm
        (if (y-or-n-p (format "Overwrite the bufferlo set bookmark `%s'? " name))
            (setq clear-active-set-bm
                  (assoc name bufferlo--active-sets))
          (throw :abort t)))
       ;; Overwriting a tab bookmark of the same name?  If so, and the tab
       ;; bookmark is active, mark it to deactivate, leaving its buffers
       ;; intact, and after we know the replacement bookmark will be saved.
       (is-tab-bm
        (if (y-or-n-p (format "Overwrite the bufferlo tab bookmark `%s'? " name))
            (setq clear-active-tab-bm
                  (assoc name (bufferlo--active-bookmarks nil 'tbm)))
          (throw :abort t))))

      (cl-labels
          ((msg-append (s) (setq msg (concat msg "; " s))))

        ;; Only check policies when bm is a frame bm, and is not already
        ;; associated with this frame.
        (unless (or is-set-bm
                    is-tab-bm
                    (and
                     fbm
                     (equal fbm (car abm))))

          ;; Bookmark already loaded in another frame?
          (when abm
            (pcase (bufferlo--bookmark-get-duplicate-policy
                    name "frame" bufferlo-bookmark-frame-duplicate-policy 'save)
              ('allow)
              ('clear
               (bufferlo--clear-frame-bookmarks-by-name name))
              ('clear-warn
               (bufferlo--clear-frame-bookmarks-by-name name)
               (msg-append "cleared duplicate active frame bookmark"))
              ('ignore
               (throw :abort t))
              ('raise
               (bufferlo--bookmark-raise abm)
               (throw :abort t))))

          ;; Tab bookmarks in this frame?
          (when (> (length
                    (bufferlo--active-bookmarks (list (selected-frame)) 'tbm))
                   0)
            (pcase (bufferlo--bookmark-tab-get-clear-policy 'save-frame)
              ('clear
               (let ((current-prefix-arg '(4))) ; emulate C-u
                 (bufferlo-clear-active-bookmarks (list (selected-frame)))))
              ('clear-warn
               (let ((current-prefix-arg '(4))) ; emulate C-u
                 (bufferlo-clear-active-bookmarks (list (selected-frame))))
               (msg-append "cleared tab bookmarks"))
              ('allow))))

        (cond
         ;; Clear the about-to-be overwritten set bookmark.
         (clear-active-set-bm
          (msg-append "cleared overwritten set bookmark")
          (bufferlo--clear-set-bookmarks-by-name name))
         ;; Clear the about-to-be overwritten tab bookmark.
         (clear-active-tab-bm
          (msg-append "cleared overwritten tab bookmark")
          (bufferlo--clear-tab-bookmarks-by-name name)))

        ;; Finally, save the bookmark
        (bufferlo--bookmark-frame-save name no-overwrite no-message msg)))))

(defun bufferlo-bookmark-frame-load (name)
  "Load a frame bookmark.
NAME is the bookmark's name.
Replace the current frame's state if
`bufferlo-bookmark-frame-load-make-frame' is nil."
  (interactive
   (list (completing-read
          "Load bufferlo frame bookmark: "
          (bufferlo--bookmark-get-names #'bufferlo--bookmark-frame-handler)
          nil 'require-match nil 'bufferlo-bookmark-frame-history
          (frame-parameter nil 'bufferlo-bookmark-frame-name))))
  (bufferlo--warn)
  (when-let* ((bookmark-record (bufferlo--bookmark-get-bookmark name)))
    (bufferlo--bookmark-frame-handler bookmark-record 'not-jump)))

(defun bufferlo-bookmark-frame-save-current ()
  "Save the current frame to its associated bookmark.
The associated bookmark is determined by the name of the bookmark to
which the frame was last saved or (if not yet saved) from which it was
initially loaded.  Performs an interactive bookmark selection if no
associated bookmark exists."
  (interactive)
  (bufferlo--warn)
  (if-let* ((bm (frame-parameter nil 'bufferlo-bookmark-frame-name)))
      (bufferlo--bookmark-frame-save bm)
    (call-interactively #'bufferlo-bookmark-frame-save)))

(defun bufferlo-bookmark-frame-load-current ()
  "Load the current frame's associated bookmark.
The associated bookmark is determined by the name of the bookmark to
which the frame was last saved or (if not yet saved) from which it was
initially loaded.  Performs an interactive bookmark selection if no
associated bookmark exists."
  (interactive)
  (bufferlo--warn)
  (if-let* ((bm (frame-parameter nil 'bufferlo-bookmark-frame-name)))
      ;; On reload, always resue the existing frame (don't make a new one)
      (let ((bufferlo-bookmark-frame-load-make-frame nil)
            (bufferlo-bookmark-frame-load-policy
             'replace-frame-retain-current-bookmark)
            ;; The bookmark is detected as a duplicate bookmark, allow it here
            (bufferlo-bookmark-frame-duplicate-policy 'allow))
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
    ((type . type) (frame . frame) (tab-number . tab-number))) ...)
for the specified FRAMES,
filtered by TYPE, where type is:
\\='fbm for frame bookmarks which include frame only or
\\='tbm for tab bookmarks which include frame and tab numbers."
  (let ((abms))
    (dolist (frame (or frames (frame-list)))
      (when-let* ((fbm (frame-parameter frame 'bufferlo-bookmark-frame-name)))
        (when (or (null type) (eq type 'fbm))
          (push (list fbm `((type . fbm)
                            (frame . ,frame)))
                abms)))
      (let ((tabs (funcall tab-bar-tabs-function frame)))
        (dolist (tab tabs)
          (when-let* ((tbm (alist-get 'bufferlo-bookmark-tab-name tab)))
            (when (or (null type) (eq type 'tbm))
              (push (list tbm `((type . tbm)
                                (frame . ,frame)
                                (tab-number . ,(1+ (tab-bar--tab-index
                                                    tab tabs frame)))))
                    abms))))))
    abms))

(defun bufferlo-bookmarks-save-all-p (_bookmark-name)
  "This predicate matches all bookmark names.
This is intended to be used in `bufferlo-bookmarks-save-predicate-functions'."
  t)

(defun bufferlo-bookmarks-load-all-p (_bookmark-name)
  "This predicate matches all bookmark names.
This is intended to be used in `bufferlo-bookmarks-load-predicate-functions'."
  t)

(defun bufferlo--active-bookmark-duplicates ()
  "Produce a list of duplicated active bookmark names."
  (let ((abm-names (mapcar #'car (bufferlo--active-bookmarks))))
    (seq-filter (lambda (abm)
                  (> (seq-count (lambda (x) (equal x abm)) abm-names) 1))
                (seq-uniq abm-names))))

(defun bufferlo--list-duplicates (lst)
  "Return unique duplicate elements from LST.
Equality test is \\='equal."
  (let ((ht (make-hash-table :test 'equal :size (length lst))))
    (mapc (lambda (x) (puthash x (if (gethash x ht) 'dupe t) ht)) lst)
    (seq-uniq
     (delq nil
           (mapcar (lambda (x) (when (eq (gethash x ht) 'dupe) x)) lst)))))

(defun bufferlo--bookmarks-save (active-bookmark-names active-bookmarks &optional no-message)
  "Save the bookmarks in ACTIVE-BOOKMARK-NAMES indexed by ACTIVE-BOOKMARKS.
Specify NO-MESSAGE to inhibit the bookmark save status message."
  (let (bookmarks-saved)
    ;; Offer to reload before we update bookmark entries.  NOTE: There is
    ;; still a potential race condition if the bookmark file changes via
    ;; another process during this loop and the user will be prompted below
    ;; when `bookmark-save' is called so we inhibit loading again around that
    ;; call.
    (bookmark-maybe-load-default-file)
    ;; Inhibit built-in bookmark file saving and reloading until we're done.
    (let (bookmark-save-flag
          bookmark-watch-bookmark-file)
      (dolist (abm-name active-bookmark-names)
        (when-let* ((abm (assoc abm-name active-bookmarks))
                    (abm-type (alist-get 'type (cadr abm)))
                    (abm-frame (alist-get 'frame (cadr abm))))
          (with-selected-frame abm-frame
            (cond
             ((eq abm-type 'fbm)
              (bufferlo--bookmark-frame-save abm-name nil t))
             ((eq abm-type 'tbm)
              (let ((orig-tab-number (1+ (tab-bar--current-tab-index)))
                    tab-bar-tab-post-select-functions)
                (tab-bar-select-tab (alist-get 'tab-number (cadr abm)))
                (bufferlo--bookmark-tab-save abm-name nil t)
                (tab-bar-select-tab orig-tab-number))))
            (push abm-name bookmarks-saved)))))
    (cond
     (bookmarks-saved
      (let ((inhibit-message (or no-message
                                 (not (memq bufferlo-bookmarks-auto-save-messages
                                            (list 'saved t))))))
        (let (bookmark-watch-bookmark-file ; see NOTE: above
              (start-time (current-time)))
          (bookmark-save)
          (message "Saved bufferlo bookmarks: %s, in %.2f second(s)"
                   (mapconcat 'identity bookmarks-saved ", ")
                   (float-time (time-subtract (current-time) start-time))))))
     (t
      (when (and (not no-message)
                 (memq bufferlo-bookmarks-auto-save-messages
                       (list 'notsaved t)))
        (message "No bufferlo bookmarks saved."))))))

(defun bufferlo-bookmarks-save (&optional all)
  "Save active bufferlo bookmarks.
This is invoked via an optional timer which runs according to
`bufferlo-bookmarks-auto-save-interval', or and is optionally invoked at
Emacs exit.

You may invoke this manually at any time to save active bookmarks;
however, doing so does not reset the save interval timer.

Each bookmark is filtered according to
`bufferlo-bookmarks-save-predicate-functions'.

Specify ALL to ignore the predicates and save every active bufferlo
bookmark or use a prefix argument across ALL frames, overriding
`bufferlo-bookmarks-save-frame-policy'.

Note: If there are duplicate active bufferlo bookmarks, the last one to
be saved will take precedence.

Duplicate bookmarks are handled according to
`bufferlo-bookmarks-save-duplicates-policy'."
  (interactive)
  (unwind-protect ; restart the timer in case the user quits any prompts
      (catch :abort
        (let* ((frames (if all
                           (frame-list)
                         (pcase bufferlo-bookmarks-save-frame-policy
                           ('current
                            (list (selected-frame)))
                           ('other
                            (seq-filter (lambda (x) (not (eq x (selected-frame))))
                                        (frame-list)))
                           (_ (frame-list)))))
               ;; Get the active bookmarks for the frames captured by the current
               ;; bufferlo-bookmarks-save-frame-policy only
               (abms (bufferlo--active-bookmarks frames))

               ;; Override bufferlo-bookmarks-save-predicate-functions on prefix arg
               (bufferlo-bookmarks-save-predicate-functions
                (if (or all (consp current-prefix-arg))
                    (list #'bufferlo-bookmarks-save-all-p)
                  bufferlo-bookmarks-save-predicate-functions))

               ;; Filter the bookmark names to save
               (abm-names-to-save
                (seq-filter (lambda (x) (not (null x)))
                            (mapcar
                             (lambda (abm)
                               (let ((abm-name (car abm)))
                                 (when (run-hook-with-args-until-success
                                        'bufferlo-bookmarks-save-predicate-functions
                                        abm-name)
                                   abm-name)))
                             abms)))

               ;; There may be open bookmarks that are duplicates
               (dupes-to-save (bufferlo--list-duplicates abm-names-to-save))
               ;; We'll handle these bookmarks according to the duplicate-policy
               (duplicate-policy bufferlo-bookmarks-save-duplicates-policy))

          (when (> (length dupes-to-save) 0)
            (when (eq duplicate-policy 'prompt)
              (pcase (with-local-quit
                       (read-answer
                        (format "Duplicate active bookmarks %s: Allow to save, Disallow to cancel "
                                dupes-to-save)
                        '(("allow" ?a "Allow duplicate")
                          ("disallow" ?d "Disallow duplicates; cancel saving")
                          ("help" ?h "Help")
                          ("quit" ?q "Quit with no changes"))))
                ("allow" (setq duplicate-policy 'allow))
                ("disallow" (setq duplicate-policy 'disallow))
                (_ (throw :abort t))))
            (pcase duplicate-policy
              ('allow)
              (_ (throw :abort t))))

          (bufferlo--bookmarks-save abm-names-to-save abms)))
    ;; Run the timer again only after this function is complete to avoid race
    ;; conditions with user prompts.
    (bufferlo--bookmarks-auto-save-timer-maybe-start)))

(defun bufferlo-bookmark--frame-save-on-delete (frame)
  "`frame-delete' advice for saving the current frame bookmark on deletion.
FRAME is the frame being deleted."
  (let ((fbm (frame-parameter frame 'bufferlo-bookmark-frame-name)))
    (pcase bufferlo-bookmark-frame-save-on-delete
      ('t
       (when (y-or-n-p (if fbm
                           (format-message "Save frame bookmark `%s'? " fbm)
                         "Save new frame bookmark? "))
         (bufferlo-bookmark-frame-save-current)))
      ('when-bookmarked
       (when fbm (bufferlo--bookmark-frame-save fbm))))))

(defun bufferlo-bookmark--tab-save-on-close (tab _only)
  "Function for saving the current tab bookmark on deletion.
Intended as a hook function for `tab-bar-tab-pre-close-functions'.
TAB is the tab being closed.  _ONLY is for compatibility with the hook."
  (let ((tbm (alist-get 'bufferlo-bookmark-tab-name tab)))
    (pcase bufferlo-bookmark-tab-save-on-close
      ('t
       (when (y-or-n-p (if tbm
                           (format-message "Save tab bookmark `%s'? " tbm)
                         "Save new tab bookmark? "))
         (bufferlo-bookmark-tab-save-current)))
      ('when-bookmarked
       (when tbm (bufferlo--bookmark-tab-save tbm))))))

(defun bufferlo--bookmarks-save-at-emacs-exit ()
  "Save bufferlo bookmarks at Emacs exit.
This honors `bufferlo-bookmarks-save-at-emacs-exit' by predicate or
\\='all.  Intended to be invoked via `kill-emacs-hook'."
  (bufferlo--bookmarks-auto-save-timer-maybe-cancel)
  (let ((bufferlo-bookmarks-save-predicate-functions
         (if (eq bufferlo-bookmarks-save-at-emacs-exit 'all)
             (list #'bufferlo-bookmarks-save-all-p)
           bufferlo-bookmarks-save-predicate-functions)))
    (bufferlo-bookmarks-save)))

(defun bufferlo--bookmarks-load-startup ()
  "Load bookmarks at startup."
  (let ((bufferlo-bookmarks-load-tabs-make-frame
         bufferlo-bookmarks-load-at-emacs-startup-tabs-make-frame))
    (run-with-idle-timer 0 nil (lambda ()
                                 (bufferlo-bookmarks-load
                                  (eq bufferlo-bookmarks-load-at-emacs-startup
                                      'all))))))

(defun bufferlo-bookmarks-load (&optional all)
  "Load stored bufferlo bookmarks.
Invoke manually or via `window-setup-hook' to restore bookmarks
at Emacs startup.

Each bookmark is filtered according to
`bufferlo-bookmarks-load-predicate-functions'.

ALL, or a prefix argument, ignores the load predicates and loads
all stored bufferlo bookmarks.  Tab bookmarks are loaded into the
current or new frame according to
`bufferlo-bookmarks-load-tabs-make-frame'."
  (interactive)
  (let* ((bookmarks-loaded nil)
         (bookmarks-failed nil)
         (start-time (current-time))
         (orig-frame (selected-frame))
         ;; NOTE: We might need a policy that controls how strict or
         ;; lax bulk bookmark loading can be. Via below, users get what
         ;; they implicitly ask for by loading all bookmarks.
         (bufferlo-bookmark-frame-duplicate-policy 'allow)
         (bufferlo-bookmark-tab-duplicate-policy 'allow)
         (bufferlo-bookmark-tab-in-bookmarked-frame-policy 'allow)
         (bufferlo-bookmarks-load-predicate-functions
          (if (or all (consp current-prefix-arg))
              (list #'bufferlo-bookmarks-load-all-p)
            bufferlo-bookmarks-load-predicate-functions))
         ;; Reset current-prefix-arg to allow
         ;; `bufferlo--bookmark-frame-handler' to create frames should
         ;; that policy be set to do so.
         (current-prefix-arg nil))

    ;; Load bookmark sets
    (dolist (bookmark-name (bufferlo--bookmark-get-names
                            #'bufferlo--bookmark-set-handler))
      (unless (assoc bookmark-name bufferlo--active-sets)
        (when (run-hook-with-args-until-success
               'bufferlo-bookmarks-load-predicate-functions bookmark-name)
          (when-let* ((bookmark-record
                       (bufferlo--bookmark-get-bookmark bookmark-name)))
            (if (bufferlo--bookmark-set-handler bookmark-record 'not-jump)
                (push bookmark-name bookmarks-failed)
              (push bookmark-name bookmarks-loaded))))))

    ;; Load tab bookmarks, making a new frame, if required (the
    ;; geometry of which is via the user's default-frame-alist)
    (select-frame orig-frame) ; default frame for tabs
    ;; We handle making tabs in this loop manually
    (let ((bufferlo-bookmark-tab-replace-policy 'replace)
          (tab-bar-new-tab-choice t)
          (new-tab-frame nil))
      (dolist (bookmark-name (bufferlo--bookmark-get-names
                              #'bufferlo--bookmark-tab-handler))
        (unless (assoc bookmark-name (bufferlo--active-bookmarks))
          (when (run-hook-with-args-until-success
                 'bufferlo-bookmarks-load-predicate-functions bookmark-name)
            (if (and bufferlo-bookmarks-load-tabs-make-frame
                     (not new-tab-frame))
                (select-frame (setq new-tab-frame (make-frame)))
              (tab-bar-new-tab-to))
            (when-let* ((bookmark-record
                         (bufferlo--bookmark-get-bookmark bookmark-name)))
              (if (bufferlo--bookmark-tab-handler bookmark-record 'not-jump)
                  (push bookmark-name bookmarks-failed)
                (push bookmark-name bookmarks-loaded)))))))

    ;; Load frame bookmarks
    (dolist (bookmark-name (bufferlo--bookmark-get-names
                            #'bufferlo--bookmark-frame-handler))
      (unless (assoc bookmark-name (bufferlo--active-bookmarks))
        (when (run-hook-with-args-until-success
               'bufferlo-bookmarks-load-predicate-functions bookmark-name)
          (when-let* ((bookmark-record
                       (bufferlo--bookmark-get-bookmark bookmark-name)))
            (if (bufferlo--bookmark-frame-handler bookmark-record 'not-jump)
                (push bookmark-name bookmarks-failed)
              (push bookmark-name bookmarks-loaded))))))

    ;; Leave the user on the starting frame
    (select-frame-set-input-focus orig-frame)
    (when bookmarks-loaded
      (message "Loaded bufferlo bookmarks: %s, in %.2f seconds%s"
               (mapconcat #'identity bookmarks-loaded ", ")
               (float-time (time-subtract (current-time) start-time))
               (if bookmarks-failed
                   (concat "; failed to load: "
                           (mapconcat #'identity bookmarks-failed ", "))
                 "")))))

;; TODO: handle option to save? prefix arg to save or not save?
(defun bufferlo-bookmarks-close-interactive ()
  "Prompt for active bufferlo bookmarks to close."
  (interactive)
  (bufferlo--warn)
  (let* ((abms (bufferlo--active-bookmarks))
         (abm-names (mapcar #'car abms))
         (comps (bufferlo--bookmark-completing-read-multiple
                 "Close bookmark(s) without saving: " abm-names)))
    (bufferlo--close-active-bookmarks comps abms)))

(defun bufferlo-bookmarks-save-interactive ()
  "Prompt for active bufferlo bookmarks to save."
  (interactive)
  (bufferlo--warn)
  (let* ((abms (bufferlo--active-bookmarks))
         (abm-names (mapcar #'car abms))
         (comps (bufferlo--bookmark-completing-read-multiple
                 "Save bookmark(s): " abm-names)))
    (bufferlo--bookmarks-save comps abms)))

(defun bufferlo-bookmarks-load-interactive ()
  "Prompt for bufferlo bookmarks to load.
Use a single prefix argument to narrow the candidates to frame
bookmarks, double for bookmarks, triple for bookmark sets."
  (interactive)
  (bufferlo--warn)
  (let* ((bookmark-names
          (apply 'bufferlo--bookmark-get-names
                 (cond
                  ((and (consp current-prefix-arg)
                        (= (prefix-numeric-value current-prefix-arg) 4))
                   (list #'bufferlo--bookmark-frame-handler))
                  ((and (consp current-prefix-arg)
                        (= (prefix-numeric-value current-prefix-arg) 16))
                   (list #'bufferlo--bookmark-tab-handler))
                  ((and (consp current-prefix-arg)
                        (= (prefix-numeric-value current-prefix-arg) 64))
                   (list #'bufferlo--bookmark-set-handler))
                  (t bufferlo--bookmark-handlers))))
         (comps (bufferlo--bookmark-completing-read-multiple
                 "Load bookmark(s): "
                 bookmark-names)))
    (dolist (bookmark-name comps)
      (when-let* ((bookmark-record
                   (bufferlo--bookmark-get-bookmark bookmark-name))
                  (bookmark-handler (bookmark-get-handler bookmark-record)))
        (funcall bookmark-handler bookmark-record 'not-jump)))))

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
         (tbm (alist-get 'bufferlo-bookmark-tab-name
                         (tab-bar--current-tab-find)))
         (duplicate-fbm (> (length (seq-filter
                                    (lambda (x) (equal fbm (car x)))
                                    (bufferlo--active-bookmarks nil 'fbm)))
                           1))
         (duplicate-tbm (> (length (seq-filter
                                    (lambda (x) (equal tbm (car x)))
                                    (bufferlo--active-bookmarks nil 'tbm)))
                           1)))
    (when (or force (consp current-prefix-arg) duplicate-fbm)
      (set-frame-parameter nil 'bufferlo-bookmark-frame-name nil))
    (when (or force (consp current-prefix-arg) duplicate-tbm)
      (setf (alist-get 'bufferlo-bookmark-tab-name
                       (cdr (bufferlo--current-tab)))
            nil))))

(defun bufferlo-clear-active-bookmarks (&optional frames)
  "Clear all active bufferlo frame and tab bookmarks.
This leaves all content untouched and does not impact stored bookmarks.

You will be prompted to confirm clearing (it cannot be undone)
unless a prefix argument is specified.

This is useful when you have accumulated a complex working set of
frames, tabs, buffers and want to save new bookmarks without
disturbing existing bookmarks, or where auto-saving is enabled
and you want to avoid overwriting stored bookmarks, perhaps with
transient work.

FRAMES is an optional list of frames on which to clear bookmarks
which defaults to all frames, if not specified."
  (interactive)
  (when (or (consp current-prefix-arg)
            (y-or-n-p "Clear active bufferlo bookmarks? "))
    (dolist (frame (or frames (frame-list)))
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
         (orig-frame (selected-frame)))
    ;; Close tab bookmarks.
    (let ((tab-bar-tab-post-select-functions))
      ;; We can't rely on tab names (they don't have to be unique) or tab
      ;; numbers to uniquely identify them (because they may change when other
      ;; tabs close), so we assign unique tags for the second pass, below.
      ;; They are removed in that pass.  If the user quits when prompted, the
      ;; tags are cleared on all tabs before being reassigned in the first
      ;; pass..
      ;;
      ;; Clear any lingering tab tags on bookmarked tabs.
      (dolist (frame (frame-list))
        (dolist (tab (funcall tab-bar-tabs-function frame))
          (when (alist-get 'bufferlo-bookmark-tab-name tab)
            (setf (alist-get 'bufferlo--tab-tag (cdr tab)) nil))))
      ;; Now assign fresh tab tags.
      (let ((tab-tag 0))
        (dolist (tbm tbms)
          (let ((tbm-frame (alist-get 'frame (cadr tbm)))
                (tbm-tab-number (alist-get 'tab-number (cadr tbm))))
            (with-selected-frame tbm-frame
              (tab-bar-select-tab tbm-tab-number)
              (setf (alist-get 'bufferlo--tab-tag (cadr tbm))
                    tab-tag)
              (setf (alist-get 'bufferlo--tab-tag (cdr (bufferlo--current-tab)))
                    tab-tag)))
          (setq tab-tag (1+ tab-tag))))
      ;; Use the tab tags to uniquely identify tabs to close.
      (dolist (tbm tbms)
        (let ((tbm-frame (alist-get 'frame (cadr tbm)))
              (tab-tag (alist-get 'bufferlo--tab-tag (cadr tbm))))
          (with-selected-frame tbm-frame
            ;; If called in a batch, raise frame in case of prompts for buffers
            ;; that need saving:
            (select-frame-set-input-focus (selected-frame))
            (when (catch :found ; catch exits with the matching tag tab selected
                    (let ((i 1)) ; tab-number is 1-based
                      (dolist (tab (funcall tab-bar-tabs-function))
                        (tab-bar-select-tab i)
                        (when-let* ((tag (alist-get 'bufferlo--tab-tag tab)))
                          (when (= tag tab-tag)
                            (setq tab (assq-delete-all 'bufferlo--tab-tag tab))
                            (throw :found i)))
                        (setq i (1+ i)))
                      nil))
              (let ((bufferlo-kill-buffers-prompt nil)
                    (bufferlo-bookmark-tab-save-on-close nil)
                    (bufferlo-close-tab-kill-buffers-prompt nil))
                (bufferlo-tab-close-kill-buffers)))))))
    ;; Close frame bookmarks.
    (dolist (fbm fbms)
      (let ((fbm-frame (alist-get 'frame (cadr fbm))))
        (with-selected-frame fbm-frame
          (let ((bufferlo-kill-buffers-prompt nil)
                (bufferlo-bookmark-frame-save-on-delete nil)
                (bufferlo-delete-frame-kill-buffers-prompt nil))
            (bufferlo-delete-frame-kill-buffers)))))
    ;; Restore the original frame, if possible, in case any frames changed
    ;; during user prompts.
    (when (frame-live-p orig-frame)
      (select-frame-set-input-focus orig-frame))))

(defun bufferlo-bookmarks-close ()
  "Close all active bufferlo frame and tab bookmarks and kill their buffers.
Bufferlo bookmark sets are cleared.

You will be prompted to save bookmarks using filter predicates or
save all.

A prefix argument inhibits the prompt and bypasses saving."
  (interactive)
  (bufferlo--warn)
  (let* ((close t)
         (abms (bufferlo--active-bookmarks))
         (abm-names (mapcar #'car abms)))
    (if (null abms)
        (message "No active bufferlo bookmarks")
      (unless (consp current-prefix-arg)
        (pcase (with-local-quit
                 (read-answer
                  "Save bookmarks before closing them: All, Predicate, No save "
                  '(("all" ?a "Save all active bookmarks")
                    ("pred" ?p "Save predicate-filtered bookmarks, if set")
                    ("nosave" ?n "Don't save")
                    ("help" ?h "Help")
                    ("quit" ?q "Quit"))))
          ("all"
           (bufferlo-bookmarks-save 'all))
          ("pred"
           (bufferlo-bookmarks-save))
          ("nosave")
          (_ (setq close nil))))
      (when close
        (bufferlo--close-active-bookmarks abm-names abms)
        (bufferlo--set-clear-all)))))

(defun bufferlo--bookmark-raise (abm)
  "Raise ABM's frame/tab."
  (when-let* ((abm-type (alist-get 'type (cadr abm)))
              (abm-frame (alist-get 'frame (cadr abm))))
    (with-selected-frame abm-frame
      (select-frame-set-input-focus (selected-frame))
      (when (eq abm-type 'tbm)
        (tab-bar-select-tab
         (alist-get 'tab-number (cadr abm)))))))

(defun bufferlo--bookmark-raise-by-name (abm-name &optional abms)
  "Raise bookmark's frame/tab by ABM-NAME in ABMS."
  (setq abms (or abms (bufferlo--active-bookmarks)))
  (when-let* ((abm (assoc abm-name abms)))
    (bufferlo--bookmark-raise abm)))

(defun bufferlo-bookmark-raise ()
  "Raise the selected bookmarked frame or tab.
Note: If there are duplicated bookmarks, the first one found is
raised."
  (interactive)
  (bufferlo--warn)
  (let* ((abms (bufferlo--active-bookmarks))
         (abm-names (mapcar #'car abms))
         (comp (bufferlo--bookmark-completing-read
                "Select a bookmark to raise: " abm-names)))
    (bufferlo--bookmark-raise-by-name comp abms)))

;; DWIM convenience functions

(defun bufferlo-bookmark-save-current ()
  "DWIM save current bufferlo bookmark.
Save the current bufferlo frame bookmark or tab bookmark,
prioritizing frame bookmarks over tab bookmarks, should both
exist.

Unlike `bufferlo-bookmark-frame-save-current' and
`bufferlo-bookmark-tab-save-current', this does not prompt to
save a new bookmark."
  (interactive)
  (bufferlo--warn)
  (if-let* ((bm (frame-parameter nil 'bufferlo-bookmark-frame-name)))
      (bufferlo-bookmark-frame-save bm)
    (if-let* ((bm (alist-get 'bufferlo-bookmark-tab-name
                             (cdr (bufferlo--current-tab)))))
        (bufferlo--bookmark-tab-save bm)
      (message "No active bufferlo frame or tab bookmark to save."))))

(defun bufferlo-bookmark-load-current ()
  "DWIM reload current bufferlo bookmark.
Load the current bufferlo frame bookmark or tab bookmark,
prioritizing frame bookmarks over tab bookmarks, should both
exist.

Unlike `bufferlo-bookmark-frame-load-current' and
`bufferlo-bookmark-tab-load-current', this does not prompt to
load a new bookmark."
  (interactive)
  (bufferlo--warn)
  (if-let* ((bm (frame-parameter nil 'bufferlo-bookmark-frame-name)))
      ;; On reload, always resue the existing frame (don't make a new one)
      (let ((bufferlo-bookmark-frame-load-make-frame nil)
            (bufferlo-bookmark-frame-load-policy
             'replace-frame-retain-current-bookmark)
            ;; The bookmark is detected as a duplicate bookmark, allow it here
            (bufferlo-bookmark-frame-duplicate-policy 'allow))
        (bufferlo-bookmark-frame-load bm))
    (if-let* ((bm (alist-get 'bufferlo-bookmark-tab-name
                             (cdr (bufferlo--current-tab)))))
        ;; On reload, always resue the existing tab (don't make a new one)
        (let ((bufferlo-bookmark-tab-replace-policy 'replace)
              ;; The bookmark is detected as a duplicate bookmark, allow it here
              (bufferlo-bookmark-tab-duplicate-policy 'allow))
          (bufferlo-bookmark-tab-load bm))
      (message "No active bufferlo frame or tab bookmark to load."))))

(defun bufferlo-bookmark-close-current ()
  "DWIM close current bufferlo bookmark and kill its buffers.
Close the current bufferlo frame bookmark or tab bookmark,
prioritizing frame bookmarks over tab bookmarks, should both
exist."
  (interactive)
  (bufferlo--warn)
  (if-let* ((bm (frame-parameter nil 'bufferlo-bookmark-frame-name)))
      (bufferlo-delete-frame-kill-buffers)
    (if-let* ((bm (alist-get 'bufferlo-bookmark-tab-name
                             (cdr (bufferlo--current-tab)))))
        (bufferlo-tab-close-kill-buffers)
      (message "No active bufferlo frame or tab bookmark to close."))))

;;; bookmark advisories

;; (defun bookmark-set (&optional name no-overwrite)
;; (defun bookmark-set-no-overwrite (&optional name push-bookmark)
;; Leave these alone for now. They warn about duplicate bookmarks.

;; (defun bookmark--jump-via (bookmark-name-or-record display-function)
(defun bufferlo--bookmark--jump-via-advice (oldfn bookmark-name-or-record display-function)
  "`bookmark--jump-via' advice to nullify `display-function'.
OLDFN BOOKMARK-NAME-OR-RECORD DISPLAY-FUNCTION"
  (when-let* ((bookmark-record (bookmark-get-bookmark bookmark-name-or-record 'noerror)))
    (if (rassoc (bookmark-type-from-full-record bookmark-record)
                bufferlo--bookmark-type-names)
        (let ((bookmark-fringe-mark nil))
          (funcall oldfn bookmark-record #'ignore))
      (funcall oldfn bookmark-record display-function))))

;; (defun bookmark-rename (old-name &optional new-name)
(defun bufferlo--bookmark-rename-advice (oldfn &optional old-name new-name)
  "`bookmark-rename' advice to prevent renaming active bufferlo bookmarks.
OLDFN OLD-NAME NEW-NAME"
  (interactive)
  (when (called-interactively-p 'interactive)
    (setq old-name (bookmark-completing-read "Old bookmark name")))
  (if-let* ((abm (assoc old-name (bufferlo--active-bookmarks))))
      (user-error
       "%s is an active bufferlo bookmark--close its frame/tab, or clear it before renaming"
       old-name)
    (if (called-interactively-p 'interactive)
        (funcall-interactively oldfn old-name new-name)
      (funcall oldfn old-name new-name))))

;; (defun bookmark-delete (bookmark-name &optional batch)
(defun bufferlo--bookmark-delete-advice (oldfn &optional bookmark-name batch)
  "`bookmark-delete' advice to prevent deleting active bufferlo bookmarks.
OLDFN BOOKMARK-NAME BATCH"
  (interactive)
  (when (called-interactively-p 'interactive)
    (setq bookmark-name (bookmark-completing-read "Delete bookmark"
                                                  bookmark-current-bookmark)))
  (if-let* ((abm (assoc bookmark-name (bufferlo--active-bookmarks))))
      (user-error
       "%s is an active bufferlo bookmark--close its frame/tab, or clear it before deleting"
       bookmark-name)
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
(defalias 'bufferlo-bm-save             'bufferlo-bookmark-save-current)
(defalias 'bufferlo-bm-load             'bufferlo-bookmark-load-current)
(defalias 'bufferlo-bm-close            'bufferlo-bookmark-close-current)
(defalias 'bufferlo-bm-tab-save         'bufferlo-bookmark-tab-save)
(defalias 'bufferlo-bm-tab-save-curr    'bufferlo-bookmark-tab-save-current)
(defalias 'bufferlo-bm-tab-load         'bufferlo-bookmark-tab-load)
(defalias 'bufferlo-bm-tab-load-curr    'bufferlo-bookmark-tab-load-current)
(defalias 'bufferlo-bm-tab-close-curr   'bufferlo-tab-close-kill-buffers)
(defalias 'bufferlo-bm-frame-save       'bufferlo-bookmark-frame-save)
(defalias 'bufferlo-bm-frame-save-curr  'bufferlo-bookmark-frame-save-current)
(defalias 'bufferlo-bm-frame-load       'bufferlo-bookmark-frame-load)
(defalias 'bufferlo-bm-frame-load-curr  'bufferlo-bookmark-frame-load-current)
(defalias 'bufferlo-bm-frame-load-merge 'bufferlo-bookmark-frame-load-merge)
(defalias 'bufferlo-bm-frame-close-curr 'bufferlo-delete-frame-kill-buffers)
(defalias 'bufferlo-set-save            'bufferlo-set-save-interactive)
(defalias 'bufferlo-set-save-curr       'bufferlo-set-save-current-interactive)
(defalias 'bufferlo-set-add             'bufferlo-set-add-interactive)
(defalias 'bufferlo-set-remove          'bufferlo-set-remove-interactive)
(defalias 'bufferlo-set-load            'bufferlo-set-load-interactive)
(defalias 'bufferlo-set-close           'bufferlo-set-close-interactive)
(defalias 'bufferlo-set-clear           'bufferlo-set-clear-interactive)
(defalias 'bufferlo-set-list            'bufferlo-set-list-interactive)

(provide 'bufferlo)

;;; bufferlo.el ends here
