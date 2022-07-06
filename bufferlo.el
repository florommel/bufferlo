;;; bufferlo.el --- Manage frame/tab-local buffer lists -*- lexical-binding: t -*-
;; Copyright (C) 2021-2022, Florian Rommel

;; Author: Florian Rommel <mail@florommel.de>
;; Maintainer: Florian Rommel <mail@florommel.de>
;; Url: https://github.com/florommel/bufferlo
;; Created: 2021-09-15
;; Version: 0.1
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

;; Bufferlo manages buffer lists that are local to the frame or (tab-bar)
;; tab.  It uses the existing buffer-list frame parameter and provides
;; commands to manipulate this list.
;;
;; Bufferlo does not touch the global buffer list or any existing
;; buffer-management facilities (buffer-menu, ibuffer, switch-to-buffer).
;; Use the equivalent bufferlo variants to work with the frame/tab local
;; buffer list.
;;
;; This is similar to the now unmaintained frame-bufs package but is
;; compatible with (tab-bar) tabs and supports desktop.el.
;; https://github.com/alpaker/frame-bufs

;;;; Installation:

;; Put this file in your load path and require it in your init file:
;;   (require 'bufferlo)
;;
;; Enable bufferlo-mode in your init file order to enable the configuration
;; and desktop support
;;   (bufferlo-mode 1)
;;
;; Or use use-package:
;;   (use-package bufferlo
;;    :config
;;    (bufferlo-mode 1))

;;;; Usage:

;; Use the bufferlo buffer-list commands an alternative to the respective
;; global commands.
;;
;; Use bufferlo-{clear,remove,bury} to manage the frame/tab-local list.
;; A buffer is added to the local buffer list if it is shown in the frame/tab.
;;
;; It is recommended to combine bufferlo with a completion framework.
;; This is an example source for consult-buffer:
;;   (defvar my-consult--source-local-buffer
;;       `(:name "Local Buffers"
;;               :narrow   ?l  ;; toggle local buffers with <l>
;;               :hidden   t   ;; set to nil to always show the local buffers
;;                             ;; (For this being effective, you should also
;;                             ;;  define a hidden global buffer source)
;;               :category buffer
;;               :face     consult-buffer
;;               :history  buffer-name-history
;;               :state    ,#'consult--buffer-state
;;               :default  nil
;;               :items ,(lambda () (consult--buffer-query
;;                                   :predicate #'bufferlo-local-buffer-p
;;                                   :sort 'visibility
;;                                   :as #'buffer-name)))
;; Add my-consult--source-local-buffer to your consult-buffer-sources list.

;;; Code:

(require 'desktop)

(defgroup bufferlo nil
  "Manage frame/tab local buffer"
  :group 'convenience)

(defcustom bufferlo-desktop-support t
  "Enable support for desktop.el.
Save and restore the frame/tab local buffer lists."
  :group 'bufferlo
  :type 'boolean)

(defcustom bufferlo-prefer-local-buffers t
  "Use a frame predicate to prefer local buffers over global ones.
This means that a local buffer will be prefered to be displayed
when the current buffer disappears (buried or killed).
This must be set before enabling command `bufferlo-mode'
in order to take effect."
  :group 'bufferlo
  :type 'boolean)

(defcustom bufferlo-include-buried-buffers t
  "Include buried buffers in the local list (`bufferlo-buffer-list').
Use `bufferlo-bury' to remove and bury a buffer if this is set to `t'."
  :group 'bufferlo
  :type 'boolean)

(defcustom bufferlo-include-buffer-filters nil
  "Buffers that should always get included in a new tab or frame.
This is a list of regular expressions that match buffer names.
This overrides buffers excluded by `bufferlo-exclude-buffer-filters.'"
  :group 'bufferlo
  :type '(repeat string))

(defcustom bufferlo-exclude-buffer-filters '(".*")
  "Buffers that should always get excluded in a new tab or frame.
This is a list of regular expressions that match buffer names.
This gets overridden by `bufferlo-include-buffer-filters.'"
  :group 'bufferlo
  :type '(repeat string))

(defcustom bufferlo-kill-buffers-exclude-filters
  '(" .*" "\\*Messages\\*" "\\*scratch\\*")
  "Buffers that should not be killed by `bufferlo-kill-buffers'.
This is a list of regular expressions that match buffer names."
  :group 'bufferlo
  :type '(repeat string))

(defvar bufferlo--desktop-advice-active nil)

;;;###autoload
(define-minor-mode bufferlo-mode
  "Manage frame/tab-local buffers."
  :global t
  :group 'bufferlo
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
        ;; Desktop support
        (advice-add #'window-state-get :around #'bufferlo--window-state-get)
        (advice-add #'window-state-put :after #'bufferlo--window-state-put)
        (advice-add #'frameset--restore-frame :around #'bufferlo--activate)
        (advice-add #'frameset-save :around #'bufferlo--activate)
        (advice-add #'tab-bar-select-tab :around #'bufferlo--activate)
        (advice-add #'tab-bar--tab :around #'bufferlo--activate))
    ;; Prefer local buffers
    (dolist (frame (frame-list))
      (bufferlo--reset-buffer-predicate frame))
    (remove-hook 'after-make-frame-functions #'bufferlo--set-buffer-predicate)
    ;; Include/exclude buffers
    (remove-hook 'after-make-frame-functions #'bufferlo--include-exclude-buffers)
    (remove-hook 'tab-bar-tab-post-open-functions #'bufferlo--tab-include-exclude-buffers)
    ;; Desktop support
    (advice-remove #'window-state-get #'bufferlo--window-state-get)
    (advice-remove #'window-state-put #'bufferlo--window-state-put)
    (advice-remove #'frameset--restore-frame #'bufferlo--activate)
    (advice-remove #'frameset-save #'bufferlo--activate)
    (advice-remove #'tab-bar-select-tab #'bufferlo--activate)
    (advice-remove #'tab-bar--tab #'bufferlo--activate)))

(defun bufferlo-local-buffer-p (buffer)
  "Return whether BUFFER is in the list of local buffers."
  (memq buffer (bufferlo--current-buffers nil)))

(defun bufferlo--set-buffer-predicate (frame)
  "Set the buffer predicate of FRAME to `bufferlo-local-buffer-p'."
  (set-frame-parameter frame 'buffer-predicate #'bufferlo-local-buffer-p))

(defun bufferlo--reset-buffer-predicate (frame)
  "Reset the buffer predicate of FRAME if it is `bufferlo-local-buffer-p'."
  (when (eq (frame-parameter frame 'buffer-predicate) #'bufferlo-local-buffer-p)
    (set-frame-parameter frame 'buffer-predicate nil)))

(defun bufferlo--merge-regexp-list (regexp-list)
  "Merge a list of regular expressions."
  (mapconcat (lambda (x)
               (concat "\\(?:^" x "$\\)"))
             regexp-list "\\|"))

(defun bufferlo--include-exclude-buffers (frame)
  "Include and exclude buffers into the buffer list of FRAME."
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
  "Include and exclude buffers into buffer-list of the current tab's FRAME."
  (ignore ignore)
  (bufferlo--include-exclude-buffers nil))

(defun bufferlo--current-buffers (frame)
  "Get the buffers of the current tab in frame"
  (if bufferlo-include-buried-buffers
      (append
       (frame-parameter frame 'buffer-list)
       (frame-parameter frame 'buried-buffer-list))
    (frame-parameter frame 'buffer-list)))

(defun bufferlo--get-tab-buffers (tab)
  "Extract buffers from the given tab structure"
  (or
   (if bufferlo-include-buried-buffers
       (append
        (cdr (assq 'wc-bl tab))
        (cdr (assq 'wc-bbl tab)))
     (cdr (assq 'wc-bl tab)))
   ;; fallback to bufferlo-buffer-list, managed by bufferlo--window-state-*
   (mapcar 'get-buffer
           (car (cdr (assq 'bufferlo-buffer-list (assq 'ws tab)))))))

(defun bufferlo-buffer-list (&optional frame tabnum)
  "Return a list of all live buffers associated with the current frame and tab.
A non-nil value of FRAME selects a specific frame instead of the current one.
If TABNUM is nil, the current tab is used.  If it is non-nil, it specifies
a tab index in the given frame."
  (let ((list
         (if tabnum
             (let ((tab (nth tabnum (frame-parameter frame 'tabs))))
               (if (eq 'current-tab (car tab))
                   (bufferlo--current-buffers frame)
                 (bufferlo--get-tab-buffers tab)))
           (bufferlo--current-buffers frame))))
    (seq-filter #'buffer-live-p list)))

(defun bufferlo--window-state-get (oldfn &optional window writable)
  "Save the frame's buffer-list to the window state.
Ignore buffers that are not able to be persisted in the desktop file."
  (let ((ws (apply oldfn (list window writable))))
    (if bufferlo--desktop-advice-active
        (let* ((buffers
                (seq-filter
                 (lambda (b)
                   (desktop-save-buffer-p (buffer-file-name b)
                                          (buffer-name b)
                                          (with-current-buffer b major-mode)))
                 (bufferlo--current-buffers (window-frame window))))
               (names (mapcar #'buffer-name buffers)))
          (if names (append ws (list (list 'bufferlo-buffer-list names))) ws))
      ws)))

(defun bufferlo--window-state-put (state &optional window ignore)
  "Restore the frame's buffer-list from the window state."
  (ignore ignore)
  (when bufferlo--desktop-advice-active
    ;; FIXME: Currently there is no distinction between buffers and
    ;;        buried buffers for dektop.el.
    (when-let (bl (car (cdr (assq 'bufferlo-buffer-list state))))
      (set-frame-parameter (window-frame window) 'buffer-list
                           (mapcar #'get-buffer bl))
      (set-frame-parameter (window-frame window) 'buried-buffer-list nil))))

(defun bufferlo--activate (oldfn &rest args)
  "Activate the advice for bufferlo--window-state-{get,put}."
  (let ((bufferlo--desktop-advice-active bufferlo-desktop-support))
    (apply oldfn args)))

(defun bufferlo-clear (&optional frame)
  "Clear the frame/tab's buffer list, except for the current buffer.
If FRAME is nil, use the current frame."
  (interactive)
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

(defun bufferlo-bury (&optional buffer-or-name)
  "Bury and remove the buffer specified by BUFFER-OR-NAME from the local list.
If `bufferlo-include-buried-buffers' is set to `nil' then this has the same
effect as a simple `bury-buffer'."
  (interactive)
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

(defun bufferlo--get-exclusive-buffers (&optional frame)
  "Get all buffers that are exclusive for this frame and tab.
If frame is nil, use the current frame."
  (let ((other-bufs (bufferlo--get-captured-buffers (or frame (selected-frame))))
        (this-bufs (bufferlo--current-buffers frame)))
    (seq-filter (lambda (b)
                  (not (memq b other-bufs)))
                this-bufs)))

(defun bufferlo-kill-buffers (&optional killall frame)
  "Kill the buffers of the frame/tab-local buffer list.
By default, this will only kill buffers that are exclusive to the frame/tab.
If KILLALL (prefix argument) is given then buffers that are also present in the
local lists of other frames and tabs are killed too.
Buffers matching `bufferlo-kill-buffers-exclude-filters' are never killed.
If FRAME is nil, use the current frame."
  (interactive "P")
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
  (let ((exclude (bufferlo--merge-regexp-list
                  (append '("a^") bufferlo-kill-buffers-exclude-filters))))
    (dolist (buffer (bufferlo--get-orphan-buffers))
      (unless (string-match-p exclude (buffer-name buffer))
        (kill-buffer buffer)))))

(defun bufferlo-delete-frame-kill-buffers (&optional frame)
  "Delete a frame and kill all the local buffers according to
`bufferlo-kill-buffers'.
If FRAME is nil, kill the current frame."
  (interactive)
  (bufferlo-kill-buffers frame)
  (delete-frame))

(defun bufferlo-tab-close-kill-buffers (&optional killall)
  "Close the current tab and kill all the local buffers according to
  `bufferlo-kill-buffers'."
  (interactive "P")
  (bufferlo-kill-buffers killall)
  (tab-bar-close-tab))

(defun bufferlo-switch-to-buffer (buffer &optional norecord force-same-window)
  "Display the local buffer BUFFER in the selected window.
This is the frame/tab-local equivilant to `switch-to-buffer'.
The arguments NORECORD and FORCE-SAME-WINDOW are passed to `switch-to-buffer'."
  (interactive
   (list
    (let ((lbs (mapcar #'buffer-name (bufferlo-buffer-list))))
      (read-buffer
       "Switch to local buffer: " lbs nil
       (lambda (b) (member (if (stringp b) b (car b)) lbs))))))
  (switch-to-buffer buffer norecord force-same-window))

(defun bufferlo-ibuffer ()
  "Invoke `ibuffer' filtered for local buffers."
  (interactive)
  (require 'ibuffer)
  (defvar ibuffer-maybe-show-predicates)
  (let ((ibuffer-maybe-show-predicates
         (append ibuffer-maybe-show-predicates
                 (list (lambda (b)
                         (not (memq b (bufferlo-buffer-list))))))))
    (ibuffer)))

(provide 'bufferlo)

;;; bufferlo.el ends here
