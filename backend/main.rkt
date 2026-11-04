#lang racket/base

;; HackDigest on Glaze — the Racket backend that replaces the Tauri/Rust
;; host (see docs/GLAZE-MIGRATION.md). Serves the built React frontend and
;; the /api surface: SQLite storage, durable JSON data files, LLM proxy
;; (keys stay in Racket), external links, update detection.
;;
;; Run:  pnpm --filter @hackdigest/desktop build:vite   (once)
;;       racket backend/main.rkt

;; Explicit glaze module imports (G3 consumer curation): the legacy `glaze`
;; facade is a compatibility shim whose deprecated re-exports are removed in
;; 0.19.0. `app-data-dir` comes from platform.rkt, which keeps the
;; Tauri-compatible layout.
(require glaze/app        ; run-app, app-id
         glaze/api        ; GET, POST, streaming-response
         glaze/api-macros ; define-api-routes
         glaze/browser    ; open-browser
         glaze/events     ; make-event-bus
         (except-in glaze/path app-data-dir) ; public-dir; app-data-dir stays ours
         glaze/sys/main   ; single-instance?
         glaze/types      ; GString, GInt64, GValue, glist
         glaze/window     ; webview? / title / url / capture / close for the selftest
         glaze/window-state ; window-state
         json
         racket/contract
         racket/file
         racket/format
         racket/list
         racket/match
         racket/path
         racket/runtime-path
         racket/string
         "data-files.rkt"
         "db.rkt"
         "llm.rkt"
         "migrate.rkt"
         "native-smoke.rkt"
         "platform.rkt"
         "settings-rpc.rkt"
         "translate.rkt"
         "update-check.rkt"
         "update.rkt")

;; Keep in sync with package.json and CHANGELOG.md; the release workflow's
;; validate job fails the tag if they disagree.
(define app-version "0.3.1")

;; HACKDIGEST_FAKE_VERSION overrides the reported version so the real
;; update flow against a published release can be exercised locally.
(current-app-version
 (or (getenv "HACKDIGEST_FAKE_VERSION") app-version))

(define-runtime-path frontend-dist "../apps/desktop/dist")

(define bus (make-event-bus))

