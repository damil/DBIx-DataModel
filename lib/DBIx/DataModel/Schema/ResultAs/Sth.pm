#----------------------------------------------------------------------
package DBIx::DataModel::Schema::ResultAs::Sth;
#----------------------------------------------------------------------
use warnings;
use strict;

use parent 'DBIx::DataModel::Schema::ResultAs';

sub get_result {
  my ($self, $statement) = @_;

  $statement->execute;
  $statement->arg(-post_bless)
    or croak "-post_bless incompatible with -result_as=>'sth'";
  return $statement->sth;
}

1;


