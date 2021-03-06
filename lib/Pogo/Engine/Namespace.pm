package Pogo::Engine::Namespace;

# Copyright (c) 2010, Yahoo! Inc. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

use common::sense;

use List::Util qw(min max);
use Log::Log4perl qw(:easy);

use Pogo::Engine::Namespace::Slot;
use Pogo::Engine::Store qw(store);
use Pogo::Common qw(merge_hash);
use JSON qw(to_json from_json);

# Naming convention:
# get_* retrieves something synchronously
# fetch_* retrieves something asynchronously, taking an error callback
# and a continuation as the last two args

sub new
{
  my ( $class, $nsname ) = @_;
  my $self = {
    ns    => $nsname,
    path  => "/pogo/ns/$nsname",
    slots => {},
  };

  bless $self, $class;
  return $self->init;
}

sub init
{
  my $self = shift;

  my $ns = $self->{ns};
  if ( !store->exists( $self->path ) )
  {
    store->create( $self->path, '' )
      or LOGDIE "unable to create namespace '$ns': " . store->get_error;
    store->create( $self->path . '/env', '' )
      or LOGDIE "unable to create namespace '$ns': " . store->get_error;
    store->create( $self->path . '/lock', '' )
      or LOGDIE "unable to create namespace '$ns': " . store->get_error;
    store->create( $self->path . '/conf', '' )
      or LOGDIE "unable to create namespace '$ns': " . store->get_error;
  }

  return $self;
}

sub name
{
  return shift->{ns};
}

sub _has_constraints
{
  my ( $self, $app, $k ) = @_;

  # TODO: potential optimization, cache these to avoid probing storage
  if ( !defined $k )
  {
    return store->exists( $self->path( '/conf/constraints/', $app ) );
  }
  else
  {
    return store->exists( $self->path("/conf/constraints/$app/$k") );
  }

  return;
}

sub unlock_job
{
  my ( $self, $job ) = @_;

  foreach my $env ( store->get_children( $self->path('/env/') ) )
  {
    foreach my $jobhost ( store->get_children( $self->path( '/env/', $env ) ) )
    {
      my ( $host_jobid, $hostname ) = split /_/, $jobhost;
      if ( $job->id eq $host_jobid )
      {
        store->delete( $self->path("/env/$env/$jobhost") );
      }
    }
    store->delete( $self->path( '/env/', $env ) );
  }
}

# sequences

sub is_sequence_blocked
{
  my ( $self, $job, $host ) = @_;

  my ( $nblockers, @bywhat ) = (0);

  foreach my $env ( @{ $host->info->{env} } )
  {
    my $k = $env->{key};
    my $v = $env->{value};

    foreach my $app ( @{ $host->info->{apps} } )
    {
      my @preds = store->get_children( $self->path("/conf/sequences/pred/$k/$app") );
      foreach my $pred (@preds)
      {
        my $n = store->get_children( $job->{path} . "/seq/$pred" . "_$k" . "_$v" );
        if ($n)
        {
          $nblockers += $n;
          push @bywhat, "$k $v $pred";
        }
      }
    }
  }
  return ( $nblockers, join( ', ', @bywhat ) );    # cosmetic, this is what shows up in the UI
}

sub get_seq_successors
{
  my ( $self, $envk, $app ) = @_;

  my @successors = ($app);
  my @results;

  while (@successors)
  {
    $app = pop @successors;
    my @s = store->get_children( $self->path("/conf/sequences/succ/$envk/$app") );
    push @results,    @s;
    push @successors, @s;
  }

  return @results;
}

# apps

sub filter_apps
{
  my ( $self, $apps ) = @_;

  my %constraints = map { $_ => 1 } store->get_children( $self->path('/conf/constraints') );

  # FIXME: if you have sequences for which there are no constraints, we might
  # improperly ignore them here.  Can't think of a straightforward fix and
  # can't tell whether it will ever be a problem, so leaving for now.

  return [ grep { exists $constraints{$_} } @$apps ];
}

#{{{ config setters
sub set_conf
{
  my ( $self, $conf_ref ) = @_;

  # copy the conf ref, since we're going to modify the crap out of it below
  my $conf_in = { %{$conf_ref} };
  my $conf    = {};

  # flatten and merge with fail on overwrite
  foreach my $deployment_name ( keys %$conf_in )
  {
    DEBUG "processing '$deployment_name'";
    eval { $conf = _parse_deployment( $conf_in, $deployment_name, $conf_in->{$deployment_name} ); };
  }

  if ($@)
  {
    LOGDIE "couldn't load config: $@";
  }

  eval { _write_conf( $self->{path}, $conf ) };
  if ($@)
  {
    LOGDIE "couldn't load config: $@";
  }
  return $self;
}

