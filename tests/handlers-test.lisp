(in-package #:rpc-backend-htmx/tests)

(deftest method-name
  (ok (equal (m "GREET") (h:htmx-method-name 'greet)))
  (ok (equal "COMMON-LISP::CAR" (h:htmx-method-name 'car)))
  (ok (signals (h:htmx-method-name :greet) 'h:htmx-error))
  (ok (signals (h:htmx-method-name "GREET") 'h:htmx-error)))

(deftest table-find
  (let ((table (handlers)))
    (multiple-value-bind (fn mode) (h:find-htmx-handler table (m "GREET"))
      (ok (eq 'greet fn))
      (ok (eq :call-response mode)))
    (ok (eq :notify (nth-value 1 (h:find-htmx-handler table (m "BUMP")))))
    (ok (eq :call-stream (nth-value 1 (h:find-htmx-handler table (m "TICKER")))))
    (ok (functionp (h:find-htmx-handler table "X::LAMBDA")))
    (ok (null (h:find-htmx-handler table (m "NOT-LISTED"))))
    (ok (null (h:find-htmx-handler table "rpc-backend-htmx/tests::greet"))
        "names are case-sensitive")))

(deftest table-names-in-order
  (ok (equal (list (m "GREET") (m "BUMP") "A::B")
             (h:htmx-handler-names
              (h:make-htmx-handlers 'greet '(bump :mode :notify)
                                    (list "A::B" (lambda (&key) nil)))))))

(deftest table-refuses-bad-entries
  (ok (signals (h:make-htmx-handlers '(greet :mode :bidi-stream)) 'h:htmx-error))
  (ok (signals (h:make-htmx-handlers 'greet 'greet) 'h:htmx-error) "duplicate")
  (ok (signals (h:make-htmx-handlers (list "nocolons" #'greet)) 'h:htmx-error))
  (ok (signals (h:make-htmx-handlers (list "A::" #'greet)) 'h:htmx-error))
  (ok (signals (h:make-htmx-handlers 42) 'h:htmx-error)))
