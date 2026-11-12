#lang racket/base

;; Pure-helper tests for update detection. The GitHub round trip is not
;; tested here (network-dependent); it is exercised on the real endpoint at
;; app startup via the UpdateBanner.

(require rackunit
         "../update-check.rkt")

(test-case "strip-v"
  (check-equal? (strip-v "v0.5.1") "0.5.1")
  (check-equal? (strip-v "0.5.1") "0.5.1"))