sub _parse_deployment
{
  my ( $conf_in, $deployment_name, $data ) = @_;
  my $conf_out = {};

  foreach my $app ( keys %{ $data->{apps} } )
  {
    DEBUG "processing '$deployment_name/app/$app'";

    # provider-processing code goes here
    $conf_out->{apps}->{$app} = delete $data->{apps}->{$app};
  }

  foreach my $env ( keys %{ $data->{envs} } )
  {
    DEBUG "processing '$deployment_name/env/$env'";

    # provider-processing code goes here
    $conf_out->{envs}->{$env} = delete $data->{envs}->{$env};
  }

  my $constraints = delete $data->{constraints};
  foreach my $c_env_type ( keys %$constraints )
  {
    DEBUG "processing '$deployment_name/constraints/$c_env_type'";

    # ensure that the apps we're constraining actually exist
    my $cur = delete $constraints->{$c_env_type}->{concurrency};
    my $seq = delete $constraints->{$c_env_type}->{sequence};

    my @err = keys %{ $constraints->{$c_env_type} };

    if ( @err > 0 )
    {
      LOGDIE "unknown config parameter '$err[0]'";
    }

    # map sequences
    LOGDIE "config error: sequences expects an array"
      unless ( ref $seq eq 'ARRAY' );

    #    $conf_out->{seq}->{pred}->{$c_env_type};
    #    $conf_out->{seq}->{succ}->{$c_env_type};

    foreach my $seq_c (@$seq)
    {
      LOGDIE "config error: sequences must be arrays"
        unless ref $seq_c eq 'ARRAY';
      LOGDIE "config error: sequences must have at least two elements"
        if scalar @$seq_c < 2;

      for ( my $i = 1; $i < @$seq_c; $i++ )
      {
        my ( $first, $second ) = @{$seq_c}[ $i - 1, $i ];

        LOGDIE "unknown application '$first'"
          unless exists $conf_out->{apps}->{$first};

        LOGDIE "unknown application '$second'"
          unless exists $conf_out->{apps}->{$second};

        # $second requires $first to go first within $env
        # $first is a predecessor of $second
        # $second is a successor of $first
        # we just make sure these exist, don't define them
        $conf_out->{seq}->{pred}->{$c_env_type}->{$second}->{$first};
        $conf_out->{seq}->{succ}->{$c_env_type}->{$first}->{$second};
      }
    }

    # transform concurrency
    foreach my $cur_c (@$cur)
    {
      while ( my ( $app, $max ) = each %$cur_c )
      {
        LOGDIE "unknown application '$app'"
          unless exists $conf_out->{apps}->{$app};
        if ( $max !~ /^\d+$/ && $max !~ /^(\d+)%$/ )
        {
          LOGDIE "invalid constraint for '$app': '$max'";
        }
        $conf_out->{cur}->{$c_env_type}->{$app} = $max;
      }
    }
  }

  return $conf_out;
}

sub _write_conf
{
  my ( $path, $conf ) = @_;
  DEBUG "writing $path";

  store->delete_r("$path/conf")
    or WARN "Couldn't delete_r '$path/conf': " . store->get_error_name;
  store->create( "$path/conf", '' )
    or WARN "Couldn't create '$path/conf': " . store->get_error_name;
  _set_conf_r( "$path/conf", $conf );
}

sub _set_conf_r
{
  my ( $path, $node ) = @_;
  foreach my $k ( keys %$node )
  {
    my $v = $node->{$k};
    my $r = ref($v);
    my $p = "$path/$k";

    # that's all, folks
    if ( !$r )
    {
      store->create( $p, '' )
        or WARN "couldn't create '$p': " . store->get_error_name;
      store->set( $p, to_json( $v, { allow_nonref => 1 } ) )
        or WARN "couldn't set '$p': " . store->get_error_name;
    }
    elsif ( $r eq 'HASH' )
    {
      store->create( $p, '' )
        or WARN "couldn't create '$p': " . store->get_error_name;
      _set_conf_r( $p, $v );
    }
    elsif ( $r eq 'ARRAY' )
    {
      store->create( $p, '' )
        or WARN "couldn't create '$p': " . store->get_error_name;
      for ( my $node = 0; $node < scalar @$v; $node++ )
      {
        store->create( "$p/$node", '' )
          or WARN "couldn't create '$p/$node': " . store->get_error_name;

        store->set( "$p/$node", to_json( $v->[$node], { allow_nonref => 1 } ) )
          or WARN "couldn't set '$p/$node': " . store->get_error_name;

      }
    }
  }
}

#}}}
#{{{ config getters
# recursively traverse conf/ dir and build hash
sub _get_conf_r
{
  my $path = shift;
  my $c    = {};
  foreach my $node ( store->get_children($path) )
  {
    my $p = "$path/$node";
    my $v = store->get($p);
    if ($v)
    {
      $c->{$node} = from_json( $v, { allow_nonref => 1 } );
    }
    else
    {
      $c->{$node} = _get_conf_r($p);
    }
  }
  return $c;
}

