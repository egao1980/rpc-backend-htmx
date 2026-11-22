(defpackage #:rpc-backend-htmx/canvas
  (:use #:cl)
  (:nicknames #:stack-rpc-htmx-canvas)
  (:export #:canvas-htmx-transport #:make-canvas-htmx-transport
           #:canvas-transport-asset-prefix #:canvas-transport-page-title
           #:htmx-resolver #:make-htmx-resolver #:htmx-resolver-handlers))

(in-package #:rpc-backend-htmx/canvas)
