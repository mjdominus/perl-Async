
package Async::ShellCommand::Simple;
use base 'Async::ShellCommand';
use strict;
use Carp 'croak';

sub new {
    my ($class, $command, @args) = @_;
    return $class->SUPER::new({command => $command,
                               args => \@args,
                               name => "command '$command @args'",
                               die_on_failure => 1,
                              });
}

1;
