#lang racket/base

;; Updater tests: signed-manifest round trip, selection, and artifact
;; verification. Signature tests run against an ephemeral Ed25519 keypair
;; (OpenSSL 3 CLI is only needed to mint the fixture keys — production
;; verification uses the crypto/libcrypto FFI) and are skipped gracefully
;; where no OpenSSL 3 exists. No network is involved.

(require crypto
         glaze/update
         json
         net/base64
         racket/file
         racket/path
         racket/port
         racket/string
         racket/system
         rackunit
         "update.rkt")

;; ---- pure helpers ----

(test-case "platform identity"
  (check-pred symbol? (platform-symbol))
  (check-pred symbol? (architecture-symbol))
  (check-pred string? (installer-extension)))

(test-case "manifest url joins the moving latest location"
  (parameterize ([current-update-base-url #f])
    (check-equal? (manifest-url)
                  "https://github.com/turlamai/hackdigest/releases/latest/download/update-manifest.json"))
  (parameterize ([current-update-base-url "http://127.0.0.1:9/feed"])
    (check-equal? (manifest-url)
                  "http://127.0.0.1:9/feed/update-manifest.json")))

(test-case "install mode is one of the documented kinds"
  (check-pred (lambda (m) (member m '(in-place manual page))) (install-mode)))

(test-case "bundle detection from an executable path"
  (define (bundle s) (and (bundle-from-exe-path (string->path s)) (path->string (bundle-from-exe-path (string->path s)))))
  ;; packaged mac layouts — the ABSOLUTE bundle path, not a bare element
  (check-equal? (bundle "/Applications/HackDigest.app/Contents/MacOS/HackDigest")
                "/Applications/HackDigest.app")
  (check-equal? (bundle "/tmp/hd-e2e/instance/HackDigest.app/Contents/MacOS/HackDigest")
                "/tmp/hd-e2e/instance/HackDigest.app")
  ;; dev and non-mac layouts must not be mistaken for a bundle
  (check-false (bundle "/opt/homebrew/bin/racket"))
  (check-false (bundle "/Applications/HackDigest.app/Contents/MacOS/bin/HackDigest"))
  (check-false (bundle "/Applications/HackDigest.app/Contents/HackDigest")))

(test-case "self-path resolution survives a launcher chdir"
  (define (resolve raw orig) (path->string (resolve-self-path (string->path raw) (string->path orig))))
  ;; absolute invocation is untouched
  (check-equal? (resolve "/tmp/hd-e2e/instance/HackDigest.app/Contents/MacOS/HackDigest" "/")
                "/tmp/hd-e2e/instance/HackDigest.app/Contents/MacOS/HackDigest")
  ;; relative argv[0] resolves against the launch-time directory, not cwd
  (check-equal? (resolve "./instance/HackDigest.app/Contents/MacOS/HackDigest" "/tmp/hd-e2e")
                "/tmp/hd-e2e/instance/HackDigest.app/Contents/MacOS/HackDigest")
  (check-equal? (resolve "HackDigest.exe" "/opt/apps/hackdigest")
                "/opt/apps/hackdigest/HackDigest.exe"))

;; ---- fixture keypair ----

;; OpenSSL 3 is required for Ed25519 (macOS's LibreSSL cannot do it).
(define (find-openssl3)
  (for/or ([candidate (in-list
                       (list "/opt/homebrew/opt/openssl@3/bin/openssl"
                             "/usr/local/opt/openssl@3/bin/openssl"
                             (find-executable-path "openssl")))])
    (define out
      (and candidate
           (with-handlers ([exn:fail? (lambda (_) "")])
             (with-output-to-string (lambda () (system* candidate "version"))))))
    (and (regexp-match? #px"OpenSSL 3" (or out "")) candidate)))

(define openssl (find-openssl3))

(define-values (private-key test-dir)
  (cond
    [openssl
     (define dir (make-temporary-file "hd-update-keys~a" 'directory))
     (define priv (build-path dir "private.der"))
     (define pub (build-path dir "public.pem"))
     ;; OneAsymmetricKey DER — what crypto's datum->pk-key consumes (the
     ;; family scripts convert PEM → DER once at signing time).
     (check-true
      (zero? (system*/exit-code openssl "genpkey" "-algorithm" "ed25519"
                                "-outform" "DER" "-out" (path->string priv)))
      "openssl could not generate an Ed25519 key")
     (check-true
      (zero? (system*/exit-code openssl "pkey" "-in" (path->string priv)
                                "-inform" "DER" "-pubout" "-out" (path->string pub)))
      "openssl could not export the public key")
     (values (datum->pk-key (file->bytes priv) 'OneAsymmetricKey) dir)]
    [else
     (displayln "skip: signed-manifest tests (no OpenSSL 3 found)")
     (values #f #f)]))

;; A minimal valid manifest struct for this platform.
(define (test-manifest [version "9.9.9"])
  (update-manifest
   app-identifier version 1 'stable "2026-10-10T00:00:00Z" "0.0.0" #f #t 100
   (list (update-artifact (platform-symbol) (architecture-symbol)
                          "https://example.invalid/x.zip"
                          (make-string 64 #\a)
                          1234 'zip '() #f)
         (update-artifact 'macos 'x64 "https://example.invalid/y.zip"
                          (make-string 64 #\b) 2345 'zip '() #f)
         (update-artifact 'windows 'x64 "https://example.invalid/w.zip"
                          (make-string 64 #\c) 3456 'zip '() #f)
         (update-artifact 'linux 'x64 "https://example.invalid/l.tar.gz"
                          (make-string 64 #\d) 4567 'targz '() #f))))

(define (payload->wrapper payload signature-bytes [key-id update-key-id])
  (hasheq 'schema 1
          'payload (bytes->string/utf-8 (base64-encode payload #""))
          'signature
          (hasheq 'algorithm "ed25519"
                  'key_id key-id
                  'value (bytes->string/utf-8
                          (base64-encode signature-bytes #"")))))

(define fixture-public-key
  (and private-key
       (datum->pk-key (pk-key->datum private-key 'rkt-public) 'rkt-public)))

(define (wrapper-input wrapper)
  (open-input-bytes (string->bytes/utf-8 (jsexpr->string wrapper))))

(define (verify-fixture input #:key-id [key-id update-key-id])
  (verify-manifest-signature input
                             #:key-id key-id
                             #:public-key fixture-public-key))

;; ---- signed wrapper round trip (the family feed format) ----

(when private-key
  (test-case "verify-manifest-signature accepts a correct signature"
    (define payload (update-manifest->payload-bytes (test-manifest)))
    ;; the payload must pass glaze's own schema validation
    (check-equal?
     (update-manifest-version (payload-bytes->update-manifest payload))
     "9.9.9")
    (define signature (pk-sign private-key payload))
    (define verified
      (verify-fixture (wrapper-input (payload->wrapper payload signature))))
    (check-equal? (update-manifest-version verified) "9.9.9")
    (check-equal? (update-manifest-application-id verified) app-identifier)
    (check-equal? (length (update-manifest-artifacts verified)) 4))

  (test-case "verify-manifest-signature rejects a tampered payload"
    (define payload (update-manifest->payload-bytes (test-manifest)))
    (define signature (pk-sign private-key payload))
    ;; bump the version inside the payload, keep the original signature
    (define tampered (regexp-replace #px"\"version\":\"9\\.9\\.9\""
                                     (bytes->string/utf-8 payload)
                                     "\"version\":\"9.9.10\""))
    (check-exn exn:fail?
               (lambda ()
                 (verify-fixture
                  (wrapper-input
                   (payload->wrapper (string->bytes/utf-8 tampered)
                                     signature))))))

  (test-case "verify-manifest-signature rejects a foreign key id"
    (define payload (update-manifest->payload-bytes (test-manifest)))
    (define signature (pk-sign private-key payload))
    (check-exn exn:fail?
               (lambda ()
                 (verify-fixture
                  (wrapper-input (payload->wrapper payload signature))
                  #:key-id "someone-elses-key"))))

  (test-case "verify-manifest-signature rejects garbage signatures"
    (define payload (update-manifest->payload-bytes (test-manifest)))
    (check-exn exn:fail?
               (lambda ()
                 (verify-fixture
                  (wrapper-input
                   (payload->wrapper payload (make-bytes 64 0))))))))

;; ---- selection ----

(test-case "select-update picks this platform's artifact"
  (define (config-for version [rollout 0])
    (updater-config app-identifier version 'stable
                    (platform-symbol) (architecture-symbol)
                    #f update-key-id rollout 1000))
  (define candidate (select-update (config-for "9.9.8") (test-manifest)))
  (check-true (update-candidate? candidate))
  (check-equal? (update-artifact-platform (update-candidate-artifact candidate))
                (platform-symbol))
  (check-equal? (update-artifact-architecture (update-candidate-artifact candidate))
                (architecture-symbol))
  ;; the mac x64 entry must never be chosen by an arm64 mac (and vice versa)
  (unless (and (eq? (platform-symbol) 'macos) (eq? (architecture-symbol) 'x64))
    (check-false (eq? (update-artifact-size (update-candidate-artifact candidate))
                      2345)))
  ;; equal version → not an update
  (check-false (select-update (config-for "9.9.9") (test-manifest)))
  ;; older builds update
  (check-true (update-candidate? (select-update (config-for "0.1.0") (test-manifest))))
  ;; rollout gate: bucket 99 < rollout 100 passes, bucket 100 never does
  (check-true (update-candidate? (select-update (config-for "0.1.0" 99) (test-manifest)))))

(test-case "select-update rejects a foreign application identity"
  (check-exn exn:fail?
             (lambda ()
               (select-update
                (updater-config "io.glaze.SomeoneElse" "0.1.0" 'stable
                                (platform-symbol) (architecture-symbol)
                                #f update-key-id 0 1000)
                (test-manifest)))))

;; ---- artifact verification ----

(test-case "verify-artifact! enforces size and sha256"
  (define dir (make-temporary-file "hd-update-art~a" 'directory))
  (define payload-bytes (make-bytes 1000 65))
  (define file (build-path dir "artifact.zip"))
  (call-with-output-file file
    (lambda (out) (write-bytes payload-bytes out))
    #:exists 'truncate)
  (define sha (bytes->hex-string (sha256-bytes payload-bytes)))
  (define (candidate-for size)
    (update-candidate
     (update-manifest app-identifier "9.9.9" 1 'stable
                      "2026-10-10T00:00:00Z" "0.0.0" #f #t 100
                      (list (update-artifact (platform-symbol)
                                             (architecture-symbol)
                                             "https://example.invalid/x.zip"
                                             sha size 'zip '() #f)))
     (update-artifact (platform-symbol) (architecture-symbol)
                      "https://example.invalid/x.zip"
                      sha size 'zip '() #f)))
  (check-equal? (verify-artifact! (candidate-for 1000) file) file)
  (check-exn exn:fail? (lambda () (verify-artifact! (candidate-for 999) file)))
  ;; a flipped digest is rejected
  (define wrong-sha (make-string 64 (if (equal? #\a #\a) #\b #\a)))
  (check-exn exn:fail?
             (lambda ()
               (verify-artifact!
                (update-candidate
                 (update-manifest app-identifier "9.9.9" 1 'stable
                                  "2026-10-10T00:00:00Z" "0.0.0" #f #t 100
                                  (list (update-artifact
                                         (platform-symbol) (architecture-symbol)
                                         "https://example.invalid/x.zip"
                                         wrong-sha 1000 'zip '() #f)))
                 (update-artifact (platform-symbol) (architecture-symbol)
                                  "https://example.invalid/x.zip"
                                  wrong-sha 1000 'zip '() #f))
                file))))
