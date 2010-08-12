package Async::ShellCommand;
use base 'Async';
use strict;
use Carp 'croak';
use IO::Handle;
use IPC::Open3;

sub new {
    my ($class, $args) = @_;
    my $code = $class->make_shell_command_action($args);
    my $self = $class->SUPER::new($code);
    my $name = $args->{name}
      || qq'shell command "$args->{command} @{$args->{args}}"';
    $self->set_name($name);
    return $self;
}

sub make_shell_command_action {
  my ($self, $args) = @_;

  return sub {
    $_ = IO::Handle->new() for my ($stdin, $stdout, $stderr);

    my $pid = open3($stdin, $stdout, $stderr,
                    $args->{command}, @{$args->{args}});
    die "open3: $!" if $pid <= 0;

    my ($wrs, $rds, $null) = ("") x 3;
    vec($wrs, fileno($_), 1) = 1 for $stdin;
    vec($rds, fileno($_), 1) = 1 for $stdout, $stderr;
    my $timeout = $args->{timeout} || undef;

    my $input = $args->{input} || "";
    my $off = 0;
    my %read_buf = (stdout => "", stderr => "");
    my %read_handle = ( stdout => $stdout, stderr => $stderr );
    my $open_handles = 3;

    # This sub, when run, waits for the shell command to complete,
    # feeding it input from $input and gathering all its output into
    # %read_buf, and then reaps the child process and returns

    my ($readable, $writable) = ("") x 2;
    while ($open_handles) {
      if (select($readable = $rds, $writable = $wrs, $null, $timeout)) {

        if (defined $stdin && _contains($writable, $stdin)) {
          if ($off < length($input)) {
            my $bw = syswrite($stdin, $input, length($input) - $off, $off);
            die "write: $!" if $bw == -1;

            #    warn "wrote $bw bytes";
            $off += $bw;
          } else {

            #    warn "closing stdin";
            close $stdin;
            undef $stdin;
            $wrs = $null;
            $open_handles--;
          }
        }

        for my $handle_name (qw(stdout stderr)) {
          my $fh = $read_handle{$handle_name};
          if (defined $fh && _contains($readable, $fh)) {
            my $buf;
            my $br = sysread($fh, $buf, 8192);
            die "read $handle_name: $!" if $br < 0;
            if ($br == 0) {  # EOF
              vec($rds, fileno($fh), 1) = 0;

              #      warn "closing $handle_name";
              close $fh;
              undef $read_handle{$handle_name};
              $open_handles--;
            } else {

              #      warn "read $br bytes from $handle_name";
              $read_buf{$handle_name} .= $buf;
            }
          }
        }

      }  # select found something
    }  # while ($open_handles)

    # all handles closed now
    my $res = waitpid($pid, 0);
    die "waitpid ($res): $!" if $res != $pid;
    my $result = { exit_status => $?,
                   %read_buf,
                 };

    if ($? != 0 && $args->{die_on_failure}) {
      die $result;
    } else {
      return $result;
    }
  }
}

sub _contains {
  my ($set, $fh) = @_;
  return vec($set, fileno($fh), 1);
}

1;
