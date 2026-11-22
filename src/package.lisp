(defpackage #:rpc-backend-htmx
  (:use #:cl)
  (:nicknames #:stack-rpc-htmx)
  (:export
   ;; conditions
   #:htmx-error #:htmx-error-status
   #:htmx-bad-request
   #:htmx-method-not-allowed
   #:htmx-not-acceptable
   #:htmx-body-too-large #:htmx-body-limit #:htmx-body-size
   #:htmx-unsupported-media-type #:htmx-error-content-type
   ;; handler table (the allowlist)
   #:htmx-handlers #:make-htmx-handlers #:find-htmx-handler #:htmx-handler-names
   #:htmx-method-name #:+htmx-handler-modes+
   ;; codec
   #:htmx-codec #:make-htmx-codec #:htmx-codec-prefix #:htmx-codec-max-body-bytes
   #:+default-max-body-bytes+ #:+request-metadata-headers+
   #:htmx-message #:htmx-message-method #:htmx-message-params #:htmx-message-metadata
   #:htmx-message-mode #:htmx-message-http-method
   #:+error-fragment-target+ #:+error-fragment-swap+
   ;; server transport
   #:htmx-transport #:make-htmx-transport #:htmx-transport-codec #:htmx-transport-prefix
   #:htmx-transport-error-target #:htmx-transport-error-swap
   #:htmx-app #:*htmx-request*
   #:htmx-handle-request #:htmx-result-nodes #:htmx-full-page
   #:htmx-condition-status #:htmx-error-response
   #:htmx-event-stream #:make-htmx-event-stream #:htmx-stream-keepalive
   #:+stream-error-event+
   #:jsonrpc-handler
   ;; client (tests, snapshots)
   #:htmx-client #:make-htmx-client #:htmx-client-app #:htmx-client-codec
   #:htmx-request #:htmx-request-url #:htmx-request-env
   #:htmx-reply #:htmx-reply-status #:htmx-reply-headers #:htmx-reply-header
   #:htmx-reply-body #:htmx-reply-fragment #:htmx-reply-events))

(in-package #:rpc-backend-htmx)
