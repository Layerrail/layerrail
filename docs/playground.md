# AI playground

The playground uses [Thinking Orbs](https://libraries.dev/orbs),
[Border Beam](https://libraries.dev/beam), and [Metal](https://libraries.dev/metal).
Waiting requests show a working orb; provider reasoning events use the solving
orb; incoming answer text uses the composing orb. Reasoning text and leading
`<think>` blocks are excluded from the displayed answer and conversation history.

The composer beam follows focus and request activity. The send control has a
subtle metal ring. These effects are decorative React islands around the existing
form, so canvas or WebGL failures do not remove controls or responses. Reduced
motion preferences use static orbs and CSS controls. Hidden tabs pause animations.
Status announcements remain available to screen readers.

## Build and verify

```sh
npm ci
npm run prod
npm run test:playground
```

`npm run dev` builds without minification. `npm run watch` watches both Tailwind
styles and the playground JavaScript. The generated `assets/js/playground.js`
bundle is ignored by Git and is loaded only on the playground route through Roda's
timestamped asset URLs. Production deployment already calls `npm run prod` through
`rake assets:precompile`. CI builds the bundle before Ruby view tests and runs the
frontend tests.

The controller lives in `assets/js/playground/controller.js`; effects live in
`index.jsx`; response and SSE parsing live in `response.js`. Model routing,
authentication, pricing, and inference requests continue using the existing APIs,
including the Azure Responses path for GPT-6 Astra.

The libraries generate element-specific styles, so inline styles are allowed
only on the playground route. Scripts still use the existing same-origin/CDN
policy. The route also allows data images and audio for generated media. The
libraries are MIT licensed; their licenses are distributed with the npm packages.

Tests exercise waiting, reasoning, streaming, completion, errors, Stop, and
New chat isolation, plus Azure usage, native audio, embeddings, rerank, keyboard
submission, PDF selection, sanitized content, and fragmented SSE responses.
These tests use local fixtures and do not call paid inference endpoints.
