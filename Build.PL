use 5.006;
use strict;
use warnings;
use Module::Build;

my $builder = Module::Build->new(
    module_name         => 'DBIx::DataModel',
    license             => 'perl',
    dist_author         => 'Laurent Dami <laurent.dami AT etat.ge.ch>',
    dist_version_from   => 'lib/DBIx/DataModel.pm',
    requires => {
        'perl'          => 5.006,
        'Test::More'    => 0,
	'Carp'          => 0,
	'DBI'           => 0,
	'SQL::Abstract' => 1.61,
	'Module::Build' => 0,
        'Acme::Damn'    => 0,
        'Scalar::Util'  => 0,
	'Storable'      => 0,
    },
    build_requires => {
        'Task::Weaken'  => 0,
    },
    recommends => {
        'DBD::Mock'                   => 0,
        'Lingua::EN::Inflect::Number' => 0,
    },
    add_to_cleanup      => [ 'DBIx-DataModel-*' ],
    create_makefile_pl  => 'traditional',
);

$builder->create_build_script();



