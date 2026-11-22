(defpackage #:rpc-backend-htmx/tests
  (:use #:cl #:rove)
  (:local-nicknames (#:h #:rpc-backend-htmx)
                    (#:hc #:rpc-backend-htmx/canvas)
                    (#:rpc #:rpc-protocol)
                    (#:html #:html-protocol)
                    (#:sse #:sse-protocol)))

(in-package #:rpc-backend-htmx/tests)
