#lang racket/base

;; Settings access for the backend: the LLM config lives in settings.json
;; (managed by the page through the data-file endpoints). R2 security rule:
;; the real API key never needs to reach the page for LLM calls — endpoints
;; resolve the config server-side, reads are masked (BYOK only; the hosted
;; provider reuses the same field as a license key the page must display),
;; and masked writes restore the stored key.
;;
;; Key custody (issue #2 secure-storage slice): the BYOK key may live in the
;; system keyring instead of the plaintext file. settings.json carries a
;; top-level `apiKeyStorage` marker: "keyring" (key is in the keyring, absent
;; from the file), "plaintext-optout" (keyring unavailable or the user
;; declined — plaintext is the explicit, visible choice), or absent (unset;
;; a real key in this state is migrated at startup). The hosted provider's
;; key is exempt: it is a license key the page must display.

(require json
         racket/contract
         racket/match
         racket/string
         "data-files.rkt"
         "llm.rkt"
         "secure-store.rkt")

(provide (contract-out [masked-key string?]
                       [settings-llm-config (-> llm-config?)]
                       [resolve-llm-config (-> llm-config? llm-config?)])
         mask-settings-jsexpr!
         unmask-settings-jsexpr!
         storage-mode
         stored-api-key
         migrate-key-storage!
         move-key-storage!)

;; Sentinel the page sees instead of a stored BYOK key.
(define masked-key "__SAVED__")

(define (settings-jsexpr)
  (define raw (read-data-file "settings"))
  (if raw
      (with-handlers ([exn:fail? (lambda (_) (hasheq))])
        (read-json (open-input-string raw)))
      (hasheq)))

(define (stored-llm-hash)
  (define s (settings-jsexpr))
  (define llm (hash-ref s 'llm #f))
  (and (hash? llm) llm))

;; ---- key custody --------------------------------------------------------------

;; The marker as stored; one of "keyring", "plaintext-optout" or "" (unset).
(define (storage-mode)
  (define v (hash-ref (settings-jsexpr) 'apiKeyStorage #f))
  (if (string? v) v ""))

;; The effective stored BYOK key (""): the keyring in keyring mode, the
;; plaintext file otherwise. Never returns the sentinel.
(define (stored-api-key)
  (case (storage-mode)
    [("keyring")
     (define store (current-secure-store))
     (or (and ((secure-store-available? store))
              ((secure-store-get store)))
         "")]
    [else
     (define llm (stored-llm-hash))
     (define v (and llm (hash-ref llm 'apiKey #f)))
     (if (string? v) v "")]))

(define (hosted? s)
  (equal? (hash-ref s 'providerId "") "hosted"))

;; Startup migration (idempotent): move a real plaintext key into the
;; keyring when one is available, else stamp the explicit plaintext-optout
;; marker. Decided modes and legacy hosted keys are left alone; no key at
;; all stays marker-free so a future real save ingests normally.
(define (migrate-key-storage!)
  (define s (settings-jsexpr))
  (define mode (storage-mode))
  (cond
    [(or (string=? mode "keyring") (string=? mode "plaintext-optout")) (void)]
    [(hosted? s) (void)]
    [else
     (define llm (hash-ref s 'llm #f))
     (define raw (and (hash? llm) (hash-ref llm 'apiKey #f)))
     (when (and (string? raw) (non-empty-string? (string-trim raw)))
       (define store (current-secure-store))
       (if ((secure-store-available? store))
           (let ()
             ((secure-store-set! store) raw)
             ;; hash-remove/hash-set on immutable hashes return immutable.
             (write-data-file
              "settings"
              (jsexpr->string
               (hash-set (hash-set s 'llm (hash-remove llm 'apiKey))
                         'apiKeyStorage "keyring"))))
           (write-data-file
            "settings"
            (jsexpr->string (hash-set s 'apiKeyStorage "plaintext-optout")))))]))

;; Explicit custody switch, driven by the settings page buttons. "keyring"
;; moves a plaintext key into the store (refusing when none is available);
;; "plaintext" exports the key back into settings.json and records the
;; opt-out marker. Hosted settings are refused (license key, visible by
;; design). Returns 'migrated, 'noop or 'unavailable.
(define (move-key-storage! mode)
  (define s (settings-jsexpr))
  (when (hosted? s)
    (error 'move-key-storage! "hosted license key stays in settings.json"))
  (define store (current-secure-store))
  (cond
    [(string=? mode "keyring")
     (cond
       [(not ((secure-store-available? store))) 'unavailable]
       [(string=? (storage-mode) "keyring") 'noop]
       [else
        (define llm (hash-ref s 'llm #f))
        (define raw (and (hash? llm) (hash-ref llm 'apiKey #f)))
        (if (and (string? raw) (non-empty-string? (string-trim raw)))
            (let ()
              ((secure-store-set! store) raw)
              (write-data-file
               "settings"
               (jsexpr->string
                (hash-set (hash-set s 'llm (hash-remove llm 'apiKey))
                          'apiKeyStorage "keyring")))
              'migrated)
            (let ()
              ;; No plaintext key: nothing to move; record the preference.
              (write-data-file
               "settings"
               (jsexpr->string (hash-set s 'apiKeyStorage "keyring")))
              'noop))])]
    [(string=? mode "plaintext")
     (cond
       [(not (string=? (storage-mode) "keyring"))
        ;; Already plaintext (or unset): record the explicit opt-out.
        (unless (string=? (storage-mode) "plaintext-optout")
          (write-data-file
           "settings"
           (jsexpr->string (hash-set s 'apiKeyStorage "plaintext-optout"))))
        'noop]
       [else
        (define key ((secure-store-get store)))
        (when ((secure-store-available? store))
          ((secure-store-remove! store)))
        (define llm (hash-ref s 'llm #f))
        (define llm2 (if (hash? llm)
                         (hash-set llm 'apiKey (or key ""))
                         (hasheq 'baseUrl "" 'apiKey (or key "") 'model "")))
        (write-data-file
         "settings"
         (jsexpr->string
          (hash-set (hash-set s 'llm llm2) 'apiKeyStorage "plaintext-optout")))
        'migrated])]
    [else (error 'move-key-storage! "mode must be \"keyring\" or \"plaintext\"")]))

;; The Racket-side LLM config: stored settings win over whatever the page
;; relays; a page cfg with a real key (settings test button before first
;; save) still takes precedence per-field.
(define (resolve-llm-config page-cfg)
  (define stored (stored-llm-hash))
  (define stored-key (stored-api-key))
  (define (pick page-val stored-val)
    (if (and (string? page-val) (not (string=? page-val "")) (not (string=? page-val masked-key)))
        page-val
        (if (string? stored-val) stored-val "")))
  (llm-config
   (pick (llm-config-base-url page-cfg)
         (let ([v (and stored (hash-ref stored 'baseUrl #f))]) (if (string? v) v "")))
   (pick (llm-config-api-key page-cfg) stored-key)
   (pick (llm-config-model page-cfg)
         (let ([v (and stored (hash-ref stored 'model #f))]) (if (string? v) v "")))))

;; The config as stored (used when the page sends nothing at all).
(define (settings-llm-config)
  (define stored (stored-llm-hash))
  (llm-config
   (let ([v (and stored (hash-ref stored 'baseUrl #f))]) (if (string? v) v ""))
   (stored-api-key)
   (let ([v (and stored (hash-ref stored 'model #f))]) (if (string? v) v ""))))

;; Mask: BYOK keys become the sentinel so reads never leak them. With the
;; key in the keyring the file has no key to mask — the marker alone tells
;; the page custody state. Hosted (providerId "hosted") keeps its key
;; visible — it is a license key. read-json produces immutable hashes, so
;; the returned value is authoritative and may be a fresh copy.
(define (mask-settings-jsexpr! s)
  (define s2 (if (immutable? s) (hash-copy s) s))
  (define llm (hash-ref s2 'llm #f))
  (when (and (hash? llm)
             (not (equal? (hash-ref s2 'providerId "") "hosted")))
    (define llm2 (if (immutable? llm) (hash-copy llm) llm))
    (define k (hash-ref llm2 'apiKey #f))
    (when (and (string? k) (non-empty-string? (string-trim k)))
      (hash-set! llm2 'apiKey masked-key)
      (hash-set! s2 'llm llm2)))
  s2)

;; Restore + ingest, on the settings write path. The page either echoes the
;; masked read (sentinel = keep the stored key wherever it lives), types a
;; new real key (ingest into the keyring when available), or clears the key
;; (remove the keyring entry and drop the marker). Legacy hosted writes keep
;; their key visible in the file (license-key semantics).
(define (unmask-settings-jsexpr! s)
  (define s2 (if (immutable? s) (hash-copy s) s))
  (define llm (hash-ref s2 'llm #f))
  (when (and (hash? llm)
             (not (equal? (hash-ref s2 'providerId "") "hosted")))
    (define llm2 (if (immutable? llm) (hash-copy llm) llm))
    (define k (hash-ref llm2 'apiKey #f))
    (define store (current-secure-store))
    (define keyring-ok (and ((secure-store-available? store))
                            (not (string=? (storage-mode) "plaintext-optout"))))
    (cond
      ;; Sentinel echo: keep the stored key. Plaintext restores it into the
      ;; file; keyring mode leaves the file keyless.
      [(and (string? k) (string=? k masked-key))
       (cond [(string=? (storage-mode) "keyring")
              (hash-set! llm2 'apiKey "")
              (hash-set! s2 'apiKeyStorage "keyring")]
             [else
              (define stored-key (let ([stored (stored-llm-hash)])
                                   (and stored (hash-ref stored 'apiKey #f))))
              (when (string? stored-key)
                (hash-set! llm2 'apiKey stored-key))])]
      ;; A real new key: ingest into the keyring when custody is available.
      [(and (string? k) (non-empty-string? (string-trim k)) keyring-ok)
       ((secure-store-set! store) k)
       (hash-set! llm2 'apiKey "")
       (hash-set! s2 'apiKeyStorage "keyring")]
      ;; Cleared key in keyring mode: remove the entry, drop the marker.
      [(and (string? k) (string=? k "") (string=? (storage-mode) "keyring"))
       (when ((secure-store-available? store))
         ((secure-store-remove! store)))
       (hash-remove! s2 'apiKeyStorage)]
      [else (void)])
    (hash-set! s2 'llm llm2))
  s2)
