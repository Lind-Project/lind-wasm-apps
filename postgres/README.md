# PostgreSQL for Lind-WASM

PostgreSQL 19devel running on lind-wasm with dynamic linking (fpcast-emu mode).

## Prerequisites

**lind-wasm built with fpcast-enabled shared libs:**
```bash
cd $LIND_WASM_ROOT
make build
./scripts/make_shared_glibc.sh --with-fpcast
./scripts/make_shared_libm.sh --with-fpcast
```

## Build

```bash
cd $LIND_WASM_ROOT/../lind-wasm-apps
export LIND_WASM_ROOT=$LIND_WASM_ROOT
export LIND_DYLINK=1
make merge-sysroot
make bash      # required for popen/system calls
make postgres
```

## Install

```bash
cd $LIND_WASM_ROOT/../lind-wasm-apps
make install-bash
make install-postgres
```

## Run

Postgres requires fpcast-emu mode. Use the `--enable-fpcast` flag:

```bash
cd $LIND_WASM_ROOT

# Initialize database
sudo ./scripts/lind_run --enable-fpcast /bin/initdb.cwasm -D /tmp/pgdata

# Apply lind-wasm optimized settings
cat lindfs/share/postgresql.conf.lind >> lindfs/tmp/pgdata/postgresql.conf

# Start server
sudo ./scripts/lind_run --enable-fpcast /bin/postgres.cwasm -D /tmp/pgdata &
sleep 3

# Test connection
sudo ./scripts/lind_run --enable-fpcast /bin/psql.cwasm -h /tmp -p 5432 -d postgres -c "SELECT 1;"
```

## pgbench (Optional)

```bash
# Initialize (scale factor 10)
sudo ./scripts/lind_run --enable-fpcast /bin/pgbench.cwasm -h /tmp -p 5432 -d postgres -i -s 10 --no-vacuum

# Run benchmark (8 clients, 100 transactions each)
sudo ./scripts/lind_run --enable-fpcast /bin/pgbench.cwasm -h /tmp -p 5432 -d postgres -c 8 -t 100
```

## pg_regress (Optional)

```bash
# Install test files
sudo mkdir -p $LIND_WASM_ROOT/lindfs/regress
sudo cp -r postgres/src/test/regress/sql $LIND_WASM_ROOT/lindfs/regress/
sudo cp -r postgres/src/test/regress/expected $LIND_WASM_ROOT/lindfs/regress/
sudo cp -r postgres/src/test/regress/data $LIND_WASM_ROOT/lindfs/regress/
sudo cp postgres/src/test/regress/parallel_schedule $LIND_WASM_ROOT/lindfs/regress/

# Install diff (required by pg_regress)
make diffutils
make install-diffutils

# Create regression database
sudo ./scripts/lind_run --enable-fpcast /bin/psql.cwasm -h /tmp -p 5432 -d postgres -c "CREATE DATABASE regression;"

# Run tests
sudo ./scripts/lind_run --enable-fpcast /bin/pg_regress.cwasm --use-existing --host=/tmp --port=5432 \
  --bindir=/bin --inputdir=/regress --expecteddir=/regress \
  --schedule=/regress/parallel_schedule --max-concurrent-tests=3
```

**Tests to skip** (cause crashes or hangs): `infinite_recurse`, `select_parallel`, `write_parallel`, `vacuum_parallel`, `create_aggregate`, `partition_aggregate`, `eager_aggregate`, `aggregates`

## Troubleshooting

| Error | Fix |
|-------|-----|
| `indirect call type mismatch` | Use `--enable-fpcast` flag and rebuild shared libs with `--with-fpcast` |
| `postgres.bki does not exist` | Re-run `make install-postgres` |
| `program postgres not found` | Re-run `make install-postgres` |
