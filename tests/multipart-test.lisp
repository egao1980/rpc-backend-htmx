(in-package #:rpc-backend-htmx/tests)

;;; 0.2.0 (rpc-backend-htmx#5): multipart file parts are mime-protocol entities
;;; on the way in, file values are raw binary parts on the way out.
;;; Rules: the src/codec.lisp header (Params, Multipart parts, File values).
;;; Bodies below are shaped the way a browser sends a form: parts in document
;;; order, no Content-Transfer-Encoding, file content as raw octets.

(defparameter +crlf+ (format nil "~C~C" #\Return #\Linefeed))

(defparameter +boundary+ "XyZzY")

(defun bytes (&rest items)
  "Octets: strings as UTF-8, integers as one octet each, octet vectors as they
are, concatenated into a fresh simple octet vector."
  (let ((out (make-array 0 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0)))
    (dolist (item items (coerce out '(simple-array (unsigned-byte 8) (*))))
      (etypecase item
        (string (loop for b across (octets item) do (vector-push-extend b out)))
        (integer (vector-push-extend item out))
        (vector (loop for b across item do (vector-push-extend b out)))))))

(defparameter +svg+
  "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 10 10\"><g id=\"a\"><path d=\"M0 0L10 10\"/></g></svg>"
  "A small engraver-style SVG (valid UTF-8 text, still a file).")

(defparameter +binary+
  (bytes #x89 "PNG" 13 10 #x1A 10 0 #xFF #xFE #x80 #xC3 #x28 13 10 "--XyZ" 13 10 "--" 13 10)
  "Binary content: not UTF-8 (#x89, #xC3 #x28), NUL, CR LF, a near-miss of
the boundary (CR LF --XyZ CR LF) and \"--\" inside, and it ends in CR LF.")

;;; Browser-shaped bodies

(defun mp-part (headers content)
  "One part: --XyZzY CRLF, each of HEADERS + CRLF, CRLF, CONTENT, CRLF."
  (apply #'bytes "--" +boundary+ +crlf+
         (append (loop for h in headers append (list h +crlf+))
                 (list +crlf+ content +crlf+))))

(defun mp-text (name value)
  (mp-part (list (format nil "Content-Disposition: form-data; name=\"~A\"" name)) value))

(defun mp-file (name filename content &optional (type "application/octet-stream"))
  "A file part; TYPE NIL sends no Content-Type."
  (mp-part (append (list (format nil "Content-Disposition: form-data; name=\"~A\"; filename=\"~A\""
                                 name filename))
                   (when type (list (format nil "Content-Type: ~A" type))))
           content))

(defun mp-empty-file (name)
  "What a browser sends for a file input left empty."
  (mp-file name "" ""))

(defun mp-body (&rest parts)
  (apply #'bytes (append parts (list "--" +boundary+ "--" +crlf+))))

(defun mp-env (parts &key query (content-length :auto) (path (s+ +prefix+ (m "CAPTURE"))))
  (env :method :post :path path :query query :body (apply #'mp-body parts)
       :content-length content-length
       :content-type (s+ "multipart/form-data; boundary=" +boundary+)))

(defun mp-params (parts &key query (codec (codec)))
  (h:htmx-message-params (decode (mp-env parts :query query) codec)))

;;; Reading a decoded part

(defun part-p (object) (typep object 'mime:mime-entity))
(defun part-name (part) (mime:disposition-name (mime:mime-content-disposition part)))
(defun part-filename (part) (mime:disposition-filename (mime:mime-content-disposition part)))
(defun part-type (part)
  (let ((ct (mime:mime-content-type part)))
    (and ct (mime:media-type-essentials ct))))
(defun part-octets (part) (mime:mime-content part))

(defun param-keys (plist)
  (loop for (k) on plist by #'cddr collect k))

;;; ---------------------------------------------------------------------------
;;; Decode
;;; ---------------------------------------------------------------------------

(deftest multipart-text-parts-unchanged
  ;; Text parts keep the 0.1 rule. mime-protocol 0.3.0 keeps an empty value
  ;; and a value ending in CR LF (a textarea) intact (mime-protocol#9).
  (let ((params (mp-params (list (mp-text "title" "Prélude & <fugue>")
                                 (mp-text "blank" "")
                                 (mp-text "notes" (s+ "a" +crlf+ "b" +crlf+))
                                 (mp-part '("Content-Disposition: form-data; name=\"lang\""
                                            "Content-Type: text/plain; charset=utf-8")
                                          "fr")
                                 (mp-text "page" "3"))
                           :query "page=1&sort=-name")))
    (ok (equal (list :page "3" :sort "-name" :title "Prélude & <fugue>" :blank ""
                     :notes (s+ "a" +crlf+ "b" +crlf+) :lang "fr")
               params)
        "strings; query first, a later text duplicate replaces in place")))

(deftest multipart-file-part-is-the-entity
  (let* ((params (mp-params (list (mp-text "title" "My score")
                                  (mp-file "score" "Prelude in C.svg" +svg+ "image/svg+xml")
                                  (mp-file "cover" "cover.png" +binary+ "image/png")
                                  (mp-file "raw" "raw.bin" (bytes 1 2 3) nil))))
         (score (getf params :score))
         (cover (getf params :cover))
         (raw (getf params :raw)))
    (ok (equal '(:title :score :cover :raw) (param-keys params)) "part order")
    (ok (equal "My score" (getf params :title)) "a text part is still a string")
    (ok (part-p score) "a part with a filename is the mime-protocol entity")
    (ok (part-p cover))
    (ok (part-p raw))
    (ok (equal "score" (part-name score)))
    (ok (equal "Prelude in C.svg" (part-filename score)))
    (ok (equal "image/svg+xml" (part-type score)))
    (ok (equalp (octets +svg+) (part-octets score))
        "UTF-8 text in a file part is still octets, not a string")
    (ok (equal "cover.png" (part-filename cover)))
    (ok (equal "image/png" (part-type cover)))
    (ok (typep (part-octets cover) '(vector (unsigned-byte 8))))
    (ok (equalp +binary+ (part-octets cover))
        "binary octets intact: non-UTF-8, NUL, CR LF, a boundary near-miss, the final CR LF")
    (ok (= (length +binary+) (length (part-octets cover))))
    (ok (equalp (bytes 1 2 3) (part-octets raw)))))

(deftest multipart-binary-file-is-not-a-bad-request
  ;; 0.1 answered 400 "Invalid UTF-8 in multipart body" for any binary upload.
  (setf *seen* nil)
  (let* ((r (h:htmx-request-env (client) (mp-env (list (mp-text "title" "T")
                                                       (mp-file "doc" "d.bin" +binary+)))))
         (seen (first *seen*)))
    (ok (= 200 (h:htmx-reply-status r)))
    (ok (equal "T" (getf seen :title)))
    (ok (part-p (getf seen :doc)) "the handler gets the entity as its keyword argument")
    (ok (equalp +binary+ (part-octets (getf seen :doc))))))

(deftest multipart-filename-is-mime-protocols
  ;; FILENAME is the client's, as mime-protocol reads it: filename* (RFC 8187)
  ;; preferred, nothing reduced or cleaned here (canvas-protocol does that).
  ;; A browser's raw UTF-8 filename and a backslash in it: the next test.
  (let ((params (mp-params
                 (list (mp-part '("Content-Disposition: form-data; name=\"a\"; filename=\"Prelude.svg\"; filename*=UTF-8''Pr%C3%A9lude.svg"
                                  "Content-Type: image/svg+xml")
                                +svg+)
                       (mp-file "b" "scores/b.svg" +svg+ "image/svg+xml")))))
    (ok (equal "Prélude.svg" (part-filename (getf params :a))))
    (ok (equal "scores/b.svg" (part-filename (getf params :b)))))
  (ok (signals (decode (mp-env (list (mp-part '("Content-Disposition: form-data; name=\"a\"; filename*=KOI8-R''%C1"
                                                "Content-Type: image/svg+xml")
                                              +svg+))))
               'h:htmx-bad-request)
      "a filename* mime-protocol cannot read → 400, not a 500"))

(defparameter +utf8-filename+ "Ünïcödé — 楽譜.svg"
  "A filename with Latin-1, General Punctuation and CJK characters.")

(deftest multipart-browser-names
  ;; 0.2.1, mime-protocol ≥ 0.3.1 (mime-protocol#14). A browser writes a
  ;; form-data name and filename as raw UTF-8 in a quoted string, sends no
  ;; filename*, encodes only " CR LF (as %22 %0D %0A) and never a quoted-pair
  ;; (RFC 7578 §2, §4.2; HTML's form-data encoding). mime-protocol 0.3.0 read
  ;; such headers as ISO-8859-1 and dropped a backslash as an escape.
  ;; The parsed parts are not re-printed (mime-protocol#16).
  (setf *seen* nil)
  (let* ((r (h:htmx-request-env
             (client)
             (mp-env (list (mp-file "score" +utf8-filename+ +binary+ "image/svg+xml")
                           (mp-text "say%22hi%22" "q")
                           (mp-file "path%22s" "C:\\fakepath\\a\\b.svg" +svg+ "image/svg+xml")
                           (mp-file "quoted" "%22x%22%0D%0A.svg" (bytes 1 2 3))
                           (mp-part (list (bytes "Content-Disposition: form-data; name=\"latin\"; filename=\"caf"
                                                 #xE9 ".txt\""))
                                    (bytes 4))))))
         (seen (first *seen*))
         (score (getf seen :score))
         (path (getf seen :|PATH"S|)))
    (ok (= 200 (h:htmx-reply-status r)))
    (ok (equal '(:score :|SAY"HI"| :|PATH"S| :quoted :latin) (param-keys seen))
        "%22 in a name is a quote, in the key too")
    (ok (part-p score) "the handler's param is the mime-protocol entity")
    (ok (equal "score" (part-name score)))
    (ok (equal +utf8-filename+ (part-filename score)) "a raw UTF-8 filename reads back")
    (ok (equal "image/svg+xml" (part-type score)))
    (ok (equalp +binary+ (part-octets score)) "octets intact beside a UTF-8 header")
    (ok (equal "q" (getf seen :|SAY"HI"|)) "a text field whose name holds %22")
    (ok (part-p path))
    (ok (equal "path\"s" (part-name path)))
    (ok (equal "C:\\fakepath\\a\\b.svg" (part-filename path)) "backslashes are literal")
    (ok (equalp (octets +svg+) (part-octets path)))
    (ok (equal (format nil "\"x\"~C~C.svg" #\Return #\Linefeed)
               (part-filename (getf seen :quoted)))
        "%22 %0D %0A in a filename → \" CR LF")
    (ok (equal (format nil "caf~C.txt" (code-char #xE9)) (part-filename (getf seen :latin)))
        "a header that is not valid UTF-8 keeps the ISO-8859-1 reading")))

(deftest multipart-empty-file-input-is-missing
  (let ((params (mp-params (list (mp-text "title" "T") (mp-empty-file "photo")))))
    (ok (equal '(:title "T") params) "filename=\"\" with no content → dropped")
    (ok (null (member :photo params)) "the key is absent, so a &key default applies"))
  (let ((params (mp-params (list (mp-empty-file "photo")
                                 (mp-file "photo" "p.png" +binary+ "image/png")
                                 (mp-empty-file "photo")))))
    (ok (equal '(:photo) (param-keys params)))
    (ok (part-p (getf params :photo)) "one real file among empty inputs: the entity, not a list")
    (ok (equal "p.png" (part-filename (getf params :photo)))))
  (ok (equal '(:photo "kept")
             (mp-params (list (mp-empty-file "photo")) :query "photo=kept"))
      "a dropped empty input does not hide a text value of that name")
  (setf *seen* nil)
  (let ((r (h:htmx-request-env (client) (mp-env (list (mp-text "title" "T")
                                                      (mp-empty-file "photo"))))))
    (ok (= 200 (h:htmx-reply-status r)))
    (ok (equal '(:title "T") (first *seen*)) "the handler sees no photo argument")))

(deftest multipart-several-files-one-name
  (let* ((params (mp-params (list (mp-file "pics" "a.png" +binary+ "image/png")
                                  (mp-text "title" "T")
                                  (mp-file "pics" "b.svg" +svg+ "image/svg+xml")
                                  (mp-file "pics" "c.bin" (bytes 0 1 2))
                                  (mp-file "one" "x.bin" (bytes 9)))))
         (pics (getf params :pics)))
    (ok (equal '(:pics :title :one) (param-keys params)) "first-occurrence key order")
    (ok (and (listp pics) (= 3 (length pics)) (every #'part-p pics))
        "several file parts under one name → a list of entities")
    (ok (equal '("a.png" "b.svg" "c.bin") (mapcar #'part-filename pics)) "in part order")
    (ok (equalp (list +binary+ (octets +svg+) (bytes 0 1 2)) (mapcar #'part-octets pics)))
    (ok (part-p (getf params :one)) "a single file is the entity itself, not a list")))

(deftest multipart-files-win-over-text
  (let ((params (mp-params (list (mp-text "photo" "y")
                                 (mp-file "photo" "p.png" +binary+ "image/png")
                                 (mp-text "photo" "z")
                                 (mp-text "keep" "2"))
                           :query "photo=x&keep=1")))
    (ok (equal '(:photo :keep) (param-keys params)) "key position from the first occurrence")
    (ok (part-p (getf params :photo))
        "a name with a file part keeps only its file parts (query and body text ignored)")
    (ok (equal "2" (getf params :keep)) "other names keep the 0.1 rule"))
  (let ((params (mp-params (list (mp-file "pics" "a.png" +binary+ "image/png")
                                 (mp-text "pics" "t")
                                 (mp-file "pics" "b.png" +binary+ "image/png")))))
    (ok (equal '("a.png" "b.png") (mapcar #'part-filename (getf params :pics))))))

(deftest multipart-refusals-unchanged
  (ok (signals (decode (mp-env (list (mp-text "t" (bytes #xC3 #x28)))))
               'h:htmx-bad-request)
      "invalid UTF-8 in a text part is still 400")
  (ok (signals (decode (mp-env (list (mp-part '("Content-Disposition: form-data; name=\"n\""
                                                "Content-Type: multipart/mixed; boundary=inner")
                                              (bytes "--inner" +crlf+ +crlf+ "x" +crlf+
                                                     "--inner--")))))
               'h:htmx-bad-request)
      "a nested multipart part is still 400")
  (ok (signals (decode (env :method :post :body (bytes "--XyZzY" +crlf+ "Content-Disposition: form-data; name=\"a\"; filename=\"a.bin\"" +crlf+ +crlf+ "no end")
                            :content-type "multipart/form-data; boundary=XyZzY"))
               'h:htmx-bad-request)
      "a truncated body is still 400"))

(deftest multipart-limit-unchanged
  (let* ((parts (list (mp-file "doc" "d.bin" (make-array 100 :element-type '(unsigned-byte 8)
                                                              :initial-element #xFF))))
         (size (length (apply #'mp-body parts))))
    (ok (part-p (getf (mp-params parts :codec (codec :max-body-bytes size)) :doc))
        "a body of exactly MAX-BODY-BYTES octets, file included, is read")
    (ok (equal (list (1- size) size)
               (handler-case (decode (mp-env parts) (codec :max-body-bytes (1- size)))
                 (h:htmx-body-too-large (c) (list (h:htmx-body-limit c) (h:htmx-body-size c)))))
        "one octet more → 413 before reading, :size the Content-Length")
    (ok (equal (list (1- size) nil)
               (handler-case (decode (mp-env parts :content-length nil)
                                     (codec :max-body-bytes (1- size)))
                 (h:htmx-body-too-large (c) (list (h:htmx-body-limit c) (h:htmx-body-size c)))))
        "without Content-Length: read limit+1 octets, then 413")
    (let ((r (h:htmx-request-env (client :transport (transport :max-body-bytes 64))
                                 (mp-env parts))))
      (ok (= 413 (h:htmx-reply-status r)))
      (ok (equal "#canvas-error" (hdr r "HX-Retarget")))
      (ok (contains "too large" (h:htmx-reply-body r))))))

;;; ---------------------------------------------------------------------------
;;; Encode: file values → raw binary parts
;;; ---------------------------------------------------------------------------

(defun env-body (env)
  "The octets of a POST env's :raw-body (consumes the stream)."
  (let ((buffer (make-array (getf env :content-length) :element-type '(unsigned-byte 8))))
    (read-sequence buffer (getf env :raw-body))
    buffer))

(defun env-boundary (env)
  (mime:media-type-boundary (mime:parse-media-type (getf env :content-type))))

(defun encode-post (params &rest keys)
  (apply #'rpc:encode-request-using-codec (codec) (m "CAPTURE") params
         :http-method :post :encoding :multipart keys))

(defun wire-text (b name value)
  (bytes "--" b +crlf+ "Content-Disposition: form-data; name=\"" name "\"" +crlf+ +crlf+
         value +crlf+))

(defun wire-file (b disposition type content)
  (bytes "--" b +crlf+ "Content-Disposition: " disposition +crlf+
         "Content-Type: " type +crlf+ +crlf+ content +crlf+))

(defun wire-end (b)
  (bytes "--" b "--" +crlf+))

(defun svg-file (&optional (filename "a.svg"))
  (list :filename filename :content (octets +svg+) :content-type "image/svg+xml"))

(defun png-file (&optional (filename "c.png") (content +binary+))
  (list :content content :filename filename :content-type "image/png"))

(deftest encode-multipart-file-wire
  (let* ((env (encode-post (list :title "Prélude" :score (svg-file) :note "n" :cover (png-file))))
         (b (env-boundary env))
         (body (env-body env)))
    (ok (stringp b))
    (ok (equal (s+ "multipart/form-data; boundary=" b) (getf env :content-type)))
    (ok (equal (getf env :content-type) (gethash "content-type" (getf env :headers))))
    (ok (= (length body) (getf env :content-length)))
    (ok (equal (princ-to-string (length body)) (gethash "content-length" (getf env :headers))))
    (ok (equalp (bytes (wire-text b "title" "Prélude")
                       (wire-text b "note" "n")
                       (wire-file b "form-data; name=\"score\"; filename=\"a.svg\""
                                  "image/svg+xml" (octets +svg+))
                       (wire-file b "form-data; name=\"cover\"; filename=\"c.png\""
                                  "image/png" +binary+)
                       (wire-end b))
                body)
        "text fields in params order, then files in params order; raw octets")
    (ok (null (search (octets "Content-Transfer-Encoding") body)) "no CTE header, no base64")))

(deftest encode-file-values
  (flet ((wire (params)
           (let* ((env (encode-post params))
                  (b (env-boundary env)))
             (values (env-body env) b))))
    (multiple-value-bind (body b) (wire (list :doc (list :filename "x.bin")))
      (ok (equalp (bytes (wire-file b "form-data; name=\"doc\"; filename=\"x.bin\""
                                    "application/octet-stream" "")
                         (wire-end b))
                  body)
          "no :content → empty; no :content-type → application/octet-stream"))
    (multiple-value-bind (body b) (wire (list :doc (list :filename "h.txt" :content "héllo"
                                                         :content-type "text/plain; charset=utf-8")))
      (ok (equalp (bytes (wire-file b "form-data; name=\"doc\"; filename=\"h.txt\""
                                    "text/plain; charset=utf-8" "héllo")
                         (wire-end b))
                  body)
          "string content as UTF-8; the content type as given"))
    (multiple-value-bind (body b) (wire (list :pics (list (png-file "a.png") (svg-file "b.svg"))
                                              :n 2))
      (ok (equalp (bytes (wire-text b "n" "2")
                         (wire-file b "form-data; name=\"pics\"; filename=\"a.png\""
                                    "image/png" +binary+)
                         (wire-file b "form-data; name=\"pics\"; filename=\"b.svg\""
                                    "image/svg+xml" (octets +svg+))
                         (wire-end b))
                  body)
          "a list of file values: consecutive parts under one name, in list order"))
    (multiple-value-bind (body b) (wire (list :photo (list :filename "")))
      (ok (equalp (bytes (wire-file b "form-data; name=\"photo\"; filename=\"\""
                                    "application/octet-stream" "")
                         (wire-end b))
                  body)
          ":filename \"\" sends an empty file input"))
    (multiple-value-bind (body b) (wire (list :score (svg-file "Prélude.svg")))
      (ok (equalp (bytes (wire-file b "form-data; name=\"score\"; filename=\"Prélude.svg\"; filename*=UTF-8''Pr%C3%A9lude.svg"
                                    "image/svg+xml" (octets +svg+))
                         (wire-end b))
                  body)
          "a non-ASCII filename: UTF-8 in filename, RFC 8187 filename* too (mime-protocol)"))
    (multiple-value-bind (body b) (wire (list :x (list :filename (format nil "a\"b~C~Cc.svg" #\Return #\Linefeed)
                                                       :content "x")))
      (ok (equalp (bytes (wire-file b "form-data; name=\"x\"; filename=\"a%22b%0D%0Ac.svg\""
                                    "application/octet-stream" "x")
                         (wire-end b))
                  body)
          "a quote or CR LF in a filename cannot forge parameters or headers"))
    (ok (equal '(:a "1")
               (h:htmx-message-params (decode (encode-post (list :a "1" :pics nil)))))
        "NIL is still dropped (an empty list is NIL)")))

(deftest encode-file-round-trip
  (let* ((params (h:htmx-message-params
                  (decode (encode-post (list :score (svg-file) :title "Zoë"
                                             :pics (list (png-file "a.png") (png-file "b.png" (bytes 7)))
                                             :photo (list :filename ""))))))
         (score (getf params :score)))
    (ok (equal '(:title :score :pics) (param-keys params))
        "fields first, then files; the empty file input comes back missing")
    (ok (equal "Zoë" (getf params :title)))
    (ok (part-p score))
    (ok (equal '("a.svg" "image/svg+xml") (list (part-filename score) (part-type score))))
    (ok (equalp (octets +svg+) (part-octets score)))
    (ok (equal '("a.png" "b.png") (mapcar #'part-filename (getf params :pics))))
    (ok (equalp (list +binary+ (bytes 7)) (mapcar #'part-octets (getf params :pics))))))

(deftest encode-file-refusals
  (flet ((refused (params &rest keys)
           (handler-case (progn (apply #'rpc:encode-request-using-codec (codec) (m "CAPTURE")
                                       params keys)
                                nil)
             (h:htmx-error () t))))
    (ok (refused (list :doc (svg-file))) "GET cannot carry a file")
    (ok (refused (list :doc (svg-file)) :http-method :post) ":urlencoded cannot carry a file")
    (ok (handler-case (progn (rpc:encode-notification-using-codec (codec) (m "CAPTURE")
                                                                  (list :doc (svg-file)))
                             nil)
          (h:htmx-error () t))
        "a notification defaults to :urlencoded")
    (dolist (bad (list (list :content (octets "x"))           ; no filename
                       (list :filename 3)
                       (list :filename "a" :content 3)
                       (list :filename "a" :content (vector 1 2)) ; not (unsigned-byte 8)
                       (list :filename "a" :content-type 5)
                       (list :filename "a" :content-type "not a media type")
                       (list :filename "a" :content-type (format nil "text/plain~C~CX-Evil: 1"
                                                                 #\Return #\Linefeed))
                       (list :filename "a" :content-type "multipart/mixed; boundary=q")
                       (list :filename "a" :size 3)                ; unknown key
                       (list :filename "a" :filename "b")          ; repeated key
                       (list :filename)                            ; odd
                       (list* :filename "a" "b")                   ; improper
                       (list "a" "b")                              ; a list of strings
                       (list (svg-file) "b")))                     ; a file and a string
      (ok (refused (list :doc bad) :http-method :post :encoding :multipart)
          (format nil "~S" bad)))))

;;; htmx-client: file params end to end through the core app

(deftest client-posts-files
  (setf *seen* nil)
  (let* ((r (h:htmx-request (client) (m "CAPTURE")
                            (list :title "T" :doc (png-file "d.png")
                                  :pics (list (svg-file "1.svg") (svg-file "2.svg")))
                            :http-method :post :encoding :multipart :target "out"))
         (seen (first *seen*)))
    (ok (= 200 (h:htmx-reply-status r)))
    (ok (equal '(:title :doc :pics) (param-keys seen)))
    (ok (equal "T" (getf seen :title)))
    (ok (part-p (getf seen :doc)))
    (ok (equal '("d.png" "image/png") (list (part-filename (getf seen :doc))
                                            (part-type (getf seen :doc)))))
    (ok (equalp +binary+ (part-octets (getf seen :doc))) "raw binary, intact")
    (ok (equal '("1.svg" "2.svg") (mapcar #'part-filename (getf seen :pics))))
    (ok (equal '(:request t :target "out") (second *seen*)) "metadata as for any request"))
  (ok (signals (h:htmx-request (client) (m "CAPTURE") (list :doc (svg-file))) 'h:htmx-error)
      "a GET with a file is refused before the app is called")
  (ok (signals (rpc:rpc-call (m "CAPTURE") (list :doc (svg-file)) :transport (client))
               'h:htmx-error)))
