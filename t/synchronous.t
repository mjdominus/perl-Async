
use Test::More tests => 2;
use Async;

{
  my $t = Async->new(sub { sleep 3; 119 });
  $t->set_synchronous(1);
  my $start = time();
  $t->start();
  my $end = time();
  ok($end > $start + 1, "synchronous start actually waits for finish");
  is($t->result, 119, "check actual result");
}
