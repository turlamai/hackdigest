#lang racket/base

;; Update detection against GitHub Releases (R1 scope — see
;; docs/GLAZE-MIGRATION.md: the Tauri in-place installer is replaced by
;; "open the release page"; the full download/install chain is R3).

(require json
         net/http-client
         racket/contract
         racket/list
         racket/string
         glaze/semver)

(provide
 (contract-out
  [strip-v (-> string? string?)]
  [check-latest-release (-> string? (or/c (hash/c symbol? jsexpr?) #f))]))

(define (strip-v version)
  (if (string-prefix? version "v") (substring version 1) version))

;; manifest-url is the repo's releases/latest landing page family; we query
;; the GitHub API for the newest published release. Returns
;; (hasheq 'version 'url 'body) or #f when there is nothing newer or the
;; endpoint is unreachable.
(define (check-latest-release current-version)
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (define conn (http-conn-open "api.github.com" #:port 443 #:ssl? #t))
    (dynamic-wind
      void
      (lambda ()
        (http-conn-send! conn
                         #"/repos/turlamai/hackdigest/releases/latest"
                         #:headers (list #"User-Agent: hackdigest-updater"
                                         #"Accept: application/vnd.github+json"))
        (define-values (status headers content) (http-conn-recv! conn))
        (define code
          (let ([m (regexp-match #px"^HTTP/[0-9.]+ +([0-9]{3})" status)])
            (and m (string->number (bytes->string/utf-8 (second m))))))
        (and (equal? code 200)
             (let* ([j (read-json content)]
                    [tag (and (hash? j) (hash-ref j 'tag_name #f))]
                    [version (and (string? tag) (strip-v tag))]
                    [current (strip-v current-version)]
                    [newer (and (string? version)
                                (semver? version)
                                (semver? current)
                                (semver>? version current))])
               (and newer
                    (hash? j)
                    (hasheq 'version version
                            'url (hash-ref j 'html_url
                                           "https://github.com/turlamai/hackdigest/releases")
                            'body (or (hash-ref j 'body #f) ""))))))
      (lambda () (http-conn-close! conn)))))
