use strict;
use warnings;

use constant NTESTS  => 3;
use Test::More tests => NTESTS;

use DBIx::DataModel -compatibility=> undef;
use DBIx::DataModel::Schema::Generator qw(fromDBI);


SKIP: {

	my $generator = DBIx::DataModel::Schema::Generator->new(-schema => 'HR');

	my $table = 'T_Employee';

	my $test = 'Convert two part table to plural';
	my $expected = 'tEmployees';
	my $plural = 1;
	my $className = DBIx::DataModel::Schema::Generator::_table2role($table, $plural);

	ok($expected eq $className, $test);

	$test = 'Convert three part table to plural';
	$expected = 'tEmployeeGroups';
	$plural = 1;
	$table = 'T_EMPLOYEE_GROUP';

	$className = DBIx::DataModel::Schema::Generator::_table2role($table, $plural);

	ok($expected eq $className, $test);

	$test = 'Leave three part table singular';
	$expected = 'tEmployeeGroup';
	$plural = 0;
	$table = 'T_EMPLOYEE_GROUP';

	$className = DBIx::DataModel::Schema::Generator::_table2role($table, $plural);

	ok($expected eq $className, $test);


}
