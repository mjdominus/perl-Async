#!/usr/bin/perl

use lib '..';
use Async;
use Tie::IxHash;
tie %result => Tie::IxHash;
local $^W = 0;

unless ($Async::VERSION == 0.15) {
  die "This is the test suite for Async version 0.15.  
You have version $Async::VERSION.  THat does not make sense.\n";
}


my @PACKAGES = qw(Async AsyncTimeout);
if (eval {require Storable}) {
  push @PACKAGES, 'AsyncData';
}

for $tie (0..1) {
  my $if = $tie ? 'Tie' : 'Object';
  for $pack (@PACKAGES) {
    print "# * tie=$tie if=$if pack=$pack\n";
    my @timeout = ($pack eq 'AsyncTimeout') ? (1000) : ();
#    print STDERR "timeout args: (@timeout)\n";
    my %h;
    if ($tie) {
      my $rc = tie %h => $pack;
      $result{"$pack-tie"} = defined $rc;
    }

    {
      my $o;
      my $sub = sub { return "3" };
      my $test = "$pack-$if-sleepless";
      if ($tie) {
        $h{key} = $sub;
      } else {
        $o = $pack->new($sub, @timeout);
        $result{"$test"} = defined $o;
      }
      sleep 1;
      $result{"$test-ready"} = $tie ? exists $h{key} : $o->ready;
      $result{"$test-error"} = not $o->error unless $tie;
      my $res = $tie ? $h{key} : $o->result;
#      print STDERR "$test: result1 is ($res)\n";
      $result{"$test-result"} = ($res == 3);
      print "# ? tie=$tie if=$if pack=$pack\n";
      $tie ? undef $h{key} : undef $o;
    }
    
    {
      my $sub = sub {sleep 2; return 3};
      my $o;
      my $test = "$pack-$if-sleepy";
      if ($tie) {
        $h{key} = $sub;
      } else {
        $o = $pack->new($sub, @timeout);
        $result{$test} = defined $o;
      }

      $result{"$test-waits"} = not($tie ? exists $h{key} : $o->ready);
      $result{"$test-error"} = not $o->error unless $tie;
      $result{"$test-early-result"} = !defined ($tie ? $h{key} : $o->result);
#      print STDERR "$test: result is ($h{key})\n";
      sleep 4;
      $result{"$test-returns-eventually"} = $tie ? exists $h{key} : $o->ready;
      $result{"$test-error-eventually"} = not $o->error unless $tie;
      $result{"$test-correctresult"} =  ($tie ? $h{key} : $o->result) == 3;
#      print STDERR "$test: result is ($h{key})\n";
    }
  }
}

if ( $@ ) {
  print "# Premature termination\n# $@\n";
}

print "1..", (scalar keys %result), "\n";
my $n = 1;
foreach $key (keys %result) {
  my $res = $result{$key};
  unless (defined $res) {
    warn "Test `$key' yielded undefined result!\n";
  }
  print +($result{$key}) ? '' : 'not ', "ok $n  # $key\n";
  $n++;
}
