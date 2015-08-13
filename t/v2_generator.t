use strict;
use warnings;

use DBIx::DataModel::Schema::Generator;

use constant NTESTS  => 17;

use Test::More tests => NTESTS;


SKIP: {
  # v1.38_* of DBD::SQLite required because it has support for foreign_key_info
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
      dpt_id        INTEGER NOT NULL REFERENCES department(dpt_id),
      supervisor    INTEGER          REFERENCES employee(emp_id)
    );
    CREATE TABLE activity_event (
      act_event_id  INTEGER PRIMARY KEY,
      act_id        INTEGER NOT NULL REFERENCES activity(act_id)
                                     ON DELETE CASCADE,
      event_text    TEXT
    );
    CREATE TABLE employee_status (
      emp_id_status INTEGER PRIMARY KEY,
      emp_id        INTEGER NOT NULL REFERENCES employee(emp_id),
      status_name   TEXT
    );

    -- two foreign keys to one reftable, one cascades
    CREATE TABLE fk_reftable_1 (
      emp_id_status INTEGER NOT NULL REFERENCES employee_status(emp_id_status),
      emp_id        INTEGER NOT NULL REFERENCES employee_status(emp_id) ON DELETE CASCADE
    );

    -- two foreign keys to one reftable, both cascade
    CREATE TABLE fk_reftable_2 (
      emp_id_status INTEGER NOT NULL REFERENCES employee_status(emp_id_status) ON DELETE CASCADE,
      emp_id        INTEGER NOT NULL REFERENCES employee_status(emp_id) ON DELETE CASCADE
    );

    -- two foreign keys to two reftables, both cascade
    CREATE TABLE fk_reftable_3 (
      emp_id_status INTEGER NOT NULL REFERENCES employee_status(emp_id_status) ON DELETE CASCADE,
      emp_id        INTEGER NOT NULL REFERENCES employee(emp_id) ON DELETE CASCADE
    );


   });

  my $generator = DBIx::DataModel::Schema::Generator->new(
    -schema => 'Test::DBIDM::Schema::Generator'
   );

  $generator->parse_DBI($dbh);
  my $perl_code = $generator->perl_code;

  sub match_entry {

      # $type, [ $class, @etc ], [ ... ], $msg
      my $msg = pop;
      my $type = quotemeta(shift);

      # match start and end of an line, depends if there are one or two lines per entry
      my ( $start, $end ) = ( @_ > 1) ? ( qr{\[qw/\s*}, qr{\s*/\]} ) : ( qr{qw/\s*}, qr{\s*/} ) ;

      my $re = join('',
		    qr{$type\s*\(\s*},
		    join( qr{\s*,\s*},  # join multiple lines
			  map {
			      join( '',
				    $start,
				    join( qr/\s+/,
					  map { defined($_) ? quotemeta( $_ )   # so multiplicity of '*' passes through
						            : qr{[^)]*?}        # undef means match to end of line (matches any char except right paren)
					      } @{$_},
					),
				    $end,
				  )
			  } @_  # iterate over lines
			),
		   );


      like( $perl_code, qr/$re/, $msg );
  }

  # ensure Tables are created
  match_entry( 'Table', [ $_, undef ], "created Table $_" )
    foreach qw[ Activity ActivityEvent Department Employee EmployeeStatus FkReftable1 ];

  match_entry( 'Association',
	       [ qw( Employee           employee            1    emp_id emp_id ) ],
	       [ qw( Activity           activities          *    supervisor emp_id ) ],
	       'Merged Association',
	     );


  match_entry( 'Association',
	       [ qw( Department         department          1    dpt_id ) ],
	       [ qw( Activity           activities          *    dpt_id ) ],
	       'Association: Department, Activity',
	     );


  match_entry( 'Composition',
	       [ qw( Activity      activity           1 act_id ) ],
	       [ qw( ActivityEvent activity_events    * act_id ) ],
	       'Composition Activity, ActivityEvent'
	     );

  match_entry( 'Association',
	       [ qw( Employee           employee            1    emp_id ) ],
	       [ qw( EmployeeStatus     employee_statuses   *    emp_id ) ],
	       'Association: Employee, EmployeeStatus',
	     );

  match_entry( 'Association',
	       [ qw( EmployeeStatus   employee_status  1    emp_id_status ) ],
	       [ qw( FkReftable1      fk_reftable_1s   *    emp_id_status ) ],
	       'Association: two foreign keys to one reftable, one cascades',
	     );

  # checks for duplicate role as well.
  match_entry( 'Composition',
	       [ qw( EmployeeStatus   employee_status_2    1    emp_id ) ],
	       [ qw( FkReftable1      fk_reftable_1s_2     *    emp_id ) ],
	       'Composition: two foreign keys to one reftable, one cascades',
	     );

  match_entry( 'Composition',
	       [ qw( EmployeeStatus   employee_status    1    emp_id emp_id_status ) ],
	       [ qw( FkReftable2      fk_reftable_2s     *    emp_id emp_id_status ) ],
	       'Merged Composition: two foreign keys to one reftable, both cascade',
	     );

  match_entry( 'Association',
	       [ qw( EmployeeStatus   employee_status    1    emp_id_status ) ],
	       [ qw( FkReftable3      fk_reftable_3s     *    emp_id_status ) ],
	       'Forced Association: two foreign keys to two reftables, both cascade (1)',
	     );


  match_entry( 'Association',
	       [ qw( Employee         employee           1    emp_id ) ],
	       [ qw( FkReftable3      fk_reftable_3s     *    emp_id ) ],
	       'Forced Association: two foreign keys to two reftables, both cascade (2)',
	     );


#  diag($perl_code);


  # Generate proper schema even if there is no association
  $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {
    RaiseError => 1,
    AutoCommit => 1,
    sqlite_allow_multiple_statements => 1,
  });
  $dbh->do(q{
    CREATE TABLE foo (foo1, foo2);
    CREATE TABLE bar (bar1, bar2, bar3);
  });
  $generator = DBIx::DataModel::Schema::Generator->new(
    -schema => 'Test::DBIDM::Schema::Generator2'
   );
  $generator->parse_DBI($dbh);
  $perl_code = $generator->perl_code;
  like($perl_code, qr{Table\(qw/Foo},             "created Table foo");
  like($perl_code, qr{Table\(qw/Bar},             "created Table bar");
}


