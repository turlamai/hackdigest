#lang racket/base

(require rackunit
         racket/string
         "native-smoke.rkt")

;; The release-only fixture is synthetic and independent of real LLM
;; providers, user credentials, or the product's reviewed schema baseline.
(test-case "packaged native smoke covers the real consumer bridge"
  (for ([required (in-list '("glaze.hello()"
                             "api/health"
                             "api/kv/set"
                             "api/kv/get"
                             "invalid-args"
                             "api/__smoke/stream"
                             "api/__smoke/slow"
                             "HD Smoke PASS"
                             "HD Smoke FAIL"))])
    (check-true (string-contains? native-smoke-html required)
                (format "missing native smoke assertion: ~a" required)))
  (check-equal? (length (native-smoke-routes)) 2)
  (check-false (string-contains? native-smoke-html "apiKey"))
  (check-false (string-contains? native-smoke-html "llm/chat")))
