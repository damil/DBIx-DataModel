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

sub new {
  my ($class, $file) = @_;

  croak "-result_as => [Tsv => ...] ... target file is missing" if !$file;
  return bless {file => $file}, $class;
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
  no warnings 'uninitialized';

  my @headers   = $statement->headers;
  print $fh @headers;

  while (my $row = $statement->next) {
    print $fh @{$row}{@headers};
  }
  $statement->finish;

  return $self->{file};
}


1;


