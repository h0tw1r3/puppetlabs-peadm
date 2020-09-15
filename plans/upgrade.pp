# @summary Upgrade an Extra Large stack from one .z to the next
#
# @param compiler_pool_address 
#   The service address used by agents to connect to compilers, or the Puppet
#   service. Typically this is a load balancer.
# @param internal_compiler_a_pool_address
#   A load balancer address directing traffic to any of the "A" pool
#   compilers. This is used for DR/HA configuration in large and extra large
#   architectures.
# @param internal_compiler_b_pool_address
#   A load balancer address directing traffic to any of the "B" pool
#   compilers. This is used for DR/HA configuration in large and extra large
#   architectures.
#
plan peadm::upgrade (
  # Standard
  Peadm::SingleTargetSpec           $master_host,
  Optional[Peadm::SingleTargetSpec] $master_replica_host = undef,

  # Large
  Optional[TargetSpec]              $compiler_hosts      = undef,

  # Extra Large
  Optional[Peadm::SingleTargetSpec] $puppetdb_database_host         = undef,
  Optional[Peadm::SingleTargetSpec] $puppetdb_database_replica_host = undef,

  # Common Configuration
  String           $version,
  Optional[String] $compiler_pool_address            = undef,
  Optional[String] $internal_compiler_a_pool_address = undef,
  Optional[String] $internal_compiler_b_pool_address = undef,

  # Other
  Optional[String]      $token_file    = undef,
  String                $stagingdir    = '/tmp',
  Enum[direct,bolthost] $download_mode = 'bolthost',
) {
  peadm::validate_version($version)

  # Ensure input valid for a supported architecture
  $arch = peadm::validate_architecture(
    $master_host,
    $master_replica_host,
    $puppetdb_database_host,
    $puppetdb_database_replica_host,
    $compiler_hosts,
  )

  # Convert inputs into targets.
  $master_target                    = peadm::get_targets($master_host, 1)
  $master_replica_target            = peadm::get_targets($master_replica_host, 1)
  $puppetdb_database_target         = peadm::get_targets($puppetdb_database_host, 1)
  $puppetdb_database_replica_target = peadm::get_targets($puppetdb_database_replica_host, 1)
  $compiler_targets                 = peadm::get_targets($compiler_hosts)

  $all_targets = peadm::flatten_compact([
    $master_target,
    $puppetdb_database_target,
    $master_replica_target,
    $puppetdb_database_replica_target,
    $compiler_targets,
  ])

  $pe_installer_targets = peadm::flatten_compact([
    $master_target,
    $puppetdb_database_target,
    $puppetdb_database_replica_target,
  ])

  # Gather trusted facts from all systems
  $cert_extensions = run_task('peadm::trusted_facts', $all_targets).reduce({}) |$memo,$result| {
    $memo + { $result.target.name => $result['extensions'] }
  }

  $convert_targets = $cert_extensions.filter |$name,$exts| {
    ($name in $compiler_targets.map |$t| { $t.name }) and ($exts['pp_auth_role'] == undef)
  }.keys

  # Determine PE version currently installed on master
  $current_pe_version = run_task('peadm::read_file', $master_target,
    path => '/opt/puppetlabs/server/pe_build',
  ).first['content']

  # Ensure needed trusted facts are available
  if $cert_extensions.any |$_,$cert| {
    [peadm::oid('peadm_role'), 'pp_auth_role'].all |$ext| { $cert[$ext] == undef }
  } {
    fail_plan(@(HEREDOC/L))
      Required trusted facts are not present; upgrade cannot be completed. If \
      this infrastructure was provisioned with an old version of peadm, you may \
      need to run the peadm::convert plan\
      | HEREDOC
  }

  # Determine which compilers are associated with which HA group
  $compiler_m1_targets = $compiler_targets.filter |$target| {
    ($cert_extensions[$target.name][peadm::oid('peadm_availability_group')]
      == $cert_extensions[$master_target[0].name][peadm::oid('peadm_availability_group')])
  }

  $compiler_m2_targets = $compiler_targets.filter |$target| {
    ($cert_extensions[$target.name][peadm::oid('peadm_availability_group')]
      == $cert_extensions[$master_replica_target[0].name][peadm::oid('peadm_availability_group')])
  }

  ###########################################################################
  # PREPARATION
  ###########################################################################

  # Support for running over the orchestrator transport relies on Bolt being
  # executed from the master using the local transport. For now, fail the plan
  # if the orchestrator is being used for the master.
  $master_target.peadm::fail_on_transport('pcp')

  $platform = run_task('peadm::precheck', $master_target).first['platform']
  $tarball_filename = "puppet-enterprise-${version}-${platform}.tar.gz"
  $tarball_source   = "https://s3.amazonaws.com/pe-builds/released/${version}/${tarball_filename}"
  $upload_tarball_path = "/tmp/${tarball_filename}"

  if $download_mode == 'bolthost' {
    # Download the PE tarball on the nodes that need it
    run_plan('peadm::util::retrieve_and_upload', $pe_installer_targets,
      source      => $tarball_source,
      local_path  => "${stagingdir}/${tarball_filename}",
      upload_path => $upload_tarball_path,
    )
  } else {
    # Download PE tarballs directly to nodes that need it
    run_task('peadm::download', $pe_installer_targets,
      source => $tarball_source,
      path   => $upload_tarball_path,
    )
  }

  # Shut down Puppet on all infra targets. Avoid using the built-in service
  # task for idempotency reasons. When the orchestrator has been upgraded but
  # not all pxp-agents have, the built-in service task does not work over pcp.
  run_command('systemctl stop puppet', $all_targets)

  ###########################################################################
  # UPGRADE MASTER SIDE
  ###########################################################################

  # Shut down PuppetDB on CMs that use the PM's PDB PG. Use run_command instead
  # of run_task(service, ...) so that upgrading from 2018.1 works over PCP.
  run_command('systemctl stop pe-puppetdb', $compiler_m1_targets)

  run_task('peadm::pe_install', $puppetdb_database_target,
    tarball               => $upload_tarball_path,
    puppet_service_ensure => 'stopped',
  )

  run_task('peadm::pe_install', $master_target,
    tarball               => $upload_tarball_path,
    puppet_service_ensure => 'stopped',
  )

  # If in use, wait until orchestrator service is healthy to proceed
  if $all_targets.any |$target| { $target.protocol == 'pcp' } {
    peadm::wait_until_service_ready('orchestrator-service', $master_target)
    wait_until_available($all_targets, wait_time => 120)
  }

  # Installer-driven upgrade will de-configure auth access for compilers.
  # Re-run Puppet immediately to fully re-enable
  run_task('peadm::puppet_runonce', peadm::flatten_compact([
    $master_target,
    $puppetdb_database_target,
  ]))

  # The master could restart orchestration services again, in which case we
  # would have to wait for nodes to reconnect
  if $all_targets.any |$target| { $target.protocol == 'pcp' } {
    peadm::wait_until_service_ready('orchestrator-service', $master_target)
    wait_until_available($all_targets, wait_time => 120)
  }

  # If necessary, add missing cert extensions to compilers
  run_plan('peadm::util::add_cert_extensions', $convert_targets,
    master_host => $master_target,
    extensions  => {
      'pp_auth_role' => 'pe_compiler',
    },
  )

  # Update classification. This needs to be done now because if we don't, and
  # the PE Compiler node groups are wrong, then the compilers won't be able to
  # successfully classify and update
  apply($master_target) {
    class { 'peadm::setup::node_manager_yaml':
      master_host => $master_target.peadm::target_name(),
    }

    class { 'peadm::setup::node_manager':
      master_host                      => $master_target.peadm::target_name(),
      master_replica_host              => $master_replica_target.peadm::target_name(),
      puppetdb_database_host           => $puppetdb_database_target.peadm::target_name(),
      puppetdb_database_replica_host   => $puppetdb_database_replica_target.peadm::target_name(),
      compiler_pool_address            => $compiler_pool_address,
      internal_compiler_a_pool_address => $internal_compiler_a_pool_address,
      internal_compiler_b_pool_address => $internal_compiler_b_pool_address,
      require                          => Class['peadm::setup::node_manager_yaml'],
    }
  }

  # Upgrade the compiler group A targets
  run_task('peadm::puppet_infra_upgrade', $master_target,
    type       => 'compiler',
    targets    => $compiler_m1_targets.map |$t| { $t.peadm::target_name() },
    token_file => $token_file,
  )

  ###########################################################################
  # UPGRADE REPLICA SIDE
  ###########################################################################

  # Shut down PuppetDB on CMs that use the replica's PDB PG. Use run_command
  # instead of run_task(service, ...) so that upgrading from 2018.1 works
  # over PCP.
  run_command('systemctl stop pe-puppetdb', $compiler_m2_targets)

  run_task('peadm::pe_install', $puppetdb_database_replica_target,
    tarball               => $upload_tarball_path,
    puppet_service_ensure => 'stopped',
  )

  # Installer-driven upgrade will de-configure auth access for compilers.
  # Re-run Puppet immediately to fully re-enable.
  #
  # Because the steps following involve performing orchestrated actions and
  # `puppet infra upgrade` cannot handle orchestration services restarting,
  # also run Puppet immediately on the master.
  run_task('peadm::puppet_runonce', peadm::flatten_compact([
    $master_target,
    $puppetdb_database_replica_target,
  ]))

  # Upgrade the master replica
  run_task('peadm::puppet_infra_upgrade', $master_target,
    type       => 'replica',
    targets    => $master_replica_target.map |$t| { $t.peadm::target_name() },
    token_file => $token_file,
  )

  # Upgrade the compiler group B targets
  run_task('peadm::puppet_infra_upgrade', $master_target,
    type       => 'compiler',
    targets    => $compiler_m2_targets.map |$t| { $t.peadm::target_name() },
    token_file => $token_file,
  )

  ###########################################################################
  # FINALIZE UPGRADE
  ###########################################################################

  # Ensure Puppet running on all infrastructure targets
  run_task('service', $all_targets,
    action => 'start',
    name   => 'puppet',
  )

  return("Upgrade of Puppet Enterprise ${arch['architecture']} succeeded.")
}
