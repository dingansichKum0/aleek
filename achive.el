;;; achive.el --- A-stocks real-time data  -*- lexical-binding: t; -*-

;; Copyright (C) 2017 zakudriver

;; Author: zakudriver <zy.hua1122@gmail.com>
;; URL: https://github.com/zakudriver/achive
;; Version: 1.0
;; Package-Requires: ((emacs "25.2"))
;; Keywords: tools

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; Achive is a plug-in based on api of Sina that creates a dashboard displaying real-time data of a-share indexs and stocks.
;; Thanks for the super-fast Sina api, and achive performs so well to update data automatically.

;;; Code:

;;;; Requirements

(require 'cl-lib)
(require 'url)
(require 'org-table)
(require 'achive-utils)


(defvar url-http-response-status 0)


;;;; Customization

(defgroup achive nil
  "Settings for `achive'."
  :prefix "achive-"
  :group 'utils)


(defcustom achive-index-list '("sh000001" "sz399001" "sz399006")
  "List of composite index."
  :group 'achive
  :type 'list)


(defcustom achive-stock-list '("sh600036" "sz000625")
  "List of stocks."
  :group 'achive
  :type 'list)


(defcustom achive-buffer-name "*A Chive*"
  "Buffer name of achive board."
  :group 'achive
  :type 'string)

(defcustom achive-search-buffer-name "*A Chive - results -*"
  "Buffer name of achive search board."
  :group 'achive
  :type 'string)


(defcustom achive-auto-refresh t
  "Whether to refresh automatically."
  :group 'achive
  :type 'boolean)


(defcustom achive-refresh-seconds 5
  "Seconds of automatic refresh time."
  :group 'achive
  :type 'integer)


(defcustom achive-cache-path (concat user-emacs-directory ".achive")
  "Path of cache."
  :group 'achive
  :type 'string)


(defcustom achive-colouring t
  "Whether to apply face.
If it's nil will be low-key, you can peek at it at company time."
  :group 'achive
  :type 'string)

;;;;; faces

(defface achive-face-up
  '((t (:inherit (error))))
  "Face used when share prices are rising."
  :group 'achive)


(defface achive-face-down
  '((t :inherit (success)))
  "Face used when share prices are dropping."
  :group 'achive)


(defface achive-face-constant
  '((t :inherit (shadow)))
  "Face used when share prices are dropping."
  :group 'achive)


(defface achive-face-index-name
  '((t (:inherit (font-lock-keyword-face bold))))
  "Face used for index name."
  :group 'achive)

;;;; constants

(defconst achive-api "https://hq.sinajs.cn"
  "Stocks Api.")


(defconst achive-field-index-list
  '((code . 0) (name . achive-make-name) (price . 4) (change-percent . achive-make-change-percent)
    (high . 5) (low . 6) (volume . achive-make-volume) (turn-volume . achive-make-turn-volume) (open . 2) (yestclose . 3))
  "Index or fucntion of each piece of data.")


(defconst achive-visual-columns (vector
                                 '("股票代码" 8 nil)
                                 '("名称" 10 nil)
                                 (list "当前价" 10 (achive-number-sort 2))
                                 (list "涨跌幅" 7 (achive-number-sort 3))
                                 (list "最高价" 10 (achive-number-sort 4))
                                 (list "最低价" 10 (achive-number-sort 5))
                                 (list "成交量" 10 (achive-number-sort 6))
                                 (list "成交额" 10 (achive-number-sort 7))
                                 (list "开盘价" 10 (achive-number-sort 8))
                                 (list "昨日收盘价" 10 (achive-number-sort 9)))
  "Realtime board columns.")

;;;;; variables

(defvar achive-prev-point nil
  "Point of before render.")


(defvar achive-search-codes nil
  "Search code list.")


(defvar achive-stocks nil
  "Realtime stocks code list.")


(defvar achive-pop-to-buffer-action nil
  "Action to use internally when `pop-to-buffer' is called.")

;;;;; functions

(defun achive-make-request-url (api parameter)
  "Make sina request url.
API: shares api.
PARAMETER: request url parameter."
  (format "%s/list=%s" api (string-join parameter ",")))


(defun achive-request (url callback)
  "Handle request by URL.
CALLBACK: function of after response."
  (let ((url-request-method "POST")
        (url-request-extra-headers '(("Content-Type" . "application/javascript;charset=UTF-8") ("Referer" . "https://finance.sina.com.cn"))))
    (url-retrieve url (lambda (_status)
                        (let ((inhibit-message t))
                          (message "achive: %s at %s" "The request is successful." (format-time-string "%T")))
                        (funcall callback)) nil 'silent)))


(defun achive-parse-response ()
  "Parse sina http response result by body."
  (if (/= 200 url-http-response-status)
      (error "Internal Server Error"))
  (let ((resp-gbcode (with-current-buffer (current-buffer)
                       (buffer-substring-no-properties (search-forward "\n\n") (point-max)))))
    (decode-coding-string resp-gbcode 'gb18030)))


(defun achive-format-content (codes resp-str)
  "Format response string to buffer string.
RESP-STR: string of response body.
CODES: stocks list of request parameters.
Return index and stocks data."
  (let ((str-list (cl-loop with i = 0
                           for it in codes
                           if (string-match (format "%s=\"\\([^\"]+\\)\"" it) resp-str)
                           collect (format "%s,%s" (nth i codes) (match-string 1 resp-str))
                           else
                           collect (nth i codes) end
                           do (cl-incf i))))
    (cl-loop for it in str-list
             with temp = nil
             do (setq temp (achive-format-row it))
             collect (list (nth 0 temp)
                           (apply 'vector temp)))))


(defun achive-format-row (row-str)
  "Format row content.
ROW-STR: string of row."
  (let ((value-list (split-string row-str ",")))
    (if (= 1 (length value-list))
        (append value-list (make-list 9 "-"))
      (cl-loop for (_k . v) in achive-field-index-list
               collect (if (functionp v)
                           (funcall v value-list achive-field-index-list)
                         (nth v value-list))))))


(defun achive-validate-request (codes callback)
  "Validate that the CODES is valid, then call CALLBACK function."
  (achive-request (achive-make-request-url achive-api codes)
                  (lambda ()
                    (funcall callback (seq-filter
                                       (lambda (arg) (not (achive-invalid-entry-p arg)))
                                       (achive-format-content codes (achive-parse-response)))))))


(defun achive-render-request (buffer-name codes &optional callback)
  "Handle request by stock CODES, and rendder buffer of BUFFER-NAME.
CALLBACK: callback function after the rendering."
  (achive-request (achive-make-request-url achive-api codes)
                  (lambda ()
                    (let ((formated-resp
                           (achive-format-content codes (achive-parse-response))))


                      (with-current-buffer buffer-name
                        (setq tabulated-list-entries (if achive-colouring
                                                         (mapcar #'achive-propertize-face
                                                                 formated-resp)
                                                       formated-resp))
                        (tabulated-list-print t))

                      (if (functionp callback)
                          (funcall callback formated-resp))))))


(defun achive-refresh ()
  "Referer achive visual buffer or achive search visual buffer."
  (if (get-buffer-window achive-buffer-name)
      (achive-render-request achive-buffer-name (append achive-index-list achive-stocks)))
  (if (get-buffer-window achive-search-buffer-name)
      (achive-render-request achive-search-buffer-name achive-search-codes)))


(defun achive-should-refresh-p ()
  "Now should be refresh.
If at 9:00 - 11:30 or 13:00 - 15:00 and visual buffer is existing,
return t. Otherwise, return nil."
  (if (get-buffer-window achive-buffer-name)
      (or (and (not (achive-compare-time "9:00")) (achive-compare-time "11:30"))
          (and (not (achive-compare-time "13:00")) (achive-compare-time "15:00")))
    nil))


(defun achive-weekday-p ()
  "Whether it is weekend or not."
  (let ((week (format-time-string "%w")))
    (not (or (string= week "0") (string= week "6")))))


(defun achive-switch-visual (buffer-name)
  "Switch to visual buffer by BUFFER-NAME."
  (pop-to-buffer buffer-name achive-pop-to-buffer-action)
  (achive-visual-mode))


(defun achive-loop-refresh (_timer)
  "Loop to refresh."
  (if (and (achive-timer-alive-p) (achive-weekday-p))
      (if (achive-should-refresh-p)
          (achive-render-request achive-buffer-name
                                 (append achive-index-list achive-stocks)
                                 (lambda (_resp)
                                   (achive-handle-auto-refresh)))
        (achive-handle-auto-refresh))))


(defun achive-handle-auto-refresh ()
  "Automatic refresh."
  (achive-set-timeout #'achive-loop-refresh
                      achive-refresh-seconds))


(defun achive-init ()
  "Init program. Read cache codes from file."
  (let ((cache (achive-readcache achive-cache-path)))
    (unless cache
      (achive-writecache achive-cache-path achive-stock-list)
      (setq cache achive-stock-list))
    (setq achive-stocks cache)))


(defun achive-propertize-face (entry)
  "Propertize ENTRY."
  (let* ((id (car entry))
         (data (cadr entry))
         (percent (aref data 3))
         (percent-number (string-to-number percent)))

    (when (cl-position id achive-index-list :test 'string=)
      (aset data 0 (propertize (aref data 0) 'face 'achive-face-index-name))
      (aset data 1 (propertize (aref data 1) 'face 'achive-face-index-name)))

    (aset data 3 (propertize percent 'face (cond
                                            ((> percent-number 0)
                                             'achive-face-up)
                                            ((< percent-number 0)
                                             'achive-face-down)
                                            (t 'achive-face-constant))))
    entry))


(defun achive-timer-alive-p ()
  "Check that the timer is alive."
  (get-buffer achive-buffer-name))

;;;;; interactive

;;;###autoload
(defun achive ()
  "Launch achive and switch to visual buffer."
  (interactive)
  (achive-init)

  (let ((timer-alive (achive-timer-alive-p)))

    (achive-switch-visual achive-buffer-name)
    (achive-render-request achive-buffer-name
                           (append achive-index-list achive-stocks)
                           (lambda (_resp)
                             (if (and achive-auto-refresh (not timer-alive))
                                 (achive-handle-auto-refresh))))))


;;;###autoload
;; (defun achive-exit ()
;;   "Exit achive."
;;   (interactive)
;;   (quit-window t)
;;   (message "Achive has been killed."))


;;;###autoload
(defun achive-search (codes)
  "Search stock by codes.
CODES: string of stocks list."
  (interactive "sPlease input code to search: ")
  (setq achive-search-codes (split-string codes))
  (achive-switch-visual achive-search-buffer-name)
  (achive-render-request achive-search-buffer-name achive-search-codes))


;;;###autoload
(defun achive-add (codes)
  "Add stocks by codes.
CODES: string of stocks list."
  (interactive "sPlease input code to add: ")
  (setq codes (split-string codes))

  (achive-validate-request codes (lambda (resp)
                                   (setq codes (mapcar (apply-partially #'car) resp))
                                   (when codes
                                     (setq achive-stocks (append achive-stocks codes))
                                     (achive-writecache achive-cache-path achive-stocks)
                                     (achive-render-request achive-buffer-name (append achive-index-list achive-stocks)
                                                            (lambda (_resp)
                                                              (message "[%s] have been added."
                                                                       (mapconcat 'identity codes ", "))))))))


;;;###autoload
(defun achive-remove ()
  "Remove stocks."
  (interactive)
  (let* ((code (completing-read "Please select the stock code to remove: "
                                achive-stocks
                                nil
                                t
                                nil
                                nil
                                nil))
         (index (cl-position code achive-stocks :test 'string=)))
    (when index
      (setq achive-stocks (achive-remove-nth-element achive-stocks index))
      (achive-writecache achive-cache-path achive-stocks)
      (achive-render-request achive-buffer-name (append achive-index-list achive-stocks)
                             (lambda (_resp)
                               (message "<%s> have been removed." code))))))

;;;;; mode

(defvar achive-visual-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map "+" 'achive-add)
    (define-key map "_" 'achive-remove)
    map)
  "Keymap for `achive-visual-mode'.")


(define-derived-mode achive-visual-mode tabulated-list-mode "Achive"
  "Major mode for avhice real-time board."
  (setq tabulated-list-format achive-visual-columns)
  (setq tabulated-list-padding 2)
  (setq tabulated-list-sort-key nil)
  (add-hook 'tabulated-list-revert-hook 'achive-refresh nil t)
  (tabulated-list-init-header)
  (tablist-minor-mode))


(provide 'achive)

;;; achive.el ends here

;; 0：”大秦铁路”，股票名字；
;; 1：”27.55″，今日开盘价；
;; 2：”27.25″，昨日收盘价；
;; 3：”26.91″，当前价格；
;; 4：”27.55″，今日最高价；
;; 5：”26.20″，今日最低价；
;; 6：”26.91″，竞买价，即“买一”报价；
;; 7：”26.92″，竞卖价，即“卖一”报价；
;; 8：”22114263″，成交的股票数，由于股票交易以一百股为基本单位，所以在使用时，通常把该值除以一百；
;; 9：”589824680″，成交金额，单位为“元”，为了一目了然，通常以“万元”为成交金额的单位，所以通常把该值除以一万；
;; 10：”4695″，“买一”申请4695股，即47手；
;; 11：”26.91″，“买一”报价；
;; 12：”57590″，“买二”
;; 13：”26.90″，“买二”
;; 14：”14700″，“买三”
;; 15：”26.89″，“买三”
;; 16：”14300″，“买四”
;; 17：”26.88″，“买四”
;; 18：”15100″，“买五”
;; 19：”26.87″，“买五”
;; 20：”3100″，“卖一”申报3100股，即31手；
;; 21：”26.92″，“卖一”报价
;; (22, 23), (24, 25), (26,27), (28, 29)分别为“卖二”至“卖四的情况”
;; 30：”2008-01-11″，日期；
;; 31：”15:05:32″，时间；

;; var hq_str_sh000001=\"上证指数,3261.9219,3268.6955,3245.3123,3262.0025,3216.9927,0,0,319906033,409976276121,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,2023-03-14,15:30:39,00,\"

;; ("sh000001" "上证指数" "3245.3123" "-0.72%" "3262.0025" "3216.9927" 3199060 "40997627W" "3261.9219" "3268.6955")

;; http://image.sinajs.cn/newchart/daily/n/sh601006.gif
