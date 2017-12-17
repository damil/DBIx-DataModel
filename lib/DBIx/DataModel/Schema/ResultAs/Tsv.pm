#----------------------------------------------------------------------
package DBIx::DataModel::Schema::ResultAs::Tsv;
#----------------------------------------------------------------------
use warnings;
use strict;
use Carp::Clan       qw[^(DBIx::DataModel::|SQL::Abstract)];
use IO::Detect       qw/is_filehandle/;
use Params::Validate qw/validate SCALAR GLOBREF/;


use parent 'DBIx::DataModel::Schema::ResultAs';

use namespace::clean;

my $spec_for_new_args = {
  file => {type => SCALAR|GLOBREF, optional => 0},
};

sub new {
  my $class = shift;

  my $self = validate(@_, $spec_for_new_args);
  return bless $self, $class;
}


sub get_result {
  my ($self, $statement) = @_;

  my $fh;
  if (is_filehandle $self->{file}) {
    $fh = $self->{file};
  }
  else {
    open $fh, ">", $self->{file}
      or croak "open $self->{file} for writing : $!";
  }

  # 
  $statement->execute;
  $statement->make_fast;

  local $\ = "\n";
  local $, = "\t";


  my @headers   = $statement->headers;
  print $fh @headers;

  while (my $row = $statement->next) {
    print $fh @{$row}{@headers};
  }
  $statement->finish;

  return $self->{file};
}


1;


