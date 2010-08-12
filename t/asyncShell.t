
use Test::More tests => 2 + 4 + 7;
use Async::ShellCommand;
use Async::ShellCommand::Simple;
use Time::HiRes;

# Trying to check ->finished on a non-started task ought not to fail utterly
{
  my $t = Async::ShellCommand::Simple->new("true");
  ok(! $t->is_started(), "non-started task is_started");
  ok(! $t->is_finished(), "non started task is_finished");
  $t->start;
  ok(  $t->is_started(), "started task is_started");
  sleep 1;
  ok(  $t->is_finished(), "started task is_finished");
}

{
  my $task = Async::ShellCommand::Simple->new('true');
  ok($task);
  $task->start();
  is_deeply($task->await, { stdout => "", stderr => "", exit_status => 0 });
}

{
  my $task = Async::ShellCommand::Simple->new(q{sh -c 'exit 1'});
  $task->start();
  my $res = eval { $task->await };
  is_deeply($@, { stdout => "", stderr => "", exit_status => 256 });
}

{
  my $task = Async::ShellCommand::Simple->new('echo', 'potato');
  $task->start();
  is_deeply($task->await, { stdout => "potato\n", stderr => "", exit_status => 0 });
}

{
  my $task = Async::ShellCommand::Simple->new('echo potato 1>&2');
  $task->start();
  is_deeply($task->await, { stdout => "", stderr => "potato\n", exit_status => 0 });
}

{
  my $task = Async::ShellCommand::Simple->new('perl -e "print qq{foo\nbar}; die"');
  $task->start();
  my $res = eval { $task->await };
  is_deeply($@, { stdout => "foo\nbar",
                  stderr => "Died at -e line 1.\n",
                  exit_status =>  255 * 256
                });
}

{
  my $task = Async::ShellCommand
    ->new({command => 'tr',
           args => [qw([a-z] [A-Z])],
           input => "With\nyour\nmouth!\n"
          },
         );

  $task->start();
  is_deeply($task->await, { stdout => "WITH\nYOUR\nMOUTH!\n",
			    stderr => "",
			    exit_status =>  0 * 256
			  });
}

# This test catches a bug at f85098f5b7a183f29cb2c893513e8d8c58c2b545
# Where if the task finished before the ->await call, the ->await
# would erroneously die because it was not running; it was only supposed
# to die if the task had never been started
{
  my $task = Async::ShellCommand::Simple->new('true');
  ok($task);
  $task->start();
  sleep 1;
  is_deeply($task->await, { stdout => "", stderr => "", exit_status => 0 });
}

