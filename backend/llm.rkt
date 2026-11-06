#lang racket/base

;; OpenAI-compatible chat client (port of packages/core/src/llm.ts). Talks to
;; any /v1/chat/completions endpoint: GLM, DeepSeek, Qwen, Kimi, OpenAI,
;; Ollama, hosted Pro. API keys live here in Racket — the webview never sees
;; them on the network (it only ever relays them through the settings form).
;;
;; Streaming: upstream SSE "data:" frames are parsed and re-emitted as plain
;; text deltas through an on-delta callback; backend/main.rkt wraps that in a
;; streaming-response. Retry parity with the TS version: 400/422 with
;; json-mode retries once without response_format (some endpoints reject it);
;; 429 retries once after 3s. Each round trip runs under a custodian deadline
;; (60s by default, HACKDIGEST_LLM_TIMEOUT_SECS for tests).

(require json
         net/http-client
         net/url
         racket/async-channel
         racket/contract
         racket/format
         racket/list
         racket/match
         racket/port
         racket/string)

;; Per-request deadline (Tauri parity: 60s). HACKDIGEST_LLM_TIMEOUT_SECS
;; overrides it for tests.
(define (llm-timeout-secs)
  (or (let ([v (getenv "HACKDIGEST_LLM_TIMEOUT_SECS")])
        (and v (string->number v)))
      60))

