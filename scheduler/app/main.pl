#!/usr/bin/perl
use Mojolicious::Lite;
use Mojo::IOLoop;

plugin 'Minion' => {
  Pg => "postgresql://$ENV{DB_USER}:$ENV{DB_PASSWORD}\@$ENV{DB_HOST}/$ENV{DB_NAME}",
};

plugin 'Minion::Admin';

plugin 'Task::eSSN';
plugin 'Task::Pred';
plugin 'Task::IRIMap';
plugin 'Task::Assimilate';
plugin 'Task::Render';

app->minion->add_task(hello => sub {
    my ($job, $pid) = @_;
    $job->app->log->info("Hello from $pid");
  }
);

sub next_run {
  my $INTERVAL = 900; # 15 minutes
  my $LEAD = 300; # Run 5 minutes early, e.g. :10, :25, :40, :55

  my $now = time;
  my $prev = $now - (($now + $LEAD) % $INTERVAL);
  my $next = $prev + $INTERVAL;
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
    {
      name => '6h',
      target_time => $run_time + 21900,
      dots => 'pred',
    },
  )
}

sub make_maps {
  my (%args) = @_;

  my @jobs;

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
        ],
        {
          parents => $args{parents},
          attempts => 2,
        }
      );
    }
  }

  return @jobs;
}


sub queue_job {
  my ($run_time, $resched) = @_;

  my $essn_24h = app->minion->enqueue('essn',
    [
      series => '24h',
    ],
    {
      attempts => 2,
    },
  );

  my $essn_6h = app->minion->enqueue('essn',
    [
      series => '6h',
    ],
  );

  my $run_id = $essn_24h;

  my @target_times = target_times($run_time);

  my $pred = app->minion->enqueue('pred',
    [
      run_id => $run_id,
      target => [ map $_->{target_time}, @target_times ]
    ],
    {
      attempts => 2,
    },
  );

  my @html_deps;

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
      },
    );
    my $assimilate = app->minion->enqueue('assimilate',
      [
        run_id => $run_id,
        target => $render->{target_time},
      ],
      {
        parents => [ $pred, $irimap ],
        attempts => 2,
      },
    );
    my @map_jobs = make_maps(
      run_id => $run_id,
      target => $render->{target_time},
      name => $render->{name},
      dots => $render->{dots},
      parents => [ $assimilate ],
    );
    push @html_deps, @map_jobs;
  }

  my $renderhtml = app->minion->enqueue('renderhtml',
    [
      run_id => $run_id,
    ],
    {
      parents => [ @html_deps ],
      attempts => 2,
    },
  );

  if ($resched) {
    my ($next, $wait) = next_run();
    Mojo::IOLoop->timer($wait => sub { queue_job($next, 1) });
  }
}

my $child = fork;
if (!defined $child) {
  die "Couldn't fork: $!";
}

if ($child) {
  # Admin web and periodic job injector
  my ($next, $wait) = next_run;
  app->log->debug("First run in $wait seconds");
  Mojo::IOLoop->timer($wait => sub { queue_job($next, 1) });

  get '/run_now' => sub {
    my $c = shift;
    queue_job(time, 0);
    $c->render(text => "OK");
  };

  app->start;
} else {

  app->minion->on(worker => sub { srand });
  my $worker = app->minion->worker;
  $worker->status->{dequeue_timeout} = 1;
  $worker->run;
}