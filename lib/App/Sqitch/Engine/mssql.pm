package App::Sqitch::Engine::mssql;

use 5.010;
use strict;
use warnings;
use utf8;
use DBI;
use Try::Tiny;
use App::Sqitch::X qw(hurl);
use Locale::TextDomain qw(App-Sqitch);
use App::Sqitch::Plan::Change;
use Path::Class;
use Moo;
use App::Sqitch::Types qw(DBH URIDB ArrayRef Str);
use namespace::autoclean;
use File::Slurp qw(read_file);

extends 'App::Sqitch::Engine';

our $VERSION = '0.999_1';

has integrated_security => (
    is      => 'ro',
    isa     => Str,
    lazy    => 1,
    default => sub {
        my $self   = shift;
        my $engine = $self->key;
        return $self->sqitch->config->get( key => "engine.$engine.integrated_security" );
    }
);

has provider => (
    is      => 'ro',
    isa     => Str,
    lazy    => 1,
    default => sub {
        my $self   = shift;
        my $engine = $self->key;
        return $self->sqitch->config->get( key => "engine.$engine.provider" );
    }
);

has registry_uri => (
    is       => 'ro',
    isa      => URIDB,
    lazy     => 1,
    required => 1,
    default  => sub {
        require URI::QueryParam;
        my $self   = shift;
        my $uri    = $self->uri->clone;
        my @fields = split /\//, $uri;
        my $db     = $fields[3];
        my @host   = split /@/, $fields[2];
        my $pwd    = $uri->password;

        # normalize params since they are case insensitive
        for my $param ( $uri->query_param ) {
            my @values = $uri->query_param_delete($param);    # does not leave $param in hash w/ no values
            $uri->query_param( lc($param) => @values );
        }

        # TODO: is this correct for all 3 $self->dbd_driver()?
        #   If so: update this comment and sqitchtutorial-mssql.pod POD to reflect that.
        #   If not: update the code to do the right thing and then update this comment and sqitchtutorial-mssql.pod POD to reflect that.
        if ( !$uri->query_param('provider') ) {
            $uri->query_param( 'provider', $self->provider ) if $self->provider;
        }
        if ( !$uri->query_param('initial catalog') ) {
            $uri->query_param( 'initial catalog', $db );
        }
        if ( !$uri->query_param('server') ) {
            $uri->query_param( 'server', $host[1] );
        }

        if ( defined $pwd ) {
            $uri->query_param( "persist security info", "False" ) unless $uri->query_param('persist security info');
        }
        else {
            # https://msdn.microsoft.com/library/ms254500(v=vs.100).aspx#Anchor_1
            my $seckey = 'integrated security';
            my $secval = $self->integrated_security || 'SSPI';

            if ( $self->provider =~ m/odbc/i ) {
                $seckey = 'trusted_connection';
                $secval = 'yes' if lc($secval) eq 'sspi' || lc($secval) eq 'true';
            }
            elsif ( $self->provider =~ m/oracleclient/i ) {
                $secval = 'yes' if lc($secval) eq 'sspi' || lc($secval) eq 'true';
            }

            $uri->query_param( $seckey, $secval ) unless $uri->query_param($seckey);
        }

        return $uri;
    },
);

sub _dt($) {
    require App::Sqitch::DateTime;
    return App::Sqitch::DateTime->new( split /:/ => shift );
}

sub _schema {
    my $self = shift;
    $self->registry . '.';
}

sub _tag_subselect_columns {
    my $self = shift;
    return join(
        ', ',
        '? AS tid',
        '? AS tname',
        '? AS proj',
        '? AS cid',
        '? AS note',
        '? AS cuser',
        '? AS cemail',
        '? AS tts',
        '? AS puser',
        '? AS pemail',
        $self->_ts_default . ' AS cat',
    );
}

sub registry_destination {
    my $uri = shift->registry_uri;
    if ( $uri->password ) {
        $uri = $uri->clone;
        $uri->password(undef);
    }
    return $uri->as_string;
}

has dbd_driver => (
    is  => 'rw',
    isa => sub { die "Driver must be one of theses DBD modules: DBD::ADO, DBD::ODBC, DBD::Sybase\n" unless $_[0] =~ m/\ADBD::(?:ADO|ODBC|Sybase)\z/ },
);

