;;;; tests/test-scheme.scm
;;;;
;;;; Phase 7 regression test for the value-materializing convenience
;;;; API: node->scheme's mapping/sequence/scalar decoding (including
;;;; that a malformed scalar degrades gracefully to its literal string
;;;; text rather than raising -- unlike the low-level typed accessors
;;;; test-scalars.scm exhaustively covers, which do raise), node->scheme
;;;; on a sub-tree (not just a document root), load-string/load-file
;;;; always returning a list of decoded documents (single- and
;;;; multi-document input), and resolve-anchors? #t vs #f on load-string.
;;;; No alibfyaml source to port -- see slibfyaml-scheme.scm's own
;;;; header comment for why.

(include "check.scm")

(import (slibfyaml scheme))
(import (slibfyaml documents))
(import (slibfyaml nodes))

(define (alookup key alist) (let ((p (assoc key alist))) (and p (cdr p))))

;; -----------------------------------------------------------------
;; node->scheme's scalar/mapping/sequence decoding, via load-string on
;; a single small document exercising every core-schema shape plus
;; both extensions, a nested mapping, and a sequence.
;; -----------------------------------------------------------------
(let* ((docs (load-string "
int_dec: 42
int_hex: 0x1A
int_bin: 0b1010
int_underscore: 1_000_000
big_int: 99999999999999999999999999999
float_val: 3.5
bool_true: true
bool_false: false
homepage: ~
name: widget
malformed: banana
tags: [alpha, beta, gamma]
nested:
  a: 1
  b: 2
"))
       (root (car docs)))
  (check "load-string returns a list of exactly 1 document" (= 1 (length docs)))
  (check "node->scheme: plain decimal integer decodes as an exact integer"
         (and (= 42 (alookup "int_dec" root)) (exact? (alookup "int_dec" root))))
  (check "node->scheme: 0x hex integer decodes correctly (extension)"
         (= 26 (alookup "int_hex" root)))
  (check "node->scheme: 0b binary integer decodes correctly (extension)"
         (= 10 (alookup "int_bin" root)))
  (check "node->scheme: underscore-separated integer decodes correctly (extension)"
         (= 1000000 (alookup "int_underscore" root)))
  (check "node->scheme: an integer too big for a machine word still decodes exactly (bignum)"
         (= 99999999999999999999999999999 (alookup "big_int" root)))
  (check "node->scheme: a value that is both valid integer and float grammar decodes as an integer, not a flonum"
         (integer? (alookup "int_dec" root)))
  (check "node->scheme: float decodes as a flonum"
         (= 3.5 (alookup "float_val" root)))
  (check "node->scheme: true decodes as #t" (eq? #t (alookup "bool_true" root)))
  (check "node->scheme: false decodes as #f" (eq? #f (alookup "bool_false" root)))
  (check "node->scheme: ~ decodes as '()" (null? (alookup "homepage" root)))
  (check "node->scheme: plain text decodes as a string" (string=? "widget" (alookup "name" root)))
  (check "node->scheme: malformed numeric-looking text degrades to its literal string, not an error"
         (string=? "banana" (alookup "malformed" root)))
  (check "node->scheme: a sequence decodes as a list of its decoded items"
         (equal? '("alpha" "beta" "gamma") (alookup "tags" root)))
  (check "node->scheme: a nested mapping decodes as a nested alist"
         (equal? '(("a" . 1) ("b" . 2)) (alookup "nested" root))))

;; -----------------------------------------------------------------
;; node->scheme works on a sub-tree, not just a document root -- a
;; genuine advantage over yaml/libyaml egg's own decoders, which can
;; only ever be pointed at the whole document.
;; -----------------------------------------------------------------
(with-document (doc (document-parse-string "server:\n  host: localhost\n  port: 8080\n"))
  (check "node->scheme on a sub-tree decodes just that sub-tree"
         (equal? '(("host" . "localhost") ("port" . 8080))
                 (node->scheme (node-value (document-root doc) "server")))))

;; -----------------------------------------------------------------
;; load-file always returns a list, matching the document count --
;; single document here (config.yaml, from Phase 2).
;; -----------------------------------------------------------------
(let ((docs (load-file "config.yaml")))
  (check "load-file on a single-document file returns a length-1 list" (= 1 (length docs)))
  (check "load-file's single decoded document reads back correctly"
         (string=? "localhost" (alookup "host" (alookup "server" (car docs))))))

;; -----------------------------------------------------------------
;; load-file/load-string on multi-document input return one decoded
;; alist per document, in order -- fixing yaml egg's actual
;; first-document-only limitation.
;; -----------------------------------------------------------------
(let ((docs (load-file "streams.yaml")))
  (check "load-file on a 3-document stream returns a length-3 list" (= 3 (length docs)))
  (check "load-file document 1 decodes correctly" (string=? "first" (alookup "name" (list-ref docs 0))))
  (check "load-file document 2 decodes correctly" (string=? "second" (alookup "name" (list-ref docs 1))))
  (check "load-file document 3 decodes correctly" (string=? "third" (alookup "name" (list-ref docs 2))))
  (check "load-file document 2's typed value decodes as an integer" (= 2 (alookup "value" (list-ref docs 1)))))

;; -----------------------------------------------------------------
;; resolve-anchors? #t (default) vs #f on load-string, using the same
;; anchors.yaml fixture test-anchors.scm already exercises at the
;; handle level.
;; -----------------------------------------------------------------
(let* ((docs-resolved (load-file "anchors.yaml"))
       (root-resolved (car docs-resolved)))
  (check "resolve-anchors? #t (default): alias resolves to the anchored mapping's content"
         (equal? '(("x" . 1) ("y" . 2)) (alookup "same" root-resolved)))
  (check "resolve-anchors? #t (default): merge key's pairs are merged into derived"
         (equal? 1 (alookup "x" (alookup "derived" root-resolved)))))

(let* ((docs-raw (load-file "anchors.yaml" #f))
       (root-raw (car docs-raw)))
  (check "resolve-anchors? #f: unresolved alias decodes as its own anchor-name text"
         (string=? "b" (alookup "same" root-raw)))
  (check "resolve-anchors? #f: unresolved merge key leaves an unmerged \"<<\" entry, not derived's real pairs"
         (not (alookup "x" (alookup "derived" root-raw)))))

(check-summary-and-exit)
