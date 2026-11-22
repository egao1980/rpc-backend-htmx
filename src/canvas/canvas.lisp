(in-package #:rpc-backend-htmx/canvas)

;;; canvas-protocol on rpc-backend-htmx (a separate system, so the core never
;;; waits for canvas-protocol; canvas-protocol never depends on this repo).
;;;
;;; CANVAS-HTMX-TRANSPORT (an HTMX-TRANSPORT): defaults prefix "/canvas/",
;;; asset-prefix "/canvas-assets/", page-title "canvas".
;;;
;;; HTMX-RESOLVER (a canvas PATH-RESOLVER with the transport's prefix and
;;; asset-prefix, so URLs have path-resolver's exact shape
;;; <prefix><PACKAGE>::<NAME>?k=v, RFC 3986 percent-encoded):
;;;   RESOLVE-CANVAS-URL: when HANDLERS is an HTMX-HANDLERS table and the
;;;     symbol's HTMX-METHOD-NAME is not in it → NIL (the element renders inert;
;;;     the server would 404 anyway); else path-resolver's URL.
;;;   RESOLVE-ASSET-URL: a name in CANVAS:ASSET-NAMES → path-resolver's URL; else NIL.
;;;   Round trip: the URL it builds, requested through the app, reaches the same
;;;   method with the same params (as strings).
;;;
;;; Methods on CANVAS-HTMX-TRANSPORT:
;;;   HTMX-HANDLE-REQUEST :around —
;;;     a GET whose :path-info starts with the asset prefix is an asset request:
;;;     the rest is the asset name; known → 200, :content-type
;;;     (ASSET-CONTENT-TYPE name), body the (ASSET-BYTES name) octet vector itself
;;;     (not in a list); unknown → HTMX-ERROR-RESPONSE of an HTMX-ERROR status 404.
;;;     Every other request runs the next method with CANVAS:*CANVAS-RESOLVER*
;;;     bound to (make-htmx-resolver transport handler) — handler functions,
;;;     PAGE and the hx helpers resolve through it. That includes a :call-stream
;;;     handler running later inside the streaming response function.
;;;   HTMX-RESULT-NODES — the result through CANVAS:RENDER (components, charts,
;;;     strings, numbers, nodes, lists), flattened to a fresh list of nodes.
;;;   HTMX-FULL-PAGE — (CANVAS:PAGE nodes :title (canvas-transport-page-title tx)),
;;;     the html-document, so a plain browser GET gets a whole page with htmx loaded
;;;     from the asset route; HX requests still get the fragment.
;;;   HTMX-CONDITION-STATUS — CANVAS:CANVAS-COERCION-ERROR → 422; others as the core.

(defclass canvas-htmx-transport (rpc-backend-htmx:htmx-transport)
  ((asset-prefix :initarg :asset-prefix :initform "/canvas-assets/"
                 :reader canvas-transport-asset-prefix)
   (page-title :initarg :page-title :initform "canvas" :reader canvas-transport-page-title))
  (:documentation "htmx transport serving canvas functions, pages and canvas assets."))

(defun make-canvas-htmx-transport (&key (prefix "/canvas/") (asset-prefix "/canvas-assets/")
                                     (page-title "canvas")
                                     (max-body-bytes rpc-backend-htmx:+default-max-body-bytes+)
                                     (error-target rpc-backend-htmx:+error-fragment-target+)
                                     (error-swap rpc-backend-htmx:+error-fragment-swap+))
  (check-type asset-prefix (and string (satisfies rpc-backend-htmx::%slash-bounded-p)))
  (check-type page-title string)
  (make-instance 'canvas-htmx-transport
                 :codec (rpc-backend-htmx:make-htmx-codec :prefix prefix
                                                          :max-body-bytes max-body-bytes)
                 :asset-prefix asset-prefix
                 :page-title page-title
                 :error-target error-target
                 :error-swap error-swap))

(defclass htmx-resolver (canvas:path-resolver)
  ((handlers :initarg :handlers :initform nil :reader htmx-resolver-handlers
             :documentation "The allowlist (HTMX-HANDLERS), or NIL / a function: no check."))
  (:documentation "canvas-protocol resolver for an rpc-backend-htmx server."))

(defun make-htmx-resolver (transport &optional handlers)
  "Resolver for TRANSPORT's prefix (and asset prefix when it is a CANVAS-HTMX-TRANSPORT;
else the canvas-protocol default) limited to HANDLERS."
  (check-type transport rpc-backend-htmx:htmx-transport)
  (make-instance 'htmx-resolver
                 :prefix (rpc-backend-htmx:htmx-transport-prefix transport)
                 :asset-prefix (if (typep transport 'canvas-htmx-transport)
                                   (canvas-transport-asset-prefix transport)
                                   (canvas:path-resolver-asset-prefix
                                    (canvas:make-path-resolver)))
                 :handlers handlers))

(defun %known-asset-p (name)
  (and (stringp name) (member name (canvas:asset-names) :test #'string=) t))

(defmethod canvas:resolve-canvas-url ((resolver htmx-resolver) symbol params)
  (let ((handlers (htmx-resolver-handlers resolver)))
    (if (and (typep handlers 'rpc-backend-htmx:htmx-handlers)
             (not (and (rpc-backend-htmx::%method-symbol-p symbol)
                       (rpc-backend-htmx:find-htmx-handler
                        handlers (rpc-backend-htmx:htmx-method-name symbol)))))
        nil
        (call-next-method))))

(defmethod canvas:resolve-asset-url ((resolver htmx-resolver) name)
  (if (%known-asset-p name)
      (call-next-method)
      nil))

(defun %asset-response (transport name)
  (if (%known-asset-p name)
      (list 200
            (list :content-type (canvas:asset-content-type name))
            (canvas:asset-bytes name))
      (rpc-backend-htmx:htmx-error-response
       transport
       (make-condition 'rpc-backend-htmx:htmx-error :status 404 :message "Asset not found"))))

(defmethod rpc-backend-htmx:htmx-handle-request :around
    ((transport canvas-htmx-transport) handler stream-handler env)
  (declare (ignore stream-handler))
  (rpc-backend-htmx::%with-error-response (transport)
    (let ((path (getf env :path-info))
          (asset-prefix (canvas-transport-asset-prefix transport)))
      (if (and (eq (getf env :request-method) :get)
               (rpc-backend-htmx::%prefixp asset-prefix path))
          (%asset-response transport (subseq path (length asset-prefix)))
          (let* ((resolver (make-htmx-resolver transport handler))
                 (response (let ((canvas:*canvas-resolver* resolver))
                             (call-next-method))))
            (if (functionp response)
                ;; A Clack streaming response runs after this method returned:
                ;; re-bind the resolver around it.
                (lambda (responder)
                  (let ((canvas:*canvas-resolver* resolver))
                    (funcall response responder)))
                response))))))

(defmethod rpc-backend-htmx:htmx-result-nodes ((transport canvas-htmx-transport) result)
  (labels ((flatten (rendered)
             (typecase rendered
               (null '())
               (list (loop for item in rendered append (flatten item)))
               (t (list rendered)))))
    (flatten (canvas:render result))))

(defmethod rpc-backend-htmx:htmx-full-page ((transport canvas-htmx-transport) nodes message)
  (declare (ignore message))
  (canvas:page nodes :title (canvas-transport-page-title transport)))

(defmethod rpc-backend-htmx:htmx-condition-status ((transport canvas-htmx-transport) condition)
  (if (typep condition 'canvas:canvas-coercion-error)
      422
      (call-next-method)))