sub use_driver {
    my ($self) = @_;

    if ( $self->dbd_driver() ) {
        eval "require " . $self->dbd_driver();
        if ($@) {
            hurl $self->key => __x( "Could not load specified driver: {driver}", driver => $self->dbd_driver() );
        }
    }
    elsif ( $^O eq 'MSWin32' && try { require DBD::ADO } ) {
        $self->dbd_driver('DBD::ADO');
    }
    elsif ( try { require DBD::ODBC } ) {
        $self->dbd_driver('DBD::ODBC');
    }
    elsif ( try { require DBD::Sybase } ) {
        $self->dbd_driver('DBD::Sybase');
    }
    else {
        hurl $self->key => __x(
            'Need one of {drivers} to manage {engine}',
            drivers => 'DBD::ADO, DBD::ODBC, DBD::Sybase',
            engine  => $self->name,
        );
    }

    return $self;
}

has dbh => (
    is      => 'rw',
    isa     => DBH,
    lazy    => 1,
    default => sub {
        my $self = shift;
        $self->use_driver;

        my $uri = $self->registry_uri;

        my $driver = $self->dbd_driver;
        $driver =~ s/DBD:://;
        my $dbh = DBI->connect(
            $uri->dbi_dsn($driver),
            scalar $self->username,
            scalar $self->password,
            {
                PrintError  => 0,
                RaiseError  => 0,
                AutoCommit  => 1,
                HandleError => sub {
                    my ( $err, $dbh ) = @_;
                    $@ = $err;
                    @_ = ( $dbh->state || 'DEV' => $dbh->errstr );
                    goto &hurl;
                },
                Callbacks => {
                    connected => sub {
                        my $dbh = shift;
                        return;
                    },
                },
            }
        );

        return $dbh;
    }
);

# Need to wait until dbh is defined.
with 'App::Sqitch::Role::DBIEngine';

has _sqlcmd => (
    is         => 'ro',
    isa        => ArrayRef,
    lazy       => 1,
    required   => 1,
    auto_deref => 1,
    default    => sub {
        my $self = shift;
        my $uri  = $self->uri;

        $self->sqitch->warn(
            __x 'Database name missing in URI "{uri}"',
            uri => $uri
        ) unless $uri->dbname;

        my @ret = ( $self->client );
        for my $spec (
            [ d => $uri->dbname ],
            [ S => $uri->host ],
          ) {
            push @ret, " -$spec->[0] " => $spec->[1] if $spec->[1];
        }

        push @ret => (
            ' -E ',
        );

        return \@ret;
    },
);

sub sqlcmd { @{ shift->_sqlcmd } }

sub key  { 'mssql' }
sub name { 'MSSQL' }

sub driver {
    my ($self) = @_;
    if ( !$self->dbd_driver ) {
        $self->use_driver;    # safe because our use_driver() does not call driver()
    }
    return $self->dbd_driver;
}
sub default_client { $^O eq "MSWin32" ? 'sqlcmd.exe' : 'sqlcmd' }    # https://msdn.microsoft.com/en-us/library/hh568451.aspx

sub _char2ts {
    substr( $_[1], 0, 10 ) . ' ' . substr( $_[1], 11, 16 );
}

sub _ts2char_format {
    return q('year:'+cast(year(%1$s) as char(4))+':month:'+cast(month(%1$s) as varchar(2))+':day:'+cast(day(%1$s) as varchar(2))+':hour:'+cast(datepart(hh,%1$s) as varchar(2))+':minute:'+cast(datepart(mi,%1$s) as varchar(2))+':second:'+cast(datepart(ss,%1$s) as varchar(2))+':time_zone:UTC');
}

sub _ts_default { 'GETUTCDATE()' }

sub initialized {
    my $self = shift;

    # Try to connect.
    my $dbh = try { $self->dbh }
    catch {
        return if $DBI::err && $DBI::err == 1049;
        die $_;
    } or return 0;

    return $dbh->selectcol_arrayref(
        q{
	select count(*) FROM information_schema.schemata
	WHERE schema_name=?
    }, undef, $self->registry
    )->[0];
}

