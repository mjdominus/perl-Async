
package Async;
use IO::Select;
use strict;
use Carp 'croak';
use Config;

our $VERSION = '0.90';

=head1 NAME

C<Async>

=head1 SYNOPSIS

    my $async = Async->new(sub { ... }, "compute-primes");
    $async->start or die $async->error;

    my $got_result;
    while (... something else ...) {
      ... do other work ...
      if ($async->is_finished) {
        my $result = $async->result;
        # Do something with $result
        $got_result = 1;
      }
      ...
    }

    unless ($got_result) {
      my $result = $async->await;  # wait until it finishes, then get result
      # Do something with $result
    }

=head1 DESCRIPTION

C<Async> executes a subroutine in a subprocess.  It serializes
the return value of the subroutine and passes it through a pipe back
to the parent.  Back on the parent side, execution continues
asynchronously.  At any time, the parent can whether the result is
available yet, and can retrieve it if so.

=head1 METHODS

=head2 new

=head2 start
=head2 stop

=head2 is_finished
=head2 is_running

=head2 result
=head2 full_result
=head2 safe_result

=head2 successful
=head2 exit_status

=head2 await

=head2 freeze
=head2 thaw

=head2 set_name
=head2 set_code


=cut


sub new {
  my ($class, $code, $name) = @_;
  my $self = bless { FINISHED => 0 } => $class;
  $self->set_code($code) if $code;
  $self->set_name($name) if $name;
  return $self;
}

sub set_code {
  my ($self, $code) = @_;
  $self->{CODE} = $code;
}
sub code { $_[0]{CODE} }

sub set_name { $_[0]{NAME} = $_[1] }
sub name { $_[0]{NAME} || "unnamed" }

sub start {
  my $self = shift;
  return 1 if $self->is_started;

  my ($rd, $wr);
  unless (pipe($rd, $wr)) {
    $self->set_error("pipe: $!");
    return;
  }

  my $pid = fork;
  unless (defined $pid) {
    $self->set_error("fork: $!");
    return;
  }

  if ($pid == 0) {              # child process
    close $rd;
    $self->make_hot($wr);
    $self->_set_write_handle($wr);
    $self->_do_post_fork_action();
    $self->_do_it(@_);  # Does not return!
    die "How did we get here???";
  } else {                      # parent process
    close $wr;
    $self->_init_saved_data();
    $self->_set_read_handle($rd);
    $self->_set_pid($pid);
    $self->_set_started(1);
    return $pid;
  }
}

sub error { $_[0]{ERROR} }
sub set_error { $_[0]{ERROR} = $_[1] }
sub clear_error {  delete $_[0]{ERROR} }

sub _set_started { $_[0]{STARTED} = $_[1] }
sub is_started { return $_[0]{STARTED} }

sub is_running { return $_[0]->is_started && ! $_[0]->is_finished }

sub _set_write_handle { $_[0]{WR} = $_[1] }
sub _set_read_handle { $_[0]{RD} = $_[1] }
sub _write_handle { $_[0]{WR} }
sub _read_handle { $_[0]{RD} }

sub await {
  my $self = shift;

  unless ($self->is_started) {
    croak "asynchronous process never started";
  }

  unless ($self->is_finished) {
    # undef = wait as long as it takes to get it all
    # and then reap the child process
    $self->receive_data(undef);
  }

  return $self->result();
}

sub full_result {
  my $self = shift;
  return $self->{RESULT} if exists $self->{RESULT};

  my $data = $self->_saved_data;
  if ($data eq "") {
    $self->{RESULT} = $self->failure("No response from child process");
  } else {
    $self->{RESULT} = $self->thaw($data);
  }

  return $self->{RESULT};
}

sub result {
  my $self = shift;
  if ($self->successful) { return $self->full_result->{RESULT} }
  else { croak $self->full_result->{RESULT} }
}

sub safe_result { $_[0]->full_result->{RESULT} }

