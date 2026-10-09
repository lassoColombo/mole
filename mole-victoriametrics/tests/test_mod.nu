use std/assert
use std/testing *
use mole-victoriametrics

# Point mole at a throwaway config holding a victoriametrics + a prometheus connection
# (the latter so the cross-driver isolation tests have something to reject). The URL
# names a closed local port, so anything that does reach the network is refused
# instantly instead of hanging on a timeout. --env so the XDG overrides land in the
# calling test's environment.
def --env fixture [] {
  let d = (mktemp -d)
  mkdir ([$d mole] | path join)
  {connections: {
    victoriametrics: [{name: victoriametrics-local-dev, url: "http://127.0.0.1:1", token: secret}]
    prometheus:      [{name: prometheus-local-dev, url: "http://127.0.0.1:1", token: secret}]
  }}
  | to yaml
  | save --force ([$d mole connections.yaml] | path join)
  $env.XDG_CONFIG_HOME = $d
  $env.XDG_CACHE_HOME = ([$d cache] | path join)
}

# ---- select: dry-run MetricsQL assembly ---------------------------------------

@test
def "dry-run select composes metric and matchers" [] {
  fixture
  assert equal (mole-victoriametrics select up -c victoriametrics-local-dev --dry-run | get query) "up"
  assert equal (mole-victoriametrics select up job=api -c victoriametrics-local-dev --dry-run | get query) 'up{job="api"}'
  assert equal (mole-victoriametrics select up job=api env!=dev status=~5.. code!~4.. -c victoriametrics-local-dev --dry-run | get query) 'up{job="api", env!="dev", status=~"5..", code!~"4.."}'
}

@test
def "dry-run select wraps range func and aggregation" [] {
  fixture
  assert equal (mole-victoriametrics select http_requests_total job=api status=~5.. --range 5m --func rate --agg sum --by job --last 1hr --step 1min -c victoriametrics-local-dev --dry-run | get query) 'sum by (job) (rate(http_requests_total{job="api", status=~"5.."}[5m]))'
  assert equal (mole-victoriametrics select up --agg count --by job,instance -c victoriametrics-local-dev --dry-run | get query) "count by (job, instance) (up)"
}

@test
def "dry-run select without splits the comma list" [] {
  fixture
  assert equal (mole-victoriametrics select up --agg avg --without "instance, job" -c victoriametrics-local-dev --dry-run | get query) "avg without (instance, job) (up)"
}

@test
def "dry-run select quotes and escapes values" [] {
  fixture
  assert equal (mole-victoriametrics select up 'msg=hello world' -c victoriametrics-local-dev --dry-run | get query) 'up{msg="hello world"}'
  assert equal (mole-victoriametrics select up 'path=a"b' -c victoriametrics-local-dev --dry-run | get query) 'up{path="a\"b"}'
}

@test
def "select guards error" [] {
  fixture
  assert error { mole-victoriametrics select job=api -c victoriametrics-local-dev --dry-run }                            # a matcher is not a metric
  assert error { mole-victoriametrics select up --by job -c victoriametrics-local-dev --dry-run }                        # --by needs --agg
  assert error { mole-victoriametrics select up --agg sum --by job --without instance -c victoriametrics-local-dev --dry-run }
  assert error { mole-victoriametrics select up hello world -c victoriametrics-local-dev --dry-run }                     # a bare non-matcher token
}

# ---- enumeration verbs: dry-run selector assembly -----------------------------

@test
def "dry-run series composes a selector and requires one" [] {
  fixture
  assert equal (mole-victoriametrics series up -c victoriametrics-local-dev --dry-run | get query) "up"
  assert equal (mole-victoriametrics series up job=api -c victoriametrics-local-dev --dry-run | get query) 'up{job="api"}'
  assert equal (mole-victoriametrics series job=api -c victoriametrics-local-dev --dry-run | get query) '{job="api"}'
  assert error { mole-victoriametrics series -c victoriametrics-local-dev --dry-run }
}

@test
def "dry-run labels composes an optional selector" [] {
  fixture
  assert equal (mole-victoriametrics labels -c victoriametrics-local-dev --dry-run | get query) ""
  assert equal (mole-victoriametrics labels up job=node -c victoriametrics-local-dev --dry-run | get query) 'up{job="node"}'
  assert equal (mole-victoriametrics labels job=node -c victoriametrics-local-dev --dry-run | get query) '{job="node"}'
}

@test
def "dry-run label-values scopes by --metric and matchers" [] {
  fixture
  assert equal (mole-victoriametrics label-values instance --metric up job=api -c victoriametrics-local-dev --dry-run | get query) 'up{job="api"}'
  assert equal (mole-victoriametrics label-values --metric up instance job=api -c victoriametrics-local-dev --dry-run | get query) 'up{job="api"}'
  assert equal (mole-victoriametrics label-values instance --metric up -c victoriametrics-local-dev --dry-run | get query) "up"
  assert equal (mole-victoriametrics label-values instance -c victoriametrics-local-dev --dry-run | get query) ""
}

@test
def "dry-run tsdb-status and export-samples compose the selector" [] {
  fixture
  assert equal (mole-victoriametrics tsdb-status up job=api -c victoriametrics-local-dev --dry-run | get query) 'up{job="api"}'
  assert equal (mole-victoriametrics tsdb-status -c victoriametrics-local-dev --dry-run | get query) ""
  assert equal (mole-victoriametrics export-samples up job=api -c victoriametrics-local-dev --dry-run | get query) 'up{job="api"}'
  assert error { mole-victoriametrics export-samples -c victoriametrics-local-dev --dry-run }
}

# ---- connection handling ------------------------------------------------------

@test
def "dry-run redacts the token and tags the victoriametrics driver" [] {
  fixture
  let c = (mole-victoriametrics select up -c victoriametrics-local-dev --dry-run | get connection)
  assert equal ($c | columns | sort) [driver name url]
  assert equal $c.name "victoriametrics-local-dev"
  assert equal $c.driver "victoriametrics"
}

@test
def "verbs reject a cross-driver connection" [] {
  fixture
  assert error { mole-victoriametrics select up -c prometheus-local-dev --dry-run }
  assert error { mole-victoriametrics labels -c prometheus-local-dev --dry-run }
}

@test
def "set-connection rejects a non-victoriametrics connection" [] {
  fixture
  assert error { mole-victoriametrics set-connection prometheus-local-dev }
}

@test
def "set-connection accepts its own connection and mirrors it for completion" [] {
  fixture
  mole-victoriametrics set-connection victoriametrics-local-dev   # the catalog warm-up is best-effort: the closed port is refused instantly
  assert equal $env.MOLE_CURRENT.victoriametrics "victoriametrics-local-dev"
  assert equal ($env.XDG_CACHE_HOME | path join mole victoriametrics __current__.nuon | path exists) true
}