sub initialize {
    my $self  = shift;
    my $uri   = $self->uri->clone;
    my $uname = $uri->user;
    my $pwd   = $uri->password;

    # Create the Sqitch database if it does not exist.
    my $stmnt = sprintf(
        q{
        IF NOT EXISTS (
        SELECT  schema_name
        FROM    information_schema.schemata
        WHERE   schema_name = '%s' )

        BEGIN
        EXEC sp_executesql N'CREATE SCHEMA %s'
        END},
        $self->registry,
        $self->registry
    );

    my $check_stmnt = sprintf(
        "SELECT schema_name FROM information_schema.schemata WHERE schema_name = N'%s'",
        $self->registry
    );

    my $dbh = $self->dbh;
    my ($reg) = $dbh->selectrow_array($check_stmnt);

    if ( !$reg || $reg ne $self->registry ) {
        $dbh->do($stmnt);
        $self->run_upgrade( file(__FILE__)->dir->file('mssql.sql') );

        my @tables = qw(releases changes dependencies events projects tags);
        foreach my $name (@tables) {
            my $schema_stmnt = sprintf( "ALTER SCHEMA %s TRANSFER $name;", $self->registry );
            $dbh->do($schema_stmnt);
        }

        $self->_register_release;
    }
}

sub run_upgrade {
    my ( $self, $file ) = @_;
    my $file_stmnt = read_file($file);
    my $result     = $self->dbh->do($file_stmnt);
}

# Override to lock the Sqitch tables. This ensures that only one instance of
# Sqitch runs at one time.
sub begin_work {
    my $self = shift;
    my $dbh  = $self->dbh;

    # Start transaction and lock all tables to disallow concurrent changes.
    #    $dbh->do('LOCK TABLES ' . join ', ', map {
    #
    #        "$_ WRITE"
    #    } qw(changes dependencies events projects tags));
    $dbh->begin_work;
    return $self;
}

# Override to unlock the tables, otherwise future transactions on this
# connection can fail.
sub finish_work {
    my $self = shift;
    my $dbh  = $self->dbh;
    $dbh->commit;

    #   $dbh->do('UNLOCK TABLES');
    return $self;
}

sub _no_table_error {
    return $DBI::errstr && $DBI::errstr =~ /^\Qno such table:/;
}

sub _regex_op { 'REGEXP' }

sub _limit_default { '1000000' }

sub _listagg_format {
    my $self   = shift;
    my $schema = $self->_schema;
    return qq{SUBSTRING((select ' ' + %s FROM $schema changes h, $schema tags t WHERE h.change_id = c.change_id AND h.change_id = t.change_id for XML path('')),2,8000)};
}

sub _run {
    my $self = shift;
    return $self->sqitch->run( $self->sqlcmd, @_ );
}

sub _capture {
    my $self = shift;
    return $self->sqitch->capture( $self->sqlcmd, @_ );
}

sub _spool {
    my $self = shift;
    my $fh   = shift;
    return $self->sqitch->spool( $fh, $self->sqlcmd, @_ );
}

sub run_file {
    my ( $self, $file ) = @_;
    $self->_run( '-i ' => "$file" );
}

sub run_verify {
    my ( $self, $file ) = @_;

    # Suppress STDOUT unless we want extra verbosity.
    my $meth = $self->can( $self->sqitch->verbosity > 1 ? '_run' : '_capture' );
    $self->$meth( '-i ' => "$file" );
}

sub run_handle {
    my ( $self, $fh ) = @_;
    $self->_spool($fh);
}

sub _cid {
    my ( $self, $ord, $offset, $project ) = @_;
    my $schema = $self->_schema;
    return try {
        return $self->dbh->selectcol_arrayref(
            qq{
		SELECT TOP 1 change_id
		FROM $schema changes	
		WHERE project = ?
		ORDER BY committed_at $ord
}, undef, $project || $self->plan->project
        )->[0];
    }
    catch {
        return if $self->_no_table_error && !$self->initialized;
        die $_;
    };
}

