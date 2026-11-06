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
         ;; CREDENTIALW packed by hand for the x64 ABI (sizeof = 80). A
         ;; define-cstruct laid this out compactly and CredWriteW read
         ;; garbage pointers after the DWORD size field — startup heap
         ;; corruption (0xc0000374), caught live on the Windows VM. Manual
         ;; offsets remove every layout assumption:
         ;;   0 Flags(u32)   4 Type(u32)     8 TargetName(ptr)
         ;;  16 Comment(ptr)                24 LastWritten(2x u32)
         ;;  32 BlobSize(u32)  [pad to 40]  40 Blob(ptr)
         ;;  48 Persist(u32)  52 AttrCount(u32)
         ;;  56 Attributes(ptr) 64 TargetAlias(ptr) 72 UserName(ptr)
         (define credential-sizeof 80)
         (define (write-u32! buf off v)
           (integer->integer-bytes v 4 #f #t buf off))
         (define (write-ptr! buf off v)
           (ptr-set! buf _pointer off v))

         (define-ffi-definer define-advapi advapi32
           #:default-make-fail make-not-available)
         (define-advapi CredWriteW (_fun #:save-errno 'windows _bytes _uint32 -> _bool))
         (define-advapi CredReadW
           (_fun _string/utf-16 _uint32 _uint32
                 (c : (_ptr o _pointer))
                 -> (ok : _bool)
                 -> (and ok c)))
         (define-advapi CredDeleteW (_fun _string/utf-16 _uint32 _uint32 -> _bool))
         (define-advapi CredFree (_fun _pointer -> _void))
         (define target (string-append keyring-service "/" keyring-account))
         ;; NUL-terminated UTF-16LE (BMP only — the target name is ASCII).
         (define (string->utf16le-z s)
           (define b (make-bytes (+ (* 2 (string-length s)) 2) 0))
           (for ([ch (in-string s)] [i (in-naturals)])
             (define c (char->integer ch))
             (bytes-set! b (* 2 i) (bitwise-and c #xFF))
             (bytes-set! b (+ (* 2 i) 1) (bitwise-and (arithmetic-shift c -8) #xFF)))
           b)
         (define cred-type-generic 1)
         (define cred-persist-local-machine 2)

         (define (read-blob-from c)
           ;; c is the API-allocated CREDENTIALW; read blob size/pointer at
           ;; the ABI offsets (32/40; ptr-add counts bytes) and return the
           ;; UTF-8 key.
           (define size (ptr-ref (ptr-add c 32) _uint32))
           (cond
             [(<= size 0) ""]
             [else
              (define bp (ptr-ref (ptr-add c 40) _pointer))
              (define b (make-bytes size))
              (memcpy b bp size)
              (bytes->string/utf-8 b)]))

         (secure-store
          (λ () #t)
          (λ ()
            (define c (CredReadW target cred-type-generic 0))
            (and c
                 (begin0 (read-blob-from c)
                   (CredFree c))))
          (λ (v)
            (define blob (string->bytes/utf-8 v))
            (define target-w (string->utf16le-z target))
            (define blob-buf (malloc (bytes-length blob) 'raw))
            (memcpy blob-buf blob (bytes-length blob))
            (define target-buf (malloc (bytes-length target-w) 'raw))
            (memcpy target-buf target-w (bytes-length target-w))
            (define buf (make-bytes credential-sizeof 0))
            (write-u32! buf 0 0)                     ; Flags
            (write-u32! buf 4 cred-type-generic)     ; Type
            (write-ptr! buf 8 target-buf)            ; TargetName
            (write-ptr! buf 16 #f)                   ; Comment
            (write-u32! buf 24 0)                    ; LastWritten lo
            (write-u32! buf 28 0)                    ; LastWritten hi
            (write-u32! buf 32 (bytes-length blob))  ; CredentialBlobSize
            (write-ptr! buf 40 blob-buf)             ; CredentialBlob
            (write-u32! buf 48 cred-persist-local-machine) ; Persist
            (write-u32! buf 52 0)                    ; AttributeCount
            (write-ptr! buf 56 #f)                   ; Attributes
            (write-ptr! buf 64 #f)                   ; TargetAlias
            (write-ptr! buf 72 #f)                   ; UserName
            (define ok (CredWriteW buf 0))
            (free blob-buf)
            (free target-buf)
            (unless ok
              (error 'keyring-set! "CredWriteW failed (GetLastError ~a)" (saved-errno))))
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
