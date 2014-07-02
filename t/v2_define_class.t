use strict;
use warnings;

use Test::More tests => 10;

if (1 == 0) {
  # the line below artificially populates DBIx::DataModel::Schema namespace
  # at compile time, even if never executed. So the previous implementation
  # of Utils::define_class got tricked by this case.
  require DBIx::DataModel::Schema::Foo::Bar;
}

require DBIx::DataModel;

my $schema = DBIx::DataModel->Schema('HR');
$schema->Table(Employee   => T_Employee   => qw/emp_id/)
       ->Table(Department => T_Department => qw/dpt_id/)
       ->Table(Activity   => T_Activity   => qw/act_id/);

ok(scalar(keys %{HR::}), "class HR is defined");

# declaraton using short name
$schema->Table( 'Bar' => T_Bar => qw/id/);
ok(scalar(keys %{HR::Bar::}), "class HR::Bar is defined");
ok( $schema->table( 'Bar' ), 'Bar accessible via short name' );
ok( $schema->table( 'HR::Bar' ), 'HR::Bar accessible via full name' );

# declaraton using full name (within schema)
$schema->Table( 'HR::Foo' => T_Foo => qw/id/);
ok(scalar(keys %{HR::Foo::}), "class HR::Foo is defined");
ok( $schema->table( 'Foo' ), 'Foo accessible via short name' );
ok( $schema->table( 'HR::Foo' ), 'HR::Foo accessible via full name' );

# declaraton using full name (outside of schema)
$schema->Table( 'Space::Empty' => T_Empty => qw/id/);
ok(scalar(keys %{Space::Empty::}), "class Space::Empty is defined");
ok( !$schema->table( 'Empty' ), 'Empty is not accessible via short name' );
ok( $schema->table( 'Space::Empty' ), 'Space::Empty accessible via full name only' );