sub current_state {
    my ( $self, $project ) = @_;
    my $cdtcol = sprintf $self->_ts2char_format, 'c.committed_at';
    my $pdtcol = sprintf $self->_ts2char_format, 'c.planned_at';
    my $tagcol = sprintf $self->_listagg_format, 't.tag';
    my $dbh    = $self->dbh;
    my $schema = $self->_schema;
    my $state  = $dbh->selectrow_hashref(
        qq{
        SELECT TOP 1 c.change_id
             , c.change
             , c.project
             , c.note
             , c.committer_name
             , c.committer_email
             , $cdtcol AS committed_at
             , c.planner_name
             , c.planner_email
             , $pdtcol AS planned_at
             , $tagcol AS tags
          FROM $schema changes   c
          LEFT JOIN $schema tags t ON c.change_id = t.change_id
         WHERE c.project = ?
         GROUP BY c.change_id
             , c.change
             , c.project
             , c.note
             , c.committer_name
             , c.committer_email
             , c.committed_at
             , c.planner_name
             , c.planner_email
             , c.planned_at
         ORDER BY c.committed_at DESC
    }, undef, $project // $self->plan->project
    ) or return undef;
    unless ( ref $state->{tags} ) {
        $state->{tags} = $state->{tags} ? [ split / / => $state->{tags} ] : [];
    }
    $state->{committed_at} = _dt $state->{committed_at};
    $state->{planned_at}   = _dt $state->{planned_at};
    return $state;
}

sub search_events {
    my ( $self, %p ) = @_;
    my $schema = $self->_schema;

    # Determine order direction.
    my $dir = 'DESC';
    if ( my $d = delete $p{direction} ) {
        $dir =
            $d =~ /^ASC/i  ? 'ASC'
          : $d =~ /^DESC/i ? 'DESC'
          :                  hurl 'Search direction must be either "ASC" or "DESC"';
    }

    # Limit with regular expressions?
    my ( @wheres, @params );
    my $op = $self->_regex_op;
    for my $spec (
        [ committer => 'e.committer_name' ],
        [ planner   => 'e.planner_name' ],
        [ change    => 'e.change' ],
        [ project   => 'e.project' ],
      ) {
        my $regex = delete $p{ $spec->[0] } // next;
        push @wheres => "$spec->[1] $op ?";
        push @params => $regex;
    }

    # Match events?
    if ( my $e = delete $p{event} ) {
        my ( $in, @vals ) = $self->_in_expr($e);
        push @wheres => "e.event $in";
        push @params => @vals;
    }

    # Assemble the where clause.
    my $where =
      @wheres
      ? "\n         WHERE " . join( "\n               ", @wheres )
      : '';

    # Handle remaining parameters.
    my $limits = '';
    if ( exists $p{limit} || exists $p{offset} ) {
        my $lim = delete $p{limit};
        if ($lim) {
            $limits = "\n         TOP 1";
            push @params => $lim;
        }
        if ( my $off = delete $p{offset} ) {
            if ( !$lim && ( $lim = $self->_limit_default ) ) {

                # Some drivers require LIMIT when OFFSET is set.
                $limits = "\n         LIMIT ?";
                push @params => $lim;
            }
            $limits .= "\n         OFFSET ?";
            push @params => $off;
        }
    }

    hurl 'Invalid parameters passed to search_events(): ' . join ', ', sort keys %p if %p;

    # Prepare, execute, and return.
    my $cdtcol = sprintf $self->_ts2char_format, 'e.committed_at';
    my $pdtcol = sprintf $self->_ts2char_format, 'e.planned_at';
    my $sth    = $self->dbh->prepare(
        qq{
        SELECT $limits e.event
             , e.project
             , e.change_id
             , e.change
             , e.note
             , e.requires
             , e.conflicts
             , e.tags
             , e.committer_name
             , e.committer_email
             , $cdtcol AS committed_at
             , e.planner_name
             , e.planner_email
             , $pdtcol AS planned_at
          FROM $schema events e$where
         ORDER BY e.committed_at $dir
    }
    );
    $sth->execute();
    return sub {
        my $row = $sth->fetchrow_hashref or return;
        $row->{committed_at} = _dt $row->{committed_at};
        $row->{planned_at}   = _dt $row->{planned_at};
        return $row;
    };
}

