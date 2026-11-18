// Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
import { mkdir, readFile, copyFile } from "node:fs/promises";
const root = new URL("../", import.meta.url);
const engine = await readFile(
  new URL("Web/local-app/engine.mjs", root),
  "utf8",
);
if (
  engine !==
  (await readFile(
    new URL("Server/functions/_lib/endgame-engine.mjs", root),
    "utf8",
  ))
)
  throw Error(
    "Client/server engine drift: update the server copy and run tests.",
  );
await mkdir(new URL("build/web/", root), { recursive: true });
for (const name of [
  "index.html",
  "app.mjs",
  "engine.mjs",
  "style.css",
  "sw.js",
  "manifest.webmanifest",
  "icon.svg",
  "privacy.html",
])
  await copyFile(
    new URL("Web/local-app/" + name, root),
    new URL("build/web/" + name, root),
  );
console.log(
  "Web artifact ready: build/web (8 public assets; tests and development files excluded).",
);
