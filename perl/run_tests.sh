#!/bin/bash
# ─────────────────────────────────────────────────────────────
# perl/run_tests.sh
# Sanity test suite for Perl in Lind/wasm sandbox
# ─────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APPS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ -z "${LIND_WASM_ROOT:-}" ]]; then
  LIND_WASM_ROOT="$(cd "$APPS_ROOT/.." && pwd)"
fi

LINDFS_ROOT="$LIND_WASM_ROOT/lindfs"

mkdir -p "$LINDFS_ROOT/tests/perl"

PASS=0
FAIL=0
TOTAL=0
counter=1
TIMEOUT_SECS=10

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

# ─────────────────────────────────────────────────────────────
# assert_perl: runs a perl script via lind_run
#   $1 = description
#   $2 = expected output
#   $3 = perl program string
#   $4 = (optional) input string piped to perl
# ─────────────────────────────────────────────────────────────
assert_perl() {
    local description="$1"
    local expected="$2"
    local program="$3"
    local input="${4:-}"

    local scriptfile="tests/perl/test$counter.pl"
    local scriptfile_path="$LINDFS_ROOT/tests/perl/test$counter.pl"
    counter=$((counter + 1))

    echo "$program" > "$scriptfile_path"
    echo "RUNNING $description........"

    local actual
    if [[ -n "$input" ]]; then
        actual=$(echo "$input" | timeout ${TIMEOUT_SECS}s lind_run --enable-fpcast \
            --env PATH=/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin \
            usr/local/bin/perl "$scriptfile" 2>/dev/null)
    else
        actual=$(timeout ${TIMEOUT_SECS}s lind_run --enable-fpcast \
            --env PATH=/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin \
            usr/local/bin/perl "$scriptfile" 2>/dev/null)
    fi

    local exit_code=$?
    TOTAL=$((TOTAL + 1))

    if [ "$expected" = "$actual" ]; then
        echo -e "  ${GREEN}PASS${NC} $description"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC} $description"
        echo    "       expected: $(echo "$expected" | head -5)"
        echo    "       actual  : $(echo "$actual"   | head -5)"
        FAIL=$((FAIL + 1))
    fi
    if [ $exit_code -eq 124 ]; then
        echo -e "  ${RED}HANG${NC} $description (Timed out after ${TIMEOUT_SECS}s)"
    fi
}

section() {
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE} $1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# ─────────────────────────────────────────────────────────────
# Check binary exists in lindfs before running
# ─────────────────────────────────────────────────────────────
if [[ ! -f "$LINDFS_ROOT/usr/local/bin/perl" ]]; then
    echo -e "[ ${RED}MISSING${NC} ] $LINDFS_ROOT/usr/local/bin/perl"
    echo "Run make install-perl first"
    exit 1
fi

# ═════════════════════════════════════════════════════════════
section "1. Basic Print & Variables"
# ═════════════════════════════════════════════════════════════

assert_perl "hello world"               "hello world"   'print "hello world\n";'
assert_perl "scalar variable"           "hello"         'my $x = "hello"; print "$x\n";'
assert_perl "integer variable"          "42"            'my $x = 42; print "$x\n";'
assert_perl "string concat"             "helloworld"    'my $a = "hello"; my $b = "world"; print "$a$b\n";'
assert_perl "string repeat"             "aaa"           'my $x = "a" x 3; print "$x\n";'
assert_perl "multiline print"           "a
b
c" \
    'print "a\nb\nc\n";'
assert_perl "undef is empty"            ""              'my $x; print defined($x) ? $x : "";'
assert_perl "defined check"             "yes"           'my $x = 1; print defined($x) ? "yes" : "no", "\n";'
assert_perl "chained assignment"        "5"             'my $a = my $b = 5; print "$a\n";'

# ═════════════════════════════════════════════════════════════
section "2. Arithmetic"
# ═════════════════════════════════════════════════════════════