sub log_deploy_change {
    my ( $self, $change ) = @_;
    my $dbh    = $self->dbh;
    my $sqitch = $self->sqitch;
    my $schema = $self->_schema;

    my ( $id, $name, $proj, $user, $email ) = (
        $change->id,
        $change->format_name,
        $change->project,
        $sqitch->user_name,
        $sqitch->user_email
    );

    my $ts = $self->_ts_default;
    my $cols = join "\n            , ", $self->_quote_idents(
        qw(
          change_id
          change
          project
          note
          committer_name
          committer_email
          planned_at
          planner_name
          planner_email
          committed_at
          )
    );

    $dbh->{odbc_force_bind_type} = DBI::SQL_VARCHAR;

    $dbh->do(
        qq{
        INSERT INTO $schema changes (
            $cols
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, $ts)
    }, undef,
        $id,
        $name,
        $proj,
        $change->note,
        $user,
        $email,
        $self->_char2ts( $change->timestamp ),
        $change->planner_name,
        $change->planner_email,
    );

    if ( my @deps = $change->dependencies ) {
        $dbh->do(
            qq{
            INSERT INTO $schema dependencies(
                  change_id
                , type
                , dependency
                , dependency_id
           ) } . $self->_multi_values( scalar @deps, $self->_dependency_placeholders ),
            undef,
            map { ( $id, $_->type, $_->as_string, $_->resolved_id, ) } @deps
        );
    }

    if ( my @tags = $change->tags ) {
        $dbh->do(
            qq{
            INSERT INTO $schema tags (
                  tag_id
                , tag
                , project
                , change_id
                , note
                , committer_name
                , committer_email
                , planned_at
                , planner_name
                , planner_email
                , committed_at
           ) } . $self->_multi_values( scalar @tags, $self->_tag_placeholders ),
            undef,
            map { ( $_->id, $_->format_name, $proj, $id, $_->note, $user, $email, $self->_char2ts( $_->timestamp ), $_->planner_name, $_->planner_email, ) } @tags
        );
    }

    return $self->_log_event( deploy => $change );
}

sub _log_event {
    my ( $self, $event, $change, $tags, $requires, $conflicts ) = @_;
    my $dbh    = $self->dbh;
    my $sqitch = $self->sqitch;
    my $schema = $self->_schema;

    my $ts = $self->_ts_default;
    my $cols = join "\n            , ", $self->_quote_idents(
        qw(
          event
          change_id
          change
          project
          note
          tags
          requires
          conflicts
          committer_name
          committer_email
          planned_at
          planner_name
          planner_email
          committed_at
          )
    );

    $dbh->{odbc_force_bind_type} = DBI::SQL_VARCHAR;

    $dbh->do(
        qq{
        INSERT INTO $schema events (
            $cols
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, $ts)
    }, undef,
        $event,
        $change->id,
        $change->name,
        $change->project,
        $change->note,
        $tags      || $self->_log_tags_param($change),
        $requires  || $self->_log_requires_param($change),
        $conflicts || $self->_log_conflicts_param($change),
        $sqitch->user_name,
        $sqitch->user_email,
        $self->_char2ts( $change->timestamp ),
        $change->planner_name,
        $change->planner_email,
    );

    return $self;
}

sub changes_requiring_change {
    my ( $self, $change ) = @_;
    my $schema  = $self->_schema;
    my $qrystmt = $self->dbh->prepare(
        qq{
        SELECT c.change_id, c.project, c.change, (
            SELECT top 1 tag
              FROM $schema changes c2
              JOIN $schema tags ON c2.change_id = tags.change_id
             WHERE c2.project      = c.project
               AND c2.committed_at >= c.committed_at
             ORDER BY c2.committed_at
        ) AS asof_tag
          FROM $schema dependencies d
          JOIN $schema changes c ON c.change_id = d.change_id
         WHERE d.dependency_id = ?}
    );

    $qrystmt->bind_param( 1, $change->id, DBI::SQL_VARCHAR );

    $qrystmt->execute();

    return @{ $qrystmt->fetchall_arrayref( {} ) };
}

sub name_for_change_id {
    my ( $self, $change_id ) = @_;
    my $schema = $self->_schema;
    return $self->dbh->selectcol_arrayref(
        qq{
        SELECT TOP 1 c.change || COALESCE((
            SELECT tag
              FROM $schema changes c2
              JOIN $schema tags ON c2.change_id = tags.change_id
             WHERE c2.committed_at >= c.committed_at
               AND c2.project = c.project
        ), '')
          FROM $schema changes c
         WHERE change_id = ?
    }, undef, $change_id
    )->[0];
}

