CREATE TABLE app.todos (
  id bigserial PRIMARY KEY,
  title text NOT NULL,
  created_by text NOT NULL DEFAULT current_user,
  created_at timestamptz NOT NULL DEFAULT now()
);

GRANT SELECT, INSERT, UPDATE, DELETE ON app.todos TO app_user;
GRANT USAGE, SELECT, UPDATE ON SEQUENCE app.todos_id_seq TO app_user;

