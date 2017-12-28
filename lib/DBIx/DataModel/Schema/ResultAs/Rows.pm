#----------------------------------------------------------------------
package DBIx::DataModel::Schema::ResultAs::Rows;
#----------------------------------------------------------------------
use warnings;
use strict;

use parent 'DBIx::DataModel::Schema::ResultAs';

sub get_result {
  my ($self, $statement) = @_;

  return $statement->all;
}

1;


