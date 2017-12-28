#----------------------------------------------------------------------
package DBIx::DataModel::Schema::ResultAs::Subquery;
#----------------------------------------------------------------------
use warnings;
use strict;

use parent 'DBIx::DataModel::Schema::ResultAs';

sub get_result {
  my ($self, $statement) = @_;

  $statement->_forbid_callbacks(__PACKAGE__);
  $statement->sqlize if $statement->status < DBIx::DataModel::Statement::SQLIZED;

  my ($sql, @bind) = $statement->sql;
  return \ ["($sql)", @bind]; # ref to an arrayref with SQL and bind values
}

1;


