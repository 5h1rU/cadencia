import { foldkit } from "@foldkit/vite-plugin";
import { defineConfig } from "vite";

export default defineConfig({
  plugins: [foldkit()],
  build: {
    rolldownOptions: {
      output: {
        // The libraries change far less often than the app: in their own file, a deploy that only
        // changes the app leaves them in the browser's cache.
        codeSplitting: { groups: [{ name: "vendor", test: /node_modules/ }] },
      },
    },
  },
  optimizeDeps: {
    entries: ["src/entry.ts"],
    // The foldkit plugin excludes foldkit from pre-bundling, so its bare imports
    // of the Effect barrels are never discovered. Pre-bundle them, or dev serves
    // a second copy of Effect next to the app's.
    include: ["effect", "effect/Function", "effect/http", "@effect/platform-browser"],
  },
});
