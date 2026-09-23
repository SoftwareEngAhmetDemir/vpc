import express from "express";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const dist = path.join(path.dirname(fileURLToPath(import.meta.url)), "dist");
const PORT = process.env.PORT || 3000;
const BACKEND_URL = process.env.BACKEND_URL || "http://localhost:3001";

const app = express();

app.use("/api", (_req, res) => res.status(404).json({ error: "Not found" }));
app.use(express.static(dist, { index: false }));

app.get("*", async (_req, res) => {
  let state;
  try {
    const r = await fetch(`${BACKEND_URL}/api/items`);
    if (!r.ok) throw new Error(`Backend responded ${r.status}`);
    state = { items: await r.json() };
  } catch (err) {
    console.error("Failed to load items:", err);
    state = { error: "Failed to load items" };
  }
  const html = await readFile(path.join(dist, "index.html"), "utf8");
  const json = JSON.stringify(state).replace(/</g, "\\u003c");
  res
    .type("html")
    .send(html.replace("</head>", `<script>window.__INITIAL_STATE__=${json}</script></head>`));
});

app.listen(PORT, () => console.log(`Frontend server listening on ${PORT}`));
