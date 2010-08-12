
package Async::Storable;
use strict;
use Carp 'croak';
use Storable qw();

# This module exists to put an OO interface on Storable::freeze and
# Storable::thaw

sub new {
  my ($class) = @_;
  my $self = bless {} => $class;
  return $self;
}

sub freeze {
  my ($self, $obj) = @_;
  return Storable::freeze($obj);
}

sub thaw {
  my ($self, $data) = @_;
  return Storable::thaw($data);
}

1;
