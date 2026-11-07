# curl with static OpenSSL + zlib; same protocol set as compile_curl.sh plus file://
DEPS=(zlib openssl)
recipe_build() {
  autoreconf -fi
  LIBS="-ldl -lpthread" mpk_configure --disable-shared --enable-static \
    --with-openssl="$PREFIX" --with-zlib="$PREFIX" \
    --without-libssh2 --without-libssh --without-brotli --without-zstd \
    --without-libpsl --without-nghttp2 --without-librtmp --without-gssapi \
    --without-gsasl --without-libidn2 --disable-ldap --disable-ldaps \
    --with-ca-bundle=/etc/ssl/certs/ca-certificates.crt
  make -j"$JOBS"
  stage_bin src/curl /usr/local/bin/curl
}
recipe_smoke() {
  printf 'file payload\n' | fixture /tmp/mpk-curl/payload.txt
  smoke version "OpenSSL" -- /usr/local/bin/curl --version
  smoke file-url "file payload" -- /usr/local/bin/curl -s file:///tmp/mpk-curl/payload.txt
  smoke output-file "" -- /usr/local/bin/curl -s -o /tmp/mpk-curl/out.txt file:///tmp/mpk-curl/payload.txt
  smoke refused "" --exit 7 -- /usr/local/bin/curl -s http://127.0.0.1:1/
}
