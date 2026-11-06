#lang racket/base

;; System keyring storage for the BYOK API key — product-side FFI (the
;; family architecture assigns secret custody to products; glaze has no
;; general secure-storage primitive). One logical item per install:
;;   macOS:   Security.framework SecItem* (kSecClassGenericPassword)
;;   Windows: advapi32 CredWriteW / CredReadW / CredDeleteW
;;   Linux:   libsecret Secret Service (optional at load time)
;; A missing keyring is not an error: unavailable stores report #f from
;; available? and settings-rpc.rkt degrades to the explicit
;; "plaintext-optout" path.
;;
;; current-secure-store is the seam tests use: an in-memory store with the
;; same four operations, so the settings/migration logic is exercised in CI
;; (GitHub runners have no keyring) while the real FFI is validated on the
;; family VMs (evidence in issue #2).

(require ffi/unsafe
         ffi/unsafe/define
         (rename-in racket/contract [-> c->])
         racket/string)

(provide
 (contract-out
  [keyring-service string?]
  [keyring-account string?]
  [struct secure-store ([available? (c-> boolean?)]
                        [get (c-> (or/c string? #f))]
                        [set! (c-> string? void?)]
                        [remove! (c-> void?)])]
  [current-secure-store (parameter/c secure-store?)]
  [make-memory-store! (c-> secure-store?)]
  [macos-store (or/c secure-store? #f)]
  [windows-store (or/c secure-store? #f)]
  [linux-store (or/c secure-store? #f)]))

;; Logical item identity: one BYOK key per install.
(define keyring-service "hackdigest")
(define keyring-account "byok-api-key")

(struct secure-store (available? get set! remove!))

;; ---- memory store (tests / seam) --------------------------------------------

(define (make-memory-store!)
  (define table (make-hash))
  (secure-store
   (λ () #t)
   (λ () (hash-ref table 'key #f))
   (λ (v) (hash-set! table 'key v))
   (λ () (hash-remove! table 'key))))

;; Unavailable placeholder: settings-rpc treats available? = #f as "refuse
;; to migrate, use the explicit plaintext-optout path".
(define unavailable-store
  (secure-store (λ () #f) (λ () #f) (λ (v) (void)) (λ () (void))))

;; ---- macOS: Security.framework SecItem --------------------------------------

;; A missing framework falls back to the process namespace: the definer
;; resolves bindings lazily (make-not-available), and macos-available gates
;; every call, so nothing is touched on other platforms.
(define sec-lib
  (with-handlers ([exn:fail? (λ (_) (ffi-lib #f))])
    (ffi-lib "/System/Library/Frameworks/Security.framework/Security")))
(define cf-lib
  (with-handlers ([exn:fail? (λ (_) (ffi-lib #f))])
    (ffi-lib "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")))

(define-ffi-definer define-sec sec-lib
  #:default-make-fail make-not-available)
(define-ffi-definer define-cf cf-lib
  #:default-make-fail make-not-available)

(define-sec SecItemAdd (_fun _pointer _pointer -> _int32))
(define-sec SecItemCopyMatching
    (_fun _pointer (res : (_ptr o _pointer)) -> (status : _int32) -> (values res status)))
(define-sec SecItemDelete (_fun _pointer -> _int32))
(define-cf CFStringCreateWithCString
    (_fun _pointer _string/utf-8 _uint32 -> _pointer))
(define-cf CFDictionaryCreateMutable
    (_fun _pointer _long _pointer _pointer -> _pointer))
(define-cf CFDictionarySetValue (_fun _pointer _pointer _pointer -> _void))
(define-cf CFDataCreate (_fun _pointer _pointer _long -> _pointer))
(define-cf CFDataGetLength (_fun _pointer -> _long))
(define-cf CFDataGetBytePtr (_fun _pointer -> _pointer))
(define-cf CFRelease (_fun _pointer -> _void))

;; kSec*/kCF* pointer-valued globals read straight through _pointer;
;; kCFTypeDictionary*CallBacks are struct globals — copy them so their
;; address can be passed.
(define-cstruct _CFDictCallbacks
  ([version _long]
   [retain _pointer]
   [release _pointer]
   [copyDescription _pointer]
   [equal _pointer]
   [hash _pointer]))

(define macos-store
  (and (eq? (system-type) 'macosx)
       (with-handlers ([exn:fail? (λ (_) #f)])
         ;; Probe: the globals this store needs must actually resolve.
         (get-ffi-obj "kSecClass" sec-lib _pointer)
         (get-ffi-obj "kCFTypeDictionaryKeyCallBacks" cf-lib _CFDictCallbacks)
         #t)
       (let ()
         (define k-cf-true (get-ffi-obj "kCFBooleanTrue" cf-lib _pointer))
         (define dict-key-callbacks
           (get-ffi-obj "kCFTypeDictionaryKeyCallBacks" cf-lib _CFDictCallbacks))
         (define dict-val-callbacks
           (get-ffi-obj "kCFTypeDictionaryValueCallBacks" cf-lib _CFDictCallbacks))
         (define k-class (get-ffi-obj "kSecClass" sec-lib _pointer))
         (define k-class-generic (get-ffi-obj "kSecClassGenericPassword" sec-lib _pointer))
         (define k-attr-service (get-ffi-obj "kSecAttrService" sec-lib _pointer))
         (define k-attr-account (get-ffi-obj "kSecAttrAccount" sec-lib _pointer))
         (define k-return-data (get-ffi-obj "kSecReturnData" sec-lib _pointer))
         (define k-value-data (get-ffi-obj "kSecValueData" sec-lib _pointer))
         (define utf8 134217984) ; kCFStringEncodingUTF8
         (define err-item-not-found -25300)

         (define (query-dict extra)
           (define dict (CFDictionaryCreateMutable #f 0 dict-key-callbacks dict-val-callbacks))
           (define (set k v) (CFDictionarySetValue dict k v))
           (set k-class k-class-generic)
           (set k-attr-service (CFStringCreateWithCString #f keyring-service utf8))
           (set k-attr-account (CFStringCreateWithCString #f keyring-account utf8))
           (for ([kv (in-list extra)]) (set (car kv) (cdr kv)))
           dict)

         (secure-store
          (λ () #t)
          (λ ()
            (define q (query-dict (list (cons k-return-data k-cf-true))))
            (define-values (data status) (SecItemCopyMatching q))
            (CFRelease q)
            (cond
              [(and data (= status 0))
               (define len (CFDataGetLength data))
               (define b (make-bytes len))
               (memcpy b (CFDataGetBytePtr data) len)
               (CFRelease data)
               (bytes->string/utf-8 b)]
              [(= status err-item-not-found) #f]
              [else (error 'keyring-get "SecItemCopyMatching failed: ~a" status)]))
          (λ (v)
            (define b (string->bytes/utf-8 v))
            ;; CFDataCreate copies the buffer; passing the bytes object as
            ;; the pointer arg keeps it alive for the call.
            (define data (CFDataCreate #f b (bytes-length b)))
            (define del-q (query-dict '()))
            (define del-status (SecItemDelete del-q))
            (CFRelease del-q)
            (unless (or (= del-status 0) (= del-status err-item-not-found))
              (error 'keyring-set! "SecItemDelete failed: ~a" del-status))
            (define add-q (query-dict (list (cons k-value-data data))))
            (define status (SecItemAdd add-q #f))
            (CFRelease add-q)
            (unless (= status 0)
              (error 'keyring-set! "SecItemAdd failed: ~a" status))
            (void))
          (λ ()
            (define q (query-dict '()))
            (define status (SecItemDelete q))
            (CFRelease q)
            (unless (or (= status 0) (= status err-item-not-found))
              (error 'keyring-remove! "SecItemDelete failed: ~a" status)))))))

;; ---- Windows: advapi32 Credential Manager -----------------------------------

(define windows-store
  (and (eq? (system-type) 'windows)
       (with-handlers ([exn:fail? (λ (_) #f)])
         (define advapi32 (ffi-lib "Advapi32.dll"))
         (define-cstruct _FILETIME
           ([dwLowDateTime _uint32]
            [dwHighDateTime _uint32]))
         (define-cstruct _CREDENTIALW
           ([Flags _uint32]
            [Type _uint32]
            [TargetName _string/utf-16]
            [Comment _string/utf-16]
            [LastWritten _FILETIME]
            [CredentialBlobSize _uint32]
            [CredentialBlob _pointer]
            [Persist _uint32]
            [AttributeCount _uint32]
            [Attributes _pointer]
            [TargetAlias _string/utf-16]
            [UserName _string/utf-16]))
         (define-ffi-definer define-advapi advapi32
           #:default-make-fail make-not-available)
         (define-advapi CredWriteW (_fun _CREDENTIALW-pointer/null _uint32 -> _bool))
         (define-advapi CredReadW
           (_fun _string/utf-16 _uint32 _uint32
                 (c : (_ptr o _CREDENTIALW-pointer/null))
                 -> (ok : _bool)
                 -> (and ok c)))
         (define-advapi CredDeleteW (_fun _string/utf-16 _uint32 _uint32 -> _bool))
         (define-advapi CredFree (_fun _pointer -> _void))
         (define target (string-append keyring-service "/" keyring-account))
         (define cred-type-generic 1)
         (define cred-persist-local-machine 2)

         (secure-store
          (λ () #t)
          (λ ()
            (define c (CredReadW target cred-type-generic 0))
            (and c
                 (let* ([size (CREDENTIALW-CredentialBlobSize c)]
                        [b (make-bytes size)])
                   (memcpy b (CREDENTIALW-CredentialBlob c) size)
                   (CredFree c)
                   (bytes->string/utf-8 b))))
          (λ (v)
            (define blob (string->bytes/utf-8 v))
            (define blob-ptr (malloc (bytes-length blob) 'raw))
            (memcpy blob-ptr blob (bytes-length blob))
            (define c (make-CREDENTIALW
                       0 cred-type-generic
                       target #f
                       (make-FILETIME 0 0)
                       (bytes-length blob) blob-ptr
                       cred-persist-local-machine
                       0 #f #f #f))
            (begin0 (unless (CredWriteW c 0) (error 'keyring-set! "CredWriteW failed"))
              (free blob-ptr)
              (free c)))
          (λ ()
            ;; Absence is fine on delete.
            (unless (CredDeleteW target cred-type-generic 0)
              (void)))))))

;; ---- Linux: libsecret (Secret Service) --------------------------------------

(define linux-store
  (and (not (memq (system-type) '(macosx windows)))
       (with-handlers ([exn:fail? (λ (_) #f)])
         (define libsecret
           (ffi-lib '("libsecret-1.so.0" "libsecret-1.so" "libsecret-1.so.1")))
         (define-ffi-definer define-secret libsecret
           #:default-make-fail make-not-available)
         ;; NULL schema + one fixed attribute pair, NULL-terminated: the
         ;; varargs tail of secret_password_*_sync reads exactly this shape.
         (define-secret secret_password_store_sync
           (_fun _pointer _string _string _string _pointer
            (err : (_ptr o _pointer))
            _string _string _pointer
            -> (ok : _bool)
            -> (values ok err)))
         (define-secret secret_password_lookup_sync
           (_fun _pointer _pointer
            (err : (_ptr o _pointer))
            _string _string _pointer
            -> (res : (_or-null _string))
            -> (values res err)))
         (define-secret secret_password_clear_sync
           (_fun _pointer _pointer
            (err : (_ptr o _pointer))
            _string _string _pointer
            -> (ok : _bool)
            -> (values ok err)))
         (define-secret secret_free (_fun _pointer -> _void))

         ;; available? actually probes the Secret Service: with no daemon
         ;; running the lookup errors, and this store must report #f so
         ;; settings take the explicit plaintext-optout path.
         (secure-store
          (λ ()
            (with-handlers ([exn:fail? (λ (_) #f)])
              (define-values (_res _err)
                (secret_password_lookup_sync #f #f "service" keyring-service #f))
              #t))
          (λ ()
            (define-values (res _err)
              (secret_password_lookup_sync #f #f "service" keyring-service #f))
            (and (string? res) (non-empty-string? res)
                 (begin0 res (secret_free res))))
          (λ (v)
            (define-values (ok _err)
              (secret_password_store_sync #f #f
                                          (string-append keyring-service " " keyring-account)
                                          v #f
                                          "service" keyring-service #f))
            (unless ok (error 'keyring-set! "secret_password_store_sync failed"))
            (void))
          (λ ()
            (secret_password_clear_sync #f #f "service" keyring-service #f)
            (void))))))

;; ---- store selection ---------------------------------------------------------

(define default-store
  (or macos-store windows-store linux-store unavailable-store))

(define current-secure-store (make-parameter default-store))
