#lang racket/base

;; Durable JSON data files in the app data dir — the source of truth for
;; settings and library (port of Tauri's read_data_file/write_data_file:
;; the webview's storage has proven unreliable in packaged builds).
;; Allowlist mirrors db.rs exactly: settings, library. Contents ride as
;; opaque strings so the page's JSON shape stays authoritative.

(require racket/contract
         racket/file
         racket/path)

(require "platform.rkt")

(provide
 (contract-out
  [data-file-path (-> string? path?)]
  [read-data-file (-> string? (or/c string? #f))]
  [write-data-file (-> string? string? void?)]))

(define allowed-files '("settings" "library"))

(define (data-file-path name)
  (unless (member name allowed-files)
    (raise-argument-error 'data-file-path (format "one of ~a" allowed-files) name))
  (build-path (app-data-dir) (string-append name ".json")))

(define (read-data-file name)
  (define path (data-file-path name))
  (and (file-exists? path)
       (let* ([b (file->bytes path)]
              ;; BOM-emitting editors (PowerShell 5.1 Set-Content -Encoding
              ;; UTF8, legacy Notepad saves) prefix settings with EF BB BF;
              ;; read-json throws on the U+FEFF and every consumer's error
              ;; handler then treated the file as empty — the user's whole
              ;; configuration silently vanished (issue #47). Strip the BOM
              ;; once at this single read choke point so settings and
              ;; library both survive it, and say so for diagnosability.
              [has-bom? (and (>= (bytes-length b) 3)
                             (equal? (subbytes b 0 3) #"ï»¿"))]
              [clean (if has-bom? (subbytes b 3) b)])
         (when has-bom?
           (eprintf "[data-files] stripped a UTF-8 BOM from ~a
" path)
           (flush-output (current-error-port)))
         (bytes->string/utf-8 clean))))

(define (write-data-file name json)
  (define path (data-file-path name))
  (make-directory* (path-only path))
  (display-to-file json path #:mode 'text #:exists 'replace))
