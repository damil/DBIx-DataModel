use strict;
use warnings;

use DBIx::DataModel::Schema::Generator;

use constant NTESTS  => 3;
use Test::More tests => NTESTS;


SKIP: {
  # v1.38_01 of DBD::SQLite required because it has support for foreign_key_info
  eval "use DBD::SQLite 1.38; 1"
    or skip "DBD::SQLite 1.38 does not seem to be installed", NTESTS;

  my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {
    RaiseError => 1,
    AutoCommit => 1,
    sqlite_allow_multiple_statements => 1,
  });

  $dbh->do(q{
    PRAGMA foreign_keys = ON;
    CREATE TABLE employee (
      emp_id        INTEGER PRIMARY KEY,
      emp_name      TEXT
    );
    CREATE TABLE department (
      dpt_id        INTEGER PRIMARY KEY,
      dpt_name      TEXT
    );
    CREATE TABLE activity (
      act_id        INTEGER PRIMARY KEY,
      emp_id        INTEGER NOT NULL REFERENCES employee(emp_id),
      dpt_id        INTEGER NOT NULL REFERENCES department(dpt_id)
    );
    CREATE TABLE activity_event (
      act_event_id  INTEGER PRIMARY KEY,
      act_id        INTEGER NOT NULL REFERENCES activity(act_id),
      event_text    TEXT
    );
    CREATE TABLE employee_status (
      emp_id_status INTEGER PRIMARY KEY,
      emp_id        INTEGER NOT NULL REFERENCES employee(emp_id),
      status_name   TEXT
    );
   });

  my $generator = DBIx::DataModel::Schema::Generator->new(
    -schema => 'Test::DBIDM::Schema::Generator'
   );

  my $output;
  { local *STDOUT;
    open STDOUT, ">", \$output;
    $generator->fromDBI($dbh); }

  like($output, qr{Table\(qw/Activity},      "Table Activity");
  like($output, qr{Table\(qw/ActivityEvent}, "Table ActivityEvent");
  like($output, qr{activity_events},         "Association activity_events");
}


