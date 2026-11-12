#lang racket/base

;; Tests for backend storage (db.rkt), data files, and migration.

(require db
         racket/file
         racket/list
         racket/port
         racket/string
         rackunit
         "../data-files.rkt"
         "../db.rkt"
         "../migrate.rkt")

(define conn (open-database #f))

;; ---- kv ---------------------------------------------------------------------

(test-case "kv roundtrip and overwrite"
  (kv-set! conn "deviceId" "abc")
  (check-equal? (kv-get conn "deviceId") "abc")
  (kv-set! conn "deviceId" "xyz")
  (check-equal? (kv-get conn "deviceId") "xyz")
  (check-false (kv-get conn "missing")))

;; ---- translations -----------------------------------------------------------

(test-case "translations batch upsert and get"
  (translations-put! conn
                     (list (list 1 "zh" "m" "标题" #f)
                           (list 2 "zh" "m" #f "正文")))
  (define-values (title text) (translation-get conn 1 "zh"))
  (check-equal? title "标题")
  (check-equal? text #f)
  (translations-put! conn (list (list 1 "zh" "m2" "新标题" #f)))
  (define-values (title2 text2) (translation-get conn 1 "zh"))
  (check-equal? title2 "新标题")
  (define batch (translations-get-batch conn (list 1 2 3) "zh"))
  (check-equal? (length batch) 2)
  (check-equal? (first batch) (list 1 "新标题" #f)))

;; ---- hn_items ---------------------------------------------------------------

(test-case "items upsert"
  (items-put! conn (list (list 42 "{\"id\":42}")))
  (check-equal? (item-get conn 42) "{\"id\":42}")
  (items-put! conn (list (list 42 "{\"id\":42,\"v\":2}")))
  (check-equal? (item-get conn 42) "{\"id\":42,\"v\":2}")
  (check-false (item-get conn 43)))

;; ---- file-backed db ----------------------------------------------------------

(test-case "open-database on disk"
  (define tmp (make-temporary-file "hd-db-~a" 'directory))
  (define fc (open-database tmp))
  (kv-set! fc "k" "v")
  (check-equal? (kv-get fc "k") "v")
  (check-true (file-exists? (build-path tmp "hackdigest.db")))
  (disconnect fc))

;; ---- data files (env override for the data dir) ------------------------------

(test-case "data files allowlist and roundtrip"
  (define tmp (make-temporary-file "hd-data-~a" 'directory))
  (define old-env (getenv "HACKDIGEST_DATA_DIR"))
  (dynamic-wind
    (lambda () (putenv "HACKDIGEST_DATA_DIR" (path->string tmp)))
    (lambda ()
      (write-data-file "settings" "{\"uiLang\":\"zh\"}")
      (check-equal? (read-data-file "settings") "{\"uiLang\":\"zh\"}")
      (check-false (read-data-file "library"))
      (check-exn exn:fail:contract? (lambda () (read-data-file "../escape"))))
    (lambda ()
      (if old-env (putenv "HACKDIGEST_DATA_DIR" old-env) (putenv "HACKDIGEST_DATA_DIR" "")))))

;; ---- migration -----------------------------------------------------------------

(test-case "migrate adopts legacy tauri dir once"
  (define tmp (make-temporary-file "hd-mig-~a" 'directory))
  (define legacy (build-path tmp "site.jrtx.hackdigest"))
  (define target (build-path tmp "hackdigest"))
  (make-directory* legacy)
  (display-to-file "{\"v\":1}" (build-path legacy "hackdigest.db") #:exists 'replace)
  (display-to-file "{}" (build-path legacy "settings.json") #:exists 'replace)
  (putenv "HACKDIGEST_DATA_DIR" (path->string target))
  (dynamic-wind
    void
    (lambda ()
      (check-pred string? (migrate-tauri-data!))
      (check-equal? (file->string (build-path target "hackdigest.db")) "{\"v\":1}")
      (check-equal? (file->string (build-path target "settings.json")) "{}")
      (check-true (file-exists? (build-path legacy "hackdigest.db"))
                  "legacy dir must stay untouched")
      ;; second run: local db exists → skip
      (check-true (string-contains? (migrate-tauri-data!) "nothing to do")))
    (lambda () (putenv "HACKDIGEST_DATA_DIR" ""))))