;; Run thunk under a private custodian with a wall-clock deadline: on
;; timeout the custodian is shut down (closing the in-flight socket) and an
;; llm-error with the TS-parity message is raised.
(define (with-llm-deadline thunk)
  (define cust (make-custodian))
  (define done (make-async-channel))
  (parameterize ([current-custodian cust])
    (thread
     (lambda ()
       (async-channel-put
        done
        (with-handlers ([exn? (lambda (e) e)])
          (cons 'ok (thunk)))))))
  (define r (sync/timeout (llm-timeout-secs) done))
  (custodian-shutdown-all cust)
  (cond
    [(not r)
     (raise (llm-error (~a "请求超时（" (llm-timeout-secs)
                           " 秒）—— 模型无响应，可尝试换一个模型或服务商")
                       #f))]
    [(exn? r) (raise r)]
    [else (cdr r)]))

(provide
 (contract-out
  [struct llm-config ([base-url string?] [api-key string?] [model string?])]
  [llm-error (->* (string?) ((or/c exact-integer? #f)) exn:llm?)]
  [llm-error-status (-> exn:llm? (or/c exact-integer? #f))]
  [chat-opts-from-jsexpr (-> hash? (values boolean? (or/c exact-integer? #f) real?))]
  [chat-endpoint (-> string? string?)]
  [chat (->* (llm-config? (listof (cons/c symbol? string?)))
             (#:json-mode boolean?
              #:max-tokens (or/c exact-positive-integer? #f)
              #:temperature real?
              #:on-delta (or/c (-> string? void?) #f))
             string?)]
  [test-llm (-> llm-config? void?)]
  [read-sse-deltas (-> input-port? (-> string? any/c) string?)]
  [extract-json (-> string? jsexpr?)]))
(provide (struct-out exn:llm))

(struct llm-config (base-url api-key model) #:transparent)

;; An exn subtype so with-handlers/check-exn work like the TS LLMError and
;; rackunit never sees a raised non-exception value.
(struct exn:llm exn:fail:user (status) #:transparent)

(define (llm-error message [status #f])
  (exn:llm message (current-continuation-marks) status))

(define (llm-error-status e) (exn:llm-status e))

;; Page chat opts → (json-mode max-tokens temperature). JSON null arrives
;; as the 'null symbol (read-json), not #f, so a naive hash-ref passed it
;; straight into the llm contract and got the route blamed — the page
;; always sends maxTokens: null for non-cap calls.
(define (chat-opts-from-jsexpr opts)
  (define (clean v default) (if (eq? v 'null) default v))
  (values (clean (hash-ref opts 'jsonMode #f) #f)
          (let ([mt (clean (hash-ref opts 'maxTokens #f) #f)])
            (if (and mt (real? mt)) (inexact->exact (truncate mt)) #f))
          (let ([tp (clean (hash-ref opts 'temperature 0.3) 0.3)])
            (if (real? tp) tp 0.3))))

;; "https://host/v1" (+ trailing slashes) → "https://host/v1/chat/completions".
(define (chat-endpoint base-url)
  (string-append (string-trim base-url #px"/+") "/chat/completions"))

(define (url-request-path u)
  (string-append "/"
                  (string-join (map path/param-path (url-path u)) "/")))

(define (split-endpoint url-str)
  (define u (string->url (chat-endpoint url-str)))
  (values (url-host u)
          (url-port u)
          (equal? (url-scheme u) "https")
          (url-request-path u)))

(define (chat-body cfg msgs
                   #:json-mode [json-mode #f]
                   #:max-tokens [max-tokens #f]
                   #:temperature [temperature 0.3]
                   #:stream [stream #f])
  (jsexpr->string
   (hasheq 'model (llm-config-model cfg)
           'messages
           (for/list ([m (in-list msgs)])
             (hasheq 'role (symbol->string (car m)) 'content (cdr m)))
           'temperature temperature
           'stream stream
           'max_tokens (or max-tokens 'null)
           'response_format (if json-mode (hasheq 'type "json_object") 'null))))

;; Each entry is a complete header line (no trailing CRLF — http-conn-send!
;; adds it; Content-Length comes automatically from #:data).
(define (request-headers cfg)
  (list (bytes-append #"Authorization: Bearer " (string->bytes/utf-8 (llm-config-api-key cfg)))))

;; http-conn-recv! hands back the full status line ("HTTP/1.1 200 OK");
;; extract the numeric code.
(define (status-code status-line)
  (define m (regexp-match #px"^HTTP/[0-9.]+ +([0-9]{3})" status-line))
  (and m (string->number (bytes->string/utf-8 (second m)))))

;; One upstream round trip. Returns the full content string; when on-delta is
;; provided the request goes out with stream:true and deltas fire as they
;; arrive. Raises llm-error on non-2xx.
(define (chat-once cfg msgs
                   #:json-mode [json-mode #f]
                   #:max-tokens [max-tokens #f]
                   #:temperature [temperature 0.3]
                   #:on-delta [on-delta #f])
  (define-values (host port ssl? path) (split-endpoint (llm-config-base-url cfg)))
  (define payload (string->bytes/utf-8
                   (chat-body cfg msgs
                              #:json-mode json-mode
                              #:max-tokens max-tokens
                              #:temperature temperature
                              #:stream (and on-delta #t))))
  ;; The whole round trip — connect, headers, body, stream reads — lives
  ;; under one deadline; the custodian shutdown closes the socket mid-read.
  (with-llm-deadline
   (lambda ()
  (define conn (http-conn-open host #:port (or port (if ssl? 443 80)) #:ssl? ssl?))
  (dynamic-wind
    void
    (lambda ()
      (http-conn-send! conn (string->bytes/utf-8 path)
                       #:method #"POST"
                       #:headers (request-headers cfg)
                       #:data payload)
      (define-values (status headers content) (http-conn-recv! conn))
      (define code (status-code status))
      (unless (equal? code 200)
        (define detail
          (with-handlers ([exn:fail? (lambda (_) "")])
            (port->string content)))
        (raise (llm-error (format "~a~a"
                                  (or code (bytes->string/utf-8 status))
                                  (if (string=? detail "") "" (string-append " — " (string-normalize-spaces detail))))
                          code)))
      (if on-delta
          (read-sse-deltas content on-delta)
          (read-non-stream-content content)))
    (lambda ()
      (http-conn-close! conn))))))

(define (read-non-stream-content in)
  (define j (read-json in))
  (define content
    (and (hash? j)
         (let ([choices (hash-ref j 'choices #f)])
           (and (pair? choices)
                (let ([choice (car choices)])
                  (and (hash? choice)
                       (let ([message (hash-ref choice 'message #f)])
                         (and (hash? message)
                              (hash-ref message 'content #f)))))))))
  (if (string? content) content ""))

;; Parse an upstream SSE body, extracting choices[0].delta.content pieces.
;; Mirrors llm.ts: non-"data:" lines are skipped, "[DONE]" ends the stream,
;; unparseable lines (partial frames) are skipped. The loop continues past
;; [DONE] until EOF so trailing frames can't truncate earlier deltas.
(define (read-sse-deltas in on-delta)
  (define full (open-output-string))
  (let loop ()
    (define line (read-line in 'any))
    (unless (eof-object? line)
      (define s (string-trim line))
      (when (string-prefix? s "data:")
        (define data (string-trim (substring s 5)))
        (unless (equal? data "[DONE]")
          (define j (with-handlers ([exn:fail? (lambda (_) #f)]) (read-json (open-input-string data))))
          (when (hash? j)
            (define delta
              (let* ([choices (hash-ref j 'choices #f)]
                     [choice (and (pair? choices) (car choices))])
                (and (hash? choice)
                     (hash-ref choice 'delta #f)
                     (hash-ref (hash-ref choice 'delta) 'content #f))))
            (when (string? delta)
              (display delta full)
              (on-delta delta)))))
      (loop)))
  (get-output-string full))

;; Retry envelope with the same decision table as llm.ts chat().
(define (chat cfg msgs
              #:json-mode [json-mode #f]
              #:max-tokens [max-tokens #f]
              #:temperature [temperature 0.3]
              #:on-delta [on-delta #f])
  (define (attempt jm first?)
    (with-handlers
        ;; network-level failures (DNS, refused, TLS) surface as plain
        ;; exn:fail — wrap them so callers always see exn:llm
        ([exn:fail:network?
          (lambda (e)
            (raise (llm-error (string-replace (exn-message e) "\n" " ") #f)))]
         [exn:llm?
          (lambda (e)
            (define status (llm-error-status e))
            (cond
              ;; Some OpenAI-compatible endpoints reject response_format with
              ;; 400/422; prompts already demand JSON-only output, retry bare.
              [(and first? json-mode (or (equal? status 400) (equal? status 422)))
               (attempt #f #f)]
              ;; Rate-limited (common on free tiers): one patient retry.
              [(and first? (equal? status 429))
               (sleep 3)
               (attempt jm #f)]
              [else (raise e)]))])
      (chat-once cfg msgs
                 #:json-mode jm
                 #:max-tokens max-tokens
                 #:temperature temperature
                 #:on-delta on-delta)))
  (attempt json-mode #t))

;; Models sometimes wrap JSON in ```json fences or prose; find the object.
;; The greedy dotall match spans the first "{" to the last "}".
(define (extract-json raw)
  (define m (regexp-match #px"(?s:\\{.*\\})" raw))
  (unless m
    (raise (llm-error "no JSON in model output" #f)))
  (with-handlers ([exn:fail? (lambda (e) (raise (llm-error "no JSON in model output" #f)))])
    (read-json (open-input-string (first m)))))

;; Quick connectivity + auth check for the settings page: GET /models must
;; answer 200 (port of llm.ts testLLM).
(define (test-llm cfg)
  (define-values (host port ssl? path) (split-endpoint (llm-config-base-url cfg)))
  (define models-path
    (string-append (string-trim (llm-config-base-url cfg) #px"/+") "/models"))
  (define conn (http-conn-open host #:port (or port (if ssl? 443 80)) #:ssl? ssl?))
  (dynamic-wind
    void
    (lambda ()
      (http-conn-send! conn (string->bytes/utf-8 models-path)
                       #:headers
                       (list (bytes-append #"Authorization: Bearer "
                                           (string->bytes/utf-8 (llm-config-api-key cfg)))))
      (define-values (status headers content) (http-conn-recv! conn))
      (define code (status-code status))
      (unless (equal? code 200)
        (raise (llm-error (format "~a" (or code (bytes->string/utf-8 status))) code))))
    (lambda () (http-conn-close! conn))))
