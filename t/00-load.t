#!perl -T

use Test::More tests => 7;

BEGIN {
	use_ok( 'DBIx::DataModel' );
	use_ok( 'DBIx::DataModel::Schema' );
	use_ok( 'DBIx::DataModel::Source' );
	use_ok( 'DBIx::DataModel::Table' );
	use_ok( 'DBIx::DataModel::View' );
	use_ok( 'DBIx::DataModel::Statement' );
	use_ok( 'DBIx::DataModel::Statement::JDBC' );
}

diag( "Testing DBIx::DataModel $DBIx::DataModel::VERSION, Perl $], $^X" );
