use strict;
use warnings;
no warnings 'uninitialized';
use FindBin;
use lib "$FindBin::Bin/lib";


use DBI;
use Data::Dumper;
use SQL::Abstract::Test import => [qw/is_same_sql_bind/];
use DBIx::DataModel;
use DBD::Mock 1.36;
use Test::More;


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
->Table(Employee   => T_Employee   => qw/emp_id/);


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

my @fake_data = ( [qw/emp_id firstname        lastname   /],
                  [qw/1      Johann-Sebastian Bach       /],
                  [qw/2      Hector           Berlioz    /],
                  [qw/3      Claudio          Monteverdi /] );



subtest 'categorize'=> sub {
  eval "use List::Categorize; 1"
    or plan skip_all => "List::Categorize not installed";

  $dbh->{mock_add_resultset}
    = [@fake_data,
       [qw/1 Johann-Christoph Bach/]]; # emp_id=1 on purpose, to test 2-level categ
  my $result = HR->table('Employee')->select(
    -result_as => [categorize => qw/lastname emp_id/],
   );
  is_deeply $result, {
    Monteverdi => {
      3 => [ { emp_id => '3',
               firstname => 'Claudio',
               lastname  => 'Monteverdi',   } ] },
    Bach => {
      1 => [ { emp_id    => '1',
               firstname => 'Johann-Sebastian',
               lastname  => 'Bach',         },
             { emp_id    => '1',
               firstname => 'Johann-Christoph',
               lastname  => 'Bach',         },
       ]
     },
    Berlioz => {
      2 => [ { emp_id    => '2',
               firstname => 'Hector',
               lastname  => 'Berlioz'       } ],
     }
 };
};

subtest 'fast_statement'=> sub {
  $dbh->{mock_add_resultset} = \@fake_data;
  my $result = HR->table('Employee')->select(-result_as => 'fast_statement');
  isa_ok $result, 'DBIx::DataModel::Statement';
};

subtest 'file_tabular'=> sub {
  eval "use File::Tabular; 1"
    or plan skip_all => "File::Tabular not installed";

  $dbh->{mock_add_resultset} = \@fake_data;
  open my $fh, ">", \my $in_memory;
  my $result = HR->table('Employee')->select(
    -result_as => [file_tabular => $fh, {fieldSep => "\t"}],
   );
  close $fh;
  $in_memory =~ s/\r\n/\n/g; # because of stupid binmode(:crlf) in File::Tabular
  my $expected = join "\n", (map {join "\t", @$_} @fake_data), "";
  is $in_memory, $expected, "File::Tabular file OK";
  is $result, 3,            "File::Tabular result count rows OK";
};


subtest 'firstrow'=> sub {
  $dbh->{mock_add_resultset} = \@fake_data;
  my $result = HR->table('Employee')->select(-result_as => 'firstrow');
  isa_ok $result, 'HR::Employee';
};

subtest 'flat_arrayref'=> sub {
  $dbh->{mock_add_resultset} = [map {[@{$_}[2,0]]} @fake_data];
  my $result = HR->table('Employee')->select(-columns => [qw/lastname emp_id/],
                                             -result_as => 'flat');
  my %hash = @$result;
  is_deeply \%hash, {Bach => 1, Berlioz => 2, Monteverdi => 3}, 'flat_arrayref';
};

subtest 'hashref'=> sub {
  $dbh->{mock_add_resultset} = \@fake_data;
  my $result = HR->table('Employee')->select(-columns => [qw/lastname emp_id/],
                                             -result_as => [hashref => 'lastname']);
  is_deeply [sort keys %$result], [qw/Bach Berlioz Monteverdi/], 'hashref';
};

subtest 'json'=> sub {
  eval "use JSON::MaybeXS; 1"
    or plan skip_all => "JSON::MaybeXS not installed";

  $dbh->{mock_add_resultset} = \@fake_data;
  my $json = HR->table('Employee')->select(-result_as => 'json');
  like $json, qr/lastname"?\s*:\s*"?Bach/, 'JSON';

  my @records = $json =~ m/{/g;
  is scalar(@records), 3, 'nb of records in JSON';
};

subtest 'rows'=> sub {
  $dbh->{mock_add_resultset} = \@fake_data;
  my $result = HR->table('Employee')->select(-result_as => 'rows');
  isa_ok $result->[0], 'HR::Employee', 'rows are Employees';
  is scalar(@$result), 3, '3 rows';
};

subtest 'sql'=> sub {
  $dbh->{mock_add_resultset} = \@fake_data;
  my $result = HR->table('Employee')->select(-where => {foo => 123},
                                             -result_as => 'sql');
  like $result, qr/^select\s+\*\s+from/i, 'SQL in scalar context';

  $dbh->{mock_add_resultset} = \@fake_data;
  my @result = HR->table('Employee')->select(-where => {foo => 123},
                                             -result_as => 'sql');
  like $result[0], qr/^select\s+\*\s+from/i, 'SQL in list context';
  is   $result[1], 123,                      'bind values';
};

subtest 'statement'=> sub {
  $dbh->{mock_add_resultset} = \@fake_data;
  my $result = HR->table('Employee')->select(-result_as => 'statement');
  isa_ok $result, 'DBIx::DataModel::Statement';
};

subtest 'sth'=> sub {
  $dbh->{mock_add_resultset} = \@fake_data;
  my $result = HR->table('Employee')->select(-result_as => 'sth');
  isa_ok $result, 'DBI::st';
};

subtest 'subquery'=> sub {
  $dbh->{mock_add_resultset} = \@fake_data;
  my $result = HR->table('Employee')->select(-result_as => 'subquery');
  isa_ok $$result, 'ARRAY', 'subquery: ref to arrayref';
};

subtest 'tsv'=> sub {
  open my $fh, ">", \my $in_memory;

  $dbh->{mock_add_resultset} = \@fake_data;
  my $result = HR->table('Employee')->select(
    -result_as => [tsv => $fh],
   );

  close $fh;
  my $expected = join "\n", (map {join "\t", @$_} @fake_data), "";
  is $in_memory, $expected, "Tsv file OK";
};




subtest 'xlsx'=> sub {
  eval "use Excel::Writer::XLSX; 1"
    or plan skip_all => "Excel::Writer::XLSX not installed";

  $dbh->{mock_add_resultset} = \@fake_data;
  open my $fh, ">", \my $in_memory;
  my $result = HR->table('Employee')->select(
    -result_as => [xlsx => $fh],
   );
  close $fh;
  ok $in_memory; # just checks if non-empty ... any way to test better ?
};


subtest 'yaml'=> sub {
  eval "use YAML::XS; 1"
    or plan skip_all => "YAML::XS not installed";

  $dbh->{mock_add_resultset} = \@fake_data;
  my $yaml = HR->table('Employee')->select(-result_as => 'yaml');
  like $yaml, qr/lastname:\s+Bach/, 'YAML';
  my @records = $yaml =~ m/^-\s/gm;
  is scalar(@records), 3, 'nb of records in YAML';
};


subtest 'find_subclass' => sub {
  # test a result kind as subclass of current schema
  my $result = HR->table('Employee')->select(-result_as => 'stupid');
  is $result, 'stupid', 'ResultAs subclass in current schema';


  # test loading a buggy result class
  die_ok (sub {HR->table('Employee')->select(-result_as => 'buggy')} );
};


done_testing;
