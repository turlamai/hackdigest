#lang racket/base

;; Tests for the prompt builders and response-map parsing (the pure layer of
;; the R2 orchestration port). Network flows are covered by llm-test's mock.

(require racket/string
         rackunit
         "../translate.rkt")

(test-case "lang-name"
  (check-equal? (lang-name "zh") "Simplified Chinese (简体中文)")
  (check-equal? (lang-name "zh-TW") "Traditional Chinese (繁體中文)")
  (check-equal? (lang-name "xx") "xx"))

(test-case "story prompts include title/text and the none case"
  (define p (story-prompts "Hello" "<p>body</p>" "zh"))
  (check-true (string-contains? (cdr p) "TITLE: Hello"))
  (check-true (string-contains? (cdr p) "TEXT (HTML): <p>body</p>"))
  (check-true (string-contains? (cdr p) "简体中文"))
  (define p2 (story-prompts "Hello" #f "zh"))
  (check-true (string-contains? (cdr p2) "TEXT: (none)")))

(test-case "comments prompts carry id markers and clip long text"
  (define long (make-string 2000 #\a))
  (define p (comments-prompts "zh" (list (cons 42 "short") (cons 43 long))))
  (check-true (string-contains? (cdr p) "[42] short"))
  (check-true (string-contains? (cdr p) "[43] aaaa"))
  (check-false (string-contains? (cdr p) (make-string 1600 #\a))))

(test-case "titles prompts carry id markers"
  (define p (titles-prompts "zh" (list (cons 1 "First") (cons 2 "Second"))))
  (check-true (string-contains? (cdr p) "[1] First"))
  (check-true (string-contains? (cdr p) "[2] Second")))

(test-case "extract-id-map cleans ids and drops empties"
  (define m (extract-id-map (hasheq 't (hasheq '|42| "a" '|[43]| "b" '|44| "" '|bad| "x"))))
  (check-equal? (hash-count m) 2)
  (check-equal? (hash-ref m 42) "a")
  (check-equal? (hash-ref m 43) "b")
  (check-equal? (hash-count (extract-id-map (hasheq 'nope 1))) 0))

(test-case "thread prompts cap comments and carry the sections"
  (define comments
    (for/list ([i (in-range 200)])
      (hasheq 'by (format "u~a" i) 'text (format "<p>c~a</p>" i))))
  (define story (hasheq 'id 1 'title "T" 'url "https://x" 'text "<p>body</p>"))
  (define p (thread-prompts story comments "zh"))
  (check-true (string-contains? (cdr p) "COMMENTS (150 of 200):"))
  (check-true (string-contains? (cdr p) "## 主要观点"))
  (check-true (string-contains? (cdr p) "## 一句话结论"))
  (check-false (string-contains? (cdr p) "c199")))

(test-case "tldr prompts use the 要点 contract"
  (define p (tldr-prompts (hasheq 'id 1 'title "T" 'text "body") "zh"))
  (check-true (string-contains? (car p) "要点："))
  (check-true (string-contains? (cdr p) "TITLE: T"))
  (check-true (string-contains? (cdr p) "TEXT: body")))

(test-case "daily prompts list stories with stats"
  (define p (daily-prompts
             (list (hasheq 'id 7 'title "Seven" 'score 42 'comments 9 'domain "example.com"))
             "2026-10-02" "zh"))
  (check-true (string-contains? (cdr p) "Today's top stories (2026-10-02):"))
  (check-true (string-contains? (cdr p) "- [7] Seven (42 pts, 9 comments, example.com)"))
  (check-true (string-contains? (car p) "编者注")))
