;;;; tests/test-parse-errors.scm
;;;;
;;;; Phase 8 regression test for document-parse-file/-string on
;;;; malformed input, an slibfyaml port of alibfyaml's own
;;;; test_parse_errors.adb -- there, a regression test for a
;;;; Parse_Common double-free hit on *every* parse failure (see that
;;;; file's own header comment). slibfyaml's own parse-common already
;;;; destroys its fy_diag exactly once on every path, ported in with
;;;; the fix already known rather than rediscovered (see PLAN.md's
;;;; Phase 2 writeup) -- this test exists to keep it that way, and to
;;;; cover the other behaviors alibfyaml's own test checks: a
;;;; non-empty message, the "(string-in-memory)" file-field override
;;;; for string input, a second independent failure, and successful
;;;; parsing after both. Uses malformed.yaml, copied from alibfyaml's
;;;; own fixture, for comparability.
;;;;
;;;; Goes one step further than the Ada original where this binding's
;;;; condition already can: alibfyaml's Parse_Error carries only a
;;;; message string (an Ada exception has no structured fields), so
;;;; its test greps the message text for the file field; the 'parse
;;;; condition kind's own 'file property (see slibfyaml.scm's
;;;; raise-parse-error) is checked directly here instead.

(include "check.scm")

(import (slibfyaml documents))
(import (slibfyaml nodes))
(import (chicken condition))

;; -----------------------------------------------------------------
;; document-parse-file on malformed input: raises (exn slibfyaml
;; parse) -- not a process abort -- with a non-empty message and the
;; real file path in its 'file property.
;; -----------------------------------------------------------------
(let ((raised #f) (message-nonempty #f) (reports-file #f))
  (condition-case
   (begin (document-parse-file "malformed.yaml") #f)
   (e (exn slibfyaml parse)
      (set! raised #t)
      (set! message-nonempty
            (> (string-length (get-condition-property e 'exn 'message)) 0))
      (set! reports-file
            (string=? "malformed.yaml" (get-condition-property e 'parse 'file))))
   (e () #f))
  (check "document-parse-file on malformed input raises (exn slibfyaml parse), not a process abort"
         raised)
  (check "document-parse-file's parse error carries a non-empty message"
         message-nonempty)
  (check "document-parse-file's parse error reports the real file path"
         reports-file))

;; -----------------------------------------------------------------
;; document-parse-string on malformed input: same parse-common code
;; path, exercised through its other caller.
;;
;; Also checks the 'file property: libfyaml has no real filename for
;; string input and falls back to a synthetic, useless
;; "<memory-@ADDR-ADDR>" label (confirmed live in earlier phases) --
;; document-parse-string overrides it to the fixed "(string-in-memory)"
;; instead.
;; -----------------------------------------------------------------
(let ((raised #f) (reports-as-string #f))
  (condition-case
   (begin (document-parse-string "bad: [1, 2") #f)
   (e (exn slibfyaml parse)
      (set! raised #t)
      (set! reports-as-string
            (string=? "(string-in-memory)" (get-condition-property e 'parse 'file))))
   (e () #f))
  (check "document-parse-string on malformed input raises (exn slibfyaml parse), not a process abort"
         raised)
  (check "document-parse-string's parse error reports \"(string-in-memory)\", not libfyaml's own synthetic memory-address label"
         reports-as-string))

;; -----------------------------------------------------------------
;; A second, independent failure right after the first: parse-common
;; creates and destroys its own fy_diag fresh per call, so there is no
;; cross-call state to corrupt -- confirmed rather than assumed.
;; -----------------------------------------------------------------
(check "a second, independent parse failure also raises cleanly"
       (condition-case
        (begin (document-parse-string "[1, 2") #f)
        ((exn slibfyaml parse) #t)
        (e () #f)))

;; -----------------------------------------------------------------
;; Valid input after two failures still works normally -- confirms the
;; two failures above didn't leave parse-common unable to succeed.
;; -----------------------------------------------------------------
(with-document (doc (document-parse-string "ok: 1"))
  (check "valid input after failures still parses successfully"
         (string=? "1" (node-scalar-value (node-by-path (document-root doc) "/ok")))))

(check-summary-and-exit)
