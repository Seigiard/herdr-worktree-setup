# Valibot decoder

- Source: https://github.com/fabian-hiller/valibot, npm `valibot@1.5.0`.
- `package-lock.json` pins the published tarball URL and SHA-512 integrity.
- `index.js` is a tree-shaken ESM bundle of the exports in `tools/valibot-entry.ts`.
- Regenerate with `npm ci && npm run vendor:decoder` using Bun 1.4.2.
- The upstream implementation is unchanged. Bun removes unused exports and minifies the bundle.
- `LICENSE` is the unchanged upstream MIT license.
- `index.d.ts` re-exports the same upstream types for development. The exact development dependency supplies those declarations; the runtime bundle needs no npm installation.
- Release archives include `index.js`, `LICENSE`, and this provenance file.