sub get_conf
{
  my $self = shift;
  return _get_conf_r( $self->{path} . "/conf" );
}

sub get_concurrence
{
  my ( $self, $app, $key ) = @_;
  my $c = store->get( $self->{path} . "/conf/cur/$app/$key" );
  return $c;
}

sub get_concurrences
{
  my ( $self, $app ) = @_;
  my $path = $self->{path} . "/conf/cur/$app";
  my %c = map { $_ => $self->get_constraint( $app, $_ ) } store->get_children($path);

  DEBUG "constraints for $app: " . join( ",", keys %c );
  return \%c;
}

sub get_all_concurrences
{
  my $self = shift;
  my $path = $self->{path} . "/conf/cur";
  return { map { $_ => $self->get_constraints($_) } store->get_children($path) };
}

sub get_all_sequences
{
  my $self = shift;
  my $path = $self->{path} . "/conf/seq/pred";
  my %seq;
  foreach my $env ( store->get_children($path) )
  {
    my $p = "$path/$env";
    my %apps = map { $_ => [ store->get_children("$p/$_") ] } store->get_children($p);
    $seq{$env} = \%apps;
  }
  return \%seq;
}

sub get_conf_apps
{
  my ($self) = @_;
  my $path = $self->{path} . "/conf/apps";

  return _get_conf_r($path);
}

#}}}

# i'm not sure we need this if we move to the new config format
#{{{ appgroup stuff
sub translate_appgroups
{
  my ( $self, $apps ) = @_;

  my %g;

  foreach my $app (@$apps)
  {
    my @groups = store->get_children( $self->path("/conf/appgroups/byrole/$app") );
    if (@groups)
    {
      map { $g{$_} = 1 } @groups;
    }
    else
    {
      $g{$app} = 1;
    }
  }

  return [ keys %g ];
}

sub appgroup_members
{
  my ( $self, $appgroup ) = @_;

  my @members = store->get_children( $self->path("/conf/appgroups/bygroup/$appgroup") );

  return @members if @members;
  return $appgroup;
}

#}}}

# remove active host from all environments
# apparently this is deprecated?
sub unlock_host    # {{{ deprecated unlock_host
{
  my ( $self, $job, $host, $unlockseq ) = @_;

  return LOGDIE "unlock_host is deprecated";

  # iterate over /pogo/host/$host/<children>
  my $path = "/pogo/job/$host/host/$host";
  return unless store->exists($path);

  my $n = 0;
  foreach my $child ( store->get_children($path) )
  {
    next if substr( $child, 0, 1 ) eq '_';

    # get the node contents $app, $k, $v
    my $child_path = $path . '/' . $child;

    if ( substr( $child, 0, 4 ) eq 'seq_' )
    {
      next unless $unlockseq;

      # remove sequence lock
      my $node = substr( $child, 4 );
      store->delete("/pogo/job/$job/seq/$node/$host");
      if ( ( scalar store->get_children("/pogo/job/$job/seq/$node") ) == 0 )
      {
        store->delete("/pogo/job/$job/seq/$node");
      }
    }
    else
    {
      my $job_host = $job->id . '_' . $host;

      # remove environment lock
      # delete /pogo/env/$app_$k_$v
      store->delete("/pogo/env/$child/$job_host")
        or ERROR "unable to remove '/pogo/env/$child/$job_host' from '$child_path': "
        . store->get_error;

      # clean up empty env nodes
      if ( ( scalar store->get_children("/pogo/env/$child") ) == 0 )
      {
        store->delete("/pogo/env/$child");
      }
    }

    store->delete($child_path)
      or LOGDIE "unable to remove $child_path: " . store->get_error;
    $n++;
  }

  return $n;
}    # }}}

# lazy
sub path
{
  my ( $self, @parts ) = @_;
  return join( '', $self->{path}, @parts );
}

1;

=pod

=head1 NAME

  CLASSNAME - SHORT DESCRIPTION

=head1 SYNOPSIS

CODE GOES HERE

=head1 DESCRIPTION

LONG_DESCRIPTION

=head1 METHODS

B<methodexample>

=over 2

methoddescription

=back

=head1 SEE ALSO

L<Pogo::Dispatcher>

=head1 COPYRIGHT

Apache 2.0

=head1 AUTHORS

  Andrew Sloane <asloane@yahoo-inc.com>
  Michael Fischer <mfischer@yahoo-inc.com>
  Nicholas Harteau <nrh@yahoo-inc.com>
  Nick Purvis <nep@yahoo-inc.com>
  Robert Phan <rphan@yahoo-inc.com>

=cut

# vim:syn=perl:sw=2:ts=2:sts=2:et:fdm=marker
