#----------------------------------------------------------------------
package DBIx::DataModel::Schema::ResultAs::Flat;
#----------------------------------------------------------------------
use warnings;
use strict;

use parent 'DBIx::DataModel::Schema::ResultAs';

use namespace::clean;

sub get_result {
  my ($self, $statement) = @_;

  $statement->execute;
  $statement->make_fast;
  my @vals;
  my @headers = $statement->headers;
  while (my $row = $statement->next) {
    push @vals, @{$row}{@headers};
  }
  $statement->finish;

  return \@vals;
}

1;


