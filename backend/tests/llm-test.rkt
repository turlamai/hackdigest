#lang racket/base

;; Tests for the LLM client: pure helpers, SSE parsing, retry parity with
;; llm.ts, and streaming end-to-end against a loopback mock server.

(require json
         racket/async-channel
         racket/format
         racket/list
         racket/port
         racket/string
         racket/tcp
         rackunit
         "../llm.rkt")

(define cfg (llm-config "http://127.0.0.1:0/v1" "sk-test" "test-model"))

;; ---- pure helpers ----------------------------------------------------------

(test-case "chat endpoint"
  (check-equal? (chat-endpoint "https://api.deepseek.com/v1")
                "https://api.deepseek.com/v1/chat/completions")
  (check-equal? (chat-endpoint "https://api.deepseek.com/v1/")
                "https://api.deepseek.com/v1/chat/completions"))

(test-case "extract json from fenced / prose-wrapped output"
  ;; read-json object keys are symbols (Racket convention)
  (check-equal? (extract-json "```json\n{\"t\":{\"1\":\"a\"}}\n```")
                (hasheq 't (hasheq '|1| "a")))
  (check-equal? (extract-json "Sure! Here it is: {\"title\": \"x\"} hope that helps")
                (hasheq 'title "x"))
  (check-exn exn:fail? (lambda () (extract-json "no json here"))))

(test-case "sse delta parsing"
  (define deltas '())
  (define full
    (read-sse-deltas
     (open-input-string
      (string-append
       "data: {\"choices\":[{\"delta\":{\"content\":\"Hel\"}}]}\n"
       "\n"
       ": keep-alive comment\n"
       "data: {\"choices\":[{\"delta\":{\"content\":\"lo\"}}]}\n"
       "data: {\"choices\":[{\"delta\":{}}]}\n"
       "data: [DONE]\n"
       "data: {\"junk\":true}\n"))
     (lambda (d) (set! deltas (cons d deltas)))))
  (check-equal? full "Hello")
  (check-equal? (reverse deltas) (list "Hel" "lo")))

;; ---- loopback mock server ---------------------------------------------------

;; racket/tcp gives no accessor for an ephemeral listener's port, so pick a
;; random high port and retry on bind failure.
(define (listen-free-port!)
  (let loop ([attempt 0])
    (define port (+ 20000 (random 30000)))
    (with-handlers ([exn:fail:network? (lambda (_) (when (> attempt 20) (raise (exn:fail "no free port")) (loop (add1 attempt))))])
      (define listener (tcp-listen port 8 #t "127.0.0.1"))
      (values listener port))))

;; Serve `count` sequential HTTP responses on an ephemeral port. Each spec
;; is (list status-bytes body-bytes). Requests are drained so closing the
;; socket never resets before our response is out.
(define (with-mock-llm! specs proc)
  (define-values (listener port) (listen-free-port!))
  (define server-thread
    (thread
     (lambda ()
       (for ([spec (in-list specs)])
         (define-values (in out) (tcp-accept listener))
         (define status (first spec))
         (define body (second spec))
         (with-handlers ([exn:fail? void])
           (drain-request! in)
           (write-bytes
            (bytes-append #"HTTP/1.1 " status #" OK\r\n"
                          #"Content-Type: application/json\r\n"
                          #"Content-Length: " (string->bytes/utf-8 (~v (bytes-length body)))
                          #"\r\nConnection: close\r\n\r\n" body)
            out)
           (close-output-port out)
           (close-input-port in))))))
  (dynamic-wind
    void
    (lambda ()
      (sleep 0.05)
      (define result-thread
        (thread (lambda ()
                  (proc (llm-config (~a "http://127.0.0.1:" port "/v1") "sk-test" "test-model")))))
      ;; A mock/client deadlock must surface as a failure, not a hang.
      (unless (sync/timeout 20 result-thread)
        (kill-thread result-thread)
        (fail "mock test timed out after 20s")))
    (lambda ()
      (tcp-close listener)
      (kill-thread server-thread))))

(define (drain-request! in)
  (let loop ([content-length 0])
    (define line (read-line in 'any))
    (cond
      [(eof-object? line) (void)]
      [(string=? line "")
       (when (> content-length 0)
         (read-bytes content-length in))]
      [else
       (define m (regexp-match #px"(?i:content-length:\\s*)(\\d+)" line))
       (loop (if m (string->number (second m)) content-length))])))

(test-case "non-stream chat parses choices[0].message.content"
  (with-mock-llm!
   (list (list #"200" #"{\"choices\":[{\"message\":{\"content\":\"answer\"}}]}"))
   (lambda (cfg)
     (check-equal? (chat cfg (list (cons 'user "hi"))) "answer"))))

(test-case "http error surfaces as llm-error with status"
  (with-mock-llm!
   (list (list #"401" #"{\"error\":{\"message\":\"bad key\"}}"))
   (lambda (cfg)
     (check-exn
      (lambda (e) (and (exn:llm? e) (equal? (llm-error-status e) 401)))
      (lambda () (chat cfg (list (cons 'user "hi"))))))))

(test-case "400 with json-mode retries once without response_format"
  (with-mock-llm!
   (list (list #"400" #"{}")
         (list #"200" #"{\"choices\":[{\"message\":{\"content\":\"recovered\"}}]}"))
   (lambda (cfg)
     (check-equal? (chat cfg (list (cons 'user "hi")) #:json-mode #t) "recovered"))))

(test-case "streaming deltas arrive incrementally via on-delta"
  (define-values (listener port) (listen-free-port!))
  (define server-thread
    (thread
     (lambda ()
       (define-values (in out) (tcp-accept listener))
       (drain-request! in)
       (write-bytes
        #"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n"
        out)
       (flush-output out)
       ;; frame 1, then a pause, then frame 2 — the first delta must be on
       ;; the wire before the stream ends (incrementality).
       (write-bytes #"data: {\"choices\":[{\"delta\":{\"content\":\"Hel\"}}]}\n\n" out)
       (flush-output out)
       (sleep 0.1)
       (write-bytes #"data: {\"choices\":[{\"delta\":{\"content\":\"lo\"}}]}\n\ndata: [DONE]\n\n" out)
       (flush-output out)
       (close-output-port out)
       (close-input-port in))))
  (dynamic-wind
    void
    (lambda ()
      (define live-cfg (llm-config (~a "http://127.0.0.1:" port "/v1") "sk" "m"))
      (define chunks '())
      (define full
        (chat live-cfg (list (cons 'user "hi"))
              #:on-delta (lambda (d) (set! chunks (cons d chunks)))))
      (check-equal? full "Hello")
      (check-equal? (reverse chunks) (list "Hel" "lo")))
    (lambda ()
      (tcp-close listener)
      (kill-thread server-thread))))

(test-case "test-llm ok and auth failure"
  (with-mock-llm!
   (list (list #"200" #"{\"data\":[]}"))
   (lambda (cfg) (check-not-exn (lambda () (test-llm cfg)))))
  (with-mock-llm!
   (list (list #"401" #"{}"))
   (lambda (cfg)
     (check-exn
      (lambda (e) (and (exn:llm? e) (equal? (llm-error-status e) 401)))
      (lambda () (test-llm cfg))))))

(test-case "per-request deadline fires (custodian closes the socket)"
  (define-values (listener port) (listen-free-port!))
  ;; a server that accepts and then never answers
  (define server-thread
    (thread
     (lambda ()
       (define-values (in out) (tcp-accept listener))
       ;; hold both ports open, respond never
       (sync (make-semaphore)))))
  (dynamic-wind
    (lambda () (putenv "HACKDIGEST_LLM_TIMEOUT_SECS" "1"))
    (lambda ()
      (sleep 0.1)
      (define live-cfg (llm-config (~a "http://127.0.0.1:" port "/v1") "sk" "m"))
      (define t0 (current-inexact-milliseconds))
      (check-exn
       (lambda (e) (and (exn:llm? e) (string-contains? (exn-message e) "请求超时")))
       (lambda () (chat live-cfg (list (cons 'user "hi")))))
      (define dt (- (current-inexact-milliseconds) t0))
      (check-true (< dt 5000) "timeout must fire promptly, not hang")
      ;; the worker thread must not leak alive after shutdown
      (sleep 0.1))
    (lambda ()
      (putenv "HACKDIGEST_LLM_TIMEOUT_SECS" "")
      (tcp-close listener)
      (kill-thread server-thread))))

;; Page chat opts: JSON null arrives as the 'null symbol (read-json), not
;; #f — a naive hash-ref passed it into the llm contract and got the route
;; blamed on every page-initiated non-streaming chat (the page always sends
;; maxTokens: null for non-cap calls).
(test-case "chat-opts-from-jsexpr collapses JSON null to defaults"
  (define-values (jm mt tp) (chat-opts-from-jsexpr (hasheq 'jsonMode #f 'maxTokens 'null 'temperature 0.3)))
  (check-equal? jm #f)
  (check-equal? mt #f)
  (check-equal? tp 0.3))

(test-case "chat-opts-from-jsexpr passes numeric values through"
  (define-values (jm mt tp) (chat-opts-from-jsexpr (hasheq 'jsonMode #t 'maxTokens 512 'temperature 0.7)))
  (check-equal? jm #t)
  (check-equal? mt 512)
  (check-equal? tp 0.7))

(test-case "chat-opts-from-jsexpr defaults on missing keys"
  (define-values (jm mt tp) (chat-opts-from-jsexpr (hasheq)))
  (check-equal? jm #f)
  (check-equal? mt #f)
  (check-equal? tp 0.3))

;; ---- keep-alive server regression (issue #40) ------------------------------
;;
;; The hosted-Pro gate was blocked on a reported misframe against a
;; "keep-alive local mock" (garbled request paths + a net/http-conn contract
;; violation after repeated /api/translate/titles batches). llm.rkt cannot
;; misframe a persistent connection: every chat-once opens a fresh
;; http-conn, and Racket's http-conn-send! sends `Connection: close` unless
;; the caller passes its own Connection header — so there is no persistent
;; connection to misframe, and the old observation was an artifact of the
;; ad-hoc mock used that day (its 2026-11-08 re-run reproduced nothing:
;; 200/200 clean batches against a strict server, and paths stayed intact
;; even against a deliberately body-ignoring one).
;;
;; This regression locks in the property that matters: under a real
;; HTTP/1.1 keep-alive server (requests and responses framed strictly by
;; Content-Length, connections held open), 30 sequential titles batches
;; arrive fully framed — every request line parses, every body matches its
;; Content-Length, zero server-side parse failures — and every client call
;; gets its answer.

(define keepalive-batches 30)

;; Strict keep-alive mock: accept loop spawns a per-connection serve loop
;; that responds to requests until EOF, keeping the connection open
;; (Connection: keep-alive) and reading bodies strictly by Content-Length.
;; Counters are the output-side assertions: seen == expected requests,
;; parse-failures == 0.
(define (with-keepalive-mock! expected-batches proc)
  (define-values (listener port) (listen-free-port!))
  (define seen (box 0))
  (define parse-failures (box 0))
  (define (serve-connection! in out)
    (let loop ()
      (define line (read-line in 'any))
      (unless (eof-object? line)
        (define path line)
        (let headers-loop ([content-length 0])
          (define h (read-line in 'any))
          (cond
            [(eof-object? h) (void)]
            [(string=? h "")
             (define body (if (> content-length 0) (read-bytes content-length in) #""))
             (set-box! seen (add1 (unbox seen)))
             (define ok-request?
               (and (regexp-match? #px"^POST /v1/chat/completions .*$" path)
                    (= (bytes-length body) content-length)
                    (with-handlers ([exn:fail? (lambda (_) #f)])
                      (hash? (read-json (open-input-bytes body))))))
             (unless ok-request? (set-box! parse-failures (add1 (unbox parse-failures))))
             ;; The model output is a JSON *string*; build the two levels
             ;; as literals because jsexpr keys are symbols, not strings.
             (define content "{\"t\":{\"123\":\"translated title\"}}")
             (define body-out
               (jsexpr->string
                (hasheq 'choices (list (hasheq 'message (hasheq 'content content))))))
             (write-bytes
              (bytes-append #"HTTP/1.1 200 OK\r\n"
                            #"Content-Type: application/json\r\n"
                            #"Content-Length: "
                            (string->bytes/utf-8 (~v (string-length body-out)))
                            #"\r\nConnection: keep-alive\r\n\r\n"
                            (string->bytes/utf-8 body-out))
              out)
             (flush-output out)
             (loop)]
            [else
             (define m (regexp-match #px"(?i:content-length:\\s*)(\\d+)" h))
             (headers-loop (if m (string->number (second m)) content-length))])))))
  (define server-thread
    (thread
     (lambda ()
       (let accept-loop ()
         (define-values (in out) (tcp-accept listener))
         (thread (lambda ()
                   (with-handlers ([exn:fail? void])
                     (serve-connection! in out))
                   (close-input-port in)
                   (close-output-port out)))
         (accept-loop))))
    #|thread|#)
  (dynamic-wind
    void
    (lambda ()
      (sleep 0.05)
      ;; Surface proc failures instead of letting the worker thread die
      ;; silently: sync/timeout on a thread object returns just the same on
      ;; an exceptional death, and the swallowed error used to show up only
      ;; as a confusing seen-count mismatch.
      (define done (make-async-channel))
      (define result-thread
        (thread
         (lambda ()
           (async-channel-put
            done
            (with-handlers ([exn? (lambda (e) e)])
              (cons 'ok
                    (proc (llm-config (~a "http://127.0.0.1:" port "/v1")
                                      "sk-test"
                                      "test-model"))))))))
      (define r (sync/timeout 30 done))
      (cond
        [(not r)
         (kill-thread result-thread)
         (fail "keep-alive mock test timed out after 30s")]
        [(exn? r) (raise r)]
        [else (cdr r)]))
    (lambda ()
      (tcp-close listener)
      (kill-thread server-thread)))
  (check-equal? (unbox seen) expected-batches "mock saw every request")
  (check-equal? (unbox parse-failures) 0 "every request framed and parsed cleanly"))

(test-case "30 sequential titles batches stay framed against a keep-alive server"
  (with-keepalive-mock!
   keepalive-batches
   (lambda (cfg)
     (define msgs
       (list (cons 'system "You translate titles. Return JSON {\"t\":{...}}.")
             (cons 'user "[123] Some Title To Translate")))
     (for ([i (in-range keepalive-batches)])
       (check-equal?
        (chat cfg msgs #:json-mode #t #:max-tokens 4000)
        "{\"t\":{\"123\":\"translated title\"}}")))))