sub change_id_offset_from_id {
    my ( $self, $change_id, $offset ) = @_;
    my $schema = $self->_schema;

    # Just return the ID if there is no offset.
    return $change_id unless $offset;

    # Are we offset forwards or backwards?
    my ( $dir, $op ) = $offset > 0 ? ( 'ASC', '>' ) : ( 'DESC', '<' );

    $offset = abs($offset) - 1;

    my ( $offset_expr, $limit_expr ) = ( '', '' );
    $offset_expr = "WHERE RowNum > $offset";

    return $self->dbh->selectcol_arrayref(
        qq{
   	 SELECT id
   	 FROM
   	 (SELECT c.change_id AS id,
	         ROW_NUMBER() OVER (ORDER BY c.committed_at $dir) as RowNum
	           FROM $schema changes   c
	          WHERE c.project = ?
	            AND c.committed_at $op (
	                SELECT committed_at FROM sqitch.changes WHERE change_id = ?
	          )
	          ) a
         $offset_expr
    }, undef, $self->plan->project, $change_id
    )->[0];
}

sub change_offset_from_id {
    my ( $self, $change_id, $offset ) = @_;
    my $schema = $self->_schema;

    # Just return the object if there is no offset.
    return $self->load_change($change_id) unless $offset;

    # Are we offset forwards or backwards?
    my ( $dir, $op ) = $offset > 0 ? ( 'ASC', '>' ) : ( 'DESC', '<' );
    my $tscol  = sprintf $self->_ts2char_format, 'c.planned_at';
    my $tagcol = sprintf $self->_listagg_format, 't.tag';

    $offset = abs($offset) - 1;
    my ( $offset_expr, $limit_expr ) = ( '', '' );
    if ($offset) {
        $offset_expr = "WHERE RowNum > $offset";
    }

    my $change = $self->dbh->selectrow_hashref(
        qq{
    
   	 SELECT id, name, project, note, "timestamp", planner_name, planner_email, tags 
   	 FROM
   	 (SELECT c.change_id AS id, c.change AS name, c.project, c.note,
	         $tscol AS "timestamp", c.planner_name, c.planner_email, $tagcol AS tags,
	         ROW_NUMBER() OVER (ORDER BY c.committed_at $dir) as RowNum
	           FROM $schema changes   c
	           LEFT JOIN $schema tags t ON c.change_id = t.change_id
	          WHERE c.project = ?
	            AND c.committed_at $op (
	                SELECT committed_at FROM sqitch.changes WHERE change_id = ?
	          )
	          GROUP BY c.change_id, c.change, c.project, c.note, $tscol, c.planned_at,
	                c.planner_name, c.planner_email, c.committed_at) a
         $offset_expr
    }, undef, $self->plan->project, $change_id
    ) || return undef;
    $change->{timestamp} = _dt $change->{timestamp};
    unless ( ref $change->{tags} ) {
        $change->{tags} = $change->{tags} ? [ split / / => $change->{tags} ] : [];
    }
    return $change;
}

sub change_id_for {
    my ( $self, %p ) = @_;
    my $dbh    = $self->dbh;
    my $schema = $self->_schema;

    if ( my $cid = $p{change_id} ) {

        # Find by ID.
        return $dbh->selectcol_arrayref(
            qq{
            SELECT change_id
              FROM $schema changes
             WHERE change_id = ?
        }, undef, $cid
        )->[0];
    }

    my $project = $p{project} || $self->plan->project;
    if ( my $change = $p{change} ) {
        if ( my $tag = $p{tag} ) {

            # There is nothing before the first tag.
            return undef if $tag eq 'ROOT' || $tag eq 'FIRST';

            # Find closest to the end for @HEAD.
            return $self->_cid_head( $project, $change )
              if $tag eq 'HEAD' || $tag eq 'LAST';

            # Find by change name and following tag.
            my $limit = $self->_can_limit ? "\n             TOP 1" : '';
            return $dbh->selectcol_arrayref(
                qq{
                SELECT $limit changes.change_id
                  FROM $schema changes
                  JOIN $schema tags
                    ON changes.committed_at <= tags.committed_at
                   AND changes.project = tags.project
                 WHERE changes.project = ?
                   AND changes.change  = ?
                   AND tags.tag        = ?
            }, undef, $project, $change, '@' . $tag
            )->[0];
        }

        # Find earliest by change name.
        my $limit = $self->_can_limit ? "\n             TOP 1" : '';
        return $dbh->selectcol_arrayref(
            qq{
            SELECT $limit change_id
              FROM $schema changes
             WHERE project = ?
               AND changes.change  = ?
             ORDER BY changes.committed_at ASC
        }, undef, $project, $change
        )->[0];
    }

    if ( my $tag = $p{tag} ) {

        # Just return the latest for @HEAD.
        return $self->_cid( 'DESC', 0, $project )
          if $tag eq 'HEAD' || $tag eq 'LAST';

        # Just return the earliest for @ROOT.
        return $self->_cid( 'ASC', 0, $project )
          if $tag eq 'ROOT' || $tag eq 'FIRST';

        # Find by tag name.
        return $dbh->selectcol_arrayref(
            qq{
            SELECT change_id
              FROM $schema tags
             WHERE project = ?
               AND tag     = ?
        }, undef, $project, '@' . $tag
        )->[0];
    }

    # We got nothin.
    return undef;
}

