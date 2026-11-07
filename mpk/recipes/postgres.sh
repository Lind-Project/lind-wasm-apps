# PostgreSQL server + client tools (no readline/icu/zlib/openssl)
RUNTIME_DEPS=(bash coreutils)
NOTE="Client tools link libpq statically. Server-side extensions (plpgsql, dict_snowball, ...) are shared objects loaded with dlopen and are installed unrewritten."
recipe_build() {
  autotools_touch
  ./configure CC="$MPK_CC" --prefix=/usr/local/pgsql --without-readline --without-icu \
    --without-zlib --without-openssl --without-zstd --without-lz4 --disable-nls
  # Link client tools against libpq.a: the rewriter only trusts lind's libc/libm/ld.so.
  # libpq's _shlib helpers and the frontend libpgcommon both carry encnames.o, hence
  # --allow-multiple-definition (the duplicate definitions are identical).
  local libpq='-Wl,--start-group $(libpq_builddir)/libpq.a $(top_builddir)/src/common/libpgcommon_shlib.a $(top_builddir)/src/port/libpgport_shlib.a -Wl,--end-group -lpthread -Wl,--allow-multiple-definition'
  make -j"$JOBS" libpq="$libpq"
  make DESTDIR="$SRC/inst" libpq="$libpq" install
  mkdir -p "$NATIVE/usr/local"
  cp -a "$SRC/inst/usr/local/pgsql" "$NATIVE/usr/local/"
  rm -rf "$NATIVE/usr/local/pgsql/include"
}
recipe_smoke() {
  local pg=/usr/local/pgsql/bin
  lindfs_rm "$LINDFS/tmp/mpk-pgdata"
  smoke postgres-version "PostgreSQL" -- $pg/postgres --version
  smoke psql-version "psql (PostgreSQL)" -- $pg/psql --version
  smoke pg_config "PGXS" -- $pg/pg_config
  SMOKE_TIMEOUT=300 smoke initdb "Success" -- $pg/initdb -A trust -U postgres -D /tmp/mpk-pgdata
  SMOKE_TIMEOUT=120 smoke single-user "lind-mpk" --stdin <(printf "SELECT 'lind' || '-mpk';\n") -- \
    $pg/postgres --single -D /tmp/mpk-pgdata postgres
}
