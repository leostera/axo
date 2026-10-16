# Axo app deployment

This site contains the HTML document, thin application entrypoint, Vite/Cloudflare configuration, and deployment-specific generated types. React UI, browser API/relay logic, and browser acceptance tests live in [`@axo/web-app`](../../packages/axo-web-app/README.md).

`cf build` builds without deploying. Authentication and production Cloudflare resources are unchanged by the package extraction.
