# Robin demo

A small app to play with Robin: sample jobs, seed data and the dashboard,
running the code in this checkout.

```sh
cd demo
bundle install
bin/seed   # create the sample data (deletes the old first)
bin/dev    # server + dashboard + a trickle of new jobs; Ctrl-C stops them
```

Then open <http://localhost:9292/>.

## Redis

The demo uses `REDIS_URL` (default `redis://127.0.0.1:6379/0`). Every key
it writes starts with `robin-demo:`, and resetting deletes only those, so
it can share a Redis (or a database) with other things. To keep it apart
entirely, point it at a database of its own:

```sh
export REDIS_URL=redis://127.0.0.1:6379/9
```

## Scripts

| Script | What it does |
|---|---|
| `bin/seed` | Deletes the demo's data and creates it afresh (about 7 seconds). Stop the demo first. |
| `bin/reset` | Deletes the demo's data and nothing else. |
| `bin/dev` | Runs `bin/work`, `bin/web` and `bin/load` together. Arguments go to `bin/work`. |
| `bin/work` | A Robin server (`robin -r ./app.rb -C config/robin.yml`). Try `bin/work -c 20` or `bin/work swarm -n 2`. |
| `bin/web` | The dashboard on port 9292 (`PORT` to change it). |
| `bin/load` | Pushes a mix of new jobs, about `RATE` per second (default 5). |

`DEMO_SPEED=0.2 bin/work` makes the jobs' pretend work five times
faster; `LOG_LEVEL=warn` quiets the job log.

## What the seed data shows

`bin/seed` first runs a wave of jobs for real, so there's history, then
leaves a backlog for `bin/work`:

- **Dashboard and metrics:** a few hundred processed and failed jobs, and
  two deploy markers (an hour ago and now).
- **Retries:** `FlakyWebhook` fails about a third of the time, with a few
  different errors; retries come back within seconds (the demo shortens
  the backoff). `SyncCrm` always fails and dies after one retry.
- **Dead:** `ImportLegacyCsv` jobs (`retry: 0`).
- **Batches:** a finished import that succeeded, one that completed with a
  failed row (row 97), and a 500-row import still in progress. Their
  callbacks log, and a successful import sends a `WelcomeEmail`.
- **Queues:** about 900 jobs waiting, weighted (see `config/robin.yml`),
  with `low` paused: unpause it on the Queues page.
- **Scheduled:** welcome emails over the next hour, flash sales that expire
  if they haven't started within 20 seconds of being due, and a digest
  tomorrow.
- **Busy:** `ResizeImage` and `ExportOrders` report progress while they
  run; `ExportOrders` is iterable, so stop the server mid-export and it
  resumes where it left off. One `ResizeImage` was cancelled before it
  ran and is skipped.
- **Limiters:** `ChargeCard` (at most 2 at once; its arguments are
  encrypted) and `GeocodeAddress` (5 a second; jobs over the limit are
  rescheduled).
- **Unique and debounced:** `RebuildSearchIndex` drops duplicates for two
  minutes; `SyncContact` runs once, 10 seconds after the last push.
- **Cron:** a digest every minute and a report every 5 minutes, once a
  server is running.
- **Capsules:** `PostLedgerEntry` jobs run one at a time on the `serial`
  capsule. Resize either capsule from the Busy page.
- **GVL:** `CrunchNumbers` is pure Ruby; push a few
  (`CrunchNumbers.perform_bulk([[5_000_000]] * 8)` from
  `bundle exec ruby -r ./app -e '...'`) and watch the Busy page's GVL
  column climb.

The jobs and the rest of the setup are in `app.rb`.
