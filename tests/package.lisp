(defpackage #:rpc-backend-htmx/tests
  (:use #:cl #:rove))

(in-package #:rpc-backend-htmx/tests)

(deftest package-exists
  (ok (find-package :rpc-backend-htmx)))
