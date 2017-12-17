#----------------------------------------------------------------------
package DBIx::DataModel::Schema::ResultAs::Hashref;
#----------------------------------------------------------------------
use warnings;
use strict;
use Carp::Clan       qw[^(DBIx::DataModel::|SQL::Abstract)];
use IO::Detect       qw/is_filehandle/;

use parent 'DBIx::DataModel::Schema::ResultAs';

use namespace::clean;

sub new {
  my $class = shift;

  my $self = {cols => \@_};
  return bless $self, $class;
}


sub get_result {
  my ($self, $statement) = @_;

  my @cols = @{$self->{cols}};
  @cols = $statement->meta_source->primary_key              if !@cols;
  croak "-result_as=>'hashref' impossible: no primary key"  if !@cols;

  $statement->execute;

  my %hash;
  while (my $row = $statement->next) {
    my @key = map {$row->{$_} // ''} @cols;
    my $last_key_item = pop @key;
    my $node          = \%hash;
    $node = $node->{$_} //= {} foreach @key;
    $node->{$last_key_item} = $row;
  }
  $statement->finish;
  return \%hash;
}


1;


