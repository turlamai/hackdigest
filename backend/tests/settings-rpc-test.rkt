#lang racket/base

;; Tests for the settings security layer: BYOK key masking on reads,
;; sentinel restore on writes, and server-side config resolution.

(require json
         racket/file
         racket/port
         racket/string
         rackunit
         "../data-files.rkt"
         "../llm.rkt"
         "../settings-rpc.rkt")

(define (roundtrip->jsexpr s)
  (read-json (open-input-string s)))

;; Store doubles for the secure-storage cases below: defined before all
;; tests so earlier cases can reference them (module defines are hoisted
;; but only usable after their definition runs).
(define unavailable-store
  (secure-store (λ () #f) (λ () #f) (λ (v) (void)) (λ () (void))))
(define (scan-artifacts-for canary)
  (define dir (app-data-dir))
  (for/fold ([hits '()])
      ([p (in-directory dir)]
       #:when (file-exists? p))
    (define b (file->bytes p))
    (if (regexp-match? (byte-regexp (string->bytes/utf-8 canary)) b)
        (cons (path->string p) hits)
        hits)))
(define (write-canary-plaintext! canary)
  (write-data-file "settings"
                   (jsexpr->string
                    (hasheq 'providerId "glm"
                            'llm (hasheq 'baseUrl "https://x/v1"
                                         'apiKey canary
                                         'model "m")))))

(test-case "BYOK key masked on read, hosted license key stays visible"
  (define tmp (make-temporary-file "hd-set-~a" 'directory))
  (putenv "HACKDIGEST_DATA_DIR" (path->string tmp))
  (dynamic-wind
    void
    (lambda ()
      ;; BYOK: masked
      (write-data-file "settings"
                       (jsexpr->string
                        (hasheq 'providerId "glm"
                                'llm (hasheq 'baseUrl "https://api.deepseek.com/v1"
                                             'apiKey "sk-real-secret"
                                             'model "deepseek-chat"))))
      (define masked
        (mask-settings-jsexpr! (roundtrip->jsexpr (read-data-file "settings"))))
      (check-equal? (hash-ref (hash-ref masked 'llm) 'apiKey) masked-key)
      (check-equal? (hash-ref (hash-ref masked 'llm) 'baseUrl) "https://api.deepseek.com/v1")

      ;; Hosted: visible (it doubles as the license key)
      (write-data-file "settings"
                       (jsexpr->string
                        (hasheq 'providerId "hosted"
                                'llm (hasheq 'baseUrl "https://hd.jrtx.site/v1"
                                             'apiKey "lic-123"
                                             'model "hosted"))))
      (define hosted
        (mask-settings-jsexpr! (roundtrip->jsexpr (read-data-file "settings"))))
      (check-equal? (hash-ref (hash-ref hosted 'llm) 'apiKey) "lic-123")

      ;; Empty BYOK key: nothing to mask
      (write-data-file "settings"
                       (jsexpr->string
                        (hasheq 'providerId "glm"
                                'llm (hasheq 'baseUrl "" 'apiKey "" 'model ""))))
      (define empty
        (mask-settings-jsexpr! (roundtrip->jsexpr (read-data-file "settings"))))
      (check-equal? (hash-ref (hash-ref empty 'llm) 'apiKey) ""))
    (lambda () (putenv "HACKDIGEST_DATA_DIR" ""))))

(test-case "masked write restores the stored key"
  (define tmp (make-temporary-file "hd-set2-~a" 'directory))
  (putenv "HACKDIGEST_DATA_DIR" (path->string tmp))
  (dynamic-wind
    void
    (lambda ()
      (write-data-file "settings"
                       (jsexpr->string
                        (hasheq 'providerId "glm"
                                'llm (hasheq 'baseUrl "https://x/v1"
                                             'apiKey "sk-keep-me"
                                             'model "m"))))
      ;; Page echoes the masked read back with an untouched key field
      (define page-write
        (hasheq 'providerId "glm"
                'llm (hasheq 'baseUrl "https://x/v1"
                             'apiKey masked-key
                             'model "m")))
      (define restored
        (unmask-settings-jsexpr! page-write))
      (check-equal? (hash-ref (hash-ref restored 'llm) 'apiKey) "sk-keep-me")
      ;; A real new key passes through untouched when no keyring is
      ;; available (plaintext-optout state); with one available it is
      ;; ingested — covered by the secure-storage cases below.
      (define new-key
        (parameterize ([current-secure-store unavailable-store])
          (unmask-settings-jsexpr!
           (hasheq 'providerId "glm"
                   'llm (hasheq 'baseUrl "https://x/v1" 'apiKey "sk-new" 'model "m")))))
      (check-equal? (hash-ref (hash-ref new-key 'llm) 'apiKey) "sk-new"))
    (lambda () (putenv "HACKDIGEST_DATA_DIR" ""))))

(test-case "resolve-llm-config fills blanks from stored settings"
  (define tmp (make-temporary-file "hd-set3-~a" 'directory))
  (putenv "HACKDIGEST_DATA_DIR" (path->string tmp))
  (dynamic-wind
    void
    (lambda ()
      (write-data-file "settings"
                       (jsexpr->string
                        (hasheq 'providerId "glm"
                                'llm (hasheq 'baseUrl "https://stored/v1"
                                             'apiKey "sk-stored"
                                             'model "stored-model"))))
      ;; Page relays the masked/empty config it holds → stored wins
      (define resolved
        (resolve-llm-config (llm-config "https://stored/v1" masked-key "stored-model")))
      (check-equal? (llm-config-api-key resolved) "sk-stored")
      (check-equal? (llm-config-base-url resolved) "https://stored/v1")
      (check-equal? (llm-config-model resolved) "stored-model")
      ;; A real key typed but not yet saved (settings test button) wins
      (define fresh
        (resolve-llm-config (llm-config "https://fresh/v1" "sk-fresh" "m1")))
      (check-equal? (llm-config-api-key fresh) "sk-fresh"))
    (lambda () (putenv "HACKDIGEST_DATA_DIR" ""))))

;; ---- secure-storage slice (issue #2): keyring custody + artifact scans ----

(require "../platform.rkt"
         "../secure-store.rkt")

(test-case "migration moves plaintext key to keyring; scan green, red direction proven"
  (define tmp (make-temporary-file "hd-sec1-~a" 'directory))
  (putenv "HACKDIGEST_DATA_DIR" (path->string tmp))
  (parameterize ([current-secure-store (make-memory-store!)])
    (dynamic-wind
      void
      (lambda ()
        (define canary "sk-secure-slice-canary-001")
        (write-canary-plaintext! canary)
        ;; Red: the pre-migration state leaks the canary into settings.json.
        (check-equal? (scan-artifacts-for canary)
                      (list (path->string (data-file-path "settings"))))
        ;; Migration moves the key; no marker existed before.
        (migrate-key-storage!)
        ;; Green: no artifact carries the canary any more, the marker is
        ;; set, the store holds the key, and resolution still returns it.
        (check-equal? (scan-artifacts-for canary) '())
        (check-equal? (storage-mode) "keyring")
        (check-equal? (stored-api-key) canary)
        (define resolved
          (resolve-llm-config (llm-config "https://x/v1" masked-key "m")))
        (check-equal? (llm-config-api-key resolved) canary))
      (lambda () (putenv "HACKDIGEST_DATA_DIR" "")))))

(test-case "migration with no keyring stamps plaintext-optout and keeps the file"
  (define tmp (make-temporary-file "hd-sec2-~a" 'directory))
  (putenv "HACKDIGEST_DATA_DIR" (path->string tmp))
  (parameterize ([current-secure-store unavailable-store])
    (dynamic-wind
      void
      (lambda ()
        (define canary "sk-optout-canary-002")
        (write-canary-plaintext! canary)
        (migrate-key-storage!)
        ;; Explicit, never silent: the marker records the plaintext choice.
        (check-equal? (storage-mode) "plaintext-optout")
        (define s (read-json (open-input-string (read-data-file "settings"))))
        (check-equal? (hash-ref (hash-ref s 'llm) 'apiKey) canary)
        ;; And a real new key on save is NOT ingested (no keyring to hold it).
        (define out
          (unmask-settings-jsexpr!
           (hasheq 'providerId "glm"
                   'llm (hasheq 'baseUrl "https://x/v1" 'apiKey "sk-new" 'model "m"))))
        (check-equal? (hash-ref (hash-ref out 'llm) 'apiKey) "sk-new"))
      (lambda () (putenv "HACKDIGEST_DATA_DIR" "")))))

(test-case "save with keyring: file keyless, marker set, store holds the key"
  (define tmp (make-temporary-file "hd-sec3-~a" 'directory))
  (putenv "HACKDIGEST_DATA_DIR" (path->string tmp))
  (parameterize ([current-secure-store (make-memory-store!)])
    (dynamic-wind
      void
      (lambda ()
        (define canary "sk-save-ingest-003")
        (define out
          (unmask-settings-jsexpr!
           (hasheq 'providerId "glm"
                   'llm (hasheq 'baseUrl "https://x/v1" 'apiKey canary 'model "m"))))
        ;; The jsexpr that reaches settings.json carries no key.
        (check-equal? (hash-ref (hash-ref out 'llm) 'apiKey) "")
        (check-equal? (hash-ref out 'apiKeyStorage) "keyring")
        (write-data-file "settings" (jsexpr->string out))
        (check-equal? (scan-artifacts-for canary) '())
        (check-equal? (storage-mode) "keyring")
        (check-equal? (stored-api-key) canary))
      (lambda () (putenv "HACKDIGEST_DATA_DIR" "")))))

(test-case "sentinel echo in keyring mode keeps the file keyless"
  (define tmp (make-temporary-file "hd-sec4-~a" 'directory))
  (putenv "HACKDIGEST_DATA_DIR" (path->string tmp))
  (parameterize ([current-secure-store (make-memory-store!)])
    (dynamic-wind
      void
      (lambda ()
        (define canary "sk-sentinel-004")
        ((secure-store-set! (current-secure-store)) canary)
        (write-data-file "settings"
                         (jsexpr->string
                          (hasheq 'providerId "glm"
                                  'llm (hasheq 'baseUrl "https://x/v1"
                                               'apiKey ""
                                               'model "m")
                                  'apiKeyStorage "keyring")))
        (define out
          (unmask-settings-jsexpr!
           (hasheq 'providerId "glm"
                   'llm (hasheq 'baseUrl "https://x/v1" 'apiKey masked-key 'model "m"))))
        (check-equal? (hash-ref (hash-ref out 'llm) 'apiKey) "")
        (check-equal? (hash-ref out 'apiKeyStorage) "keyring")
        (check-equal? (scan-artifacts-for canary) '()))
      (lambda () (putenv "HACKDIGEST_DATA_DIR" "")))))

(test-case "cleared key in keyring mode removes the entry and the marker"
  (define tmp (make-temporary-file "hd-sec5-~a" 'directory))
  (putenv "HACKDIGEST_DATA_DIR" (path->string tmp))
  (parameterize ([current-secure-store (make-memory-store!)])
    (dynamic-wind
      void
      (lambda ()
        (define store (current-secure-store))
        ((secure-store-set! store) "sk-to-be-cleared-005")
        (write-data-file "settings"
                         (jsexpr->string
                          (hasheq 'providerId "glm"
                                  'llm (hasheq 'baseUrl "https://x/v1"
                                               'apiKey ""
                                               'model "m")
                                  'apiKeyStorage "keyring")))
        (define out
          (unmask-settings-jsexpr!
           (hasheq 'providerId "glm"
                   'llm (hasheq 'baseUrl "https://x/v1" 'apiKey "" 'model "m"))))
        (check-equal? (hash-ref out 'apiKeyStorage #f) #f)
        (check-equal? ((secure-store-get store)) #f)
        (check-equal? (stored-api-key) ""))
      (lambda () (putenv "HACKDIGEST_DATA_DIR" "")))))

(test-case "memory store round trip (CI seam without a real keyring)"
  (define store (make-memory-store!))
  (check-true ((secure-store-available? store)))
  (check-equal? ((secure-store-get store)) #f)
  ((secure-store-set! store) "v1")
  (check-equal? ((secure-store-get store)) "v1")
  ((secure-store-set! store) "v2")
  (check-equal? ((secure-store-get store)) "v2")
  ((secure-store-remove! store))
  (check-equal? ((secure-store-get store)) #f)
  ((secure-store-remove! store)) ; idempotent
  (check-equal? ((secure-store-get store)) #f))

(test-case "hosted license key bypasses keyring ingestion"
  (define tmp (make-temporary-file "hd-sec6-~a" 'directory))
  (putenv "HACKDIGEST_DATA_DIR" (path->string tmp))
  (parameterize ([current-secure-store (make-memory-store!)])
    (dynamic-wind
      void
      (lambda ()
        (define out
          (unmask-settings-jsexpr!
           (hasheq 'providerId "hosted"
                   'llm (hasheq 'baseUrl "https://hd/v1" 'apiKey "lic-123" 'model "m"))))
        ;; License key stays visible/plaintext (the page must display it).
        (check-equal? (hash-ref (hash-ref out 'llm) 'apiKey) "lic-123")
        (check-equal? (hash-ref out 'apiKeyStorage #f) #f)
        (check-equal? ((secure-store-get (current-secure-store))) #f)
        ;; And migration skips hosted settings entirely.
        (write-data-file "settings" (jsexpr->string out))
        (migrate-key-storage!)
        (check-equal? (storage-mode) ""))
      (lambda () (putenv "HACKDIGEST_DATA_DIR" "")))))

(test-case "move-key-storage! refuses with an error when no keyring exists"
  (define tmp (make-temporary-file "hd-sec7-~a" 'directory))
  (putenv "HACKDIGEST_DATA_DIR" (path->string tmp))
  (parameterize ([current-secure-store unavailable-store])
    (dynamic-wind
      void
      (lambda ()
        ;; Moving to the keyring without a keyring reports 'unavailable;
        ;; the route turns that into a user error so the page can show the
        ;; refusal reason instead of a fake success.
        (check-equal? (move-key-storage! "keyring") 'unavailable)
        ;; The plaintext direction is always available (explicit opt-out).
        (check-equal? (move-key-storage! "plaintext") 'noop))
      (lambda () (putenv "HACKDIGEST_DATA_DIR" "")))))
