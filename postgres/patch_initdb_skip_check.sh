#!/usr/bin/env bash                                                                                                                                                 
  # patch_initdb_skip_check.sh                                                                                                                                      
  # Apply to postgres source tree to skip --check probing under WASI.                                                                                                 
  # Usage: bash patch_initdb_skip_check.sh /path/to/postgres                                                                                                          
                                                                                                                                                                      
  set -euo pipefail                                                                                                                                                 
                                                                                                                                                                      
  PG_ROOT="${1:?Usage: $0 /path/to/postgres}"                                                                                                                         
  INITDB_C="$PG_ROOT/src/bin/initdb/initdb.c"
                                                                                                                                                                      
  if [[ ! -f "$INITDB_C" ]]; then                                                                                                                                     
    echo "ERROR: $INITDB_C not found" >&2
    exit 1                                                                                                                                                            
  fi                                                                                                                                                                

  if grep -q '#ifdef __wasi__.*skip.*check' "$INITDB_C"; then                                                                                                         
    echo "Patch already applied, skipping."
    exit 0                                                                                                                                                            
  fi                                                                                                                                                                
                                                                                                                                                                      
  # Find the line number of "test_config_settings(void)" opening brace                                                                                                
  LINE=$(grep -n '^test_config_settings(void)$' "$INITDB_C" | head -1 | cut -d: -f1)
  if [[ -z "$LINE" ]]; then                                                                                                                                           
    echo "ERROR: could not find test_config_settings(void) in $INITDB_C" >&2                                                                                          
    exit 1
  fi                                                                                                                                                                  
                                                                                                                                                                    
  # The opening brace '{' is on the next line; insert after it                                                                                                        
  BRACE_LINE=$((LINE + 1))
                                                                                                                                                                      
  sed -i "${BRACE_LINE}a\\                                                                                                                                          
  #ifdef __wasi__\\
  \t/* Skip postgres --check probing under WASI — double fork+exec shmat bug */\\
  \tprintf(_(\"selecting dynamic shared memory implementation ... \"));\\                                                                                             
  \tfflush(stdout);\\
  \tdynamic_shared_memory_type = \"sysv\";\\                                                                                                                          
  \tprintf(\"%s\\\\n\", dynamic_shared_memory_type);\\                                                                                                              
  \tprintf(_(\"selecting default \\\\\"max_connections\\\\\" ... \"));\\                                                                                              
  \tfflush(stdout);\\                                                                                                                                                 
  \tn_connections = 20;\\
  \tn_av_slots = 3;\\                                                                                                                                                 
  \tprintf(\"%d\\\\n\", n_connections);\\                                                                                                                           
  \tprintf(_(\"selecting default \\\\\"shared_buffers\\\\\" ... \"));\\
  \tfflush(stdout);\\                                                                                                                                                 
  \tn_buffers = 200;\\
  \tprintf(\"%dkB\\\\n\", n_buffers * (BLCKSZ / 1024));\\                                                                                                             
  \tprintf(_(\"selecting default time zone ... \"));\\                                                                                                                
  \tfflush(stdout);\\
  \tdefault_timezone = select_default_timezone(share_path);\\                                                                                                         
  \tprintf(\"%s\\\\n\", default_timezone ? default_timezone : \"GMT\");\\                                                                                           
  \treturn;\\                                                                                                                                                         
  #endif" "$INITDB_C"
                                                                                                                                                                      
  echo "Patched $INITDB_C — test_config_settings() returns early under __wasi__" 
