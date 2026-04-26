# PostgreSQL for Lind-WASM

PostgreSQL 19devel running on lind-wasm with dynamic linking (fpcast-emu mode).

## Prerequisites

1. **lind-wasm built with fpcast-enabled shared libs:**
   ```bash
   cd /home/lind/lind-wasm
   make build
   ./scripts/make_shared_glibc.sh --with-fpcast
   ./scripts/make_shared_libm.sh --with-fpcast
   ```

2. **Enable fpcast in lind_run:**
   ```bash
   sed -i 's|exec "${LINDBOOT_BIN}" --preload|exec "${LINDBOOT_BIN}" --enable-fpcast --preload|' /home/lind/lind-wasm/scripts/lind_run
   ```

3. **Export getrusage from shared libc** (required for postgres recovery):
   ```bash
   echo "./resource/Versions" >> /home/lind/lind-wasm/scripts/version-path-minimal.txt
   ./scripts/make_shared_glibc.sh --with-fpcast
   sudo cp /home/lind/lind-wasm/build/lib/libc.cwasm /home/lind/lind-wasm/lindfs/lib/
   ```

## Build

```bash
cd /home/lind/lind-wasm-apps
export LIND_WASM_ROOT=/home/lind/lind-wasm
export LIND_DYLINK=1
make merge-sysroot
make bash      # required for popen/system calls
make postgres
```

## Install

```bash
cd /home/lind/lind-wasm-apps

# Install postgres and bash to lindfs
make install-bash
make install-postgres

# Device files (required for random number generation)
sudo cp -a /dev/urandom /dev/random /home/lind/lind-wasm/lindfs/dev/

# Timezone data
sudo apt-get install -y tzdata
sudo cp -r /usr/share/zoneinfo/* /home/lind/lind-wasm/lindfs/usr/share/zoneinfo/
```

## Run

```bash
cd /home/lind/lind-wasm

# Initialize database
sudo ./scripts/lind_run /bin/initdb.cwasm -D /tmp/pgdata

# Apply recommended settings
cat >> lindfs/tmp/pgdata/postgresql.conf << 'EOF'
max_parallel_workers_per_gather = 0
max_parallel_workers = 0
io_method = 'sync'
EOF

# Start server
sudo ./scripts/lind_run /bin/postgres.cwasm -D /tmp/pgdata &
sleep 3

# Test connection
sudo ./scripts/lind_run /bin/psql.cwasm -h /tmp -p 5432 -d postgres -c "SELECT 1;"
```

## pgbench (Optional)

```bash
# Initialize (scale factor 10)
sudo ./scripts/lind_run /bin/pgbench.cwasm -h /tmp -p 5432 -d postgres -i -s 10 --no-vacuum

# Run benchmark (8 clients, 100 transactions each)
sudo ./scripts/lind_run /bin/pgbench.cwasm -h /tmp -p 5432 -d postgres -c 8 -t 100
```

## pg_regress (Optional)

```bash
# Install test files
sudo mkdir -p lindfs/regress
sudo cp -r /home/lind/lind-wasm-apps/postgres/src/test/regress/sql lindfs/regress/
sudo cp -r /home/lind/lind-wasm-apps/postgres/src/test/regress/expected lindfs/regress/
sudo cp -r /home/lind/lind-wasm-apps/postgres/src/test/regress/data lindfs/regress/
sudo cp /home/lind/lind-wasm-apps/postgres/src/test/regress/parallel_schedule lindfs/regress/

# Install diff (required by pg_regress)
make -C /home/lind/lind-wasm-apps diffutils
sudo cp /home/lind/lind-wasm-apps/build/diffutils/wasm32-wasi/diff.cwasm lindfs/bin/
cd lindfs/bin && sudo ln -sf diff.cwasm diff && cd /home/lind/lind-wasm

# Create regression database
sudo ./scripts/lind_run /bin/psql.cwasm -h /tmp -p 5432 -d postgres -c "CREATE DATABASE regression;"

# Run tests (skip known problematic tests)
sudo ./scripts/lind_run /bin/pg_regress.cwasm --use-existing --host=/tmp --port=5432 \
  --bindir=/bin --inputdir=/regress --expecteddir=/regress \
  --schedule=/regress/parallel_schedule --max-concurrent-tests=3
```

**Tests to skip** (cause crashes or hangs): `infinite_recurse`, `select_parallel`, `write_parallel`, `vacuum_parallel`, `create_aggregate`, `partition_aggregate`, `eager_aggregate`, `aggregates`

To create a custom schedule excluding these:
```bash
cp lindfs/regress/parallel_schedule lindfs/regress/custom_schedule
sed -i 's/infinite_recurse//g; s/select_parallel//g; s/write_parallel//g; s/vacuum_parallel//g; s/create_aggregate//g; s/partition_aggregate//g; s/eager_aggregate//g' lindfs/regress/custom_schedule
```

## Troubleshooting

| Error | Fix |
|-------|-----|
| `indirect call type mismatch` | Rebuild shared libs with `--with-fpcast` and enable fpcast in lind_run |
| `could not generate secret authorization token` | `sudo cp -a /dev/urandom lindfs/dev/` |
| `env::getrusage has not been defined` | Add `./resource/Versions` to version-path-minimal.txt and rebuild libc |
| `invalid value for parameter "TimeZone"` | Copy timezone data to `lindfs/usr/share/zoneinfo/` |
| `postgres.bki does not exist` | Copy share files from build output |
| `program postgres not found` | Create symlink: `ln -sf postgres.cwasm postgres` |
