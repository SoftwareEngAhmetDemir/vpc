import { useEffect, useState } from "react";
import "./App.css";

// In production the frontend server injects the data into the page, so the browser never calls the API.
// In dev (no injected state) the app fetches the backend directly.
const initial = window.__INITIAL_STATE__;
const API_URL = import.meta.env.VITE_API_URL ?? "http://localhost:3001";

function App() {
  const [items, setItems] = useState(initial?.items ?? []);
  const [error, setError] = useState(initial?.error ?? null);
  const [loading, setLoading] = useState(!initial);

  useEffect(() => {
    if (initial) return;
    fetch(`${API_URL}/api/items`)
      .then((res) => {
        if (!res.ok) throw new Error(`Request failed: ${res.status}`);
        return res.json();
      })
      .then((data) => setItems(data))
      .catch((err) => setError(err.message))
      .finally(() => setLoading(false));
  }, []);

  return (
    <div className="app">
      <h1>Hello World</h1>
      <p>React frontend &rarr; Express API &rarr; PostgreSQL (RDS)</p>

      {loading && <p>Loading items...</p>}
      {error && <p className="error">Error: {error}</p>}

      {!loading && !error && (
        <ul className="items">
          {items.map((item) => (
            <li key={item.id}>
              <strong>{item.name}</strong> - {item.description}
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

export default App;
