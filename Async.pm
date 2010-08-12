
package Async;
$VERSION = '0.15';

sub new {
  my ($pack, $task) = @_;
  unless (defined $task) {
    require Carp;
    Carp::confess("Usage: Async->new(sub { ... })");
  }
  my $r   = \ do {local *FH};
  my $w = \ do {local *FH};
  unless (pipe $r, $w) {
    return bless { ERROR => "Couldn't make pipe: $!",
		   FINISHED => 1} => $pack;
  }
  my $pid = fork();
  unless (defined $pid) {
    return bless { ERROR => "Couldn't fork: $!",
		   FINISHED => 1} => $pack;
  }
  if ($pid) {			# parent
    close $w;
    my $self = { TASK => $task,
		 PID => $pid,
		 PIPE => $r,
		 FD => fileno($r),
		 DATA => '',
	       };
    bless $self => $pack;
  } else {			# child
    close $r;
    my $result = $task->();
    print $w $result;
    exit 0;
  }
}

# return true iff async process is complete
# with true `$force' argument, wait until process is complete before returning
sub ready {
  my ($self, $force) = @_;
  my $timeout;
  $timeout = 0 unless $force;
  return 1 if $self->{FINISHED};
  my $fdset = '';
  vec($fdset, $self->{FD}, 1) = 1;
  while (select($fdset, undef, undef, $timeout)) {
    my $buf;
    my $nr = sysread $self->{PIPE}, $buf, 8192;
    if ($nr) {
      $self->{DATA} .= $buf;
    } elsif (defined $nr) {		# EOF
      $self->{FINISHED} = 1;
      return 1;
    } else {
      $self->{ERROR} = "Read error: $!";
      $self->{FINISHED} = 1;
      return 1;
    }
  }
  return 0;
}

# Return error message if an error occurred
# Return false if no error occurred 
sub error {
  $_[0]{ERROR};
}

# Return resulting data if async process is complete
# return undef if it is incopmplete
# a true $force argument waits for the process to complete before returning
sub result {
  my ($self, $force) = @_;
  if ($self->{FINISHED}) {
    $self->{DATA};
  } elsif ($force) {
    $self->ready('force completion');
    $self->{DATA};
  } else {
    return;
  }
}

sub DESTROY {
  my ($self) = @_;
  my $pid = $self->{PID};
  return unless defined $pid;
  kill 9 => $pid;	# I don't care.
  waitpid($pid, 0);
}


################################################################

sub TIEHASH {
  my $pack = shift;
  my %self;
  bless \%self => $pack;
}

sub STORE {
  my ($self, $key, $val) = @_;
  $self->{$key} = (ref $self)->new($val);
}

sub FETCH {
  my ($self, $key) = @_;
  my $type = ref $self->{$key};
  if ($type) {
    if ($self->{$key}->ready) {
      my $result = $self->{$key}->result;
      $self->{$key} = $result;
      return $result;
    } else {
      return;
    }
  } else {
    return $self->{$key};
  }
}

sub EXISTS {
  my ($self, $key) = @_;
  my $type = ref $self->{$key};
  return $type ? $self->{$key}->ready : $self->{$key};
}

sub DELETE {
  my ($self, $key) = @_;
  delete $self->{$key};
}

sub FIRSTKEY {
  my ($self) = @_;
  keys %$self;
  return scalar(each %$self);
}

sub NEXTKEY {
  my ($self) = @_;
  return scalar(each %$self);
}

################################################################

package AsyncTimeout;
@ISA = 'Async';

sub new {
  my ($pack, $task, $timeout, $msg) = @_;
  $msg = "Timed out\n" unless defined $msg;
  my $newtask = 
    sub { 
      local $SIG{ALRM} = sub {  die "TIMEOUT\n"  };
      alarm $timeout; 
      my $s = eval {$task->()};
      return $msg if !defined($s) && $@ eq "TIMEOUT\n";
      return $s;
    };
  
  # A timeout of 0 doesn't work as you might expect, because 0 has a
  # special meaning to the alarm() call.  So if the timeout is zero,
  # we'll use a fake computation that behaves *as if* it had timed out
  # immediately.
  $newtask = sub { $msg } if $timeout == 0;  # I like this hack.

  my $self = Async->new($newtask);
  return unless $self;
  bless $self => AsyncTimeout;
}

