;;; bufferlo.el --- Manage frame/tab-local buffer lists -*- lexical-binding: t -*-
;; Copyright (C) 2021, Florian Rommel

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
  (memq buffer (frame-parameter nil 'buffer-list)))

(defun bufferlo--set-buffer-predicate (frame)
  "Set the buffer predicate of FRAME to `bufferlo-local-buffer-p'."
  (set-frame-parameter frame 'buffer-predicate #'bufferlo-local-buffer-p))

(defun bufferlo--reset-buffer-predicate (frame)
  "Reset the buffer predicate of FRAME if it is `bufferlo-local-buffer-p'."
  (when (eq (frame-parameter frame 'buffer-predicate) #'bufferlo-local-buffer-p)
    (set-frame-parameter frame 'buffer-predicate nil)))

(defun bufferlo--include-exclude-buffers (frame)
  "Include and exclude buffers into the buffer list of FRAME."
  (let* ((merge-regexp-list (lambda (li)
                              (mapconcat (lambda (x) (concat "\\(?:" x "\\)"))
                                         li "\\|")))
         (include (funcall merge-regexp-list
                           (append '("a^") bufferlo-include-buffer-filters)))
         (exclude (funcall merge-regexp-list
                           (append '("a^") bufferlo-exclude-buffer-filters)))
         (buffers (frame-parameter frame 'buffer-list))
         (buffers (seq-filter (lambda (b)
                                (not (string-match-p exclude (buffer-name b))))
                              buffers))
         (incl-buffers (seq-filter (lambda (b)
                                     (string-match-p include (buffer-name b)))
                                   (buffer-list frame)))
         (buffers (delete-dups (append buffers incl-buffers))))
    (set-frame-parameter frame 'buffer-list buffers)))

(defun bufferlo--tab-include-exclude-buffers (ignore)
  "Include and exclude buffers into buffer-list of the current tab's FRAME."
  (ignore ignore)
  (bufferlo--include-exclude-buffers nil))

(defun bufferlo-buffer-list (&optional frame tabnum)
  "Return a list of all live buffers associated with the current frame and tab.
A non-nil value of FRAME selects a specific frame instead of the current one.
If TABNUM is nil, the current tab is used.  If it is non-nil, it specifies
a tab index in the given frame."
  (let ((list
         (if tabnum
             (let ((tab (nth tabnum (frame-parameter frame 'tabs))))
               (if (eq 'current-tab (car tab))
                   (frame-parameter frame 'buffer-list)
                 (or
                  (cdr (assq 'wc-bl tab))
                  (mapcar 'get-buffer
                          (car (cdr (assq #'bufferlo-buffer-list (assq 'ws tab))))))))
           (frame-parameter frame 'buffer-list))))
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
                 (frame-parameter (window-frame window) 'buffer-list)))
               (names (mapcar #'buffer-name buffers)))
          (if names (append ws (list (list 'bufferlo-buffer-list names))) ws))
      ws)))

(defun bufferlo--window-state-put (state &optional window ignore)
  "Restore the frame's buffer-list from the window state."
  (ignore ignore)
  (when bufferlo--desktop-advice-active
    (when-let (bl (car (cdr (assq 'bufferlo-buffer-list state))))
      (set-frame-parameter (window-frame window) 'buffer-list
                           (mapcar #'get-buffer bl)))))

(defun bufferlo--activate (oldfn &rest args)
  "Activate the advice for bufferlo--window-state-{get,put}."
  (let ((bufferlo--desktop-advice-active bufferlo-desktop-support))
    (apply oldfn args)))

(defun bufferlo-clear (&optional frame)
  "Clear the frame's buffer list, except for the current buffer.
If FRAME is nil, use the current frame."
  (interactive)
  (set-frame-parameter frame 'buffer-list
                       (list (if frame
                                 (with-selected-frame frame
                                   (current-buffer))
                               (current-buffer)))))

(defun bufferlo-remove (buffer)
  "Remove BUFFER from the frame's buffer list."
  (interactive
   (list
    (let ((lbs (mapcar (lambda (b) (buffer-name b))
                       (bufferlo-buffer-list))))
      (read-buffer "Remove buffer: " nil t
                   (lambda (b) (member (car b) lbs))))))
  (delete (get-buffer buffer) (frame-parameter nil 'buffer-list)))

(defun bufferlo-bury (&optional buffer-or-name)
  "Bury and remove the buffer specified by BUFFER-OR-NAME from the local list."
  (interactive)
  (let ((buffer (or buffer-or-name (current-buffer))))
    (delete (get-buffer buffer) (frame-parameter nil 'buffer-list))
    (bury-buffer buffer-or-name)))

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