assert_perl "addition"                  "7"             'print 3 + 4, "\n";'
assert_perl "subtraction"              "5"             'print 9 - 4, "\n";'
assert_perl "multiplication"           "12"            'print 3 * 4, "\n";'
assert_perl "division"                 "2.5"           'print 5 / 2, "\n";'
assert_perl "integer division"         "3"             'print int(10/3), "\n";'
assert_perl "modulo"                   "1"             'print 10 % 3, "\n";'
assert_perl "exponentiation"           "8"             'print 2 ** 3, "\n";'
assert_perl "increment ++"             "6"             'my $x = 5; $x++; print "$x\n";'
assert_perl "decrement --"             "4"             'my $x = 5; $x--; print "$x\n";'
assert_perl "abs"                      "5"             'print abs(-5), "\n";'
assert_perl "int truncate"             "3"             'print int(3.9), "\n";'
assert_perl "sqrt"                     "4"             'print sqrt(16), "\n";'

# ═════════════════════════════════════════════════════════════
section "3. Strings"
# ═════════════════════════════════════════════════════════════

assert_perl "length"                   "5"             'print length("hello"), "\n";'
assert_perl "uc uppercase"             "HELLO"         'print uc("hello"), "\n";'
assert_perl "lc lowercase"             "hello"         'print lc("HELLO"), "\n";'
assert_perl "ucfirst"                  "Hello"         'print ucfirst("hello"), "\n";'
assert_perl "lcfirst"                  "hELLO"         'print lcfirst("HELLO"), "\n";'
assert_perl "substr"                   "ell"           'print substr("hello", 1, 3), "\n";'
assert_perl "index"                    "2"             'print index("hello", "llo"), "\n";'
assert_perl "rindex"                   "3"             'print rindex("hello", "l"), "\n";'
assert_perl "reverse"                  "olleh"         'print scalar reverse("hello"), "\n";'
assert_perl "chomp"                    "hello"         'my $x = "hello\n"; chomp $x; print "$x\n";'
assert_perl "chop"                     "hell"          'my $x = "hello"; chop $x; print "$x\n";'
assert_perl "sprintf"                  "042"           'print sprintf("%03d", 42), "\n";'
assert_perl "join"                     "a,b,c"         'print join(",", "a", "b", "c"), "\n";'
assert_perl "split"                    "3"             'my @a = split(/,/, "a,b,c"); print scalar @a, "\n";'
assert_perl "trim with regex"          "hello"         'my $x = "  hello  "; $x =~ s/^\s+|\s+$//g; print "$x\n";'

# ═════════════════════════════════════════════════════════════
section "4. Regex"
# ═════════════════════════════════════════════════════════════

assert_perl "basic match"              "yes"           'print "hello" =~ /ell/ ? "yes" : "no", "\n";'
assert_perl "no match"                 "no"            'print "hello" =~ /xyz/ ? "yes" : "no", "\n";'
assert_perl "substitution s///"       "hXllo"         'my $x = "hello"; $x =~ s/e/X/; print "$x\n";'
assert_perl "global substitution g"   "hXllX"         'my $x = "hello"; $x =~ s/[eo]/X/g; print "$x\n";'
assert_perl "case insensitive i"       "yes"           'print "Hello" =~ /hello/i ? "yes" : "no", "\n";'
assert_perl "capture group"            "ell"           '"hello" =~ /h(ell)o/; print "$1\n";'
assert_perl "multiple captures"        "hello world"   '"hello world" =~ /(\w+) (\w+)/; print "$1 $2\n";'
assert_perl "tr transliterate"         "HELLO"         'my $x = "hello"; $x =~ tr/a-z/A-Z/; print "$x\n";'
assert_perl "tr count"                 "2"             'my $x = "hello"; my $c = ($x =~ tr/l//); print "$c\n";'
assert_perl "split on regex"           "a b c"         'my @a = split(/\s+/, "a  b  c"); print join(" ", @a), "\n";'
assert_perl "global match list"        "3"             'my @m = ("aababc" =~ /a/g); print scalar @m, "\n";'

# ═════════════════════════════════════════════════════════════
section "5. Arrays"
# ═════════════════════════════════════════════════════════════

