#lang racket/base

;; Tests for the durable JSON data-file layer, including the UTF-8 BOM
;; tolerance added for issue #47: settings.json edited by BOM-emitting
;; tools (PowerShell 5.1 Set-Content -Encoding UTF8, legacy Notepad saves)
;; used to fail read-json, whose handler silently turned the whole
;; configuration into an empty map — the startup key migration then saw
;; "no key" and a user's provider config vanished without diagnostics.

(require json
         racket/file
         racket/path
         racket/port
         racket/string
         rackunit
         "data-files.rkt"
         "settings-rpc.rkt")

(define bom (bytes #xEF #xBB #xBF))

(define (seed! content)
  (define path (data-file-path "settings"))
  (make-directory* (path-only path))
  (display-to-file content path #:mode 'text #:exists 'replace))

(test-case "plain settings.json round-trips unchanged (baseline)"
  (define tmp (make-temporary-file "hd-df-~a" 'directory))
  (putenv "HACKDIGEST_DATA_DIR" (path->string tmp))
  (dynamic-wind
    void
    (lambda ()
      (seed! "{\"providerId\":\"glm\",\"llm\":{\"apiKey\":\"sk-plain\"}}")
      ;; storage-mode is the exported observable of a parsed settings file.
      (check-equal? (storage-mode) ""))
    (lambda () (delete-directory/files tmp))))

(test-case "UTF-8 BOM in settings.json is stripped, not silently fatal (issue #47)"
  (define tmp (make-temporary-file "hd-df-~a" 'directory))
  (putenv "HACKDIGEST_DATA_DIR" (path->string tmp))
  (dynamic-wind
    void
    (lambda ()
      ;; Write raw bytes: BOM + valid config, exactly what a BOM-emitting
      ;; editor produces.
      (define path (data-file-path "settings"))
      (make-directory* (path-only path))
      (call-with-output-file path
        (lambda (out)
          (write-bytes bom out)
          (write-bytes
           (string->bytes/utf-8
            "{\"providerId\":\"custom\",\"llm\":{\"baseUrl\":\"http://127.0.0.1:8766/v1\",\"apiKey\":\"sk-bom-canary\",\"model\":\"mock-model\"}}")
           out))
        #:exists 'replace)
      ;; The layer's own contract: the returned string is BOM-free and
      ;; parses to the real config.
      (define raw (read-data-file "settings"))
      (check-false (string-prefix? raw "\uFEFF") "no U+FEFF at the start")
      (define j (read-json (open-input-string raw)))
      (check-equal? (hash-ref j 'providerId) "custom")
      ;; The user-visible contract: settings parse (previously the exn
      ;; handler returned an empty map and the config silently vanished —
      ;; stored-api-key is the exported observable of exactly that: the
      ;; unmarked plaintext key must come back).
      (check-equal? (stored-api-key) "sk-bom-canary"))
    (lambda () (delete-directory/files tmp))))

(test-case "library.json tolerates a BOM too (same reader path)"
  (define tmp (make-temporary-file "hd-df-~a" 'directory))
  (putenv "HACKDIGEST_DATA_DIR" (path->string tmp))
  (dynamic-wind
    void
    (lambda ()
      (define path (data-file-path "library"))
      (make-directory* (path-only path))
      (call-with-output-file path
        (lambda (out) (write-bytes bom out) (write-bytes #"[]" out))
        #:exists 'replace)
      (check-equal? (read-data-file "library") "[]"))
    (lambda () (delete-directory/files tmp))))
