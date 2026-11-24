(in-package #:rpc-backend-htmx/tests)

;;; 0.2.0 (rpc-backend-htmx#5): uploads end to end through rpc-backend-htmx/canvas.
;;; A canvas form holds FILE-INPUTs; htmx-client posts files to it the way
;;; htmx 2 sends such a form (multipart FormData); the handler's
;;; COERCE-PARAM :file turns the codec's mime-protocol parts into
;;; UPLOADED-FILEs. canvas-protocol 0.2.0 owns the coercion rules
;;; (its src/forms.lisp); this file checks the transport carries them.

(defvar *uploaded* nil "The UPLOADED-FILEs the last upload handler coerced.")

(defun describe-upload (file)
  (if file
      (format nil "~A ~A ~D" (canvas:uploaded-file-filename file)
              (canvas:uploaded-file-media-type file) (canvas:uploaded-file-size file))
      "none"))

(defun upload-form (&key)
  (canvas:form (list (canvas:text-input "title" :label "Title")
                     (canvas:file-input "score" :label "Score" :accept '(".svg" "image/svg+xml")
                                                :required t)
                     (canvas:file-input "cover" :label "Cover" :accept "image/*")
                     (canvas:submit-button "Upload"))
               :link (canvas:canvas-link 'upload-score)
               :id "upload"))

(defun upload-score (&key title score cover)
  (let ((score (canvas:coerce-param score :file :field "score" :required t
                                                :accept '(".svg" "image/svg+xml")
                                                :max-size 4096))
        (cover (canvas:coerce-param cover :file :field "cover" :accept "image/*"
                                                :max-size 64)))
    (setf *uploaded* (list score cover))
    (canvas:el :p nil (format nil "~A: ~A; ~A" title (describe-upload score)
                              (describe-upload cover)))))

(defun upload-pics (&key pics)
  (let ((files (canvas:coerce-param pics :file :field "pics" :multiple t :accept "image/*")))
    (setf *uploaded* files)
    (canvas:el :p nil (if files
                          (format nil "~{~A~^, ~}" (mapcar #'describe-upload files))
                          "no pictures"))))

(defun upload-handlers ()
  (h:make-htmx-handlers 'upload-form 'upload-score 'upload-pics))

(defun upload-client (&optional (tx (canvas-transport)))
  (h:make-htmx-client (h:htmx-app tx (upload-handlers)) :codec (h:htmx-transport-codec tx)))

(defun post-files (method params &optional (client (upload-client)))
  (h:htmx-request client method params :http-method :post :encoding :multipart))

(defparameter +upload-url+ "/canvas/RPC-BACKEND-HTMX%2FTESTS::UPLOAD-SCORE")

(defparameter +big-binary+
  (let ((v (make-array 100 :element-type '(unsigned-byte 8))))
    (dotimes (i 100 v) (setf (aref v i) (mod (* i 37) 256))))
  "100 octets, every value class: over the cover's :max-size 64.")

(deftest upload-form-posts-multipart
  ;; Given by canvas-protocol 0.2.0 and the 0.1 resolver: the form the client
  ;; posts to below.
  (let ((body (h:htmx-reply-body (h:htmx-request (upload-client) (m "UPLOAD-FORM") nil))))
    (ok (contains (s+ "<form id=\"upload\" hx-post=\"" +upload-url+ "\"") body))
    (ok (contains "enctype=\"multipart/form-data\"" body))
    (ok (contains "<input type=\"file\" name=\"score\" accept=\".svg,image/svg+xml\" required=\"\">"
                  body))
    (ok (contains "<input type=\"file\" name=\"cover\" accept=\"image/*\">" body))))

(deftest upload-svg-and-binary
  (setf *uploaded* nil)
  (let ((r (post-files (m "UPLOAD-SCORE")
                       (list :title "Prelude"
                             :score (list :filename "Prelude in C.svg" :content (octets +svg+)
                                          :content-type "image/svg+xml")
                             :cover (list :filename "cover.PNG" :content +binary+
                                          :content-type "image/png")))))
    (ok (= 200 (h:htmx-reply-status r)))
    (ok (equal (format nil "<p>Prelude: Prelude in C.svg image/svg+xml ~D; cover.PNG image/png ~D</p>"
                       (length (octets +svg+)) (length +binary+))
               (h:htmx-reply-body r)))
    (destructuring-bind (score cover) *uploaded*
      (ok (canvas:uploaded-file-p score))
      (ok (equal "Prelude in C.svg" (canvas:uploaded-file-filename score)))
      (ok (equal "image/svg+xml" (canvas:uploaded-file-media-type score)))
      (ok (= (length (octets +svg+)) (canvas:uploaded-file-size score)))
      (ok (equalp (octets +svg+) (canvas:uploaded-file-octets score)))
      (ok (equal "cover.PNG" (canvas:uploaded-file-filename cover)))
      (ok (equal "image/png" (canvas:uploaded-file-media-type cover)))
      (ok (= (length +binary+) (canvas:uploaded-file-size cover)))
      (ok (equalp +binary+ (canvas:uploaded-file-octets cover)) "binary octets intact")
      (ok (null (canvas:uploaded-file-path cover)) "nothing spooled to disk"))))

(deftest upload-over-max-size-is-422
  (let ((r (post-files (m "UPLOAD-SCORE")
                       (list :score (list :filename "s.svg" :content (octets +svg+)
                                          :content-type "image/svg+xml")
                             :cover (list :filename "big.png" :content +big-binary+
                                          :content-type "image/png")))))
    (ok (= 422 (h:htmx-reply-status r)) "CANVAS-UPLOAD-TOO-LARGE is a CANVAS-COERCION-ERROR")
    (ok (equal "#canvas-error" (hdr r "HX-Retarget")))
    (ok (equal "innerHTML" (hdr r "HX-Reswap")))
    (ok (equal "<p role=\"alert\">cover must be at most 64 bytes</p>" (h:htmx-reply-body r))))
  (let ((r (post-files (m "UPLOAD-SCORE")
                       (list :score (list :filename "s.png" :content +binary+
                                          :content-type "image/png")))))
    (ok (= 422 (h:htmx-reply-status r)))
    (ok (equal "<p role=\"alert\">score must be a file of type: .svg, image/svg+xml</p>"
               (h:htmx-reply-body r)))))

(deftest upload-empty-file-input
  (let ((r (post-files (m "UPLOAD-SCORE")
                       (list :title "T"
                             :score (list :filename "s.svg" :content (octets +svg+)
                                          :content-type "image/svg+xml")
                             :cover (list :filename "")))))
    (ok (= 200 (h:htmx-reply-status r)))
    (ok (contains "; none</p>" (h:htmx-reply-body r)) "an empty optional input → its default"))
  (let ((r (post-files (m "UPLOAD-SCORE") (list :title "T" :score (list :filename "")))))
    (ok (= 422 (h:htmx-reply-status r)))
    (ok (equal "<p role=\"alert\">score is required</p>" (h:htmx-reply-body r))))
  ;; The bytes a browser sends for the same form (empty content, CR LF, then
  ;; the next delimiter): the mime-protocol#9 case.
  (let ((r (h:htmx-request-env
            (upload-client)
            (mp-env (list (mp-text "title" "T")
                          (mp-file "score" "s.svg" +svg+ "image/svg+xml")
                          (mp-empty-file "cover"))
                    :path (s+ "/canvas/" (m "UPLOAD-SCORE"))))))
    (ok (= 200 (h:htmx-reply-status r)))
    (ok (equal (format nil "<p>T: s.svg image/svg+xml ~D; none</p>" (length (octets +svg+)))
               (h:htmx-reply-body r)))))

(deftest upload-browser-filenames
  ;; 0.2.1 (mime-protocol#14): the octets a browser sends for the upload form,
  ;; a raw UTF-8 filename and a Windows path, read by COERCE-PARAM :file
  ;; behind the canvas route.
  (setf *uploaded* nil)
  (let ((r (h:htmx-request-env
            (upload-client)
            (mp-env (list (mp-text "title" "Étude")
                          (mp-file "score" +utf8-filename+ +svg+ "image/svg+xml")
                          (mp-file "cover" "C:\\fakepath\\cöver.png" (bytes 1 2 3) "image/png"))
                    :path (s+ "/canvas/" (m "UPLOAD-SCORE"))))))
    (ok (= 200 (h:htmx-reply-status r)))
    (ok (equal (format nil "<p>Étude: ~A image/svg+xml ~D; cöver.png image/png 3</p>"
                       +utf8-filename+ (length (octets +svg+)))
               (h:htmx-reply-body r)))
    (destructuring-bind (score cover) *uploaded*
      (ok (equal +utf8-filename+ (canvas:uploaded-file-filename score)))
      (ok (equal "image/svg+xml" (canvas:uploaded-file-media-type score)))
      (ok (equalp (octets +svg+) (canvas:uploaded-file-octets score)))
      (ok (equal "cöver.png" (canvas:uploaded-file-filename cover))
          "the backslash is kept, so canvas-protocol takes the last path segment")
      (ok (equalp (bytes 1 2 3) (canvas:uploaded-file-octets cover)))))
  ;; htmx-client sends the same name (filename plus filename*).
  (setf *uploaded* nil)
  (let ((r (post-files (m "UPLOAD-SCORE")
                       (list :score (list :filename +utf8-filename+ :content (octets +svg+)
                                          :content-type "image/svg+xml")))))
    (ok (= 200 (h:htmx-reply-status r)))
    (ok (equal +utf8-filename+ (canvas:uploaded-file-filename (first *uploaded*))))))

(deftest upload-multiple-files
  (setf *uploaded* nil)
  (let ((r (post-files (m "UPLOAD-PICS")
                       (list :pics (list (list :filename "a.png" :content +binary+
                                               :content-type "image/png")
                                         (list :filename "b.svg" :content (octets +svg+)
                                               :content-type "image/svg+xml"))))))
    (ok (= 200 (h:htmx-reply-status r)))
    (ok (equal (format nil "<p>a.png image/png ~D, b.svg image/svg+xml ~D</p>"
                       (length +binary+) (length (octets +svg+)))
               (h:htmx-reply-body r))
        "a list of entities, coerced in part order")
    (ok (equalp (list +binary+ (octets +svg+)) (mapcar #'canvas:uploaded-file-octets *uploaded*))))
  (ok (equal "<p>no pictures</p>"
             (h:htmx-reply-body (post-files (m "UPLOAD-PICS") (list :pics (list :filename ""))))))
  (let ((r (post-files (m "UPLOAD-PICS")
                       (list :pics (list (list :filename "a.png" :content +binary+
                                               :content-type "image/png")
                                         (list :filename "n.txt" :content "x"
                                               :content-type "text/plain"))))))
    (ok (= 422 (h:htmx-reply-status r)))
    (ok (equal "<p role=\"alert\">pics must be a file of type: image/*</p>" (h:htmx-reply-body r)))))

(deftest upload-text-for-a-file-is-422
  ;; A text part under a file field (e.g. a hand-made request) stays a string,
  ;; and COERCE-PARAM :file refuses it.
  (let ((r (h:htmx-request (upload-client) (m "UPLOAD-SCORE") '(:score "<svg/>")
                           :http-method :post :encoding :multipart)))
    (ok (= 422 (h:htmx-reply-status r)))
    (ok (equal "<p role=\"alert\">score must be a file</p>" (h:htmx-reply-body r)))))

;;; JSON-RPC: file params have no JSON-RPC form (src/server.lisp header).

(defparameter +no-files-message+
  "Param doc must be a string or an integer; JSON-RPC carries no file params")

(deftest jsonrpc-refuses-file-params
  (flet ((err (params)
           (let ((e (gethash "error" (jsonrpc (m "CAPTURE") params))))
             (list (gethash "code" e) (gethash "message" e)))))
    (ok (equal (list -32602 +no-files-message+)
               (err (json-object "doc" (json-object "filename" "a.svg"
                                                    "content" "PHN2Zy8+"
                                                    "content-type" "image/svg+xml"))))
        "a file-shaped object")
    (ok (equal (list -32602 +no-files-message+) (err (json-object "doc" (vector 1 2))))
        "an array")
    (ok (equal (list -32602 +no-files-message+) (err (json-object "doc" 1.5)))
        "any other non-string"))
  (ok (equal +no-files-message+
             (handler-case (funcall (h:jsonrpc-handler (transport) (handlers)) (m "CAPTURE")
                                    (json-object "doc" (json-object "filename" "a.svg")))
               (rpc:rpc-invalid-params (c) (rpc:rpc-error-message c))))
      "JSONRPC-HANDLER itself signals RPC-INVALID-PARAMS"))
