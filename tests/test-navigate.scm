;;;; tests/test-navigate.scm
;;;;
;;;; Phase 2 regression test for tree navigation: node-length/node-item,
;;;; node-iterate-items/node-iterate-pairs, deep node-by-path, and a
;;;; hand-walked equivalent of the same deep path -- an slibfyaml port
;;;; of alibfyaml's own test_navigate.adb, using the same
;;;; tests/navigate.yaml fixture. No typed-scalar checks yet
;;;; (node-integer-value etc. are Phase 3) -- every scalar check here
;;;; compares node-scalar-value against the literal source text, same
;;;; as test-quickstart.scm.

(include "check.scm")

(import (slibfyaml documents))
(import (slibfyaml nodes))

(with-document (doc (document-parse-file "navigate.yaml"))
  (let ((root (document-root doc)))

    ;; -- Top-level scalars, by kind (raw text only -- see header) --
    (check "name is a scalar" (node-scalar? (node-value root "name")))
    (check "name is \"Sample Config\""
           (string=? "Sample Config" (node-scalar-value (node-value root "name"))))
    (check "version (raw) is \"3\""
           (string=? "3" (node-scalar-value (node-value root "version"))))
    (check "homepage (raw, null spelled ~) is \"~\""
           (string=? "~" (node-scalar-value (node-value root "homepage"))))

    ;; -- Sequence: tags --
    (let ((tags (node-value root "tags")))
      (check "tags is a sequence" (node-sequence? tags))
      (check "tags has 3 items" (= 3 (node-length tags)))
      (check "tags[1] (1-based) is \"alpha\""
             (string=? "alpha" (node-scalar-value (node-item tags 1))))
      (check "tags[3] (1-based) is \"gamma\""
             (string=? "gamma" (node-scalar-value (node-item tags 3))))
      (check "tags[4] (out of range) is null-node"
             (not (node-valid? (node-item tags 4))))

      (let ((collected '()))
        (node-iterate-items tags (lambda (item)
                                    (set! collected (cons (node-scalar-value item) collected))))
        (check "node-iterate-items visits all 3 tags in order"
               (equal? '("alpha" "beta" "gamma") (reverse collected)))))

    ;; -- Mapping: server --
    (let ((server (node-value root "server")))
      (check "server is a mapping" (node-mapping? server))
      (check "server has 4 pairs" (= 4 (node-length server)))
      (let ((keys '()))
        (node-iterate-pairs server (lambda (key value)
                                      (set! keys (cons (node-scalar-value key) keys))))
        (check "node-iterate-pairs visits all 4 keys"
               (equal? '("host" "port" "timeout" "ssl") (reverse keys)))))

    ;; -- Sequence of mappings: endpoints --
    (let ((endpoints (node-value root "endpoints")))
      (check "endpoints has 2 items" (= 2 (node-length endpoints)))
      (let ((first (node-item endpoints 1)))
        (check "endpoints[1].name is \"health\""
               (string=? "health" (node-scalar-value (node-value first "name"))))
        (check "endpoints[1].public (raw) is \"true\""
               (string=? "true" (node-scalar-value (node-value first "public"))))))

    ;; -- 4 levels deep: company/departments/[0]/teams/[1]/lead, both by
    ;; hand-walking and via a single By_Path call, checked against each
    ;; other as well as the fixture. --
    (let* ((company (node-value root "company"))
           (departments (node-value company "departments"))
           (engineering (node-item departments 1))
           (teams (node-value engineering "teams"))
           (infra (node-item teams 2))
           (lead-by-hand (node-value infra "lead"))
           (lead-by-path (node-by-path root "/company/departments/0/teams/1/lead")))
      (check "hand-walked company > departments[1] > teams[2] > lead is \"Alan Turing\""
             (string=? "Alan Turing" (node-scalar-value lead-by-hand)))
      (check "the same node reached via node-by-path (0-based path syntax)"
             (string=? "Alan Turing" (node-scalar-value lead-by-path)))
      (check "node-path of the hand-walked node matches the path used to reach it via node-by-path"
             (string=? "/company/departments/0/teams/1/lead" (node-path lead-by-hand))))))

(check-summary-and-exit)
