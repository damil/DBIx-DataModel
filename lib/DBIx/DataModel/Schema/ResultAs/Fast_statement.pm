#----------------------------------------------------------------------
package DBIx::DataModel::Schema::ResultAs::Fast_statement;
#----------------------------------------------------------------------
use warnings;
use strict;

use parent 'DBIx::DataModel::Schema::ResultAs';

sub get_result {
  my ($self, $statement) = @_;

  $statement->execute;
  $statement->make_fast;
  return $statement;
}

1;


