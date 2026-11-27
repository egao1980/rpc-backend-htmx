(defsystem "rpc-backend-htmx"
  :version "0.5.0"
  :description "htmx as an rpc-protocol transport + codec: Clack server, SSE streams, multipart uploads, CSP and token gate, visitor sessions, request context, test client (H4h-1b)"
  :author "egao1980"
  :license "MIT"
  :depends-on ((:version "rpc-protocol" "0.2.0")
               (:version "http-server-protocol" "0.1.0")
               (:version "http-protocol" "0.4.1")
               (:version "sse-protocol" "0.1.1")
               (:version "sse-backend-clack" "0.1.1")
               (:version "html-protocol" "0.1.1")
               (:version "mime-protocol" "0.3.1")
               (:version "encoding-protocol" "0.2.0")
               (:version "secrets-protocol" "0.1.3")
               ;; 0.5.0 (#19, #15): sessions through S0b's SESSION-HANDLER,
               ;; the trusted-proxy networks, the test client's cookie jar.
               (:version "session-protocol" "0.2.0")
               (:version "session-protocol/middleware" "0.2.0")
               (:version "middleware-protocol" "0.1.0")
               (:version "middleware-protocol/clack" "0.1.0")
               (:version "cache-protocol" "0.2.0")
               (:version "ip-protocol" "0.1.0")
               (:version "cl-cookie" "0.2.0")
               "quri"
               "bordeaux-threads")
  :serial t
  :pathname "src"
  :components ((:file "package")
               (:file "conditions")
               (:file "handlers")
               (:file "codec")
               (:file "server")
               (:file "session")
               (:file "client"))
  :in-order-to ((test-op (test-op "rpc-backend-htmx/tests"))))

(defsystem "rpc-backend-htmx/canvas"
  :version "0.5.0"
  :description "canvas-protocol resolver + page/asset routes for rpc-backend-htmx (H4h-1b)"
  :author "egao1980"
  :license "MIT"
  :depends-on ("rpc-backend-htmx"
               (:version "canvas-protocol" "0.3.0"))
  :pathname "src/canvas"
  :serial t
  :components ((:file "package")
               (:file "canvas")))

(defsystem "rpc-backend-htmx/tests"
  :version "0.5.0"
  :depends-on ("rpc-backend-htmx"
               "rpc-backend-htmx/canvas"
               (:version "canvas-protocol" "0.3.0")
               (:version "rpc-protocol-json" "0.1.1")
               (:version "json-protocol" "0.2.4")
               (:version "json-backend-jzon" "0.2.4")
               (:version "rpc-backend-http" "0.1.2")
               (:version "html-backend-plump" "0.1.1")
               (:version "crypto-backend-ironclad" "0.2.2")
               (:version "rove" "0.11.1"))
  :pathname "tests"
  :serial t
  :components ((:file "package")
               (:file "support")
               (:file "handlers-test")
               (:file "codec-test")
               (:file "server-test")
               (:file "errors-test")
               (:file "stream-test")
               (:file "escape-test")
               (:file "limit-test")
               (:file "client-test")
               (:file "parity-test")
               (:file "canvas-test")
               (:file "multipart-test")
               (:file "upload-test")
               (:file "page-keys-test")
               (:file "keys-test")
               (:file "arity-test")
               (:file "csp-test")
               (:file "token-test")
               (:file "page-scripts-test")
               ;; 0.5.0 (S1: #19 sessions, #15 request context)
               (:file "s1-support")
               (:file "context-test")
               (:file "jar-test")
               (:file "session-test")
               (:file "session-gate-test")
               (:file "session-stream-test")
               (:file "cross-origin-test"))
  :perform (test-op (o c)
             (unless (symbol-call :rove :run c)
               (error "tests failed for ~A" (component-name c)))))
