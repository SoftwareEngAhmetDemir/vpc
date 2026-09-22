import "dotenv/config";
import express from "express";
import cors from "cors";
import { pool } from "./db.js";

const app = express();
const PORT = process.env.PORT || 3001;

app.use(cors());
app.use(express.json());

app.get("/api/health", (_req, res) => {
  res.json({ status: "ok" });
});

app.get("/api/items", async (_req, res) => {
  try {
    const result = await pool.query(
      "SELECT id, name, description, created_at FROM items ORDER BY id"
    );
    res.json(result.rows);
  } catch (err) {
    console.error("Failed to fetch items:", err);
    res.status(500).json({ error: "Failed to fetch items" });
  }
});

app.listen(PORT, () => {
  console.log(`Backend listening on port ${PORT}`);
});
