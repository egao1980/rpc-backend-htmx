# rpc-backend-htmx

htmx requests as rpc-protocol calls (slice H4h-1b): hx-get / hx-post → `:call-response`, HX-Trigger with no swap → `:notify`, the htmx SSE extension → `:call-stream` (one HTML fragment per SSE event). A canvas function is a method named `<PACKAGE>::<NAME>` in the path; the handler table is the allowlist.

- `rpc-backend-htmx` — `htmx-codec` (Clack env ↔ message, fragment ↔ response, `HX-*` headers as metadata, bounded request bodies), `htmx-transport` / `htmx-app` (Clack app via `backend-rpc-serve` / `backend-rpc-serve-stream` on http-server-protocol), `htmx-client` (in-process browser stand-in, also an rpc-protocol transport), `jsonrpc-handler` (the same handlers over JSON-RPC).
- `rpc-backend-htmx/canvas` — canvas-protocol's resolver GF (`htmx-resolver`), canvas `render`, full `page` for plain GETs (optionally loading `canvas-keys.js`), the asset route.

Uploads (0.2.0): a multipart part with a filename reaches the handler as its mime-protocol entity (several under one name: a list), ready for canvas-protocol's `coerce-param :file`; an empty file input is a missing param. `htmx-request … :http-method :post :encoding :multipart` sends file values `(:filename "a.svg" :content octets :content-type "image/svg+xml")` as raw binary parts. JSON-RPC carries no file params.

Design: [cl-stack/docs/capabilities/canvas.md](https://github.com/egao1980/cl-stack/blob/main/docs/capabilities/canvas.md) § H4h-1b. 0.2.0 (#5 uploads, #6 page keys) lands through team-solve: this branch holds the contract (API, file-header rules, `%htmx2-pending` stubs, Rove suite).

```sh
cl-repo test --system rpc-backend-htmx
```

## License

MIT — see [LICENSE](LICENSE).
