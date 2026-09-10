;;;; tests/test-quickstart.scm
;;;;
;;;; Phase 2 regression test for the handle-based read-only API:
;;;; document-parse-file/document-parse-string, document-root,
;;;; node-by-path, node-value, node-scalar-value, with-document, and
;;;; document-destroy!'s idempotency -- an slibfyaml port of alibfyaml's
;;;; own test_quickstart.adb (itself a port of libfyaml's own
;;;; examples/quick-start.c), using the same tests/config.yaml fixture
;;;; for direct comparability.
;;;;
;;;; No typed-scalar checks yet (node-integer-value etc. don't exist
;;;; until Phase 3) -- every scalar check here compares node-scalar-value
;;;; against the literal source text.

(include "check.scm")

(import (slibfyaml documents))
(import (slibfyaml nodes))
(import (chicken condition))

(with-document (doc (document-parse-file "config.yaml"))
  (let ((root (document-root doc)))
    (check "root is a mapping" (node-mapping? root))

    (let ((server (node-by-path root "/server")))
      (check "By_Path finds /server" (node-valid? server))
      (check "server.host is localhost"
             (string=? "localhost" (node-scalar-value (node-value server "host"))))
      (check "server.port is 8080"
             (string=? "8080" (node-scalar-value (node-value server "port"))))
      (check "server.ssl is true"
             (string=? "true" (node-scalar-value (node-value server "ssl"))))
      (check "server has no such key \"nope\""
             (not (node-has-key? server "nope"))))

    (let ((db (node-value root "database")))
      (check "root has key \"database\"" (node-has-key? root "database"))
      (check "database.name is production_db"
             (string=? "production_db" (node-scalar-value (node-value db "name")))))

    (check "node-path of /server is \"/server\""
           (string=? "/server" (node-path (node-by-path root "/server"))))
    (check "node-path of root is \"/\""
           (string=? "/" (node-path root)))

    (check "By_Path on a nonexistent path returns null-node"
           (not (node-valid? (node-by-path root "/nope/nope"))))))

;; document-parse-string, and the buffer it copies its input into,
;; round-tripping correctly -- not exercised above, which is entirely
;; document-parse-file.
(with-document (doc (document-parse-string "greeting: hello\n"))
  (check "document-parse-string parses"
         (string=? "hello" (node-scalar-value (node-value (document-root doc) "greeting")))))

;; A deliberately malformed document raises (exn slibfyaml parse)
;; rather than crashing or returning a garbage document.
(check "malformed input raises (exn slibfyaml parse)"
       (condition-case
        (begin (document-parse-string "key: [unterminated") #f)
        ((exn slibfyaml parse) #t)
        (e () #f)))

;; document-destroy! is idempotent: destroying twice (once explicitly,
;; once more before with-document's own dynamic-wind cleanup would have
;; run anyway) must not double-free.
(let ((doc (document-parse-string "x: 1\n")))
  (document-destroy! doc)
  (document-destroy! doc)
  (check "document-destroy! is idempotent (no crash on second call)" #t))

;; A node accessor called after its document is destroyed raises
;; (exn slibfyaml use-after-free) rather than reading freed memory.
(check "use-after-free on a node from a destroyed document is caught"
       (let* ((doc (document-parse-string "x: 1\n"))
              (root (document-root doc)))
         (document-destroy! doc)
         (condition-case
          (begin (node-scalar-value (node-value root "x")) #f)
          ((exn slibfyaml use-after-free) #t)
          (e () #f))))

(check-summary-and-exit)
