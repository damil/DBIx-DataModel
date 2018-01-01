use strict;
use warnings;
no warnings 'uninitialized';

use DBI;
use SQL::Abstract::Test import => [qw/is_same_sql_bind/];
use DBIx::DataModel;
use Test::More;
use DBD::Mock 1.36;

# die_ok : succeeds if the supplied coderef dies with an exception
sub die_ok(&) {
  my $code=shift;
  eval {$code->()};
  my $err = $@;
  $err =~ s/ at .*//;
  ok($err, $err);
}

my $schema = DBIx::DataModel->define_schema(
  class                        => 'HR', # Human Resources
  auto_update_columns          => {user_id => sub {'USER'}},
 );


HR->Table(Employee   => T_Employee   => qw/emp_id/)
  ->Table(Department => T_Department => qw/dpt_id/, {
    auto_update_columns => {user_id => sub {'USER2'}},
   })
  ->Table(Activity   => T_Activity   => qw/act_id/, {
    auto_update_columns => {user_id => undef},
   });


my $dbh = DBI->connect('DBI:Mock:FakeDB', '', '',
                       {RaiseError => 1, AutoCommit => 1});

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

HR::Employee->insert({emp_id => 1, lastname => 'Bach'});

sqlLike('INSERT INTO T_Employee (emp_id, lastname, user_id) VALUES (?, ?, ?)',
        [1, 'Bach', 'USER'],
        'insert Employee with auto_update');

HR::Department->insert({dpt_id => 1});

sqlLike('INSERT INTO T_Department (dpt_id, user_id) VALUES (?, ?)',
        [1, 'USER2'],
        'insert Department with overridden auto_update');

HR::Activity->insert({act_id => 1, emp_id => 1});

sqlLike('INSERT INTO T_Activity (act_id, emp_id) VALUES (?, ?)',
        [1, 1],
        'insert Activity without auto_update');

done_testing;