################################################################



package AsyncData;
@ISA = 'Async';

sub new {
  require Storable;
  my ($pack, $task) = @_;
  my $newtask =
    sub {
      my $v = $task->();
      return ref $v ? Storable::freeze($v) : $v;
    };
  my $self = Async->new($newtask);
  return unless $self;
  bless $self => AsyncData;
}

sub result {
  require Storable;
  my $self = shift;
  my $rc = $self->SUPER::result(@_);
  return unless defined $rc;
  my $result =  Storable::thaw($rc);
#  print STDERR "rc: ($rc) result: ($result)\n";
  return defined $result ? $result : $rc;
}


################################################################



package AsyncCallback;
@ISA = 'Async';

my @callbacks;
my @args;

sub _run_callbacks {
  local $_;
  for (@callbacks) { next unless defined $_;
                     my ($f, $v) = @$_; 
                     $f->($v);      # $_->[0]->($_->[1])?
                   } 
  $oldHandler->('USR1') if ref $oldHandler ;
}

sub new {
  my ($pack, $task, $callback, $arg) = @_;
  my $n;
  if ($callback) {
    unless (@callbacks) {
      $oldHandler = $SIG{USR1} || 'DEFAULT';
      $SIG{USR1} = \&_run_callbacks;
    }
    push @callbacks, [$callback, $arg];
    $n = $#callbacks;
  }
  my $pid = $$;
  my $newtask =
    sub {
      my $v = $task->();
      kill 10 => $pid;
      return $v
    };
  my $self = Async->new($newtask);
  return unless $self;
  $self->{callback} = $n; 
  bless $self => AsyncCallback;
}

sub DESTROY {
  my ($self) = @_;
  my $n = $self->{callback};
  undef $callbacks[$n];
  my $i;
  pop @callbacks until defined $callbacks[-1] || @callbacks == 0;
  if (@callbacks == 0) {
    $SIG{USR1} = $oldHandler;
    undef $oldHandler;
  }
}

1;

=head1 NAME

Async - Asynchronous evaluation of Perl code (with optional timeouts)

=head1 SYNOPSIS

  my $proc = Async->new(sub { any perl code you want executed });
  
  if ($proc->ready) {
    # the code has finished executing
    if ($proc->error) {
      # something went wrong
    } else {
      $result = $proc->result;  # The return value of the code
    }
  }

  # or:
  $result = $proc->result('force completion');  # wait for it to finish
  

=head1 DESCRIPTION

