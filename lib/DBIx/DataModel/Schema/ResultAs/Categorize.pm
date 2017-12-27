#----------------------------------------------------------------------
package DBIx::DataModel::Schema::ResultAs::Categorize;
#----------------------------------------------------------------------
use warnings;
use strict;
use Carp::Clan              qw[^(DBIx::DataModel::|SQL::Abstract)];
use List::Categorize 0.04   qw/categorize/;

use parent 'DBIx::DataModel::Schema::ResultAs';

use namespace::clean;

sub new {
  my $class = shift;

  @_ or croak "-result_as => [categorize => ...] ... need field names ";

  my $self = {cols => \@_};
  return bless $self, $class;
}

sub get_result {
  my ($self, $statement) = @_;

  my @cols = @{$self->{cols}};

  $statement->execute;
  my $rows = $statement->all;
  my %result = categorize {@{$_}{@cols}} @$rows;
  $statement->finish;

  return \%result;
}


1;


