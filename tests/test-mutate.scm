;;;; tests/test-mutate.scm
;;;;
;;;; Phase 4 regression test for build + emit + mutate:
;;;; document-create-scalar/-sequence/-mapping, node-append!/
;;;; node-append-pair!, document-set-root!, document->yaml-string/
;;;; document-write-to-file!, and document-insert-at! -- including its
;;;; unconditional-consumption discipline, an slibfyaml port of
;;;; alibfyaml's own test_mutate.adb's three Insert_At scenarios,
;;;; extended to also cover the rest of Phase 4's surface (alibfyaml
;;;; doesn't bundle all of this into one test file the way slibfyaml's
;;;; own roadmap does).

(include "check.scm")

(import (slibfyaml documents))
(import (slibfyaml nodes))
(import (chicken condition))

;; -----------------------------------------------------------------
;; Building a document from scratch: create-*, node-append!/
;; node-append-pair!, document-set-root! -- and confirming none of
;; these consume their node arguments (unlike document-insert-at!
;; below).
;; -----------------------------------------------------------------
(with-document (doc (document-parse-string "placeholder: null"))
  (let* ((new-root (document-create-mapping doc))
         (tags (document-create-sequence doc))
         (tag1 (document-create-scalar doc "alpha"))
         (tag2 (document-create-scalar doc "beta"))
         (name-key (document-create-scalar doc "name"))
         (name-val (document-create-scalar doc "widget"))
         (tags-key (document-create-scalar doc "tags")))

    (node-append! tags tag1)
    (node-append! tags tag2)
    (check "node-append! does not consume its item (tag1 still valid)"
           (node-valid? tag1))
    (check "node-append! does not consume its item (tag1 scalar-value unchanged)"
           (string=? "alpha" (node-scalar-value tag1)))

    (node-append-pair! new-root name-key name-val)
    (node-append-pair! new-root tags-key tags)
    (check "node-append-pair! does not consume its key (name-key still valid)"
           (node-valid? name-key))
    (check "node-append-pair! does not consume its value (tags still valid)"
           (node-valid? tags))

    (document-set-root! doc new-root)
    (check "document-set-root! does not consume its argument (new-root still valid)"
           (node-valid? new-root))
    (check "document-set-root! took effect: document-root is our mapping"
           (node-mapping? (document-root doc)))
    (check "built tree reads back: name is widget"
           (string=? "widget" (node-scalar-value (node-value (document-root doc) "name"))))
    (check "built tree reads back: tags has 2 items"
           (= 2 (node-length (node-value (document-root doc) "tags"))))
    (check "built tree reads back: tags[2] is beta"
           (string=? "beta" (node-scalar-value (node-item (node-value (document-root doc) "tags") 2))))

    ;; -- document->yaml-string: round-trip through a fresh parse --
    (let ((default-text (document->yaml-string doc)))
      (with-document (doc2 (document-parse-string default-text))
        (check "document->yaml-string round-trips: name is widget"
               (string=? "widget" (node-scalar-value (node-value (document-root doc2) "name"))))
        (check "document->yaml-string round-trips: tags[1] is alpha"
               (string=? "alpha" (node-scalar-value (node-item (node-value (document-root doc2) "tags") 1)))))

      ;; -- a non-default emit flag actually changes the emitted text,
      ;; while the result still parses back to the same tree --
      (let ((json-text (document->yaml-string doc emit-mode-json)))
        (check "document->yaml-string with emit-mode-json differs from the default"
               (not (string=? default-text json-text)))
        (with-document (doc3 (document-parse-string json-text))
          (check "emit-mode-json output still round-trips: name is widget"
                 (string=? "widget" (node-scalar-value (node-value (document-root doc3) "name")))))))

    ;; -- document-write-to-file! --
    (document-write-to-file! doc "mutate-output.yaml")
    (with-document (doc4 (document-parse-file "mutate-output.yaml"))
      (check "document-write-to-file! round-trips: name is widget"
             (string=? "widget" (node-scalar-value (node-value (document-root doc4) "name")))))))

;; -----------------------------------------------------------------
;; document-insert-at! replacing an existing scalar with another
;; scalar: n is unref'ed by libfyaml and, having no other reference,
;; freed -- this binding nulls it out, so n reads back as not valid,
;; while the new value is reachable at path.
;; -----------------------------------------------------------------
(with-document (doc (document-parse-string "greeting: old"))
  (let ((fresh (document-create-scalar doc "hello")))
    (document-insert-at! doc "/greeting" fresh)
    (check "document-insert-at! replacing a scalar: n is nulled out (not left dangling)"
           (not (node-valid? fresh)))
    (check "document-insert-at! replacing a scalar: the value is reachable by path"
           (string=? "hello" (node-scalar-value (node-by-path (document-root doc) "/greeting"))))
    (check "a document-insert-at!-consumed node raises (exn slibfyaml consumed) on further use"
           (condition-case (begin (node-scalar-value fresh) #f)
             ((exn slibfyaml consumed) #t)
             (e () #f)))))

;; -----------------------------------------------------------------
;; document-insert-at! merging a mapping into an existing mapping: the
;; merge itself moves n's pairs into the target, but n is then
;; unref'ed the same as any other case -- with no other reference,
;; libfyaml frees it.
;; -----------------------------------------------------------------
(with-document (doc (document-parse-string "server: {host: localhost}"))
  (let ((patch (document-create-mapping doc)))
    (node-append-pair! patch (document-create-scalar doc "port") (document-create-scalar doc "8080"))
    (document-insert-at! doc "/server" patch)
    (check "document-insert-at! merging into an existing mapping: n is nulled out"
           (not (node-valid? patch)))
    (check "document-insert-at! merging: the merged value is reachable at /server/port"
           (string=? "8080" (node-scalar-value (node-by-path (document-root doc) "/server/port"))))
    (check "document-insert-at! merging: the original value is still reachable at /server/host"
           (string=? "localhost" (node-scalar-value (node-by-path (document-root doc) "/server/host"))))))

;; -----------------------------------------------------------------
;; document-insert-at! with a syntactically invalid path fails; n
;; must be nulled out rather than left pointing at what libfyaml just
;; freed. This is the core regression test for the fix (ported
;; directly from alibfyaml's own confirmed valgrind-caught bug).
;; -----------------------------------------------------------------
(with-document (doc (document-parse-string "{}"))
  (let ((fresh (document-create-scalar doc "orphan")))
    (check "document-insert-at! with an invalid path raises an error"
           (condition-case (begin (document-insert-at! doc "///not a valid path((" fresh) #f)
             (e () #t)))
    (check "document-insert-at! with an invalid path still nulls out n"
           (not (node-valid? fresh)))))

(check-summary-and-exit)
