
use Test::More tests => 4 + 11;
use Async;

# Trying to check ->finished on a non-started task ought not to fail utterly
{
  my $t = Async->new(sub { 1 });
  ok(! $t->is_started(), "non-started task is_started");
  ok(! $t->is_finished(), "non started task is_finished");
  $t->start;
  ok(  $t->is_started(), "started task is_started");
  sleep 1;
  ok(  $t->is_finished(), "started task is_finished");
}

{
  my $task = Async->new(sub { return 1 + 1 });
  ok($task);
  eval { $task->await() };
  like($@, qr/(not|never) (running|started)/, "forgot to start");
  ok($task->start());
  is($task->await(), 2, "1+1=2");
}

{
  my $task = Async->new(sub { sleep 1; return 1 + 1 });
  $task->start();
  is(0 + $task->is_finished, 0, "not finished yet");
  is($task->_saved_data, "", "no data yet");

  sleep 2;
  is(0 + $task->is_finished, 1, "finished");
  isnt($task->_saved_data, "", "aha data");
  is_deeply($task->full_result, { SUCCESS => 1, RESULT => 2 }, "full result");
  is($task->result, 2, "1+1=2");
}

{
  my $n = 4;
  my (@tasks, @result, @x);
  @result = (0) x ($n+1);
  @x = (0, (1) x $n);
  for my $i (1 .. $n) {
    push @tasks, Async->new(sub { sleep $i; return $i });
  }
  $_->start for @tasks;
  my $unfinished = $n;
  while ($unfinished > 0) {
    for my $t (@tasks) {
      my $ZZZ = 1;
      if ($t->is_finished) {
	$unfinished--;
	$result[$t->result] = 1;
	$ZZZ = 0;
      }
      sleep $ZZZ;
    }
  }
  is("@result", "@x", "simultaneous tasks");
}

