#!/usr/bin/perl
use Mojolicious::Lite;
use Mojo::IOLoop;
use Mojo::Pg;
use Mojo::UserAgent;
use List::Util 'shuffle';

app->secrets([$ENV{MOJO_SECRET}]);

helper pg => sub {
  state $pg = Mojo::Pg->new("postgresql://$ENV{DB_USER}:$ENV{DB_PASSWORD}\@$ENV{DB_HOST}/$ENV{DB_NAME}");
};

plugin 'Minion' => {
  Pg => app->pg,
};

app->minion->missing_after(3 * 60);
app->minion->repair;

app->minion->on(dequeue => sub {
  my ($job) = @_;
  warn "[$$] ", $job->id, " dequeued\n";
  $job->on(finished => sub {
    my ($job) = @_;
    warn "[$$] ", $job->id, " finished\n";
  });
  $job->on(failed => sub {
    my ($job) = @_;
    warn "[$$] ", $job->id, " failed\n";
  });
});

plugin 'Minion::Admin';
plugin 'Minion::Notifier';
plugin 'Minion::Statsd';

plugin 'Task::eSSN';
plugin 'Task::Pred';
plugin 'Task::IRIMap';
plugin 'Task::Assimilate';
plugin 'Task::BandQuality';
plugin 'Task::Render';
plugin 'Task::Cleanup';
plugin 'Task::HoldoutEvaluate';

sub prev_next {
  my $INTERVAL = 900; # 15 minutes
  my $LEAD = 300; # Run 5 minutes early, e.g. :10, :25, :40, :55

  my $now = time;
  my $prev = $now - (($now + $LEAD) % $INTERVAL);
  my $next = $prev + $INTERVAL;

  return ($prev, $next, $now);
}

sub next_run {
  my ($prev, $next, $now) = prev_next();
  my $wait = $next - $now;
  return ($next, $wait);
}

sub target_times {
  my ($run_time) = @_;

  return (
    {
      name => 'now',
      target_time => $run_time + 300,
      dots => 'curr',
    },
    map(+{
      name => "${_}h",
      target_time => $run_time + 300 + $_*3600,
      dots => 'pred',
    }, 1 .. 24),
  )
}

sub pred_times {
  my ($run_time) = @_;

  # Every 15 minutes from -1hr to +6hr; every hour from +7hr to +24hr, inclusive.
  return map({ $run_time + 300 + 900*$_ } -4 .. 24), map({ $run_time + 300 + 3600*$_ } 7 .. 24);
}


sub make_maps {
  my (%args) = @_;

  my @jobs;

  my %file_formats_by_format = (
    normal => [
      'svg',
      'station_json',
      'geojson',
    ],
    bare => [
      'jpg',
    ],
    overlay => [
      'svg',
    ],
  );

  for my $metric (qw(mufd fof2)) {
    for my $format (qw(normal bare)) {
      push @jobs, app->minion->enqueue('rendersvg',
        [
          run_id => $args{run_id},
          target => $args{target},
          metric => $metric,
          name   => $args{name},
          format => $format,
          dots   => $args{dots},
          file_format => $file_formats_by_format{$format},
        ],
        {
          parents => $args{parents},
          attempts => 2,
          expire => 18 * 60,
        }
      );
    }
  }

  return @jobs;
}

