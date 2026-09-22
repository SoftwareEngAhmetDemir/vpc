CREATE TABLE IF NOT EXISTS items (
  id SERIAL PRIMARY KEY,
  name TEXT NOT NULL,
  description TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

INSERT INTO items (name, description) VALUES
  ('Hello', 'First item from RDS PostgreSQL'),
  ('World', 'Second item from RDS PostgreSQL'),
  ('VPC Demo', 'Frontend in public subnet, backend + DB in private subnet');