C<Async> executes some code in a separate process and retrieves the
result.  Since the code is running in a separate process, your main
program can continue with whatever it was doing while the separate
code is executing.  This separate code is called an `asynchronous
computation'.  When your program wants to check to see if the
asynchronous computation is complete, it can call the C<ready()>
method, which returns true if so, and false if it is still running.

After the asynchronous computation is complete, you should call the
C<error()> method to make sure that everything went all right.
C<error()> will return C<undef> if the computation completed normally,
and an error message otherwise.

Data returned by the computation can be retrieved with the C<result()>
method.  The data must be a single string; any non-string value
returned by the computation will be stringized. (See AsyncData below
for how to avoid this.)  If the computation has not completed yet,
C<result()> will return an undefined value.

C<result()> takes an optional parameter, C<$force>.  If C<$force> is
true, then the calling process will wait until the asynchronous
computation is complete before returning.  

=head2 C<AsyncTimeout>

  use Async;
  $proc = AsyncTimeout->new(sub {...}, $timeout, $special);

C<Async::Timeout> implements a version of C<Async> that has an
automatic timeout.  If the asynchronous computation does not complete
before C<$timeout> seconds have elapsed, it is forcibly terminated and
returns a special value C<$special>.  The default special value is the
string "Timed out\n".

Because the timeouts are implemented with C<alarm()>, computations
that use C<sleep()> or C<alarm()> will probably not work properly.

All the other methods for C<AsyncTimeout> are exactly the same as for
C<Async>.

=head2 C<AsyncData>

  use Async;
  $proc = AsyncData->new(sub {...});

C<AsyncData> is just like C<Async> except that instead of returning a
string, the asynchronous computation may return any scalar value.  If
the scalar value is a reference, the C<result()> method will yield a
reference to a copy of this data structure.  If the scalar value is
I<not> a reference, the C<result()> method will I<still> yield a
reference to the value.

The C<AsyncData> module requires that C<Storable> be installed.
C<AsyncData::new> will die if C<Storable> is unavailable.

All the other methods for C<AsyncData> are exactly the same as for
C<Async>.


=head1 TIED HASH

Rather than managing the C<Async> objects directly, you can use
C<Async> with a tied hash interface.  Use

	tie %hash => Async;

Then 

	$hash{key} = sub { ... };

runs the specified code asynchronously.  You can retrieve the result
of the code by looking at the value of C<$hash{key}>.  If the code has
not yet yielded a result, C<$hash{key}> will be undefined.  You have
as many asynchronous jobs as you want; for example:

	for $i (1 .. 100) {
	  $hash{"square_root$i"} = sub { sqrt($i) };
	}

This starts 100 asynchronous jobs whose results will eventually appear
in the hash.

C<delete $hash{key}> destroys an asnychronous job without waiting for
it to complete.  C<exists $hash{key}> returns true if and only if the
job has completed.

C<keys> will return a list of keys for computations that are running
or have completed.  C<each> will return a key and the result of the
corresponding asynchronous computation, or C<undef> if the compuation
has not completed.  C<values> returns a list of results and C<undef>s.

You can tie a hash to C<AsyncData> and get the data-passing semantics
that it provides, but at present tying doesn't work for
C<AsyncTImeout> because there's no way to pass the timeout.

=head1 WARNINGS FOR THE PROGRAMMER

The asynchronous computation takes place in a separate process, so
nothing it does can affect the main program.  For example, if it
modifies global variables, changes the current directory, opens and
closes filehandles, or calls C<die>, the parent process will be
unaware of these things.  However, the asynchronous computation does
inherit the main program's file handles, so if it reads data from
files that the main program had open, that data will not be available
to the main program; similarly the asynchronous computation can write
data to the same file as the main program if it inherits an open
filehandle for that file.

=head1 ERRORS

The only errors that are reported by the C<error()> mechanism are
those that are internal to C<Async> itself:

	Couldn't make pipe: (reason)
	Couldn't fork: (reason)
	Read error: (reason)

If your asynchronous computation dies for any reason, that is not
considered to be an `error'; that is the normal termination of the
process.  Any messages written to C<STDERR> will go to the
computation's C<STDERR>, which is normally inherited from the main
program, and the C<result()> will be the empty string.

Compile-time errors in the code for the computation are, of course,
caught at the time the main program is compiled.

=head1 EXAMPLE

  use Async;
  sub long_running_computation {
     # This function simulates a computation that takes a long time to run
     my ($x) = @_;
     sleep 5;
     return $x+2;  # Eureka!
  }

  # Main program:
  my $proc = Async->new(sub {long_running_computation(2)}) or die;
  # The long-running computation is now executing.
  #

  while (1) {
    print "Main program:  The time is now ", scalar(localtime), "\n";
    my $e;
    if ($proc->ready) {
      if ($e = $proc->error) {
	print "Something went wrong.  The error was: $e\n";
      } else {
	print "The result of the computation is: ", $proc->result, "\n";
      }
      undef $proc;
      last;
    }
    # The result is not ready; we can go off and do something else here.
    sleep 1; # One thing we could do is to take nap.
  }

=head1 AUTHOR

Mark-Jason Dominus C<mjd-perl-async@plover.com>.

=cut