assert_perl "basic array"              "one"           'my @a = ("one", "two", "three"); print "$a[0]\n";'
assert_perl "array length"             "3"             'my @a = (1, 2, 3); print scalar @a, "\n";'
assert_perl "last index"               "2"             'my @a = (1, 2, 3); print $#a, "\n";'
assert_perl "push"                     "4"             'my @a = (1,2,3); push @a, 4; print scalar @a, "\n";'
assert_perl "pop"                      "3"             'my @a = (1,2,3); my $x = pop @a; print "$x\n";'
assert_perl "shift"                    "1"             'my @a = (1,2,3); my $x = shift @a; print "$x\n";'
assert_perl "unshift"                  "4"             'my @a = (1,2,3); unshift @a, 0; print scalar @a, "\n";'
assert_perl "slice"                    "2 3"           'my @a = (1,2,3,4); print join(" ", @a[1..2]), "\n";'
assert_perl "reverse array"            "3 2 1"         'my @a = (1,2,3); print join(" ", reverse @a), "\n";'
assert_perl "sort array"               "a b c"         'my @a = ("c","a","b"); print join(" ", sort @a), "\n";'
assert_perl "sort numeric"             "1 2 10"        'my @a = (10,1,2); print join(" ", sort { $a <=> $b } @a), "\n";'
assert_perl "grep filter"              "2"             'my @a = (1,2,3,4); my @e = grep { $_ % 2 == 0 } @a; print scalar @e, "\n";'
assert_perl "map transform"            "2 4 6"         'my @a = (1,2,3); my @b = map { $_ * 2 } @a; print join(" ", @b), "\n";'
assert_perl "join array"               "1,2,3"         'my @a = (1,2,3); print join(",", @a), "\n";'
assert_perl "wantarray context"        "3"             'my @a = (1..3); print scalar @a, "\n";'

# ═════════════════════════════════════════════════════════════
section "6. Hashes"
# ═════════════════════════════════════════════════════════════

assert_perl "basic hash set/get"       "bar"           'my %h = (foo => "bar"); print "$h{foo}\n";'
assert_perl "hash exists"              "yes"           'my %h = (a => 1); print exists $h{a} ? "yes" : "no", "\n";'
assert_perl "hash not exists"          "no"            'my %h = (a => 1); print exists $h{b} ? "yes" : "no", "\n";'
assert_perl "delete key"               "no"            'my %h = (a => 1); delete $h{a}; print exists $h{a} ? "yes" : "no", "\n";'
assert_perl "hash keys count"          "3"             'my %h = (a=>1, b=>2, c=>3); print scalar keys %h, "\n";'
assert_perl "hash values"              "1"             'my %h = (a=>1); my @v = values %h; print "$v[0]\n";'
assert_perl "iterate hash"             "1"             'my %h = (a=>1); while (my ($k,$v) = each %h) { print "$v\n"; }'
assert_perl "hash slice"               "1 2"           'my %h = (a=>1, b=>2, c=>3); print join(" ", @h{qw(a b)}), "\n";'
assert_perl "hash ref"                 "bar"           'my $h = {foo => "bar"}; print "$h->{foo}\n";'
assert_perl "nested hash"              "deep"          'my %h = (a => {b => "deep"}); print "$h{a}{b}\n";'

# ═════════════════════════════════════════════════════════════
section "7. Control Flow"
# ═════════════════════════════════════════════════════════════

assert_perl "if true"                  "yes"           'if (1) { print "yes\n"; }'
assert_perl "if false else"            "no"            'if (0) { print "yes\n"; } else { print "no\n"; }'
assert_perl "elsif"                    "middle"        'my $x=5; if ($x<3){print "low\n"}elsif($x<8){print "middle\n"}else{print "high\n"}'
assert_perl "unless"                   "yes"           'unless (0) { print "yes\n"; }'
assert_perl "while loop"               "0
1
2" \
    'my $i=0; while($i<3){ print "$i\n"; $i++; }'

assert_perl "until loop"               "0
1
2" \
    'my $i=0; until($i>=3){ print "$i\n"; $i++; }'

assert_perl "for loop"                 "0
1
2" \
    'for(my $i=0; $i<3; $i++){ print "$i\n"; }'

assert_perl "foreach"                  "a
b
c" \
    'foreach my $x ("a","b","c"){ print "$x\n"; }'

assert_perl "last (break)"             "0
1" \
    'for my $i (0..3){ last if $i==2; print "$i\n"; }'

assert_perl "next (continue)"          "0
1
3" \
    'for my $i (0..3){ next if $i==2; print "$i\n"; }'

assert_perl "ternary"                  "big"           'my $x=10; print($x>5 ? "big" : "small"); print "\n";'
assert_perl "postfix if"               "yes"           'print "yes\n" if 1;'
assert_perl "postfix unless"           "yes"           'print "yes\n" unless 0;'
assert_perl "do-while"                 "0
1
2" \
    'my $i=0; do { print "$i\n"; $i++; } while($i<3);'

