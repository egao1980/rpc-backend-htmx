# rpc-backend-htmx

htmx requests as rpc-protocol calls (slice H4h-1b): hx-get / hx-post → `:call-response`, HX-Trigger with no swap → `:notify`, the htmx SSE extension → `:call-stream` (one HTML fragment per SSE event). A canvas function is a method named `<PACKAGE>::<NAME>` in the path; the handler table is the allowlist.

- `rpc-backend-htmx` — `htmx-codec` (Clack env ↔ message, fragment ↔ response, `HX-*` headers as metadata, bounded request bodies), `htmx-transport` / `htmx-app` (Clack app via `backend-rpc-serve` / `backend-rpc-serve-stream` on http-server-protocol), `htmx-client` (in-process browser stand-in, also an rpc-protocol transport), `jsonrpc-handler` (the same handlers over JSON-RPC).
- `rpc-backend-htmx/canvas` — canvas-protocol's resolver GF (`htmx-resolver`), canvas `render`, full `page` for plain GETs (optionally loading `canvas-keys.js`), the asset route.

Uploads (0.2.0): a multipart part with a filename reaches the handler as its mime-protocol entity (several under one name: a list), ready for canvas-protocol's `coerce-param :file`; an empty file input is a missing param. `htmx-request … :http-method :post :encoding :multipart` sends file values `(:filename "a.svg" :content octets :content-type "image/svg+xml")` as raw binary parts. JSON-RPC carries no file params.

0.2.1 requires mime-protocol 0.3.1: a part's `name` and `filename` reach the handler as a browser writes them, raw UTF-8 (`Ünïcödé — 楽譜.svg`), a backslash kept, `%22 %0D %0A` read as `"` CR LF (mime-protocol#14).

0.3.0 (contract on this branch; a team-solve run implements it):

- Request keys (#2): names map to keywords with `find-symbol`, never `intern`, so a client cannot grow the KEYWORD package. Each handler accepts its key set, from its lambda list or a declared `:params` (`(people :params (:sort :page))`, `:params t` for any); a param it does not take is a 400 (`htmx-unknown-param`). At most `:max-params` fields per request (default 1000; 413).
- Zero-arg canvases (#3): `(defun dashboard () …)` is called with no arguments; params sent to it are a 400. A lambda list the server cannot call (a required or `&optional` parameter) is an `htmx-error` when the table is built.
- CSP and token gate (#4): `:csp` on `make-htmx-transport`, `make-canvas-htmx-transport` and `htmx-app` adds `Content-Security-Policy` to every response, streams and assets included (the canvas transport sends the brief's policy by default; the core is opt-in). `:token` gates the app: `htmx-token-url` gives a one-time URL whose single-use bootstrap token is exchanged for a separate, freshly generated session secret (secrets-protocol CSPRNG) in an HttpOnly, SameSite=Strict cookie; a used token, or any request without that cookie, is a 403. A secrets backend must be loaded (e.g. crypto-backend-ironclad).

Design: [cl-stack/docs/capabilities/canvas.md](https://github.com/egao1980/cl-stack/blob/main/docs/capabilities/canvas.md) § H4h-1b and H4h-2. 0.2.0 implements #5 (uploads) and #6 (page keys, `make-canvas-htmx-transport :page-keys`); 0.3.0 #2, #3 and #4. The exact rules are the file headers in `src/`.

```sh
cl-repo test --system rpc-backend-htmx
```

## License

MIT — see [LICENSE](LICENSE).
