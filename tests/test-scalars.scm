;;;; tests/test-scalars.scm
;;;;
;;;; Phase 3 regression test for typed scalar accessors: node-null-value?,
;;;; node-integer?/node-float?/node-boolean?, node-integer-value/
;;;; node-float-value/node-boolean-value/node-string-value in all three
;;;; arities (bare node; required (root key); optional (root key default)),
;;;; and node-required -- an slibfyaml port of alibfyaml's own
;;;; test_scalars.adb, using its tests/scalars.yaml fixture directly for
;;;; comparability.
;;;;
;;;; Two places deliberately diverge from the Ada original, both per
;;;; PLAN.md's documented collapse of Ada's per-width overloads into one
;;;; accessor each: CHICKEN's numeric tower auto-promotes to bignums, so
;;;; big_int/huge_int (which overflow Ada's 32-/64-bit Integer forms)
;;;; are checked here as ordinary successful conversions, not Data_Error;
;;;; float_overflow (which overflows Ada's 32-bit Float but fits its
;;;; 64-bit Long_Float) is likewise a plain success here, since CHICKEN
;;;; flonums are IEEE double already -- only huge_float, which overflows
;;;; even a double, still exercises the "float out of range" Data_Error
;;;; path.

(include "check.scm")

(import (slibfyaml documents))
(import (slibfyaml nodes))
(import (chicken condition))

(define (raises-missing-key? thunk)
  (condition-case (begin (thunk) #f)
    ((exn slibfyaml missing-key) #t)
    (e () #f)))

(define (raises-data-error? thunk)
  (condition-case (begin (thunk) #f)
    ((exn slibfyaml data) #t)
    (e () #f)))

(with-document (doc (document-parse-file "scalars.yaml"))
  (let ((root (document-root doc)))

    ;; -- Per-node accessors and shape predicates --
    (let ((n-int (node-value root "int_dec"))
          (n-bool (node-value root "bool_true")))
      (check "node-integer? (int_dec)" (node-integer? n-int))
      (check "node-float? (int_dec)" (node-float? n-int))
      (check "not node-boolean? (int_dec)" (not (node-boolean? n-int)))
      (check "node-integer-value (int_dec node) = 42"
             (= 42 (node-integer-value n-int)))
      (check "node-float-value (int_dec node) = 42.0"
             (= 42.0 (node-float-value n-int)))

      (check "node-boolean? (bool_true)" (node-boolean? n-bool))
      (check "not node-integer? (bool_true)" (not (node-integer? n-bool)))
      (check "node-boolean-value (bool_true node) = #t"
             (eq? #t (node-boolean-value n-bool))))

    ;; -- node-null-value? --
    (check "not node-null-value? (int_dec)" (not (node-null-value? (node-value root "int_dec"))))

    ;; -- node-required: happy path --
    (check "node-required (name) is a scalar" (node-scalar? (node-required root "name")))
    (check "node-required (name) scalar text is \"widget\""
           (string=? "widget" (node-scalar-value (node-required root "name"))))

    ;; -- Required (root key) accessors --
    (check "node-integer-value (int_dec) = 42" (= 42 (node-integer-value root "int_dec")))
    (check "node-integer-value (int_neg) = -7" (= -7 (node-integer-value root "int_neg")))
    (check "node-integer-value (int_hex) = 26" (= 26 (node-integer-value root "int_hex")))
    (check "node-integer-value (int_oct) = 15" (= 15 (node-integer-value root "int_oct")))
    (check "node-integer-value (int_zero) = 0" (= 0 (node-integer-value root "int_zero")))

    ;; Extensions beyond YAML 1.2 core schema (see README.md): "0b"
    ;; binary, and "_" as a digit separator in any base.
    (check "node-integer-value (int_bin) = 10 (0b extension)"
           (= 10 (node-integer-value root "int_bin")))
    (check "node-integer-value (int_underscore) = 1000000 (_ extension)"
           (= 1000000 (node-integer-value root "int_underscore")))
    (check "node-integer-value (int_hex_underscore) = 65535 (0x + _ extension)"
           (= 65535 (node-integer-value root "int_hex_underscore")))
    (check "node-integer-value (int_hex_neg) = -26 (sign + 0x prefix)"
           (= -26 (node-integer-value root "int_hex_neg")))

    ;; CHICKEN's bignums mean there is no narrower-width overflow the
    ;; way Ada's Integer_Value has -- big_int/huge_int both succeed
    ;; here, unlike test_scalars.adb's Integer_Value (which raises for
    ;; both, since Ada's Integer is 32-bit) -- see this file's own
    ;; header comment.
    (check "node-integer-value (big_int) = 5000000000 (no 32-bit overflow, unlike Ada)"
           (= 5000000000 (node-integer-value root "big_int")))
    (check "node-integer-value (huge_int) = 99999999999999999999999999999 (bignum, no overflow at all)"
           (= 99999999999999999999999999999 (node-integer-value root "huge_int")))

    (check "node-float-value (float_val) = 3.5" (= 3.5 (node-float-value root "float_val")))
    (check "node-float-value (float_exp) = 150.0" (= 150.0 (node-float-value root "float_exp")))
    (check "node-float-value (float_neg) = -2.25" (= -2.25 (node-float-value root "float_neg")))
    (check "node-float-value (float_underscore) = 1234.56 (_ extension)"
           (= 1234.56 (node-float-value root "float_underscore")))
    ;; CHICKEN flonums are IEEE double, matching Ada's Long_Float --
    ;; float_overflow (which overflows only Ada's 32-bit Float) is a
    ;; plain success here, unlike test_scalars.adb's Float_Value.
    (check "node-float-value (float_overflow) > 1.0 (fits a double, unlike Ada's 32-bit Float)"
           (> (node-float-value root "float_overflow") 1.0))

    (check "node-boolean-value (bool_true) = #t" (eq? #t (node-boolean-value root "bool_true")))
    (check "node-boolean-value (bool_True) = #t" (eq? #t (node-boolean-value root "bool_True")))
    (check "node-boolean-value (bool_TRUE) = #t" (eq? #t (node-boolean-value root "bool_TRUE")))
    (check "node-boolean-value (bool_false) = #f" (eq? #f (node-boolean-value root "bool_false")))
    (check "node-boolean-value (bool_False) = #f" (eq? #f (node-boolean-value root "bool_False")))
    (check "node-boolean-value (bool_FALSE) = #f" (eq? #f (node-boolean-value root "bool_FALSE")))

    (check "node-string-value (name) = \"widget\""
           (string=? "widget" (node-string-value root "name")))

    ;; -- missing-key: required key absent --
    (check "node-required (does_not_exist) -> missing-key"
           (raises-missing-key? (lambda () (node-required root "does_not_exist"))))
    (check "node-integer-value (does_not_exist) -> missing-key"
           (raises-missing-key? (lambda () (node-integer-value root "does_not_exist"))))

    ;; -- data: malformed text, for every required numeric/boolean
    ;; accessor -- node-string-value, by contrast, accepts any text.
    (check "node-integer-value (malformed) -> data"
           (raises-data-error? (lambda () (node-integer-value root "malformed"))))
    (check "node-float-value (malformed) -> data"
           (raises-data-error? (lambda () (node-float-value root "malformed"))))
    (check "node-boolean-value (malformed) -> data"
           (raises-data-error? (lambda () (node-boolean-value root "malformed"))))
    (check "node-string-value (malformed) = \"banana\" (no error)"
           (string=? "banana" (node-string-value root "malformed")))

    ;; -- data: malformed digit-separator placement, and an invalid
    ;; binary digit.
    (check "node-integer-value (bad_underscore_leading) -> data"
           (raises-data-error? (lambda () (node-integer-value root "bad_underscore_leading"))))
    (check "node-integer-value (bad_underscore_trailing) -> data"
           (raises-data-error? (lambda () (node-integer-value root "bad_underscore_trailing"))))
    (check "node-integer-value (bad_underscore_double) -> data"
           (raises-data-error? (lambda () (node-integer-value root "bad_underscore_double"))))
    (check "node-integer-value (bad_binary) -> data"
           (raises-data-error? (lambda () (node-integer-value root "bad_binary"))))

    ;; -- data: the one numeric-range overflow slibfyaml still has --
    ;; a float literal that overflows even a double.
    (check "node-float-value (huge_float) -> data (overflow to infinity)"
           (raises-data-error? (lambda () (node-float-value root "huge_float"))))

    ;; -- data: value present but not a scalar (a mapping) -- both the
    ;; required and optional-with-default forms must still raise; a
    ;; default only substitutes for absence.
    (check "node-required (not_scalar) is a mapping"
           (node-mapping? (node-required root "not_scalar")))
    (check "node-integer-value (not_scalar) -> data"
           (raises-data-error? (lambda () (node-integer-value root "not_scalar"))))
    (check "node-boolean-value (not_scalar, default) -> data (default doesn't hide a shape error)"
           (raises-data-error? (lambda () (node-boolean-value root "not_scalar" #t))))

    ;; -- optional (root key default): key absent -> default --
    (check "node-integer-value (absent, 99) = 99" (= 99 (node-integer-value root "absent" 99)))
    (check "node-float-value (absent, 9.5) = 9.5" (= 9.5 (node-float-value root "absent" 9.5)))
    (check "node-boolean-value (absent, #t) = #t" (eq? #t (node-boolean-value root "absent" #t)))
    (check "node-string-value (absent, \"fallback\") = \"fallback\""
           (string=? "fallback" (node-string-value root "absent" "fallback")))

    ;; -- optional (root key default): key present -> actual value, not
    ;; default.
    (check "node-integer-value (int_dec, 0) = 42" (= 42 (node-integer-value root "int_dec" 0)))
    (check "node-integer-value (big_int, 0) = 5000000000"
           (= 5000000000 (node-integer-value root "big_int" 0)))
    (check "node-float-value (float_val, 0.0) = 3.5" (= 3.5 (node-float-value root "float_val" 0.0)))
    (check "node-float-value (float_overflow, 0.0) > 1.0"
           (> (node-float-value root "float_overflow" 0.0) 1.0))
    (check "node-boolean-value (bool_true, #f) = #t" (eq? #t (node-boolean-value root "bool_true" #f)))
    (check "node-string-value (name, \"x\") = \"widget\""
           (string=? "widget" (node-string-value root "name" "x")))))

(check-summary-and-exit)
