use strict;
use warnings;
no warnings 'uninitialized';

use DBI;
use Data::Dumper;
use SQL::Abstract::Test import => [qw/is_same_sql_bind/];
use DBIx::DataModel;

use constant N_DBI_MOCK_TESTS => 11;
use constant N_BASIC_TESTS    =>  0;

use Test::More tests => (N_BASIC_TESTS + N_DBI_MOCK_TESTS);


# die_ok : succeeds if the supplied coderef dies with an exception
sub die_ok(&) {
  my $code=shift;
  eval {$code->()};
  my $err = $@;
  $err =~ s/ at .*//;
  ok($err, $err);
}

# define a small schema
DBIx::DataModel->Schema('HR') # Human Resources
->Table(Employee   => T_Employee       => qw/emp_id/)
->Table(Department => T_Department     => qw/dpt_id/)
->Table(Activity   => 'FOO.T_Activity' => qw/act_id/)
->Composition([qw/Employee   employee   1 /],
              [qw/Activity   activities * /])
->Association([qw/Department department 1 /],
              [qw/Activity   activities * /]);




SKIP: {
  eval "use DBD::Mock 1.36; 1"
    or skip "DBD::Mock 1.36 does not seem to be installed", N_DBI_MOCK_TESTS;

  my $dbh = DBI->connect('DBI:Mock:', '', '', {RaiseError => 1, AutoCommit => 1});

  # sqlLike : takes a list of SQL regex and bind params, and a test msg.
  # Checks if those match with the DBD::Mock history.

  sub sqlLike { # closure on $dbh
                # TODO : fix line number, should report the caller's line
    my $msg = pop @_;

    for (my $hist_index = -(@_ / 2); $hist_index < 0; $hist_index++) {
      my ($sql, $bind)  = (shift, shift);
      my $hist = $dbh->{mock_all_history}[$hist_index];

      is_same_sql_bind($hist->statement, $hist->bound_params,
                       $sql,             $bind, "$msg [$hist_index]");
    }
    $dbh->{mock_clear_history} = 1;
  }

  HR->dbh($dbh);

  my $rows = HR::Employee->select;
  sqlLike('SELECT * FROM T_Employee ' , [],
	  'initial select');

  HR->db_schema('DEV');
  $rows = HR::Employee->select;
  sqlLike('SELECT * FROM DEV.T_Employee ' , [],
	  'schema DEV');

  HR::Employee->insert({firstname => 'Giovanni', lastname => 'Palestrina'});
  sqlLike('INSERT INTO DEV.T_Employee (firstname, lastname) VALUES (?, ?)' ,
          ['Giovanni', 'Palestrina'],
	  'insert - DEV');

  HR::Employee->update(1, {lastname => 'Johann-Sebastian'});
  sqlLike('UPDATE DEV.T_Employee SET lastname = ? WHERE emp_id = ? ' ,
          ['Johann-Sebastian', 1],
	  'update - DEV');

  HR::Employee->delete(3);
  sqlLike('DELETE FROM DEV.T_Employee WHERE emp_id = ?' ,
          [3],
	  'delete - DEV');

  $rows = HR->join(qw/Employee activities/)->select;
  sqlLike('SELECT * FROM DEV.T_Employee '
            . 'LEFT OUTER JOIN FOO.T_Activity '
            . 'ON T_Employee.emp_id = FOO.T_Activity.emp_id',
          [],
	  'join - DEV');


  # temporary switch db_schema
  $rows = HR->with_db_schema('PRO')->table('Employee')->select;
  sqlLike('SELECT * FROM PRO.T_Employee ' , [],
	  'tmp schema PRO');

  $dbh->{mock_add_resultset} = [ [qw/dpt_id/], [123]];
  $rows = HR->with_db_schema('PRO')->join(qw/Employee activities/)->select;
  sqlLike('SELECT * FROM PRO.T_Employee '
            . 'LEFT OUTER JOIN FOO.T_Activity '
            . 'ON T_Employee.emp_id = FOO.T_Activity.emp_id',
          [],
	  'tmp schema PRO - join');

  # back to previous db_schema
  HR->table('Employee')->select;
  sqlLike('SELECT * FROM DEV.T_Employee ' , [],
	  'back to schema DEV');

  # rows from temporary db_schema still remember that db_schema
  my $dept = $rows->[0]->department();
  sqlLike('SELECT * FROM PRO.T_Department WHERE dpt_id = ?',
          [123],
          'join from record with temporary db_schema - still using PRO');



  # permanently remove db_schema
  HR->db_schema(undef);
  $rows = HR::Employee->select;
  sqlLike('SELECT * FROM T_Employee ' , [],
	  'back to initial');


}


