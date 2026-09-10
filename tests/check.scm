;;;; tests/check.scm
;;;;
;;;; Shared ok/FAIL check helper, `(include "check.scm")`d (textual
;;;; inclusion, not a compiled module -- these are standalone test
;;;; programs, not part of the installed egg, so there's no separate
;;;; unit/link bookkeeping worth the ceremony for a three-line helper)
;;;; at the top of every tests/test-*.scm file. Matches alibfyaml's own
;;;; test convention: each check prints "ok   - <label>" or
;;;; "FAIL - <label>", and the run ends with "All checks passed." or
;;;; "<N> check(s) failed.", exiting nonzero on any failure.
;;;;
;;;; Factored out here once a second test file (tests/test-quickstart.scm)
;;;; needed the same few lines tests/test-thin.scm had defined inline --
;;;; see that file's own header comment for why it wasn't factored out
;;;; from the start.

(define check-failures 0)

(define (check label ok?)
  (if ok?
      (print "ok   - " label)
      (begin
        (print "FAIL - " label)
        (set! check-failures (+ check-failures 1)))))

(define (check-summary-and-exit)
  (print)
  (if (= 0 check-failures)
      (print "All checks passed.")
      (print check-failures " check(s) failed."))
  (exit (if (= 0 check-failures) 0 1)))
