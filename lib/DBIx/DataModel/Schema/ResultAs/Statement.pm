#----------------------------------------------------------------------
package DBIx::DataModel::Schema::ResultAs::Statement;
#----------------------------------------------------------------------
use warnings;
use strict;

use parent 'DBIx::DataModel::Schema::ResultAs';

use namespace::clean;

sub get_result {
  my ($self, $statement) = @_;

  delete $statement->{args}{-result_as};
  return $statement;
}

1;


