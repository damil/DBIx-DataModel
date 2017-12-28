#----------------------------------------------------------------------
package DBIx::DataModel::Schema::ResultAs::Firstrow;
#----------------------------------------------------------------------
use warnings;
use strict;

use parent 'DBIx::DataModel::Schema::ResultAs';

sub get_result {
  my ($self, $statement) = @_;

  return $statement->_next_and_finish;
}

1;