# ═════════════════════════════════════════════════════════════
section "8. Subroutines"
# ═════════════════════════════════════════════════════════════

assert_perl "basic sub"                "hello"         'sub f { print "hello\n"; } f();'
assert_perl "sub with args"            "hello world"   'sub f { print "$_[0] $_[1]\n"; } f("hello","world");'
assert_perl "sub return value"         "42"            'sub f { return 42; } print f(), "\n";'
assert_perl "sub default return"       "last"          'sub f { "last"; } print f(), "\n";'
assert_perl "recursive factorial"      "120"           'sub fact { my $n=shift; return 1 if $n<=1; return $n*fact($n-1); } print fact(5), "\n";'
assert_perl "sub sees lexical"         "global"        'my $x="global"; sub f { print "$x\n"; } f();'
assert_perl "sub modifies ref"         "modified"      'sub f { ${$_[0]} = "modified"; } my $x="orig"; f(\$x); print "$x\n";'
assert_perl "variadic args"            "3"             'sub f { return scalar @_; } print f(1,2,3), "\n";'

# ═════════════════════════════════════════════════════════════
section "9. File I/O"
# ═════════════════════════════════════════════════════════════

assert_perl "write and read file"      "hello" \
'my $fname = "/tmp/perl_test_$$";
open(my $fh, ">", $fname) or die;
print $fh "hello\n";
close $fh;
open(my $in, "<", $fname) or die;
my $line = <$in>;
chomp $line;
print "$line\n";
close $in;
unlink $fname;'

assert_perl "append to file"           "line1
line2" \
'my $fname = "/tmp/perl_test_$$";
open(my $fh, ">", $fname) or die;
print $fh "line1\n";
close $fh;
open(my $a, ">>", $fname) or die;
print $a "line2\n";
close $a;
open(my $in, "<", $fname) or die;
while(<$in>){ chomp; print "$_\n"; }
close $in;
unlink $fname;'

assert_perl "read all lines"           "3" \
'my $fname = "/tmp/perl_test_$$";
open(my $fh, ">", $fname) or die;
print $fh "a\nb\nc\n";
close $fh;
open(my $in, "<", $fname) or die;
my @lines = <$in>;
close $in;
print scalar @lines, "\n";
unlink $fname;'

assert_perl "read from stdin"          "hello" \
    'my $line = <STDIN>; chomp $line; print "$line\n";' \
    "hello"

assert_perl "write to stdout"          "test"          'print STDOUT "test\n";'

# ═════════════════════════════════════════════════════════════
section "10. References"
# ═════════════════════════════════════════════════════════════

assert_perl "scalar ref"               "42"            'my $x=42; my $r=\$x; print $$r, "\n";'
assert_perl "array ref"                "two"           'my @a=("one","two","three"); my $r=\@a; print $r->[1], "\n";'
assert_perl "hash ref access"          "bar"           'my %h=(foo=>"bar"); my $r=\%h; print $r->{foo}, "\n";'
assert_perl "anon array ref"           "b"             'my $r=["a","b","c"]; print $r->[1], "\n";'
assert_perl "anon hash ref"            "val"           'my $r={key=>"val"}; print $r->{key}, "\n";'
assert_perl "nested array ref"         "deep"          'my $r=[["shallow"],["deep"]]; print $r->[1][0], "\n";'
assert_perl "ref type check"           "ARRAY"         'my $r=[1,2,3]; print ref($r), "\n";'
assert_perl "deref array in loop"      "1 2 3"         'my $r=[1,2,3]; print join(" ", @$r), "\n";'

# ═════════════════════════════════════════════════════════════
# SUMMARY
# ═════════════════════════════════════════════════════════════
echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE} Results${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e " Total : $TOTAL"
echo -e " ${GREEN}Pass${NC}  : $PASS"
echo -e " ${RED}Fail${NC}  : $FAIL"
echo ""
if [ $FAIL -gt 0 ]; then
    echo -e "${RED}FAILED${NC} — $FAIL/$TOTAL tests failed"
    exit 1
else
    echo -e "${GREEN}ALL PASSED${NC} — $PASS/$TOTAL tests passed"
    exit 0
fi