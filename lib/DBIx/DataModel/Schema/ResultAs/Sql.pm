#----------------------------------------------------------------------
package DBIx::DataModel::Schema::ResultAs::Sql;
#----------------------------------------------------------------------
use warnings;
use strict;

use parent 'DBIx::DataModel::Schema::ResultAs';

sub get_result {
  my ($self, $statement) = @_;

  $statement->_forbid_callbacks(__PACKAGE__);
  $statement->sqlize if $statement->status < DBIx::DataModel::Statement::SQLIZED;

  return $statement->sql;
}

1;