sub deployed_changes_since {
    my ( $self, $change ) = @_;
    my $tscol  = sprintf $self->_ts2char_format, 'c.planned_at';
    my $tagcol = sprintf $self->_listagg_format, 't.tag';
    my $schema = $self->_schema;

    my $qrystmt = $self->dbh->prepare(
        qq{
            SELECT c.change_id AS id, c.change AS name, c.project, c.note,
                   $tscol AS "timestamp", c.planner_name, c.planner_email,
                   $tagcol AS tags
              FROM $schema changes   c
              LEFT JOIN $schema tags t ON c.change_id = t.change_id
             WHERE c.project = ?
               AND c.committed_at > (SELECT committed_at FROM sqitch.changes WHERE change_id = ?)
             GROUP BY c.change_id, c.change, c.project, c.note, c.planned_at,
                   c.planner_name, c.planner_email, c.committed_at
             ORDER BY c.committed_at ASC}
    );

    $qrystmt->bind_param( 1, $self->plan->project, DBI::SQL_VARCHAR );
    $qrystmt->bind_param( 2, $change->id,          DBI::SQL_VARCHAR );

    $qrystmt->execute();

    return map {
        $_->{timestamp} = _dt $_->{timestamp};
        unless ( ref $_->{tags} ) {
            $_->{tags} = $_->{tags} ? [ split / / => $_->{tags} ] : [];
        }
        $_;
    } @{ $qrystmt->fetchall_arrayref( {} ) };
}

1;

1;

__END__

=head1 Name

App::Sqitch::Engine::mssql - Sqitch MSSQL Engine

=head1 Synopsis

my $mssql = App::Sqitch::Engine->load( engine => 'mssql' );

=head1 Description

App::Sqitch::Engine::mssql provides the MSSQL storage engine for Sqitch.

=head2 Changing the DBD driver

App::Sqitch::Engine::mssql supports multiple DBD drivers.

You can get the current driver from:

     $mysql->dbd_driver()

If it is not set it will attempt to determine the best one to use in this order: L<DBD::ADO> on Win32 machine, L<DBD::ODBC>, L<DBD::Sybase>.

It can be set two ways:

via the new() attribute C<dbd_driver>:

   my $mssql = App::Sqitch::Engine->load( engine => 'mssql', dbd_driver => "DBD::ADO" );
   my $mssql = App::Sqitch::Engine->load( engine => 'mssql', dbd_driver => "DBD::ODBC" );
   my $mssql = App::Sqitch::Engine->load( engine => 'mssql', dbd_driver => "DBD::Sybase" );

or via the attribute method C<dbd_driver>:

   $mysql->dbd_driver("DBD::ADO");
   $mysql->dbd_driver("DBD::ODBC");
   $mysql->dbd_driver("DBD::Sybase");

Specifying any other value will also throw an exception.

Later when it is actually needed, if the given driver can not be loaded C<use_driver()> will throw an exception to that effect.

=head1 Author

David E. Wheeler <david@justatheory.com>, Brian Mckeen <brian.mckeen@nhs.net>, Dan Muey <http://drmuey.com/cpan_contact.pl>

=head1 License

Copyright (c) 2012-2015 iovation Inc.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

=cut