;; The database is opened in module+ main (after data migration); routes
;; read it through this box so impl functions stay directly testable.
(define db-box (box #f))
(define (current-db) (unbox db-box))

;; Sticky staged-rollout bucket 0..99 for the updater, persisted in kv so
;; an installation keeps its bucket across launches.
(define (seed-rollout-bucket!)
  (define existing
    (let ([v (kv-get (current-db) "rollout-bucket")])
      (and v (string->number v))))
  (if (and existing (exact-integer? existing) (<= 0 existing 99))
      (current-rollout-bucket existing)
      (let ([bucket (random 100)])
        (kv-set! (current-db) "rollout-bucket" (number->string bucket))
        (current-rollout-bucket bucket))))

;; ---- page-jsexpr → impl shims ----------------------------------------------

(define (nullable v) (if (string? v) v 'null))

(define (jsexpr->cfg h)
  (llm-config (hash-ref h 'baseUrl "")
              (hash-ref h 'apiKey "")
              (hash-ref h 'model "")))

;; [{role, content}] → ((role . content) ...)
(define (jsexpr->msgs arr)
  (for/list ([m (in-list arr)])
    (cons (string->symbol (hash-ref m 'role)) (hash-ref m 'content))))

(define (jsexpr->trans-rows rows)
  (for/list ([r (in-list rows)])
    (match r
      [(list id lang model title text)
       (list id lang model
             (if (string? title) title #f)
             (if (string? text) text #f))])))

(define (jsexpr->items items)
  (for/list ([it (in-list items)])
    (match it [(list id json) (list id json)])))

;; Stream a digest: OK line + raw markdown deltas (same wire protocol as
;; api/llm/chat/stream, prompts built server-side by backend/translate.rkt).
(define (digest-stream cfg prompts max-tokens)
  (streaming-response
   (lambda (out)
     (define wrote-status? #f)
     (define (status-ok!)
       (unless wrote-status?
         (set! wrote-status? #t)
         (display "OK\n" out)
         (flush-output out)))
     (with-handlers
         ([exn:llm?
           (lambda (e)
             (unless wrote-status?
               (fprintf out "ERR ~a ~a\n"
                        (or (llm-error-status e) 0)
                        (string-replace (exn-message e) "\n" " "))
               (flush-output out)))]
          [exn:fail?
           (lambda (e)
             (unless wrote-status?
               (fprintf out "ERR 0 ~a\n" (string-replace (exn-message e) "\n" " "))
               (flush-output out)))])
       (chat cfg
             (list (cons 'system (car prompts)) (cons 'user (cdr prompts)))
             #:max-tokens max-tokens
             #:on-delta (lambda (delta)
                          (status-ok!)
                          (display delta out)
                          (flush-output out)))
       (status-ok!)))
   #:mime #"text/plain; charset=utf-8"))

;; ---- routes ----------------------------------------------------------------

(define-api-routes api
  [(GET "api/health")
   (health)
   (hasheq 'ok #t 'version app-version)]

  [(POST "api/kv/get")
   (kv-get-r [key GString])
   (hasheq 'value (nullable (kv-get (current-db) key)))]

  [(POST "api/kv/set")
   (kv-set-r [key GString] [value GString])
   (kv-set! (current-db) key value)
   (hasheq 'ok #t)]

  [(POST "api/translations/get")
   (translations-get [itemId GInt64] [lang GString])
   (define-values (title text) (translation-get (current-db) itemId lang))
   (hasheq 'found (if (or title text) #t 'null)
           'title (nullable title)
           'text (nullable text))]

  [(POST "api/translations/get-batch")
   (translations-get-batch-r [itemIds (glist GInt64)] [lang GString])
   (hasheq 'rows
           (for/list ([row (in-list (translations-get-batch (current-db) itemIds lang))])
             (match-define (list id title text) row)
             (list id (nullable title) (nullable text))))]

  [(POST "api/translations/put")
   (translations-put-r [rows (glist (glist GValue))])
   (translations-put! (current-db) (jsexpr->trans-rows rows))
   (hasheq 'ok #t)]

  [(POST "api/items/get")
   (items-get [id GInt64])
   (hasheq 'json (nullable (item-get (current-db) id)))]

  [(POST "api/items/put")
   (items-put-r [items (glist (glist GValue))])
   (items-put! (current-db) (jsexpr->items items))
   (hasheq 'ok #t)]

  [(POST "api/data/read")
   (data-read [name GString])
   (define raw (read-data-file name))
   (define masked-json
     (if (and (string=? name "settings") raw)
         (jsexpr->string
          (mask-settings-jsexpr!
           (with-handlers ([exn:fail? (lambda (_) (hasheq))])
             (read-json (open-input-string raw)))))
         raw))
   (hasheq 'json (nullable masked-json))]

  [(POST "api/data/write")
   (data-write [name GString] [json GString])
   ;; A masked key on the write path echoes the masked read — swap the
   ;; stored key back so the page can never clear it by saving untouched.
   (write-data-file
    name
    (if (string=? name "settings")
        (jsexpr->string
         (unmask-settings-jsexpr!
          (with-handlers ([exn:fail? (lambda (_) (hasheq))])
            (read-json (open-input-string json)))))
        json))
   (hasheq 'ok #t)]

  [(POST "api/llm/test")
   (llm-test [cfg hash?])
   (test-llm (resolve-llm-config (jsexpr->cfg cfg)))
   (hasheq 'ok #t)]

  [(POST "api/llm/chat")
   (llm-chat-r [cfg hash?] [msgs list?] [opts hash?])
   (hasheq 'content
           (chat (resolve-llm-config (jsexpr->cfg cfg))
                 (jsexpr->msgs msgs)
                 #:json-mode (hash-ref opts 'jsonMode #f)
                 #:max-tokens (hash-ref opts 'maxTokens #f)
                 #:temperature (hash-ref opts 'temperature 0.3)))]

  ;; Wire protocol: first line "OK" or "ERR <status> <message>", then raw
  ;; text deltas. POST can't use EventSource, so the page reads the body
  ;; with a fetch reader (bridge.ts). The status line is emitted lazily so
  ;; it always precedes the first delta; a mid-stream failure just ends the
  ;; connection (streaming-response truncation semantics).
  [(POST "api/llm/chat/stream")
   (llm-chat-stream [cfg hash?] [msgs list?] [opts hash?])
   (define the-cfg (resolve-llm-config (jsexpr->cfg cfg)))
   (define the-msgs (jsexpr->msgs msgs))
   (streaming-response
    (lambda (out)
      (define wrote-status? #f)
      (define (status-ok!)
        (unless wrote-status?
          (set! wrote-status? #t)
          (display "OK\n" out)
          (flush-output out)))
      (with-handlers
          ([exn:llm?
            (lambda (e)
              (unless wrote-status?
                (fprintf out "ERR ~a ~a\n"
                         (or (llm-error-status e) 0)
                         (string-replace (exn-message e) "\n" " "))
                (flush-output out)))]
           ;; network-level failures (DNS, refused, TLS) are exn:fail, not
           ;; exn:llm — still lead with an ERR line, never a silent close
           [exn:fail?
            (lambda (e)
              (unless wrote-status?
                (fprintf out "ERR 0 ~a\n" (string-replace (exn-message e) "\n" " "))
                (flush-output out)))])
        (chat the-cfg the-msgs
              #:json-mode (hash-ref opts 'jsonMode #f)
              #:max-tokens (hash-ref opts 'maxTokens #f)
              #:temperature (hash-ref opts 'temperature 0.3)
              #:on-delta
              (lambda (delta)
                (status-ok!)
                (display delta out)
                (flush-output out)))
        (status-ok!)))
    #:mime #"text/plain; charset=utf-8")]

  ;; ---- R2: translation orchestration lives server-side ----

  [(POST "api/translate/story")
   (translate-story-r [cfg hash?] [story hash?] [lang string?])
   (define r (translate-story (current-db) (resolve-llm-config (jsexpr->cfg cfg)) story lang))
   (hasheq 'title (hash-ref r 'title "") 'text (hash-ref r 'text ""))]

  [(POST "api/translate/titles")
   (translate-titles-r [cfg hash?] [stories list?] [lang string?])
   (define map (translate-titles (current-db) (resolve-llm-config (jsexpr->cfg cfg)) stories lang))
   ;; integer-keyed hashes are not jsexpr — pairs on the wire
   (hasheq 'pairs (for/list ([(k v) (in-hash map)]) (list k v)))]

  ;; ndjson progress: OK line, then one {"batch":{id:text},"done":N,"total":M}
  ;; line per completed batch, finally {"failed":K}
  [(POST "api/translate/comments")
   (translate-comments-r [cfg hash?] [comments list?] [lang string?])
   (define the-cfg (resolve-llm-config (jsexpr->cfg cfg)))
   (define items
     (for/list ([c (in-list comments)])
       (cons (hash-ref c 'id) (hash-ref c 'text ""))))
   (streaming-response
    (lambda (out)
      (display "OK\n" out)
      (flush-output out)
      (define failed
        (translate-comments (current-db) the-cfg items lang
                            (lambda (batch done total)
                              (define line
                                (jsexpr->string
                                 (hasheq 'batch (for/hash ([(k v) (in-hash batch)]) (values (~a k) v))
                                         'done done
                                         'total total)))
                              (display line out) (display "\n" out) (flush-output out))))
      (display (jsexpr->string (hasheq 'failed failed)) out)
      (display "\n" out)
      (flush-output out))
    #:mime #"application/x-ndjson")]

  [(POST "api/digest/thread")
   (digest-thread-r [cfg hash?] [story hash?] [comments list?] [lang string?])
   (digest-stream (resolve-llm-config (jsexpr->cfg cfg))
                  (thread-prompts story comments lang) 2000)]

  [(POST "api/digest/tldr")
   (digest-tldr-r [cfg hash?] [story hash?] [lang string?])
   (digest-stream (resolve-llm-config (jsexpr->cfg cfg))
                  (tldr-prompts story lang) 800)]

  [(POST "api/digest/daily")
   (digest-daily-r [cfg hash?] [stories list?] [lang string?] [date string?])
   (define the-cfg (resolve-llm-config (jsexpr->cfg cfg)))
   (streaming-response
    (lambda (out)
      (define wrote-status? #f)
      (define (status-ok!)
        (unless wrote-status?
          (set! wrote-status? #t)
          (display "OK\n" out)
          (flush-output out)))
      (with-handlers
          ([exn:llm?
            (lambda (e)
              (unless wrote-status?
                (fprintf out "ERR ~a ~a\n"
                         (or (llm-error-status e) 0)
                         (string-replace (exn-message e) "\n" " "))
                (flush-output out)))]
           [exn:fail?
            (lambda (e)
              (unless wrote-status?
                (fprintf out "ERR 0 ~a\n" (string-replace (exn-message e) "\n" " "))
                (flush-output out)))])
        (define full
          (chat the-cfg
                (list (cons 'system (car (daily-prompts stories date lang)))
                      (cons 'user (cdr (daily-prompts stories date lang))))
                #:max-tokens 3000
                #:on-delta (lambda (delta)
                             (status-ok!)
                             (display delta out)
                             (flush-output out))))
        ;; cache the daily digest with the same kv key layout digest.ts used
        (kv-set! (current-db) (string-append "daily:" date ":" lang) full)
        (status-ok!)))
    #:mime #"text/plain; charset=utf-8")]

  [(POST "api/open")
   (open-external [url string?])
   (unless (or (string-prefix? url "https://") (string-prefix? url "http://"))
     (raise-user-error 'open "only http(s) urls: ~a" url))
   (open-browser url)
   (hasheq 'ok #t)]

  ;; ---- R3: signed update feed — check / download / state / install ----

  [(POST "api/update/check")
   (update-check-r)
   (check-response)]

  ;; Errors land in the polled state instead of an RPC error, so the
  ;; frontend has a single failure channel (family pattern).
  [(POST "api/update/start")
   (update-start-r)
   (with-handlers ([exn:fail?
                    (lambda (e)
                      (set-update-error! (exn-message e))
                      (hasheq 'ok #f 'message (exn-message e)))])
     (start-download!)
     (hasheq 'ok #t))]

  [(POST "api/update/state")
   (update-state-r)
   (update-state-snapshot)]

  ;; macOS/Windows answer first and exit on a delay so the handover
  ;; (bundle swap / cmd script) completes; Linux reveals the archive.
  [(POST "api/update/install")
   (update-install-r)
   (with-handlers ([exn:fail?
                    (lambda (e)
                      (set-update-error! (exn-message e))
                      (hasheq 'ok #f 'message (exn-message e)))])
     (install-downloaded!))])

(module+ main
  ;; Never mutate a developer's real database while running synthetic
  ;; packaged-native checks. CI and release smoke both pass an isolated dir.
  (define selftest? (equal? (getenv "HACKDIGEST_SELFTEST") "1"))
  (when selftest?
    (let ([data-dir (getenv "HACKDIGEST_DATA_DIR")])
      (unless (and data-dir (not (string=? data-dir "")))
        (raise-user-error 'hackdigest-selftest "set HACKDIGEST_DATA_DIR to an isolated test directory"))))

  (unless (single-instance? "hackdigest")
    (displayln "[hackdigest] another instance is running; exiting")
    (exit 1))

  (displayln (migrate-tauri-data!))
  (set-box! db-box (open-database (app-data-dir)))
  (seed-rollout-bucket!)
  (surface-install-failure!)

  ;; Transport: native (the page loads from glaze:// and every call rides
  ;; the GLZ1 message handler — no TCP port) is the production shape on
  ;; every platform — the packaged-native switch (0.4 RC, glaze 1.0 plan
  ;; G4). HTTP/SSE stays available as the explicit development adapter via
  ;; HACKDIGEST_TRANSPORT=http. GLAZE_API_TOKEN pins a fixed token for
  ;; dev/test automation on the HTTP transport; the native transport has
  ;; no token because the message handler is the trust boundary.
  (define transport
    (or (let ([v (getenv "HACKDIGEST_TRANSPORT")])
          (and (member v '("native" "http")) (string->symbol v)))
        'native))

  ;; HACKDIGEST_SELFTEST=1 turns launch into a self-terminating assertion
  ;; for the packaged-native smoke (release CI on all three platforms):
  ;; the production shape — launcher, engine, native WebView, page served
  ;; from the controlled origin — must come up and render, then the
  ;; process exits 0. A missing WebView backend, a page that never
  ;; commits, or an empty capture exits non-zero; there is no browser
  ;; fallback to mask a broken packaged bridge.
  ;; Selftest must fail closed: an explicit HTTP override is never native
  ;; evidence, even if the app opens and captures the same frontend.
  (when (and selftest? (not (eq? transport 'native)))
    (raise-user-error 'hackdigest-selftest "native transport required"))

  ;; A packaged build's actual frontend resources are copied unchanged to
  ;; an isolated temporary directory; only that selftest copy receives the
  ;; synthetic GLZ1 page. Normal installs never serve this page or its
  ;; synthetic routes. The checked-in application schema stays unchanged.
  (define smoke-root
    (and selftest? (make-temporary-file "hackdigest-native-smoke-~a" 'directory)))
  (define serving-dir
    (if selftest?
        (let ([dir (build-path smoke-root "frontend")])
          (copy-directory/files frontend-dist dir)
          (call-with-output-file (build-path dir "__glaze-smoke.html")
            (lambda (out) (display native-smoke-html out))
            #:exists 'truncate/replace)
          dir)
        frontend-dist))

  (define selftest-passed? (box #f))
  (define selftest-start-ms (and selftest? (current-inexact-milliseconds)))
  (define (smoke-mark phase)
    (when selftest?
      (eprintf "[selftest] phase=~a elapsed-ms=~a\n"
               phase (- (current-inexact-milliseconds) selftest-start-ms))
      (flush-output (current-error-port))))
  (smoke-mark 'before-run-app)
  (run-app
   #:public-dir serving-dir
   #:api (if selftest? (append api (native-smoke-routes)) api)
   #:events bus
   #:transport transport
   #:api-token (or (getenv "GLAZE_API_TOKEN") #t)
   #:title "HackDigest"
   #:width 1160
   #:height 800
   #:app-id "hackdigest"
   #:window-state #t
   #:on-ready
   (if selftest?
       (lambda (wv url)
         (define deadline (+ (current-inexact-milliseconds) 20000))
         (define loaded?
           (and (webview? wv)
                (let loop ()
                  (cond
                    [(equal? (webview-title wv) "HackDigest") #t]
                    [(> (current-inexact-milliseconds) deadline) #f]
                    [else (sleep 0.25) (loop)]))))
         (smoke-mark 'react-title-loaded)
         ;; A real native page must use the controlled WebView origin, never
         ;; loopback HTTP. WebView2 maps the custom scheme to glaze.localhost.
         (define native-origin
           (if (eq? (system-type 'os) 'windows)
               "http://glaze.localhost/"
               "glaze://app/"))
         (define observed-url (and (webview? wv) (webview-url wv)))
         (define origin-ok?
           (and (string? observed-url)
                (string-prefix? observed-url native-origin)))
         ;; A title may commit before the first frame has composited.
         (define shot
           (and loaded?
                (let retry ([limit (+ (current-inexact-milliseconds) 5000)])
                  (define s (webview-capture! wv))
                  (cond
                    [(and s (>= (file-size s) 5000)) s]
                    [(> (current-inexact-milliseconds) limit) s]
                    [else (sleep 0.3) (retry limit)]))))
         (define capture-ok? (and shot (>= (file-size shot) 5000)))
         (smoke-mark 'capture-checked)
         (define smoke-title #f)
         (define bridge-ok?
           (and loaded? origin-ok? capture-ok?
                (begin
                  (smoke-mark 'before-probe-navigation)
                  (webview-navigate wv (string-append native-origin "__glaze-smoke.html"))
                  (let loop ([until (+ (current-inexact-milliseconds) 30000)])
                    (set! smoke-title (webview-title wv))
                    (cond
                      [(equal? smoke-title "HD Smoke PASS") #t]
                      [(and (string? smoke-title)
                            (string-prefix? smoke-title "HD Smoke FAIL")) #f]
                      [(> (current-inexact-milliseconds) until) #f]
                      [else (sleep 0.25) (loop until)])))))
         (smoke-mark 'probe-finished)
         (set-box! selftest-passed? (and bridge-ok? #t))
         (eprintf
          "[selftest] transport=~a url=~a observed=~a loaded=~a origin=~a capture=~a glz1=~a title=~s\n"
          transport url observed-url loaded? (and origin-ok? #t)
          (and capture-ok? #t) (and bridge-ok? #t) smoke-title)
         (smoke-mark 'before-webview-close)
         (when (webview? wv) (webview-close wv))
         (smoke-mark 'after-webview-close)
         ;; A packaged smoke must exit even if a native host does not send
         ;; the last-window callback after an explicit close. run-app supports
         ;; app-quit! during #:on-ready; it posts the exit semaphore once.
         (app-quit!)
         (smoke-mark 'after-app-quit))
       (lambda (_wv _url) (void))))

  (when selftest?
    (smoke-mark 'after-run-app)
    ;; Isolate any Windows shutdown stall: a passed GLZ1 probe must not be
    ;; mistaken for a successful process exit. Keep cleanup and exit distinct
    ;; in the CI logs to show which step needs the platform fix.
    (smoke-mark 'before-smoke-cleanup)
    (delete-directory/files smoke-root)
    (smoke-mark 'after-smoke-cleanup)
    ;; Keep the real exit handler, but mark entry into it: this separates
    ;; Racket exit dispatch from Windows native/process finalization. A
    ;; trapped shutdown must remain a CI failure, never a forced green exit.
    (let ([original-exit-handler (exit-handler)])
      (exit-handler
       (lambda (status)
         (smoke-mark 'exit-handler-enter)
         (original-exit-handler status))))
    (smoke-mark 'before-process-exit)
    (exit (if (unbox selftest-passed?) 0 1))))

(provide api bus)
