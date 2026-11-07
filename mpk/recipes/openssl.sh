# OpenSSL: static libcrypto/libssl for curl/git/cpython plus the openssl CLI
KIND=library
NOTE="Built no-asm, like compile_openssl.sh. With OpenSSL's default x86-64 assembly, gsfork-elf rejects the AVX-512 paths (unsupported instruction vpxord)."
recipe_build() {
  ./Configure linux-x86_64 no-asm no-shared no-tests no-docs no-module \
    --prefix="$PREFIX" --libdir=lib --openssldir=/usr/local/ssl CC="$MPK_CC"
  make -j"$JOBS" build_sw
  make install_sw
  stage_bin apps/openssl /usr/local/bin/openssl
}
recipe_smoke() {
  printf 'lind mpk\n' | fixture /tmp/mpk-openssl/msg.txt
  smoke version "OpenSSL" -- /usr/local/bin/openssl version
  smoke sha256 "a4d7d3e2" -- /usr/local/bin/openssl dgst -sha256 /tmp/mpk-openssl/msg.txt
  smoke rand-hex "" -- /usr/local/bin/openssl rand -hex 16
  smoke aes-encrypt "" -- /usr/local/bin/openssl enc -aes-256-cbc -pbkdf2 -k pw -in /tmp/mpk-openssl/msg.txt -out /tmp/mpk-openssl/msg.enc
  smoke aes-decrypt "lind mpk" -- /usr/local/bin/openssl enc -d -aes-256-cbc -pbkdf2 -k pw -in /tmp/mpk-openssl/msg.enc
  smoke ed25519-keygen "BEGIN PRIVATE KEY" -- /usr/local/bin/openssl genpkey -algorithm ed25519
  smoke rsa-keygen "BEGIN PRIVATE KEY" -- /usr/local/bin/openssl genpkey -algorithm rsa -pkeyopt rsa_keygen_bits:1024
}