sub successful {
  my $self = shift;
  return $self->full_result->{SUCCESS};
}


# PID of child process, if any
sub pid { $_[0]{PID} }
sub _set_pid { $_[0]{PID} = $_[1] }

sub got_eof { # got EOF on the pipe
  my $self = shift;

  unless (close ($self->_read_handle())) {
    $self->set_error("close pipe: $!");
    return;
  }
  my $pid = waitpid($self->pid, 0);  # XXX could hang forever?
  if ($pid != $self->pid) {
    $self->set_error("waitpid: $!");
    return;
  }

  $self->set_exit_status($?);
  $self->_set_finished(1);
  return 1;
}


sub _set_finished { $_[0]{FINISHED} = $_[1] }
sub is_finished {
  my $self = shift;
  return 1 if $self->{FINISHED};
  $self->receive_data; return $self->{FINISHED}
 }

sub exit_status { $_[0]{STATUS} }
sub set_exit_status { $_[0]{STATUS} = $_[1] }

sub serializer {
  require Async::Storable;
  return 'Async::Storable';
}

sub thaw {
  my ($self, $frozen) = @_;
  return $self->serializer->thaw($frozen);
}

# suck data out of the pipe until none is ready
# return received data
sub receive_data {
  my $self = shift;
  return unless $self->is_started;
  my $timeout = @_ ? shift() : 0.0;  # unusual code here allows explicit 'undef'
  my $fh = $self->_read_handle();

  my $s = IO::Select->new();
  $s->add($fh);

  my ($buf, $len) = ("", 0);
  while ($s->can_read($timeout)) {
    my $nr = sysread($fh, $buf, 8192, $len);
    warn "read $nr bytes\n" if $self->debug;
    if ($nr == 0) {
      $self->got_eof();
      last;
    }
    $len += $nr;
  }
  $self->_save_data($buf);
  return $buf;
}

sub _init_saved_data {
  $_[0]{DATA} = "";
}
sub _saved_data { $_[0]{DATA} }
sub _save_data {
  my ($self, $data) = @_;
  $self->{DATA} .= $data;
}

sub debug { $_[0]{debug} }
sub set_debug { $_[0]{debug} = $_[1] }

################################################################
#
# Methods only used by child processes
#

sub freeze {
  my ($self, $val) = @_;
  return $self->serializer->freeze($val);
}

# DOES NOT RETURN
sub _do_it {
  my $self = shift;
  my $result = eval {
    # Do not let exceptions propagate back to the caller!
    warn "running code\n" if $self->debug;
    $self->code->(@_);
  };
  warn "code finished\n" if $self->debug;
  my $reply;
  if ($@) {
    $reply = $self->failure($@);
  } else {
    $reply = $self->success($result);
  }

  warn "replying\n" if $self->debug;
  $self->reply($reply);
  warn "exiting\n" if $self->debug;
  exit 0;
}

sub reply {
  my ($self, $reply) = @_;
  $self->write($self->freeze($reply));
}

sub make_hot {
  my $self = shift;
  my $ofh = select(shift());
  $| = 1;
  select($ofh);
}

sub write {
  my ($self, $text) = @_;
  print {$self->_write_handle()} $text;
}

sub success {
  my ($self, $result) = @_;
  return { SUCCESS => 1, RESULT => $result };
}

sub failure {
  my ($self, $result) = @_;
  return { SUCCESS => 0, RESULT => $result };
}

my @signames = split(/ /, $Config{sig_name});
my %sig_number = map { $signames[$_] => $_ } (0 .. $#signames);

sub stop {
  my $self = shift;
  return unless $self->is_running;
  my $pid = $self->pid;
  for my $signal ('TERM') {   # INT?  KILL?
    return 1 if kill $sig_number{$signal} => $pid;
  }
  return;
}

sub set_post_fork_action { $_[0]{POSTFORK} = $_[1] }
sub _do_post_fork_action {
  my $action = $_[0]{POSTFORK} or return;
  $action->();
}


1;
