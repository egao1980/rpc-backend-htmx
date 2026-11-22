(in-package #:rpc-backend-htmx)

;;; HTMX-CODEC: an rpc-protocol codec whose "wire" is a Clack request env on the
;;; way in and a Clack response (status headers body) on the way out.
;;; Pass the codec explicitly; never read or set RPC-PROTOCOL:*RPC-CODEC*
;;; (rpc-protocol-json sets it globally when loaded).
;;;
;;; DECODE-MESSAGE-USING-CODEC (codec env) → HTMX-MESSAGE
;;; - HTTP method: :GET or :POST, else HTMX-METHOD-NOT-ALLOWED.
;;; - Method name: ENV :PATH-INFO (already percent-decoded, per Clack) must start
;;;   with the codec PREFIX; the rest is the method name and must be
;;;   "<pkg>::<name>" with both sides non-empty. Otherwise RPC-METHOD-NOT-FOUND
;;;   whose message is "Method not found: <rest>" (the server escapes it).
;;; - Params: ENV :QUERY-STRING (raw) first, then for POST the body, decoded as
;;;   application/x-www-form-urlencoded ("+" → space, UTF-8 percent-escapes) or
;;;   multipart/form-data (every part → its name and its content as UTF-8 text;
;;;   a filename is ignored). Decode with the stack: quri for urlencoded,
;;;   mime-protocol (PARSE-MIME, media types, dispositions) for multipart,
;;;   encoding-protocol for UTF-8. No private parsers.
;;;   An empty POST body needs no content type; a non-empty body of any other
;;;   type → HTMX-UNSUPPORTED-MEDIA-TYPE. Malformed input → HTMX-BAD-REQUEST.
;;;   Result: a plist keyword → string. Key = (intern (string-upcase name) :keyword);
;;;   empty names dropped; first-occurrence order; a later duplicate (query then
;;;   body) replaces the value in place. Values are never read with the Lisp reader.
;;; - Body size: at most MAX-BODY-BYTES octets are ever read. A Content-Length
;;;   above the limit → HTMX-BODY-TOO-LARGE (:size = that length) before reading
;;;   anything; without Content-Length, read at most limit+1 octets and signal
;;;   HTMX-BODY-TOO-LARGE (:size NIL) past the limit. :LIMIT is always the limit.
;;;   GET bodies are not read.
;;;   http-server-protocol has no request-body helper yet
;;;   (https://github.com/egao1980/http-server-protocol/issues/12). Until it ships,
;;;   the body is read in exactly one place (one internal function) with
;;;   READ-SEQUENCE into a buffer bounded as above; when #12 ships
;;;   (`request-body-octets :max-bytes`), that function becomes a call to it.
;;;   Never read to EOF without a bound, never copy SLURP-ENV-BODY.
;;; - Metadata: request headers (ENV :HEADERS, a hash table keyed by lowercase
;;;   names) per +REQUEST-METADATA-HEADERS+, as a plist in that order holding only
;;;   the headers present. :REQUEST and :BOOSTED are T when the value is "true"
;;;   (case-insensitive) and omitted otherwise; the rest are the header strings.
;;; - Mode: :CALL-STREAM when the Accept header contains "text/event-stream",
;;;   else :CALL-RESPONSE. (:NOTIFY is a handler-table mode, not a wire one.)
;;;
;;; ENCODE-REQUEST-USING-CODEC (codec method params &key id http-method encoding
;;;                             metadata headers) → a Clack env plist, what a
;;; browser running htmx would send. METHOD: a method-name string or a symbol
;;; (HTMX-METHOD-NAME). PARAMS: plist keyword → string or integer (decimal),
;;; NIL values dropped. HTTP-METHOD :GET (default; params in the query string)
;;; or :POST (params in the body). ENCODING :URLENCODED (default) or :MULTIPART
;;; (POST only). METADATA: a plist like the decoded one (:request T → "HX-Request:
;;; true"). HEADERS: extra alist (name . value), sent as given (lowercased names).
;;; The env has :request-method :script-name "" :path-info (prefix + method,
;;; decoded) :request-uri (prefix + percent-encoded method + "?query")
;;; :query-string (raw, or NIL) :server-name "localhost" :server-port 80
;;; :server-protocol :http/1.1 :url-scheme "http" :remote-addr "127.0.0.1"
;;; :headers (EQUAL hash table, lowercase keys) and, for POST, :content-type
;;; :content-length and :raw-body (HTTP-PROTOCOL:MAKE-OCTET-INPUT-STREAM).
;;; Encode with the stack: HTTP-PROTOCOL:ENCODE-URLENCODED / MAKE-MULTIPART-BODY
;;; (or mime-protocol MAKE-FORM-DATA). ID is ignored.
;;; ENCODE-NOTIFICATION-USING-CODEC: the same with HTTP-METHOD :POST.
;;; Round trip: DECODE of ENCODE gives back the method and the params (as strings).
;;;
;;; ENCODE-RESPONSE-USING-CODEC (codec result &key id status headers)
;;; → (status clack-headers (body-string)).
;;; RESULT: an html-protocol node, a list of nodes, a string (one escaped text
;;; node), or NIL (empty body). An HTML-DOCUMENT is serialized whole (doctype
;;; included). Serialization and escaping are html-protocol's
;;; (STACK-HTML:SERIALIZE of a document holding the nodes); no hand escaping.
;;; STATUS default 200. HEADERS: response metadata, an alist ("HX-…" . string),
;;; e.g. canvas-protocol's HTMX-RESPONSE-HEADERS. Clack headers: :content-type
;;; "text/html; charset=utf-8" first, then each pair as a keyword header
;;; (("HX-Retarget" . "#e") → :hx-retarget "#e") in the given order. A name not
;;; starting with "HX-" (case-insensitive) or a value that is not a string or
;;; contains CR or LF → HTMX-ERROR (500).
;;;
;;; ENCODE-ERROR-RESPONSE-USING-CODEC (codec code message &key id data target swap)
;;; → (status clack-headers (fragment)). STATUS: CODE itself when 100..599, else
;;; -32601 → 404, -32602 → 422, -32600 / -32700 → 400, anything else 500.
;;; Headers: :content-type "text/html; charset=utf-8", :hx-retarget TARGET
;;; (default +ERROR-FRAGMENT-TARGET+), :hx-reswap SWAP (default
;;; +ERROR-FRAGMENT-SWAP+). Fragment: <p role="alert">MESSAGE</p>, MESSAGE as one
;;; escaped text node (html-protocol). No backtrace. DATA is ignored.

(defconstant +default-max-body-bytes+ 1048576
  "Default request body limit (1 MiB).")

(defparameter +request-metadata-headers+
  '(("hx-request" . :request)
    ("hx-target" . :target)
    ("hx-trigger" . :trigger)
    ("hx-trigger-name" . :trigger-name)
    ("hx-current-url" . :current-url)
    ("hx-boosted" . :boosted))
  "Request header (lowercase) → metadata key, in metadata order.")

(defparameter +error-fragment-target+ "#canvas-error"
  "Default HX-Retarget of an error response.")

(defparameter +error-fragment-swap+ "innerHTML"
  "Default HX-Reswap of an error response.")

(defclass htmx-codec (rpc-protocol:rpc-codec)
  ((prefix :initarg :prefix :initform "/" :reader htmx-codec-prefix
           :documentation "Mount prefix; method names follow it in the path. Ends with /.")
   (max-body-bytes :initarg :max-body-bytes :initform +default-max-body-bytes+
                   :reader htmx-codec-max-body-bytes))
  (:documentation "htmx requests ↔ rpc messages; fragments ↔ responses."))

(defun make-htmx-codec (&key (prefix "/") (max-body-bytes +default-max-body-bytes+))
  "PREFIX a string starting and ending with /; MAX-BODY-BYTES a non-negative integer."
  (declare (ignore prefix max-body-bytes))
  (%htmx0-pending 'make-htmx-codec))

(defclass htmx-message ()
  ((method :initarg :method :reader htmx-message-method
           :documentation "Method name string \"PKG::NAME\".")
   (params :initarg :params :initform nil :reader htmx-message-params
           :documentation "Plist keyword → string.")
   (metadata :initarg :metadata :initform nil :reader htmx-message-metadata
             :documentation "Plist, see +REQUEST-METADATA-HEADERS+.")
   (mode :initarg :mode :initform :call-response :reader htmx-message-mode
         :documentation ":CALL-RESPONSE or :CALL-STREAM (from Accept).")
   (http-method :initarg :http-method :initform :get :reader htmx-message-http-method
                :documentation ":GET or :POST."))
  (:documentation "One decoded htmx request."))

(defmethod rpc-protocol:decode-message-using-codec ((codec htmx-codec) env)
  (declare (ignore env))
  (%htmx0-pending 'decode-message-using-codec))

(defmethod rpc-protocol:encode-request-using-codec
    ((codec htmx-codec) method params &key id (http-method :get) (encoding :urlencoded)
                                        metadata headers)
  (declare (ignore method params id http-method encoding metadata headers))
  (%htmx0-pending 'encode-request-using-codec))

(defmethod rpc-protocol:encode-notification-using-codec
    ((codec htmx-codec) method params &key (encoding :urlencoded) metadata headers)
  (declare (ignore method params encoding metadata headers))
  (%htmx0-pending 'encode-notification-using-codec))

(defmethod rpc-protocol:encode-response-using-codec
    ((codec htmx-codec) result &key id (status 200) headers)
  (declare (ignore result id status headers))
  (%htmx0-pending 'encode-response-using-codec))

(defmethod rpc-protocol:encode-error-response-using-codec
    ((codec htmx-codec) code message &key id data
                                      (target +error-fragment-target+)
                                      (swap +error-fragment-swap+))
  (declare (ignore code message id data target swap))
  (%htmx0-pending 'encode-error-response-using-codec))
