use strict;
use warnings;
use DBI;
use SQL::Abstract::Test import => [qw/is_same_sql_bind/];
use constant N_DBI_MOCK_TESTS => 3;
use constant N_BASIC_TESTS    => 1;

use Test::More tests => (N_BASIC_TESTS + N_DBI_MOCK_TESTS);

use_ok("DBIx::DataModel", -compatibility=> 1.0);

SKIP: {
  eval "use DBD::Mock 1.36; 1"
    or skip "DBD::Mock 1.36 does not seem to be installed", N_DBI_MOCK_TESTS;

  my $dbh = DBI->connect('DBI:Mock:', '', '', {RaiseError => 1});
  sub sqlLike { # closure on $dbh
    my $msg = pop @_;    

    for (my $hist_index = -(@_ / 2); $hist_index < 0; $hist_index++) {
      my ($sql, $bind)  = (shift, shift);
      my $hist = $dbh->{mock_all_history}[$hist_index];

      is_same_sql_bind($hist->statement, $hist->bound_params,
                       $sql,             $bind, "$msg [$hist_index]");
    }
    $dbh->{mock_clear_history} = 1;
  }


  DBIx::DataModel->Schema('D1', sqlDialect => {limitOffset => "LimitOffset"})
                 ->Table(qw/T T PK/)
                 ->dbh($dbh);
  D1::T->select(-limit => 13);
  sqlLike('SELECT * FROM T LIMIT ? OFFSET ?', [13, 0], 'limitOffset');

  DBIx::DataModel->Schema('D2', sqlDialect => 'MySQL')
                 ->Table(qw/T T PK/)
                 ->dbh($dbh);
  D2::T->select(-limit => 13);
  sqlLike('SELECT * FROM T LIMIT ?, ?', [0, 13], 'limitXY');

  DBIx::DataModel->Schema('D3', sqlDialect => {limitOffset => "LimitYX"})
                 ->Table(qw/T T PK/)
                 ->dbh($dbh);
  D3::T->select(-limit => 13, -offset => 7);
  sqlLike('SELECT * FROM T LIMIT ?, ?', [13, 7], 'limitYX');
}



