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
;;;   multipart/form-data (the part rules below). Decode with the stack: quri
;;;   for urlencoded, mime-protocol (PARSE-MIME, media types, dispositions) for
;;;   multipart, encoding-protocol for UTF-8. No private parsers.
;;;   An empty POST body needs no content type; a non-empty body of any other
;;;   type → HTMX-UNSUPPORTED-MEDIA-TYPE. Malformed input → HTMX-BAD-REQUEST.
;;;   Result: a plist keyword → value. Empty names dropped; first-occurrence
;;;   order (of any kind of value). Names become keys WITHOUT interning (0.3.0,
;;;   rpc-backend-htmx#2; 0.2.1 interned every name, so any client could grow
;;;   the KEYWORD package without bound):
;;;     key = the symbol (FIND-SYMBOL (STRING-UPCASE name) :KEYWORD) finds,
;;;           when its second value is non-NIL;
;;;     no such keyword → the name is UNMAPPED: not in the params, listed in
;;;           HTMX-MESSAGE-UNMAPPED-NAMES — each upcased name once, under its
;;;           first spelling, in wire order (a fresh list of strings).
;;;   Nothing a request sends is ever interned (no INTERN, no reader). Every
;;;   keyword a handler can take already exists — its lambda list or :PARAMS
;;;   made it (handlers.lisp, Key sets) — so an unmapped name is one no handler
;;;   takes; the server refuses it or drops it by the handler's key set.
;;;   Field cap (0.3.0, #2): at most MAX-PARAMS (codec option, default
;;;   +DEFAULT-MAX-PARAMS+ = 1000) fields that carry a value — query and
;;;   urlencoded fields with a non-empty name, multipart parts with a
;;;   non-empty name other than empty file inputs — counted together over the
;;;   query and the body, duplicates and unmapped names included. More →
;;;   HTMX-TOO-MANY-PARAMS (413, :limit MAX-PARAMS), before any name is
;;;   mapped. 413 like HTMX-BODY-TOO-LARGE: the request is well formed, only
;;;   bigger than the server takes (400 stays "malformed").
;;;   Values:
;;;   - text (a query field, a urlencoded field, a multipart part without a
;;;     filename): a string; a later text duplicate (query then body) replaces
;;;     the value in place, as in 0.1.
;;;   - file parts (0.2.0): one under a name → that STACK-MIME:MIME-ENTITY; two
;;;     or more → a fresh list of them in part order (<input type="file"
;;;     multiple>). A name that has a file part keeps only its file parts: text
;;;     values under that name (query or body, before or after) are ignored, so
;;;     a query string cannot stand in for an upload.
;;;   Values are never read with the Lisp reader.
;;;
;;; Multipart parts (0.2.0, rpc-backend-htmx#5). Each part, in order:
;;; - no Content-Disposition, no name parameter, or name "" → dropped (as in 0.1);
;;; - a nested multipart part → HTMX-BAD-REQUEST (as in 0.1);
;;; - a disposition without a filename (STACK-MIME:DISPOSITION-FILENAME is NIL:
;;;   neither filename nor filename*) → a text field: its content as UTF-8
;;;   text, invalid UTF-8 → HTMX-BAD-REQUEST. Unchanged from 0.1.
;;; - filename "" → an empty file input (what a browser sends when no file was
;;;   chosen) → dropped, so the param is missing unless another part of that
;;;   name supplies a value.
;;; - any other filename → a file: the value is the part itself, the
;;;   STACK-MIME:MIME-ENTITY that PARSE-MIME returned, not a copy and not
;;;   text. Its MIME-CONTENT-DISPOSITION and MIME-CONTENT-TYPE are
;;;   mime-protocol's parse of the part headers, taken as they are (a part
;;;   without a Content-Type: mime-protocol#13; fixes there reach handlers
;;;   unchanged). MIME-CONTENT is the content octets exactly as sent (any
;;;   octet, CR LF and "--" included; a part with a Content-Transfer-Encoding
;;;   is decoded by mime-protocol, though browsers never send one, RFC 7578
;;;   §4.7). Nothing is decoded as text, read with the Lisp reader or written
;;;   to disk; FILENAME is the client's and is never used as a path here.
;;; - A filename* mime-protocol cannot read (MIME-ERROR) → HTMX-BAD-REQUEST.
;;; The body limit is unchanged: MAX-BODY-BYTES covers the whole body, files
;;; included (413 below); the body is parsed in memory. A per-field limit is the
;;; handler's (canvas-protocol COERCE-PARAM :file :max-size).
;;; mime-protocol ≥ 0.3.1 is required: it keeps a part whose content is empty or
;;; ends in CR LF intact (mime-protocol#9), which is exactly an empty file input,
;;; a textarea value ending in a line break, or a binary file; and it reads a
;;; form-data name and filename the way browsers write them (mime-protocol#14):
;;; part headers as UTF-8 when their octets are valid UTF-8, a backslash
;;; literal, %22 %0D %0A as " CR LF.
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
;;;   0.5.0 (#15) appends ("last-event-id" . :last-event-id): the Last-Event-ID
;;;   header, as the string sent, under :LAST-EVENT-ID, last. A browser's
;;;   EventSource sends it when it reconnects to a stream whose events had ids
;;;   (STACK-SSE:SSE-EVENT :id), so a :call-stream handler resumes after the
;;;   last event it sent instead of starting over. Any request that carries the
;;;   header gets it; a request without it has no :LAST-EVENT-ID, so every 0.4.0
;;;   metadata plist is unchanged.
;;; - Mode: :CALL-STREAM when the Accept header contains "text/event-stream",
;;;   else :CALL-RESPONSE. (:NOTIFY is a handler-table mode, not a wire one.)
;;; - Client address (0.5.0, #15): HTMX-MESSAGE-CLIENT-ADDRESS, below.
;;; - Session (0.5.0, #19): HTMX-MESSAGE-SESSION is (STACK-SESSION:ENV-SESSION
;;;   env), the session S0b's SESSION-HANDLER put under :SESSION, or NIL (no
;;;   session layer: server.lisp and session.lisp).
;;;
;;; Client address (0.5.0, rpc-backend-htmx#15). HTMX-MESSAGE-CLIENT-ADDRESS is
;;; the address of the client that sent the request, for a per-client limit
;;; ("at most N running jobs per client") or a log line. MAKE-HTMX-CODEC
;;; &key trusted-proxies (MAKE-HTMX-TRANSPORT and MAKE-CANVAS-HTMX-TRANSPORT
;;; pass it on):
;;;   NIL (default) — no proxy is trusted: the address is ENV :REMOTE-ADDR as
;;;     the server gave it (a string), or NIL when the env has none. The
;;;     X-Forwarded-For header is never read, so a client cannot choose its own
;;;     address by sending one (spoofing).
;;;   a non-empty proper list of strings, each an address or a CIDR network
;;;     that STACK-IP:PARSE-NETWORK reads ("10.0.0.0/8", "127.0.0.1", "::1",
;;;     "fd00::/8"; an address alone is a /32 or /128) — the networks of the
;;;     reverse proxies in front of the app. Anything else (a lone string, a
;;;     string ip-protocol refuses, a non-string, an improper list) →
;;;     TYPE-ERROR (CHECK-TYPE) at construction. HTMX-CODEC-TRUSTED-PROXIES →
;;;     NIL or a fresh list of the strings as given.
;;;   An address is TRUSTED when STACK-IP:PARSE-IP reads it and some trusted
;;;   network contains it (STACK-IP:IP-CONTAINS-P); a string ip-protocol
;;;   cannot read is never trusted. With trusted proxies the address is found
;;;   by walking from the right, nginx's real_ip_recursive:
;;;     1. A := ENV :REMOTE-ADDR (the peer of this connection). Not a string,
;;;        or not trusted → A, and X-Forwarded-For is not read: a client that
;;;        reaches the app directly cannot spoof its address.
;;;     2. HOPS := the "x-forwarded-for" header split at commas (as the server
;;;        hands it: several header lines arrive joined with commas), each hop
;;;        trimmed of spaces and tabs, empty hops dropped, kept in order.
;;;     3. While A is trusted and HOPS is not empty: H := the last (right-most)
;;;        hop, removed from HOPS. H not an address STACK-IP:PARSE-IP reads
;;;        ("unknown", "1.2.3.4:5678", "[::1]", junk) → the walk stops and the
;;;        result is A: an address is never taken from beyond a hop no
;;;        trusted proxy could have written. Else A := H.
;;;     4. → A, the string as it appeared (trimmed; not re-printed by
;;;        ip-protocol): the right-most untrusted hop, or, when every hop is
;;;        trusted, the left-most one, or the proxy itself when there is no
;;;        X-Forwarded-For.
;;;   Hops left of the right-most untrusted one were written by the client and
;;;   are ignored. The RFC 7239 Forwarded header and X-Real-IP are not read;
;;;   X-Forwarded-Proto is not read either (behind a TLS-terminating proxy, a
;;;   session cookie needs a cookie policy with :secure t, session-protocol's
;;;   cookie.lisp). ip-protocol 0.1.0 has no IPv4-mapped IPv6 ("::ffff:1.2.3.4").
;;;   One internal function computes it, %CLIENT-ADDRESS (codec env), called by
;;;   DECODE-MESSAGE-USING-CODEC.
;;;   JSONRPC-HANDLER's message has no client address (NIL): the JSON-RPC
;;;   server's own request is not an htmx env.
;;;
;;; ENCODE-REQUEST-USING-CODEC (codec method params &key id http-method encoding
;;;                             metadata headers) → a Clack env plist, what a
;;; browser running htmx would send. METHOD: a method-name string or a symbol
;;; (HTMX-METHOD-NAME). PARAMS: plist keyword → string or integer (decimal),
;;; NIL values dropped; 0.2.0 adds file values (below). HTTP-METHOD :GET
;;; (default; params in the query string) or :POST (params in the body).
;;; ENCODING :URLENCODED (default) or :MULTIPART (POST only). METADATA: a plist
;;; like the decoded one (:request T → "HX-Request: true"). HEADERS: extra alist
;;; (name . value), sent as given (lowercased names).
;;; The env has :request-method :script-name "" :path-info (prefix + method,
;;; decoded) :request-uri (prefix + percent-encoded method + "?query")
;;; :query-string (raw, or NIL) :server-name "localhost" :server-port 80
;;; :server-protocol :http/1.1 :url-scheme "http" :remote-addr "127.0.0.1"
;;; :headers (EQUAL hash table, lowercase keys) and, for POST, :content-type
;;; :content-length and :raw-body (HTTP-PROTOCOL:MAKE-OCTET-INPUT-STREAM).
;;; Encode with the stack: HTTP-PROTOCOL:ENCODE-URLENCODED / MAKE-MULTIPART-BODY.
;;; ID is ignored.
;;; ENCODE-NOTIFICATION-USING-CODEC: the same with HTTP-METHOD :POST.
;;; Round trip: DECODE of ENCODE gives back the method and the params (text
;;; params as strings; files as below).
;;;
;;; File values (0.2.0, rpc-backend-htmx#5). A param value may also be a file
;;; value or a non-empty proper list of file values (one part each, in list
;;; order: <input type="file" multiple>). A file value is a plist
;;;   (:filename F [:content C] [:content-type T])
;;; the file shape of mime-protocol MAKE-FORM-DATA and http-protocol :files:
;;;   F  a string, the part's filename; "" sends an empty file input.
;;;   C  a vector of (unsigned-byte 8), sent as is; a string, sent as UTF-8;
;;;      or NIL / absent: no content.
;;;   T  a string STACK-MIME:PARSE-MEDIA-TYPE accepts, with no control
;;;      character and not of type multipart (the server refuses a nested
;;;      multipart part); sent as given; absent: "application/octet-stream".
;;; An odd or improper plist, a key other than these three, a repeated key, F
;;; missing or not a string, or C / T of another type → HTMX-ERROR (500, a
;;; caller bug). File values need HTTP-METHOD :POST and ENCODING :MULTIPART;
;;; with :GET or :URLENCODED → HTMX-ERROR. Any other value (a list of strings,
;;; a symbol, a float …) → HTMX-ERROR, as in 0.1.
;;; The multipart body holds one part per text field, in PARAMS order, then
;;; one part per file, in PARAMS order and list order. This is
;;; HTTP-PROTOCOL:MAKE-MULTIPART-BODY's order (fields, then files); servers
;;; that read fields before files rely on it. With B the boundary and N the
;;; lowercased key name, a text part is (as in 0.1)
;;;   --B CRLF Content-Disposition: form-data; name="N" CRLF CRLF <UTF-8 value> CRLF
;;; and a file part, raw octets the way a browser sends them (no
;;; Content-Transfer-Encoding, no base64):
;;;   --B CRLF Content-Disposition: <FORMAT-FORM-DATA-DISPOSITION N :filename F> CRLF
;;;   Content-Type: T CRLF CRLF <C> CRLF
;;; and the body ends --B-- CRLF. Build it with http-protocol's encoder,
;;; MAKE-MULTIPART-BODY (text fields as DATA, files as FILES), never a private
;;; writer: it quotes N and F through mime-protocol (" CR LF percent-encoded,
;;; filename* added for a non-ASCII F). mime-protocol MAKE-FORM-DATA is not
;;; used for files: it base64-encodes binary parts, which no browser does.
;;; :content-type is "multipart/form-data; boundary=B", :content-length the
;;; body's octet count.
;;; Round trip: DECODE of ENCODE gives each text param back as a string and
;;; each file as a MIME-ENTITY with filename F, media type T and content C
;;; (as octets); a file value with F "" comes back missing.
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

(defconstant +default-max-params+ 1000
  "Default limit on the fields of one request (0.3.0, #2): codec.lisp header, Params.")

(defparameter +request-metadata-headers+
  '(("hx-request" . :request)
    ("hx-target" . :target)
    ("hx-trigger" . :trigger)
    ("hx-trigger-name" . :trigger-name)
    ("hx-current-url" . :current-url)
    ("hx-boosted" . :boosted)
    ("last-event-id" . :last-event-id))
  "Request header (lowercase) → metadata key, in metadata order. 0.5.0 (#15)
appends Last-Event-ID (file header, Metadata).")

(defparameter +error-fragment-target+ "#canvas-error"
  "Default HX-Retarget of an error response.")

(defparameter +error-fragment-swap+ "innerHTML"
  "Default HX-Reswap of an error response.")

(defclass htmx-codec (rpc-protocol:rpc-codec)
  ((prefix :initarg :prefix :initform "/" :reader htmx-codec-prefix
           :documentation "Mount prefix; method names follow it in the path. Ends with /.")
   (max-body-bytes :initarg :max-body-bytes :initform +default-max-body-bytes+
                   :reader htmx-codec-max-body-bytes)
   (max-params :initarg :max-params :initform +default-max-params+
               :reader htmx-codec-max-params
               :documentation "Most fields one request may carry (0.3.0, #2).")
   (trusted-proxies :initarg :trusted-proxies :initform nil
                    :documentation "NIL or the strings as given (0.5.0, #15); read with
HTMX-CODEC-TRUSTED-PROXIES.")
   (trusted-networks :initarg :trusted-networks :initform nil
                     :reader %codec-trusted-networks
                     :documentation "The STACK-IP:IP-NETWORK of each trusted proxy string."))
  (:documentation "htmx requests ↔ rpc messages; fragments ↔ responses."))

(defun %trusted-proxy-string-p (object)
  "True for a string STACK-IP:PARSE-NETWORK reads (file header, Client address)."
  (and (stringp object)
       ;; Translate only: ip-protocol's refusal is the option's TYPE-ERROR.
       (handler-case (and (stack-ip:parse-network object) t)
         (stack-ip:ip-error () nil))))

(defun %trusted-proxies-p (object)
  "True for a non-empty proper list of trusted-proxy strings."
  (and (consp object)
       (null (cdr (last object)))
       (every #'%trusted-proxy-string-p object)))

(defun %trusted-proxies-option (trusted-proxies)
  "TRUSTED-PROXIES (NIL or a list of address / CIDR strings) → itself, or
TYPE-ERROR (CHECK-TYPE). File header, Client address."
  (check-type trusted-proxies (or null (satisfies %trusted-proxies-p))
              "NIL or a non-empty proper list of IP address or CIDR network strings")
  trusted-proxies)

(defun make-htmx-codec (&key (prefix "/") (max-body-bytes +default-max-body-bytes+)
                          (max-params +default-max-params+) trusted-proxies)
  "PREFIX a string starting and ending with /; MAX-BODY-BYTES and MAX-PARAMS
non-negative integers; TRUSTED-PROXIES NIL or a list of address / CIDR strings
(file header, Client address). Else TYPE-ERROR."
  (check-type prefix (and string (satisfies %slash-bounded-p)))
  (check-type max-body-bytes (integer 0))
  (check-type max-params (integer 0))
  (let ((proxies (copy-list (%trusted-proxies-option trusted-proxies))))
    (make-instance 'htmx-codec :prefix prefix :max-body-bytes max-body-bytes
                               :max-params max-params
                               :trusted-proxies proxies
                               :trusted-networks (mapcar #'stack-ip:parse-network proxies))))

(defun htmx-codec-trusted-proxies (codec)
  "NIL or a fresh list of CODEC's trusted-proxy strings, as given (file header,
Client address)."
  (copy-list (slot-value codec 'trusted-proxies)))

(defun %slash-bounded-p (string)
  "True for a non-empty string that starts and ends with /."
  (and (stringp string) (plusp (length string))
       (char= #\/ (char string 0))
       (char= #\/ (char string (1- (length string))))))

(defclass htmx-message ()
  ((method :initarg :method :reader htmx-message-method
           :documentation "Method name string \"PKG::NAME\".")
   (params :initarg :params :initform nil :reader htmx-message-params
           :documentation "Plist keyword → string, STACK-MIME:MIME-ENTITY (a file part)
or a list of entities (several files under one name). See the file header.")
   (unmapped-names :initarg :unmapped-names :initform nil
                   :reader htmx-message-unmapped-names
                   :documentation "Param names that named no keyword (0.3.0, #2), as sent,
in wire order. See the file header (Params).")
   (metadata :initarg :metadata :initform nil :reader htmx-message-metadata
             :documentation "Plist, see +REQUEST-METADATA-HEADERS+.")
   (mode :initarg :mode :initform :call-response :reader htmx-message-mode
         :documentation ":CALL-RESPONSE or :CALL-STREAM (from Accept).")
   (http-method :initarg :http-method :initform :get :reader htmx-message-http-method
                :documentation ":GET or :POST.")
   (client-address :initarg :client-address :initform nil
                   :reader htmx-message-client-address
                   :documentation "The client's address, a string, or NIL (0.5.0, #15). See
the file header (Client address).")
   (session :initarg :session :initform nil :reader htmx-message-session
            :documentation "The request's STACK-SESSION:SESSION, or NIL when no session
layer ran (0.5.0, #19). Handlers use HTMX-SESSION (session.lisp)."))
  (:documentation "One decoded htmx request."))


;;; ---------------------------------------------------------------------------
;;; Small shared helpers
;;; ---------------------------------------------------------------------------

(deftype %octets () '(simple-array (unsigned-byte 8) (*)))

(defun %empty-octets ()
  (make-array 0 :element-type '(unsigned-byte 8)))

(defun %octets (sequence)
  (coerce sequence '%octets))

(defun %prefixp (prefix string)
  (and (stringp string)
       (>= (length string) (length prefix))
       (string= prefix string :end2 (length prefix))))

(defun %env-header (env name)
  "Request header NAME (lowercase) from a Clack ENV, or NIL."
  (let ((headers (getf env :headers)))
    (and (hash-table-p headers) (values (gethash name headers)))))

(defun %utf8-octets (string)
  (%octets (stack-encoding:encode-to-octets string :encoding :utf-8)))

(defun %utf8-string (octets)
  "OCTETS as UTF-8 text. Invalid UTF-8 → STACK-ENCODING:ENCODING-ERROR."
  (stack-encoding:decode-octets octets :encoding :utf-8))

(defun %method-not-found (rest)
  (error 'rpc-protocol:rpc-method-not-found
         :message (format nil "Method not found: ~A" rest)))

;;; ---------------------------------------------------------------------------
;;; The request body: the one place that reads :RAW-BODY
;;; ---------------------------------------------------------------------------

(defun %read-request-body (env limit)
  "The request body as octets, at most LIMIT of them.
The only function that reads :RAW-BODY. http-server-protocol has no body
helper yet (https://github.com/egao1980/http-server-protocol/issues/12); when
`request-body-octets :max-bytes` ships, this becomes a call to it.
A Content-Length above LIMIT signals HTMX-BODY-TOO-LARGE (:size = that length)
before anything is read. Without one, at most LIMIT+1 octets are read with
READ-SEQUENCE, and more than LIMIT signals HTMX-BODY-TOO-LARGE (:size NIL)."
  (let ((length (getf env :content-length))
        (in (getf env :raw-body)))
    (when (and length (not (typep length '(integer 0))))
      (error 'htmx-bad-request :message "Bad Content-Length"))
    (when (and length (> length limit))
      (error 'htmx-body-too-large :limit limit :size length))
    (cond ((or (eql length 0) (and (null in) (null length)))
           (%empty-octets))
          ((null in)
           (error 'htmx-bad-request :message "Missing request body"))
          (t
           (let* ((buffer (make-array (or length (1+ limit))
                                      :element-type '(unsigned-byte 8)))
                  (n (read-sequence buffer in)))
             (cond ((and length (< n length))
                    (error 'htmx-bad-request :message "Truncated request body"))
                   ((> n limit)
                    (error 'htmx-body-too-large :limit limit :size nil))
                   (t (subseq buffer 0 n))))))))

;;; ---------------------------------------------------------------------------
;;; Params: urlencoded (quri), multipart (mime-protocol), UTF-8 (encoding-protocol)
;;; ---------------------------------------------------------------------------

(defun %latin1-to-utf8 (string)
  "STRING holds one octet per character (quri decoded it as Latin-1) → UTF-8 text."
  (%utf8-string (stack-encoding:encode-to-octets string :encoding :latin-1)))

(defun %form-pairs (octets)
  "application/x-www-form-urlencoded OCTETS → ((name . value) …) in wire order.
quri splits the fields without decoding; each piece is then percent-decoded
strictly (octet-transparent, as Latin-1) and read as UTF-8 by encoding-protocol.
Empty names are dropped; a field without = has the value \"\"."
  (handler-case
      (loop for (key . value) in (quri:url-decode-params (%octets octets)
                                                         :lenient t :percent-decode nil)
            for name = (%latin1-to-utf8 (quri:url-decode (%octets key) :encoding :latin-1))
            unless (zerop (length name))
              collect (cons name
                            (if value
                                (%latin1-to-utf8 (quri:url-decode (%octets value)
                                                                  :encoding :latin-1))
                                "")))
    (quri:uri-error ()
      (error 'htmx-bad-request :message "Malformed urlencoded data"))
    (stack-encoding:encoding-error ()
      (error 'htmx-bad-request :message "Invalid UTF-8 in urlencoded data"))))

(defun %file-part-pairs (name part)
  "The pairs a file PART (its disposition has a filename parameter) named NAME
contributes: () for an empty file input (filename \"\"), else ((NAME . PART)),
PART itself. See the file header (Multipart parts).
Runs inside %MULTIPART-PAIRS' handler, so an unreadable filename* is 400."
  (let ((filename (stack-mime:disposition-filename
                   (stack-mime:mime-content-disposition part))))
    (if (zerop (length filename))
        '()
        (list (cons name part)))))

(defun %multipart-pairs (media-type body)
  "multipart/form-data BODY (octets) → ((name . value) …) in part order: VALUE
the UTF-8 text of a text part, or the part itself for a file part (0.2.0).
mime-protocol parses the entity; the header block it reads is rebuilt from
the parsed MEDIA-TYPE, never copied from the request."
  (handler-case
      (let* ((head (format nil "Content-Type: ~A~C~C~C~C"
                           (stack-mime:format-media-type media-type)
                           #\Return #\Linefeed #\Return #\Linefeed))
             (entity (stack-mime:parse-mime
                      (concatenate '%octets
                                   (stack-encoding:encode-to-octets head :encoding :latin-1)
                                   body))))
        (loop for part in (stack-mime:mime-parts entity)
              for disposition = (stack-mime:mime-content-disposition part)
              for name = (and disposition (stack-mime:disposition-name disposition))
              when (stack-mime:multipart-p part)
                do (error 'htmx-bad-request :message "Nested multipart is not supported")
              when (and name (plusp (length name)))
                if (stack-mime:disposition-filename disposition)
                  nconc (%file-part-pairs name part)
                else
                  collect (cons name (%utf8-string (%octets (stack-mime:mime-content part))))))
    (stack-mime:mime-error ()
      (error 'htmx-bad-request :message "Malformed multipart body"))
    (stack-encoding:encoding-error ()
      (error 'htmx-bad-request :message "Invalid UTF-8 in multipart body"))))

(defun %body-pairs (env body)
  "Pairs of a non-empty POST BODY, by its content type."
  (let ((content-type (or (getf env :content-type) (%env-header env "content-type"))))
    (unless content-type
      (error 'htmx-unsupported-media-type :content-type nil))
    (let ((media-type (handler-case (stack-mime:parse-media-type content-type)
                        (stack-mime:mime-error ()
                          (error 'htmx-bad-request :message "Malformed Content-Type")))))
      (let ((essentials (stack-mime:media-type-essentials media-type)))
        (cond ((string= essentials "application/x-www-form-urlencoded")
               (let ((charset (stack-mime:media-type-charset media-type)))
                 (unless (or (null charset) (string-equal charset "utf-8"))
                   (error 'htmx-unsupported-media-type :content-type content-type)))
               (%form-pairs body))
              ((string= essentials "multipart/form-data")
               (%multipart-pairs media-type body))
              (t (error 'htmx-unsupported-media-type :content-type content-type)))))))

;;; Names → keys (0.3.0, rpc-backend-htmx#2): %NAME-KEY (FIND-SYMBOL, never
;;; INTERN) is the one mapping site, %KEY-PAIRS the one pass over the pairs;
;;; JSONRPC-HANDLER goes through the same %PARAMS-PLIST. %CHECK-PARAM-COUNT runs
;;; on all the pairs (query then body) before any name is mapped. File header,
;;; Params.

(defun %name-key (name)
  "The keyword the param NAME maps to, or NIL when NAME is unmapped.
Never interns (FIND-SYMBOL in KEYWORD). See the file header (Params)."
  (multiple-value-bind (symbol status) (find-symbol (string-upcase name) :keyword)
    (and status symbol)))

(defun %check-param-count (pairs limit)
  "Signal HTMX-TOO-MANY-PARAMS (:limit LIMIT) when PAIRS — the value-carrying
fields of one request, query then body — are more than LIMIT."
  (when (> (length pairs) limit)
    (error 'htmx-too-many-params :limit limit))
  (values))

(defun %key-pairs (pairs)
  "PAIRS ((name . value) …) in wire order → (values KEYED UNMAPPED): KEYED the
fresh ((keyword . value) …) of the names %NAME-KEY maps, in order; UNMAPPED the
other names, each upcased name once under its first spelling, in wire order (a
fresh list)."
  (let ((seen (make-hash-table :test 'equal)) ; lookup only, never iterated
        (keyed '())
        (unmapped '()))
    (loop for (name . value) in pairs
          for key = (%name-key name)
          do (if key
                 (push (cons key value) keyed)
                 (let ((upcased (string-upcase name)))
                   (unless (gethash upcased seen)
                     (setf (gethash upcased seen) t)
                     (push name unmapped)))))
    (values (nreverse keyed) (nreverse unmapped))))

(defun %file-params-plist (keyed)
  "%PARAMS-PLIST for KEYED pairs ((keyword . value) …) that hold file parts:
keys in first-occurrence order; text values as in 0.1; a key with file parts
takes only those (one → the entity, several → a fresh list in part order). See
the file header."
  (let ((cells (make-hash-table :test 'eq)) ; lookup only, never iterated
        (out '()))
    ;; A cell is (KEY TEXT FILES): TEXT the last text value (a string) or NIL,
    ;; FILES the entities under KEY, newest first.
    (loop for (key . value) in keyed
          do (let ((cell (or (gethash key cells)
                             (let ((new (list key nil '())))
                               (push new out)
                               (setf (gethash key cells) new)))))
               (if (stack-mime:mime-entity-p value)
                   (push value (third cell))
                   (setf (second cell) value))))
    (loop for (key text files) in (nreverse out)
          collect key
          collect (cond ((null files) text)
                        ((null (rest files)) (first files))
                        (t (reverse files))))))

(defun %text-params-plist (keyed)
  "KEYED pairs ((keyword . string) …) → plist; first-occurrence order, later
duplicates replace the value in place."
  (let ((cells (make-hash-table :test 'eq)) ; lookup only, never iterated
        (out '()))
    (loop for (key . value) in keyed
          for cell = (gethash key cells)
          do (if cell
                 (setf (cdr cell) value)
                 (let ((new (cons key value)))
                   (setf (gethash key cells) new)
                   (push new out))))
    (loop for (key . value) in (nreverse out) collect key collect value)))

(defun %params-plist (pairs)
  "PAIRS ((name . value) …) in wire order → (values PLIST UNMAPPED): PLIST
keyword → value in first-occurrence order (text duplicates replace the value in
place; 0.2.0 file parts as %FILE-PARAMS-PLIST), UNMAPPED the names that named no
keyword (%KEY-PAIRS). Nothing is interned. See the file header (Params)."
  (multiple-value-bind (keyed unmapped) (%key-pairs pairs)
    (values (if (some (lambda (pair) (stack-mime:mime-entity-p (cdr pair))) keyed)
                (%file-params-plist keyed)
                (%text-params-plist keyed))
            unmapped)))

(defun %request-metadata (env)
  (loop for (header . key) in +request-metadata-headers+
        for value = (%env-header env header)
        when value
          if (member key '(:request :boosted))
            when (string-equal value "true") collect key and collect t end
          else collect key and collect value))

(defun %request-mode (env)
  (let ((accept (%env-header env "accept")))
    (if (and accept (search "text/event-stream" accept :test #'char-equal))
        :call-stream
        :call-response)))

;;; Client address (0.5.0, #15): file header, Client address.

(defun %client-address (codec env)
  "The client address of ENV under CODEC's trusted proxies: a string or NIL.
File header, Client address (steps 1 to 4)."
  ;; S1 contract stub. It runs on every request, so it does not signal: it
  ;; answers NIL, which the 0.4.0 suite never reads. The implementation
  ;; follows the file header.
  (declare (ignore codec env))
  nil)

(defmethod rpc-protocol:decode-message-using-codec ((codec htmx-codec) env)
  (let ((http-method (getf env :request-method)))
    (unless (member http-method '(:get :post))
      (error 'htmx-method-not-allowed))
    (let* ((prefix (htmx-codec-prefix codec))
           (path (or (getf env :path-info) ""))
           (rest (if (%prefixp prefix path) (subseq path (length prefix)) nil)))
      (unless (and rest (%method-name-p rest))
        (%method-not-found (or rest path)))
      (let* ((query (getf env :query-string))
             (pairs (if (and query (plusp (length query)))
                        (%form-pairs (%utf8-octets query))
                        '())))
        (when (eq http-method :post)
          (let ((body (%read-request-body env (htmx-codec-max-body-bytes codec))))
            (when (plusp (length body))
              (setf pairs (append pairs (%body-pairs env body))))))
        ;; The field cap first, on every pair (query then body), before any
        ;; name is mapped; then the names, never interned (file header, Params).
        (%check-param-count pairs (htmx-codec-max-params codec))
        (multiple-value-bind (params unmapped) (%params-plist pairs)
          (make-instance 'htmx-message
                         :method rest
                         :params params
                         :unmapped-names unmapped
                         :metadata (%request-metadata env)
                         :mode (%request-mode env)
                         :http-method http-method
                         :client-address (%client-address codec env)
                         :session (stack-session:env-session env)))))))

;;; ---------------------------------------------------------------------------
;;; Requests (client side)
;;; ---------------------------------------------------------------------------

(defun %method-string (method)
  (etypecase method
    (string method)
    (symbol (htmx-method-name method))))

(defun %params-alist (params)
  "Plist keyword → string / integer (NIL dropped) → ((\"name\" . \"value\") …)."
  (loop for (key value) on params by #'cddr
        unless (null value)
          collect (cons (string-downcase (string key))
                        (typecase value
                          (string value)
                          (integer (format nil "~D" value))
                          (t (error 'htmx-error
                                    :message (format nil "Param ~S: not a string or integer: ~S"
                                                     key value)))))))

(defun %request-uri (prefix method query)
  (let* ((sep (search "::" method))
         (encoded (if sep
                      (concatenate 'string
                                   (quri:url-encode (subseq method 0 sep))
                                   "::"
                                   (quri:url-encode (subseq method (+ sep 2))))
                      (quri:url-encode method))))
    (concatenate 'string prefix encoded (if query (concatenate 'string "?" query) ""))))

(defun %encode-env (codec http-method path-info query body content-type metadata headers
                    &key request-uri)
  "The one Clack env builder. BODY octets (POST) or NIL."
  (let ((table (make-hash-table :test 'equal)))
    (loop for (header . key) in +request-metadata-headers+
          for value = (getf metadata key)
          when value
            do (setf (gethash header table) (if (eq value t) "true" value)))
    (loop for (name . value) in headers
          do (setf (gethash (string-downcase name) table) value))
    (when body
      (setf (gethash "content-type" table) content-type
            (gethash "content-length" table) (format nil "~D" (length body))))
    (append (list :request-method http-method
                  :script-name ""
                  :path-info path-info
                  :request-uri (or request-uri
                                   (%request-uri (htmx-codec-prefix codec)
                                                 (subseq path-info (length (htmx-codec-prefix codec)))
                                                 query))
                  :query-string query
                  :server-name "localhost"
                  :server-port 80
                  :server-protocol :http/1.1
                  :url-scheme "http"
                  :remote-addr "127.0.0.1"
                  :headers table)
            (when body
              (list :content-type content-type
                    :content-length (length body)
                    :raw-body (http-protocol:make-octet-input-stream body))))))

(defun %multipart-octets (alist &optional files)
  "ALIST (text fields) and FILES (http-protocol :files entries) as a
multipart/form-data body, fields first → (values octets content-type)."
  (multiple-value-bind (stream content-type length) (http-protocol:make-multipart-body alist files)
    (unless length
      (error 'htmx-error :message "multipart body without a length"))
    (let* ((buffer (make-array length :element-type '(unsigned-byte 8)))
           (n (read-sequence buffer stream)))
      (values (subseq buffer 0 n) content-type))))

(defun %file-params-p (params)
  "True when some value of PARAMS is a cons: a file value, a list of them, or
a list the file rules refuse. Those requests go to %ENCODE-FILE-REQUEST."
  (loop for (nil value) on params by #'cddr thereis (consp value)))

(defun %file-refused (key control &rest args)
  "A file value under KEY the File values rules refuse → HTMX-ERROR (500).
The message never prints the content (it may be large)."
  (error 'htmx-error
         :message (format nil "File param ~S: ~?" key control args)))

(defun %proper-list-p (object)
  "True for a proper list (the repo idiom; circular input is not guarded)."
  (and (listp object) (null (cdr (last object)))))

(defun %file-value-p (value)
  "True when VALUE has the shape of one file value: a cons whose car is a keyword."
  (and (consp value) (keywordp (car value))))

(defun %file-control-char-p (char)
  (let ((code (char-code char)))
    (or (< code 32) (= code 127))))

(defun %file-content-type (key type)
  "T of a file value under KEY → TYPE itself (sent as given), or HTMX-ERROR."
  (unless (stringp type)
    (%file-refused key ":content-type must be a string, not a ~(~A~)" (type-of type)))
  (when (find-if #'%file-control-char-p type)
    (%file-refused key ":content-type contains a control character"))
  (let ((media-type (handler-case (stack-mime:parse-media-type type)
                      (stack-mime:mime-error () nil)))) ; translated just below
    (unless media-type
      (%file-refused key ":content-type ~S is not a media type" type))
    (when (string= "multipart" (stack-mime:media-type-type media-type))
      (%file-refused key ":content-type cannot be multipart: ~S" type))
    type))

(defun %file-content (key content)
  "C of a file value under KEY → a simple octet vector, or HTMX-ERROR."
  (typecase content
    (null (%empty-octets))
    (string (%utf8-octets content))
    ((vector (unsigned-byte 8)) (%octets content))
    (t (%file-refused key ":content must be octets, a string or NIL, not a ~(~A~)"
                      (type-of content)))))

(defun %file-part (key value)
  "One file VALUE under KEY → an HTTP-PROTOCOL:MAKE-MULTIPART-BODY :files entry
(\"name\" :filename F :content octets :content-type T), or HTMX-ERROR.
See the file header (File values)."
  (unless (%proper-list-p value)
    (%file-refused key "improper file plist"))
  (unless (evenp (length value))
    (%file-refused key "odd file plist"))
  (let ((seen '())
        (filename nil)
        (content (%empty-octets))
        (content-type "application/octet-stream"))
    (loop for (k v) on value by #'cddr
          do (unless (member k '(:filename :content :content-type))
               (%file-refused key "unknown key ~S (one of :filename :content :content-type)" k))
             (when (member k seen)
               (%file-refused key "repeated key ~S" k))
             (push k seen)
             (ecase k
               (:filename
                (unless (stringp v)
                  (%file-refused key ":filename must be a string, not a ~(~A~)" (type-of v)))
                (setf filename v))
               (:content (setf content (%file-content key v)))
               (:content-type (setf content-type (%file-content-type key v)))))
    (unless filename
      (%file-refused key ":filename is missing"))
    ;; :content is never NIL (http-protocol needs it); :filename "" stays "".
    (list (string-downcase (string key))
          :filename filename :content content :content-type content-type)))

(defun %file-parts (key value)
  "A cons param VALUE under KEY → fresh list of :files entries, in list order."
  (cond ((%file-value-p value)
         (list (%file-part key value)))
        ((and (consp (car value)) (%proper-list-p value) (every #'%file-value-p value))
         (mapcar (lambda (one) (%file-part key one)) value))
        (t (%file-refused key "not a string, an integer, a file value or a list of file values"))))

(defun %split-file-params (params)
  "PARAMS with a cons value → (values TEXT FILES): TEXT the plist of the other
params (for %PARAMS-ALIST, so 0.1's drops and refusals apply), FILES the
:files entries in PARAMS order and list order."
  (let ((text '())
        (files '()))
    (loop for (key value) on params by #'cddr
          do (if (consp value)
                 (dolist (part (%file-parts key value))
                   (push part files))
                 (progn (push key text) (push value text))))
    (values (nreverse text) (nreverse files))))

(defun %encode-file-request (codec method params http-method encoding metadata headers)
  "ENCODE-REQUEST-USING-CODEC for PARAMS with a cons value: validate the file
values, refuse them outside :POST :MULTIPART, and build the multipart body with
HTTP-PROTOCOL:MAKE-MULTIPART-BODY (text fields as DATA, files as FILES).
See the file header (File values)."
  (let ((name (%method-string method)))
    (multiple-value-bind (text files) (%split-file-params params)
      (unless (and (eq http-method :post) (eq encoding :multipart))
        (error 'htmx-error
               :message (format nil "File params need :http-method :post and :encoding :multipart, not ~S ~S"
                                http-method encoding)))
      (let ((alist (%params-alist text))
            (path-info (concatenate 'string (htmx-codec-prefix codec) name)))
        (multiple-value-bind (body content-type)
            ;; Translate only: a stack refusal while building the body (a NUL in
            ;; a filename, from mime-protocol) is a caller bug → HTMX-ERROR 500.
            (handler-case (%multipart-octets alist files)
              (stack-mime:mime-error (c)
                (error 'htmx-error :message (princ-to-string c) :data c))
              (http-protocol:http-protocol-error (c)
                (error 'htmx-error :message (princ-to-string c) :data c)))
          (%encode-env codec :post path-info nil body content-type metadata headers))))))

(defmethod rpc-protocol:encode-request-using-codec
    ((codec htmx-codec) method params &key id (http-method :get) (encoding :urlencoded)
                                        metadata headers)
  (declare (ignore id))
  (when (%file-params-p params)
    (return-from rpc-protocol:encode-request-using-codec
      (%encode-file-request codec method params http-method encoding metadata headers)))
  (let* ((name (%method-string method))
         (alist (%params-alist params))
         (form (and alist (%octets (http-protocol:encode-urlencoded alist))))
         (path-info (concatenate 'string (htmx-codec-prefix codec) name)))
    (ecase http-method
      (:get
       (unless (eq encoding :urlencoded)
         (error 'htmx-error :message (format nil "~S encoding needs :post" encoding)))
       (%encode-env codec :get path-info (and form (%utf8-string form)) nil nil
                    metadata headers))
      (:post
       (ecase encoding
         (:urlencoded
          (%encode-env codec :post path-info nil (or form (%empty-octets))
                       "application/x-www-form-urlencoded" metadata headers))
         (:multipart
          (multiple-value-bind (body content-type) (%multipart-octets alist)
            (%encode-env codec :post path-info nil body content-type metadata headers))))))))

(defmethod rpc-protocol:encode-notification-using-codec
    ((codec htmx-codec) method params &key (encoding :urlencoded) metadata headers)
  (rpc-protocol:encode-request-using-codec codec method params
                                           :http-method :post :encoding encoding
                                           :metadata metadata :headers headers))

;;; ---------------------------------------------------------------------------
;;; Responses
;;; ---------------------------------------------------------------------------

(defun %plain-nodes (result)
  "RESULT → fresh list of html-protocol nodes (the default HTMX-RESULT-NODES)."
  (typecase result
    (null '())
    (stack-html:html-node (list result))
    (string (list (make-instance 'stack-html:html-text :data result)))
    (list (loop for item in result append (%plain-nodes item)))
    (t (error 'htmx-error
              :message (format nil "Cannot turn ~S into HTML nodes" (type-of result))))))

(defun %html-string (result)
  "Serialized HTML for RESULT: an html-document whole, else its nodes."
  (stack-html:serialize
   (if (typep result 'stack-html:html-document)
       result
       (stack-html:make-html-document :children (%plain-nodes result)))))

(defun %header-name-char-p (char)
  (or (char<= #\a char #\z) (char<= #\A char #\Z) (char<= #\0 char #\9) (char= char #\-)))

(defun %hx-header-plist (headers)
  "Response metadata alist ((\"HX-…\" . string) …) → Clack header plist, in order.
Anything else → HTMX-ERROR (500)."
  (loop for entry in headers
        for (name . value) = (if (consp entry) entry (cons nil nil))
        unless (and (stringp name)
                    (> (length name) 3)
                    (string-equal "HX-" name :end2 3)
                    (every #'%header-name-char-p name)
                    (stringp value)
                    (not (find #\Return value))
                    (not (find #\Linefeed value)))
          do (error 'htmx-error :status 500
                                :message (format nil "Refused response header ~S" name))
        collect (intern (string-upcase name) :keyword)
        collect value))

(defmethod rpc-protocol:encode-response-using-codec
    ((codec htmx-codec) result &key id (status 200) headers)
  (declare (ignore id))
  (let ((header-plist (%hx-header-plist headers)))
    (list status
          (list* :content-type "text/html; charset=utf-8" header-plist)
          (list (%html-string result)))))

(defun %error-status (code)
  (cond ((and (integerp code) (<= 100 code 599)) code)
        ((eql code rpc-protocol:+method-not-found+) 404)
        ((eql code rpc-protocol:+invalid-params+) 422)
        ((member code (list rpc-protocol:+invalid-request+ rpc-protocol:+parse-error+)) 400)
        (t 500)))

(defun %error-fragment (message)
  "<p role=\"alert\">MESSAGE</p>, MESSAGE one escaped text node."
  (stack-html:serialize
   (stack-html:make-html-document
    :children (list (stack-html:make-html-element
                     "p" :attributes (list (cons "role" "alert"))
                         :children (list (make-instance 'stack-html:html-text
                                                        :data message)))))))

(defmethod rpc-protocol:encode-error-response-using-codec
    ((codec htmx-codec) code message &key id data
                                      (target +error-fragment-target+)
                                      (swap +error-fragment-swap+))
  (declare (ignore id data))
  (list (%error-status code)
        (list :content-type "text/html; charset=utf-8"
              :hx-retarget target
              :hx-reswap swap)
        (list (%error-fragment (if (stringp message) message (princ-to-string (or message "")))))))
