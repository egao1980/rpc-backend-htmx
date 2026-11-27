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
;;;   HTMX-FULL-PAGE — (CANVAS:PAGE nodes :title (canvas-transport-page-title tx)
;;;     :keys K :scripts S), the html-document, so a plain browser GET gets a whole page with
;;;     htmx loaded from the asset route; HX requests still get the fragment.
;;;     K is NIL unless PAGE-KEYS (below) selects the page; S is NIL unless
;;;     PAGE-SCRIPTS (below) does.
;;;   HTMX-CONDITION-STATUS — CANVAS:CANVAS-COERCION-ERROR → 422 (its subclass
;;;     CANVAS:CANVAS-UPLOAD-TOO-LARGE included); others as the core.
;;;
;;; Page keys (0.2.0, rpc-backend-htmx#6). canvas-protocol 0.2.0 binds key
;;; chords with hx-get / hx-post :keys; the canvas:key event comes only from the
;;; asset canvas-keys.js, which (CANVAS:PAGE … :keys t) loads.
;;; MAKE-CANVAS-HTMX-TRANSPORT &key page-keys:
;;;   NIL (default) — no page loads it; every response is byte-identical to 0.1.0.
;;;   T — every full page loads it.
;;;   a non-empty proper list of handler names, each a method symbol (as
;;;     HTMX-METHOD-NAME takes it) or a "PKG::NAME" string (both sides
;;;     non-empty) — only the full pages of those methods load it; the others
;;;     stay byte-identical to 0.1.0. Only some canvases bind keys.
;;;   Anything else (a keyword, a lone symbol or string, an improper list, or
;;;   a list holding a keyword, a non-name or a malformed name) → TYPE-ERROR at
;;;   construction (CHECK-TYPE, as for ASSET-PREFIX and PAGE-TITLE).
;;; CANVAS-TRANSPORT-PAGE-KEYS → NIL, T, or a fresh list of method-name strings
;;;   in the given order (symbols named at construction, so a later package
;;;   rename does not change the selection).
;;; HTMX-FULL-PAGE passes :keys T when PAGE-KEYS is T or lists the message's
;;;   HTMX-MESSAGE-METHOD (STRING=), else :keys NIL. canvas-protocol then ends
;;;   <head> with <script src="<asset-prefix>canvas-keys.js"></script>, right
;;;   after the htmx and htmx-ext-sse scripts. Fragments (HX requests, POSTs),
;;;   streams and error responses never carry a script, whatever PAGE-KEYS is.
;;;   The asset route already serves canvas-keys.js (CANVAS:ASSET-NAMES).
;;;
;;; Page scripts (0.4.0, canvas-protocol#15). canvas-protocol 0.3.0 registers
;;; an app's own assets (CANVAS:REGISTER-ASSET / DEFINE-ASSET: first-party
;;; scripts, a vendored JS/WASM toolkit) and loads them with
;;; (CANVAS:PAGE … :scripts entries).
;;; The asset route serves every name in CANVAS:ASSET-NAMES, app assets
;;;   included, unchanged: 200, :content-type (ASSET-CONTENT-TYPE name) (.wasm
;;;   application/wasm), body the held (CANVAS:ASSET-OCTETS name) vector, so a
;;;   multi-MB file is not copied per request. Names may contain "/".
;;; MAKE-CANVAS-HTMX-TRANSPORT &key page-scripts:
;;;   NIL (default) — no app script; every response as in 0.3.0.
;;;   a non-empty proper list of rules (SELECTION . SCRIPTS):
;;;     SELECTION — T (every full page) or a non-empty proper list of handler
;;;       names, as for PAGE-KEYS (method symbols or "PKG::NAME" strings);
;;;     SCRIPTS — a non-empty proper list of CANVAS:PAGE :scripts entries: an
;;;       asset name string, or (name &key module defer) with a string name.
;;;   Anything else → TYPE-ERROR at construction (CHECK-TYPE). Each named
;;;   asset must exist at construction (register assets at load time, make the
;;;   transport after) → CANVAS:CANVAS-ASSET-NOT-FOUND otherwise.
;;; CANVAS-TRANSPORT-PAGE-SCRIPTS → NIL or a fresh list of (SELECTION .
;;;   SCRIPTS), SELECTION T or method-name strings, in the given order.
;;; HTMX-FULL-PAGE passes :scripts — the SCRIPTS of every rule whose SELECTION
;;;   is T or lists the message's HTMX-MESSAGE-METHOD, in rule order, a name
;;;   already taken by an earlier rule skipped — so the page ends <head> with
;;;   them, after the htmx, htmx-ext-sse and (PAGE-KEYS) canvas-keys scripts.
;;;   No rule matching → :scripts NIL, the page byte-identical to 0.3.0.
;;;   Fragments, streams and error responses never carry a script.
;;; CSP: the scripts are 'self', so the default policy holds. A WASM toolkit
;;;   compiling its module needs 'wasm-unsafe-eval': pass :csp a policy string,
;;;   e.g. +DEFAULT-CSP+ with script-src 'self' 'wasm-unsafe-eval'.
;;;
;;; Security (0.3.0, rpc-backend-htmx#4). MAKE-CANVAS-HTMX-TRANSPORT &key …
;;; max-params (csp t) token (token-name +default-token-name+): the core
;;; transport's options (server.lisp, MAKE-HTMX-TRANSPORT, Content-Security-
;;; Policy, Token gate; codec.lisp, Params), validated the same way, with one
;;; difference: CSP defaults to T, the brief's policy (+DEFAULT-CSP+), here.
;;; Why on by default: canvas output is CSP-clean by construction —
;;; canvas-protocol's EL refuses script / iframe / object / embed and on* /
;;; hx-on* attributes, no component writes a style attribute or inline
;;; script, and PAGE loads htmx, its SSE extension, canvas-keys.js and the
;;; stylesheet from 'self' with htmx eval and indicator styles off — so the
;;; policy cannot break a canvas page, and every canvas server gets it
;;; without a wrapper of its own. Against 0.2.x: response bodies stay
;;; byte-identical (pages, fragments, events, assets); every response gains
;;; one header, the last. :csp nil gives 0.2.1's responses exactly, headers
;;; included. The core transport stays opt-in (server.lisp).
;;; The asset route below is gated and carries the header like any other
;;; response: HTMX-APP wraps the :around (server.lisp, HTMX-APP).
;;;
;;; Sessions and request context (0.5.0, rpc-backend-htmx#19 #15).
;;; MAKE-CANVAS-HTMX-TRANSPORT &key … trusted-proxies sessions: the core
;;; transport's options, validated the same way and with the same defaults (both
;;; off): TRUSTED-PROXIES goes to the codec (codec.lisp, Client address),
;;; SESSIONS NIL, T or a STACK-SESSION:SESSION-MANAGER (server.lisp, Sessions).
;;; With sessions in force the asset route (a GET under the asset prefix, which
;;; is outside the method prefix by default) gets no session: no store read, no
;;; Set-Cookie (session.lisp, step 2). A canvas reads the visitor's session with
;;; HTMX-SESSION / HTMX-SESSION-VALUE like any handler; PAGE, fragments and
;;; events are unchanged, and the session's Set-Cookie sits before the CSP
;;; header, which stays last.
;;;
;;; Uploads (0.2.0, rpc-backend-htmx#5): the core codec hands a multipart file
;;; part to the handler as its STACK-MIME:MIME-ENTITY (codec.lisp), the value
;;; canvas-protocol (COERCE-PARAM part :file &key max-size accept multiple)
;;; takes; a FORM holding a FILE-INPUT already posts multipart/form-data.
;;; Nothing upload-specific lives here beyond the 422 above.

(defclass canvas-htmx-transport (rpc-backend-htmx:htmx-transport)
  ((asset-prefix :initarg :asset-prefix :initform "/canvas-assets/"
                 :reader canvas-transport-asset-prefix)
   (page-title :initarg :page-title :initform "canvas" :reader canvas-transport-page-title)
   (page-keys :initarg :page-keys :initform nil :reader canvas-transport-page-keys
              :documentation "NIL, T or a list of method-name strings (see the file header).")
   (page-scripts :initarg :page-scripts :initform nil :reader %page-script-rules
                 :documentation "NIL or a list of (T-or-method-names . script-entries)."))
  (:documentation "htmx transport serving canvas functions, pages and canvas assets."))

(defun %page-key-name-p (object)
  "True for one PAGE-KEYS entry: a method symbol or a \"PKG::NAME\" string."
  (typecase object
    (string (rpc-backend-htmx::%method-name-p object))
    (symbol (rpc-backend-htmx::%method-symbol-p object)) ; NIL and keywords refused
    (t nil)))

(defun %page-key-list-p (object)
  "True for a non-empty proper list of page-key names."
  (and (consp object)
       (null (cdr (last object)))
       (every #'%page-key-name-p object)))

(defun %page-keys-option (page-keys)
  "MAKE-CANVAS-HTMX-TRANSPORT's non-NIL PAGE-KEYS → T or a fresh list of
method-name strings; anything else → TYPE-ERROR. See the file header.
NIL (e.g. stored through CHECK-TYPE's STORE-VALUE) → NIL."
  (check-type page-keys (or null (eql t) (satisfies %page-key-list-p))
              "NIL, T or a non-empty proper list of method symbols or \"PKG::NAME\" strings")
  (if (eq page-keys t)
      t
      (mapcar (lambda (name)
                (if (stringp name)
                    (copy-seq name)
                    (rpc-backend-htmx:htmx-method-name name)))
              page-keys)))

(defun %page-keys-p (transport message)
  "True when the full page for MESSAGE loads canvas-keys.js (TRANSPORT's
PAGE-KEYS is T or lists the message's method). See the file header."
  (let ((keys (canvas-transport-page-keys transport)))
    (or (eq keys t)
        (and (consp keys)
             (member (rpc-backend-htmx:htmx-message-method message) keys :test #'string=)
             t))))

(defun %page-script-entry-p (object)
  "True for one CANVAS:PAGE :scripts entry: a name, or (name &key module defer)."
  (or (stringp object)
      (and (consp object)
           (stringp (car object))
           (let ((options (cdr object)))
             (and (null (cdr (last options)))
                  (evenp (length options))
                  (loop for (key) on options by #'cddr
                        always (member key '(:module :defer))))))))

(defun %proper-list-of-p (object predicate)
  (and (consp object) (null (cdr (last object))) (every predicate object)))

(defun %page-script-rule-p (object)
  "True for one PAGE-SCRIPTS rule (SELECTION . SCRIPTS). See the file header."
  (and (consp object)
       (or (eq (car object) t) (%page-key-list-p (car object)))
       (%proper-list-of-p (cdr object) #'%page-script-entry-p)))

(defun %page-script-rules-p (object)
  (%proper-list-of-p object #'%page-script-rule-p))

(defun %page-scripts-option (page-scripts)
  "MAKE-CANVAS-HTMX-TRANSPORT's PAGE-SCRIPTS → NIL or a fresh normalized list of
rules; a malformed value → TYPE-ERROR, an unknown asset → CANVAS-ASSET-NOT-FOUND."
  (check-type page-scripts (or null (satisfies %page-script-rules-p))
              "NIL or a non-empty list of (T-or-handler-names . script-entries)")
  (loop for (selection . scripts) in page-scripts
        do (dolist (entry scripts)
             ;; Signals CANVAS-ASSET-NOT-FOUND now rather than on the first page.
             (canvas:asset-content-type (if (consp entry) (car entry) entry)))
        collect (cons (if (eq selection t) t (%page-keys-option selection))
                      (copy-tree scripts))))

(defun canvas-transport-page-scripts (transport)
  "NIL or a fresh list of (SELECTION . SCRIPTS). See the file header."
  (copy-tree (%page-script-rules transport)))

(defun %page-scripts (transport message)
  "The :scripts entries for MESSAGE's full page. See the file header."
  (let ((method (rpc-backend-htmx:htmx-message-method message))
        (scripts '()))
    (loop for (selection . entries) in (%page-script-rules transport)
          when (or (eq selection t) (member method selection :test #'string=))
            do (dolist (entry entries)
                 (let ((name (if (consp entry) (car entry) entry)))
                   (unless (member name scripts :test #'string=
                                                :key (lambda (e) (if (consp e) (car e) e)))
                     (push entry scripts)))))
    (nreverse scripts)))

(defun make-canvas-htmx-transport (&key (prefix "/canvas/") (asset-prefix "/canvas-assets/")
                                     (page-title "canvas")
                                     (max-body-bytes rpc-backend-htmx:+default-max-body-bytes+)
                                     (max-params rpc-backend-htmx:+default-max-params+)
                                     trusted-proxies
                                     (error-target rpc-backend-htmx:+error-fragment-target+)
                                     (error-swap rpc-backend-htmx:+error-fragment-swap+)
                                     page-keys page-scripts
                                     (csp t) token
                                     (token-name rpc-backend-htmx:+default-token-name+)
                                     sessions)
  "A CANVAS-HTMX-TRANSPORT. See the file header (Page keys, Page scripts, Security,
Sessions and request context)."
  (check-type asset-prefix (and string (satisfies rpc-backend-htmx::%slash-bounded-p)))
  (check-type page-title string)
  (make-instance 'canvas-htmx-transport
                 :codec (rpc-backend-htmx:make-htmx-codec :prefix prefix
                                                          :max-body-bytes max-body-bytes
                                                          :max-params max-params
                                                          :trusted-proxies trusted-proxies)
                 :sessions (rpc-backend-htmx::%sessions-option sessions)
                 :asset-prefix asset-prefix
                 :page-title page-title
                 :page-keys (and page-keys (%page-keys-option page-keys))
                 :page-scripts (%page-scripts-option page-scripts)
                 :error-target error-target
                 :error-swap error-swap
                 :csp (rpc-backend-htmx::%transport-csp csp)
                 :token (and token (rpc-backend-htmx::%token-option token))
                 :token-name (if (equal token-name rpc-backend-htmx:+default-token-name+)
                                 token-name
                                 (rpc-backend-htmx::%token-name-option token-name))))

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
            (canvas:asset-octets name))
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
  (canvas:page nodes :title (canvas-transport-page-title transport)
                     :keys (and (canvas-transport-page-keys transport)
                                (%page-keys-p transport message)
                                t)
                     :scripts (and (%page-script-rules transport)
                                   (%page-scripts transport message))))

(defmethod rpc-backend-htmx:htmx-condition-status ((transport canvas-htmx-transport) condition)
  (if (typep condition 'canvas:canvas-coercion-error)
      422
      (call-next-method)))