sub one_run {
  my ($run_time, $holdout_meas, $experiment, $jobs) = @_;
  my @target_times = target_times($run_time);
  my $first_target_time = $target_times[0]{target_time};

  my $holdouts = @$holdout_meas && eval {
    Mojo::UserAgent->new->inactivity_timeout(30)->post("http://localhost:$ENV{API_PORT}/holdout", form => { measurements => $holdout_meas })->result->json
  } || [];

  my @holdout_ids = map $_->{holdout}, @$holdouts;
  my @holdout_times = map $_->{ts}, @$holdouts;

  my $essn_24h = app->minion->enqueue('essn',
    [
      series => '24h',
      holdouts => [ @holdout_ids ],
    ],
    {
      attempts => 2,
      expire => 18 * 60,
    },
  );

  my $run_id = $essn_24h;
  app->pg->db->query('insert into runs (id, started, target_time, experiment, state) values (?, to_timestamp(?), to_timestamp(?), ?, ?)',
    $run_id, time(), $first_target_time, $experiment, 'created'
  );

  my $essn_6h = app->minion->enqueue('essn',
    [
      series => '6h',
    ],
    {
      expire => 18 * 60,
    },
  );

  my @pred_times = pred_times($run_time);

  for my $holdout_time (@holdout_times) {
    push @pred_times, $holdout_time unless grep { $_ == $holdout_time} @pred_times;
  }

  my $pred = app->minion->enqueue('pred',
    [
      run_id => $run_id,
      target => [ @pred_times ],
      ($jobs->{new_kernel} ? (kernels => 'new') : ()),
    ],
    {
      parents => [ $essn_24h ],
      attempts => 2,
      queue => 'pred',
      expire => 18 * 60,
    },
  );

  my @html_deps;
  my @holdout_deps;

  for my $render (@target_times) {
    my $irimap = app->minion->enqueue('irimap',
      [
        run_id => $run_id,
        target => $render->{target_time},
        series => '24h',
      ],
      {
        parents => [ $essn_24h ],
        attempts => 2,
        expire => 18 * 60,
      },
    );
    my $assimilate = app->minion->enqueue('assimilate',
      [
        run_id => $run_id,
        target => $render->{target_time},
        holdout => ($jobs->{holdout_all_timestep} ? 1 : 0),
      ],
      {
        parents => [ $pred, $irimap ],
        attempts => 2,
        expire => 18 * 60,
        queue => 'assimilate',
      },
    );
    if ($jobs->{make_maps}) {
      my @map_jobs = make_maps(
        run_id => $run_id,
        target => $render->{target_time},
        name => $render->{name},
        dots => $render->{dots},
        parents => [ $assimilate ],
      );
      push @html_deps, @map_jobs;
      push @holdout_deps, @map_jobs;
    } else {
      push @html_deps, $assimilate;
      push @holdout_deps, $assimilate;
    }

    # This is inside of the loop because of its dependence on the assimilate
    # for the same target time.
    if ($jobs->{band_quality} && $render->{target_time} == $first_target_time) {
      my $band_quality = app->minion->enqueue('band_quality',
        [
          run_id => $run_id,
          target => $render->{target_time},
        ],
        {
          parents => [ $assimilate ],
          attempts => 2,
        },
      );
      push @html_deps, $band_quality;
    }
  }

  my @finish_deps;
  if ($jobs->{renderhtml}) {
    my $renderhtml = app->minion->enqueue('renderhtml',
      [
        run_id => $run_id,
      ],
      {
        parents => [ @html_deps ],
        expire => 18 * 60,
        attempts => 2,
      },
    );
    @finish_deps = $renderhtml;
  } else {
    @finish_deps = @html_deps;
  }

  for my $holdout_time (@holdout_times) {
    my $irimap = app->minion->enqueue('irimap',
      [
        run_id => $run_id,
        target => $holdout_time,
        series => '24h',
      ],
      {
        parents => [ $essn_24h ],
        attempts => 2,
        expire => 18 * 60,
      },
    );
    my $assimilate = app->minion->enqueue('assimilate',
      [
        run_id => $run_id,
        target => $holdout_time,
        holdout => 1,
      ],
      {
        parents => [ $pred, $irimap ],
        attempts => 2,
        expire => 18 * 60,
        queue => 'assimilate',
      },
    );
    push @holdout_deps, $assimilate;
  }

  if (@$holdouts) {
    my $holdout_eval = app->minion->enqueue('holdout_evaluate',
      [
        run_id => $run_id,
      ],
      {
        parents => [ @holdout_deps ],
        attempts => 2,
        expire => 3 * 60 * 60,
      },
    );
  }

  app->minion->enqueue('finish_run',
    [
      run_id => $run_id,
    ],
    {
      parents => [ @finish_deps ],
      attempts => 2,
      expire => 3 * 60 * 60,
    },
  );
}

sub queue_job {
  my ($run_time, $resched) = @_;

  my $num_holdouts = 1;

  my $holdout_meas = $num_holdouts && eval {
    Mojo::UserAgent->new->inactivity_timeout(30)->post("http://localhost:$ENV{API_PORT}/holdout_measurements", form => { num => $num_holdouts })->result->json
  } || [];

  one_run($run_time, [], undef, {
    make_maps => 1,
    renderhtml => 1,
    band_quality => 1,
  });

  my @experiments = (
    sub {
      one_run($run_time, $holdout_meas, '2022-08-kernel-old', {
      });
    },
    sub {
      one_run($run_time, $holdout_meas, '2022-08-kernel-new', {
          new_kernel => 1,
      });
    },
  );

  $_->() for shuffle @experiments;

  app->minion->enqueue('cleanup');

  if ($resched) {
    my ($next, $wait) = next_run();
    Mojo::IOLoop->timer($wait => sub { queue_job($next, 1) });
  }
}

# Admin web and periodic job injector
my ($next, $wait) = next_run;
app->log->debug("First run in $wait seconds");
Mojo::IOLoop->timer($wait => sub { queue_job($next, 1) });

get '/run_prev' => sub {
  my $c = shift;
  my ($prev, $next, undef) = prev_next();
  queue_job($prev, 0);
  $c->render(text => "OK\n");
};

get '/run_next' => sub {
  my $c = shift;
  my ($prev, $next, undef) = prev_next();
  queue_job($next, 0);
  $c->render(text => "OK\n");
};

get '/run_now' => sub {
  my $c = shift;
  queue_job(time, 0);
  $c->render(text => "OK\n");
};

get '/cleanup_now' => sub {
  my $c = shift;
  app->minion->enqueue('cleanup');
  $c->render(text => "OK\n");
};

app->start;
