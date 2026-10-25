-- One row per install per UTC day. The primary key is the rate limit: a
-- second ping the same day adds to the row instead of making a new install.
-- No IP, no user, no server, no song: nothing here identifies anyone.
CREATE TABLE IF NOT EXISTS pings (
  day TEXT NOT NULL,
  install_id TEXT NOT NULL,
  version TEXT NOT NULL,
  edition TEXT NOT NULL,
  device TEXT NOT NULL,
  songs INTEGER NOT NULL,
  PRIMARY KEY (day, install_id)
);
